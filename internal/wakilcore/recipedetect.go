package wakilcore

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// Recipe detection (workspaces piece 2, Detect table): a draft recipe read from a repo's files with
// no model, each field carrying a note saying where it came from (Recipe.Notes). The repo's own
// entry points (bin/dev, Procfile, script/, Makefile, justfile, Taskfile) win over stack guesses.
// Nothing here runs anything or writes anything.

// DetectOptions is what detection may know about the machine.
type DetectOptions struct {
	// Managers are the runtime version managers the operator has: "mise", "asdf", "nvm".
	Managers []string `json:"managers,omitempty"`
}

// Draft is a detected recipe for one repo.
type Draft struct {
	Repo      string `json:"repo"`
	Kind      string `json:"kind"`
	Recipe    Recipe `json:"recipe"`
	DoesntRun bool   `json:"doesntRun"`
	// Why says why a repo looks like it does not run.
	Why        string           `json:"why,omitempty"`
	Runtimes   []RuntimeVersion `json:"runtimes"`
	MissingEnv []EnvSuggestion  `json:"missingEnv"`
	Hosts      []EnvHost        `json:"hosts"`
	Compose    *DraftCompose    `json:"compose,omitempty"`
	Questions  []string         `json:"questions"`
}

// RuntimeVersion is one runtime pin found in the repo.
type RuntimeVersion struct {
	Tool    string `json:"tool"`
	Version string `json:"version"`
	File    string `json:"file"`
}

// EnvSuggestion is a key the example env has and the repo's .env lacks.
type EnvSuggestion struct {
	Key     string `json:"key"`
	Example string `json:"example"`
}

// EnvHost is a host an example env points at (a database, a queue): how Draft all finds shared
// services.
type EnvHost struct {
	Key  string `json:"key"`
	Host string `json:"host"`
	File string `json:"file"`
}

// DraftCompose is what the compose file says about running twice.
type DraftCompose struct {
	File           string            `json:"file"`
	Services       []string          `json:"services"`
	AppServices    []string          `json:"appServices"`
	Variables      []ComposeVariable `json:"variables"`
	FixedPorts     []PortRemap       `json:"fixedPorts"`
	ContainerNames []ContainerName   `json:"containerNames"`
	CannotRunTwice string            `json:"cannotRunTwice,omitempty"`
}

type detector struct {
	dir   string
	repo  string
	opts  DetectOptions
	d     Draft
	r     *Recipe
	files map[string]bool
	// port is true once a process listens on $WAKIL_PORT itself.
	port bool
	// pm is the Node package manager's run prefix, when Node was found.
	pm string
}

// DetectRecipe reads dir (a repo's folder) and drafts its recipe.
func DetectRecipe(dir string, opts DetectOptions) (Draft, error) {
	st, err := os.Stat(dir)
	if err != nil {
		return Draft{}, UserError(fmt.Sprintf("cannot read %s: %v", dir, err))
	}
	if !st.IsDir() {
		return Draft{}, UserError(dir + " is not a folder")
	}
	t := &detector{dir: dir, repo: filepath.Base(filepath.Clean(dir)), opts: opts, files: map[string]bool{}}
	t.d = Draft{Repo: t.repo, Runtimes: []RuntimeVersion{}, MissingEnv: []EnvSuggestion{}, Hosts: []EnvHost{}, Questions: []string{}}
	t.r = &t.d.Recipe
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		t.files[e.Name()] = true
	}
	delete(t.files, ".git")
	delete(t.files, ".DS_Store")
	if len(t.files) == 0 {
		t.d.DoesntRun, t.d.Why, t.d.Kind = true, "an empty folder", "none"
		return t.d, nil
	}

	t.detectStack()
	t.detectCompose()
	t.detectDockerfile()
	t.detectEntryPoints()
	t.detectRuntimes()
	t.detectEnvExample()
	t.detectEnvFileWrite()

	if !t.d.DoesntRun && len(t.r.Processes) == 0 && len(t.r.Services) == 0 && t.d.Kind == "" {
		t.d.Kind = "unknown"
		t.ask("Wakil found nothing it knows how to run in %s. Write its processes by hand, or mark it doesn't run.", t.repo)
	}
	if t.d.DoesntRun {
		t.d.Recipe = Recipe{}
	}
	return t.d, nil
}

func (t *detector) has(name string) bool {
	if !strings.Contains(name, "/") {
		return t.files[name]
	}
	_, err := os.Stat(filepath.Join(t.dir, name))
	return err == nil
}

func (t *detector) read(name string) string {
	b, err := os.ReadFile(filepath.Join(t.dir, name))
	if err != nil {
		return ""
	}
	return string(b)
}

func (t *detector) firstOf(names ...string) string {
	for _, n := range names {
		if t.has(n) {
			return n
		}
	}
	return ""
}

func (t *detector) glob(pattern string) []string {
	m, _ := filepath.Glob(filepath.Join(t.dir, pattern))
	out := make([]string, 0, len(m))
	for _, p := range m {
		rel, _ := filepath.Rel(t.dir, p)
		out = append(out, rel)
	}
	sort.Strings(out)
	return out
}

func (t *detector) note(key, text string) {
	if t.r.Notes == nil {
		t.r.Notes = map[string]string{}
	}
	t.r.Notes[key] = text
}

func (t *detector) ask(format string, a ...any) {
	t.d.Questions = append(t.d.Questions, fmt.Sprintf(format, a...))
}

func (t *detector) setProcesses(note string, procs ...Process) {
	for _, p := range t.r.Processes {
		delete(t.r.Notes, "processes."+p.Name)
	}
	t.r.Processes = procs
	for _, p := range procs {
		t.note("processes."+p.Name, note)
	}
}

func (t *detector) addProcess(p Process, note string) {
	t.r.Processes = append(t.r.Processes, p)
	t.note("processes."+p.Name, note)
}

func (t *detector) setList(field string, list *[]string, note string, cmds ...string) {
	*list = cmds
	t.note(field, note)
}

func (t *detector) mapPort(variable, expr, note string) {
	if t.r.Ports == nil {
		t.r.Ports = map[string]string{}
	}
	if _, ok := t.r.Ports[variable]; ok {
		return
	}
	t.r.Ports[variable] = expr
	t.note("ports."+variable, note)
}

func (t *detector) readyURL(path, note string) {
	t.r.Ready = &Ready{URL: "http://localhost:$WAKIL_PORT" + path}
	t.note("ready", note)
}

func (t *detector) build(cmd, note string) {
	t.r.Build = ptr(cmd)
	t.note("build", note)
}

func (t *detector) clone(folder, note string) {
	for _, c := range t.r.Clone {
		if c == folder {
			return
		}
	}
	t.r.Clone = append(t.r.Clone, folder)
	if prev := t.r.Notes["clone"]; prev != "" && !strings.Contains(prev, note) {
		note = prev + ", " + note
	}
	t.note("clone", note)
}

// ---- stacks ----

func (t *detector) detectStack() {
	switch {
	case t.has("composer.json") && t.has("artisan"):
		t.laravel()
	case t.has("composer.json") && t.has("yii"):
		t.yii()
	case t.has("Gemfile") && t.has("bin/rails"):
		t.rails()
	case t.has("manage.py") || t.has("pyproject.toml") || t.has("uv.lock") || t.has("poetry.lock") || t.has("requirements.txt"):
		t.python()
	case t.has("go.mod"):
		t.golang()
	case t.has("Cargo.toml"):
		t.rust()
	case t.has("mix.exs"):
		t.elixir()
	case t.has("pom.xml"):
		t.maven()
	case t.has("build.gradle") || t.has("build.gradle.kts"):
		t.gradle()
	case len(t.glob("*.csproj")) > 0 || len(t.glob("*/*.csproj")) > 0:
		t.dotnet()
	case t.has("composer.json"):
		t.composerOnly()
	}
	if t.has("package.json") {
		t.node(t.d.Kind == "")
	}
}

type packageJSON struct {
	Scripts         map[string]string `json:"scripts"`
	Dependencies    map[string]string `json:"dependencies"`
	DevDependencies map[string]string `json:"devDependencies"`
	PackageManager  string            `json:"packageManager"`
	Private         bool              `json:"private"`
	Workspaces      json.RawMessage   `json:"workspaces"`
	Main            string            `json:"main"`
}

func (p packageJSON) dep(name string) bool {
	_, a := p.Dependencies[name]
	_, b := p.DevDependencies[name]
	return a || b
}

// node drafts a Node repo; primary is false when another stack already owns the app, so Node only
// adds its install and its node_modules.
func (t *detector) node(primary bool) {
	var pkg packageJSON
	if err := json.Unmarshal([]byte(t.read("package.json")), &pkg); err != nil {
		t.ask("package.json in %s cannot be read (%v); its scripts were not drafted.", t.repo, err)
		return
	}
	pm, lock := "npm", ""
	switch {
	case t.has("pnpm-lock.yaml"):
		pm, lock = "pnpm", "pnpm-lock.yaml"
	case t.has("yarn.lock"):
		pm, lock = "yarn", "yarn.lock"
	case t.has("bun.lockb") || t.has("bun.lock"):
		pm, lock = "bun", t.firstOf("bun.lockb", "bun.lock")
	case t.has("package-lock.json"):
		pm, lock = "npm", "package-lock.json"
	case pkg.PackageManager != "":
		pm = strings.SplitN(pkg.PackageManager, "@", 2)[0]
		lock = "package.json packageManager"
	}
	install := map[string]string{"pnpm": "pnpm install", "yarn": "yarn install", "bun": "bun install", "npm": "npm install"}[pm]
	if pm == "npm" && lock == "package-lock.json" {
		install = "npm ci"
	}
	if install == "" {
		install = pm + " install"
	}
	run := func(script string, args string) string {
		var s string
		switch pm {
		case "npm":
			s = "npm run " + script
			if args != "" {
				s += " -- " + args
			}
			return s
		case "bun":
			s = "bun run " + script
		default:
			s = pm + " " + script
		}
		if args != "" {
			s += " " + args
		}
		return s
	}
	t.pm = pm
	lockNote := lock
	if lockNote == "" {
		lockNote = "package.json (no lockfile: npm)"
	}
	t.r.Setup = append(t.r.Setup, install)
	if prev := t.r.Notes["setup"]; prev != "" {
		t.note("setup", prev+"; "+lockNote)
	} else {
		t.note("setup", lockNote)
	}
	t.clone("node_modules", "package.json")
	if !primary {
		return
	}

	framework, config, flag := "", "", ""
	switch {
	case t.firstOf("next.config.js", "next.config.mjs", "next.config.ts") != "" || pkg.dep("next"):
		framework, config, flag = "next", t.firstOf("next.config.js", "next.config.mjs", "next.config.ts"), "-p $WAKIL_PORT"
	case t.firstOf("nuxt.config.ts", "nuxt.config.js") != "" || pkg.dep("nuxt"):
		framework, config, flag = "nuxt", t.firstOf("nuxt.config.ts", "nuxt.config.js"), "--port $WAKIL_PORT"
	case t.has("angular.json"):
		framework, config, flag = "angular", "angular.json", "--port $WAKIL_PORT"
	case t.firstOf("svelte.config.js", "svelte.config.ts") != "":
		framework, config, flag = "sveltekit", t.firstOf("svelte.config.js", "svelte.config.ts"), "--port $WAKIL_PORT --strictPort"
	case t.firstOf("vite.config.ts", "vite.config.js", "vite.config.mjs", "vite.config.mts", "vite.config.cjs") != "" || pkg.dep("vite"):
		framework, config, flag = "vite", t.firstOf("vite.config.ts", "vite.config.js", "vite.config.mjs", "vite.config.mts", "vite.config.cjs"), "--port $WAKIL_PORT --strictPort"
	}
	if config == "" && framework != "" {
		config = "package.json dependency " + framework
	}
	script := ""
	for _, s := range []string{"dev", "start", "serve"} {
		if _, ok := pkg.Scripts[s]; ok {
			script = s
			break
		}
	}
	if b, ok := pkg.Scripts["build"]; ok && b != "" {
		t.build(run("build", ""), "package.json script build")
	}
	kind := framework
	if kind == "" {
		kind = "node"
	}
	t.d.Kind = kind + "-" + pm
	if script == "" {
		if framework == "" {
			t.d.DoesntRun = true
			t.d.Why = "a Node package with no dev, start or serve script"
			return
		}
		t.ask("%s uses %s but has no dev, start or serve script; write its dev server command by hand.", t.repo, framework)
		return
	}
	if framework != "" {
		t.addProcess(Process{Name: script, Command: run(script, flag)},
			fmt.Sprintf("package.json script %s; %s takes %s", script, config, flag))
	} else {
		t.addProcess(Process{Name: script, Command: run(script, "")}, "package.json script "+script)
		t.mapPort("PORT", "$WAKIL_PORT", "most Node servers read PORT")
	}
	t.port = true
	t.readyURL("/", "the dev server answering on $WAKIL_PORT")
	// A workspace of several apps run together (turbo, a workspace script) cannot share one port.
	if apps := t.workspaceApps(pkg); len(apps) > 1 {
		t.ask("%s is a workspace of %d apps (%s) run together by %s; each needs its own port. Give each app its own "+
			"process on $WAKIL_PORT, $WAKIL_PORT_1 … (its dev script with the port), or say which one serves.",
			t.repo, len(apps), strings.Join(apps, ", "), run(script, ""))
	}
}

// workspaceApps is the workspace's packages that have a dev, start or serve script, by folder:
// pnpm-workspace.yaml's packages, or package.json's workspaces (a list, or {packages}).
func (t *detector) workspaceApps(pkg packageJSON) []string {
	var globs []string
	if y := t.read("pnpm-workspace.yaml"); y != "" {
		for _, l := range strings.Split(y, "\n") {
			l = strings.TrimSpace(l)
			if strings.HasPrefix(l, "- ") {
				globs = append(globs, strings.Trim(strings.TrimSpace(l[2:]), `"'`))
			}
		}
	}
	if len(pkg.Workspaces) > 0 {
		var list []string
		if json.Unmarshal(pkg.Workspaces, &list) != nil {
			var obj struct {
				Packages []string `json:"packages"`
			}
			json.Unmarshal(pkg.Workspaces, &obj)
			list = obj.Packages
		}
		globs = append(globs, list...)
	}
	var apps []string
	for _, g := range globs {
		if strings.HasPrefix(g, "!") {
			continue
		}
		for _, f := range t.glob(strings.TrimSuffix(g, "/") + "/package.json") {
			var sub packageJSON
			if json.Unmarshal([]byte(t.read(f)), &sub) != nil {
				continue
			}
			for _, sc := range []string{"dev", "start", "serve"} {
				if _, ok := sub.Scripts[sc]; ok {
					apps = append(apps, filepath.Dir(f))
					break
				}
			}
		}
	}
	slices.Sort(apps)
	return slices.Compact(apps)
}

func (t *detector) composerRequires(name string) bool {
	var c struct {
		Require    map[string]string `json:"require"`
		RequireDev map[string]string `json:"require-dev"`
	}
	json.Unmarshal([]byte(t.read("composer.json")), &c)
	_, a := c.Require[name]
	_, b := c.RequireDev[name]
	return a || b
}

func (t *detector) laravel() {
	t.setList("setup", &t.r.Setup, "composer.json", "composer install")
	t.clone("vendor", "composer.json")
	queue, queueNote := false, ""
	if env := t.firstOf(".env.example", ".env.dist"); env != "" {
		if v, ok := parseDotEnv(t.read(env))["QUEUE_CONNECTION"]; ok && v != "sync" && v != "null" && v != "" {
			queue, queueNote = true, fmt.Sprintf("%s QUEUE_CONNECTION=%s", env, v)
		}
	}
	health := strings.Contains(t.read("bootstrap/app.php"), "health:")
	compose := FindComposeFile(t.dir)
	if t.composerRequires("laravel/sail") && compose != "" && strings.Contains(t.read(compose), "laravel.test") {
		t.d.Kind = "laravel-sail"
		sail := "./vendor/bin/sail"
		t.addProcess(Process{Name: "app", Command: sail + " up laravel.test"}, compose+" (Sail) laravel.test")
		if queue {
			// The queue needs laravel.test up (the walk: a Sail queue failed before it was).
			t.addProcess(Process{Name: "queue", Command: sail + " artisan queue:work", AfterReady: true},
				queueNote+"; it starts once the app is ready, as it needs laravel.test up")
		}
		t.setList("teardown", &t.r.Teardown, compose+" (Sail)", sail+" down")
		// A first run builds Sail's images: in setup, never under the ready timeout.
		t.setList("setup", &t.r.Setup, "composer.json; the images are built in setup, not under the ready timeout",
			"composer install", sail+" build")
		t.port = true
	} else {
		t.d.Kind = "laravel"
		t.addProcess(Process{Name: "app", Command: "php artisan serve --port=$WAKIL_PORT"}, "artisan serve takes --port")
		if queue {
			t.addProcess(Process{Name: "queue", Command: "php artisan queue:work"}, queueNote)
		}
		t.port = true
	}
	if health {
		t.readyURL("/up", "Laravel's health route in bootstrap/app.php")
	} else {
		t.readyURL("/", "the app answering on $WAKIL_PORT")
	}
}

func (t *detector) yii() {
	t.d.Kind = "yii"
	t.setList("setup", &t.r.Setup, "composer.json", "composer install")
	t.clone("vendor", "composer.json")
	t.addProcess(Process{Name: "app", Command: "php yii serve --port=$WAKIL_PORT"}, "yii serve takes --port")
	t.port = true
	t.readyURL("/", "the app answering on $WAKIL_PORT")
}

func (t *detector) composerOnly() {
	var c struct {
		Type string `json:"type"`
	}
	json.Unmarshal([]byte(t.read("composer.json")), &c)
	t.setList("setup", &t.r.Setup, "composer.json", "composer install")
	t.clone("vendor", "composer.json")
	if c.Type == "library" {
		t.d.Kind, t.d.DoesntRun, t.d.Why = "php-library", true, `a composer library (composer.json type "library"), with no entry point`
		return
	}
	t.d.Kind = "php"
	if t.has("public/index.php") {
		t.addProcess(Process{Name: "app", Command: "php -S localhost:$WAKIL_PORT -t public"}, "public/index.php, PHP's built-in server")
		t.port = true
		t.readyURL("/", "the app answering on $WAKIL_PORT")
	}
}

func (t *detector) rails() {
	t.d.Kind = "rails"
	t.setList("setup", &t.r.Setup, "Gemfile", "bundle install")
	if t.has("config/database.yml") {
		t.setList("setup", &t.r.Setup, "Gemfile; config/database.yml: the database is created and migrated in setup",
			"bundle install", "bin/rails db:prepare")
	}
	// bin/dev runs Procfile.dev; a process there that pins its port collides between workspaces.
	for _, l := range strings.Split(t.read("Procfile.dev"), "\n") {
		if m := pinnedPortPattern.FindStringSubmatch(l); m != nil {
			name, _, _ := strings.Cut(l, ":")
			t.ask("Procfile.dev's %s pins port %s, so two workspaces would collide; make it read $PORT (bin/dev passes "+
				"$WAKIL_PORT as PORT), or write its command here with $WAKIL_PORT.", strings.TrimSpace(name), m[1])
		}
	}
	t.addProcess(Process{Name: "app", Command: "bin/rails server -p $WAKIL_PORT"}, "bin/rails server takes -p")
	t.port = true
	if strings.Contains(t.read("config/routes.rb"), "rails/health") {
		t.readyURL("/up", "the health route in config/routes.rb")
	} else {
		t.readyURL("/", "the app answering on $WAKIL_PORT")
	}
}

var (
	pinnedPortPattern = regexp.MustCompile(`(?:-p|--port)[ =](\d{2,5})\b`)
	fastAPIPattern    = regexp.MustCompile(`(?m)^(\w+)\s*=\s*FastAPI\(`)
	flaskPattern      = regexp.MustCompile(`(?m)^(\w+)\s*=\s*Flask\(`)
)

func (t *detector) python() {
	mgr, prefix, note := "pip", ".venv/bin/", ""
	switch {
	case t.has("uv.lock"):
		mgr, prefix, note = "uv", "uv run ", "uv.lock"
		t.setList("setup", &t.r.Setup, note, "uv sync")
	case t.has("poetry.lock") || strings.Contains(t.read("pyproject.toml"), "[tool.poetry]"):
		mgr, prefix, note = "poetry", "poetry run ", t.firstOf("poetry.lock", "pyproject.toml")
		t.setList("setup", &t.r.Setup, note, "poetry install")
	case t.has("requirements.txt"):
		t.setList("setup", &t.r.Setup, "requirements.txt", "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt")
	case t.has("pyproject.toml"):
		mgr, prefix = "uv", "uv run "
		t.setList("setup", &t.r.Setup, "pyproject.toml (no lockfile: uv)", "uv sync")
	}
	t.clone(".venv", t.r.Notes["setup"])
	t.d.Kind = "python-" + mgr
	pyCmd := prefix + "python"
	if prefix == ".venv/bin/" {
		pyCmd = ".venv/bin/python"
	}
	if t.has("manage.py") {
		t.d.Kind = "django-" + mgr
		t.addProcess(Process{Name: "app", Command: pyCmd + " manage.py runserver 127.0.0.1:$WAKIL_PORT"}, "manage.py (Django) runserver takes the address")
		t.port = true
		t.readyURL("/", "the app answering on $WAKIL_PORT")
		return
	}
	candidates := []string{"main.py", "app.py", "app/main.py", "src/main.py", "api/main.py", "wsgi.py", "server.py"}
	candidates = append(candidates, t.glob("src/*/main.py")...)
	for _, file := range candidates {
		body := t.read(file)
		if body == "" {
			continue
		}
		module := strings.TrimSuffix(strings.ReplaceAll(file, "/", "."), ".py")
		if strings.HasPrefix(module, "src.") && file != "src/main.py" {
			module = strings.TrimPrefix(module, "src.")
		}
		if m := fastAPIPattern.FindStringSubmatch(body); m != nil {
			t.d.Kind = "fastapi-" + mgr
			t.addProcess(Process{Name: "app", Command: fmt.Sprintf("%suvicorn %s:%s --reload --port $WAKIL_PORT", prefix, module, m[1])},
				fmt.Sprintf("%s creates FastAPI() as %s; uvicorn takes --port", file, m[1]))
			t.port = true
			t.readyURL("/docs", "FastAPI's docs page on $WAKIL_PORT")
			return
		}
		if m := flaskPattern.FindStringSubmatch(body); m != nil {
			t.d.Kind = "flask-" + mgr
			t.addProcess(Process{Name: "app", Command: fmt.Sprintf("%sflask --app %s run --port $WAKIL_PORT", prefix, module)},
				fmt.Sprintf("%s creates Flask() as %s; flask run takes --port", file, m[1]))
			t.port = true
			t.readyURL("/", "the app answering on $WAKIL_PORT")
			return
		}
	}
	t.ask("%s is a Python project, but Wakil found no Django manage.py and no FastAPI or Flask app; write its process by hand, or mark it doesn't run.", t.repo)
}

func (t *detector) golang() {
	t.d.Kind = "go"
	t.setList("setup", &t.r.Setup, "go.mod", "go mod download")
	t.build("go build ./...", "go.mod")
	main := ""
	if strings.Contains(t.read("main.go"), "package main") {
		main = "."
	} else {
		var cmds []string
		for _, f := range t.glob("cmd/*/main.go") {
			cmds = append(cmds, "./"+filepath.Dir(f))
		}
		if len(cmds) > 0 {
			main = cmds[0]
			if len(cmds) > 1 {
				t.ask("%s has %d commands (%s); the draft runs %s. Pick the one that serves the app.", t.repo, len(cmds), strings.Join(cmds, ", "), main)
			}
		}
	}
	if main == "" {
		t.d.DoesntRun, t.d.Why = true, "a Go module with no main package"
		return
	}
	if t.has(".air.toml") {
		// The repo's own live reload comes before go run.
		t.addProcess(Process{Name: "app", Command: "air"}, ".air.toml: air builds and restarts the server on change")
	} else {
		t.addProcess(Process{Name: "app", Command: "go run " + main}, "package main in "+map[bool]string{true: "main.go", false: main}[main == "."])
	}
	t.mapPort("PORT", "$WAKIL_PORT", "the usual variable a Go server reads; check main reads it")
	t.port = true
}

func (t *detector) rust() {
	t.d.Kind = "rust"
	cargo := t.read("Cargo.toml")
	t.setList("setup", &t.r.Setup, "Cargo.toml", "cargo fetch")
	t.build("cargo build", "Cargo.toml")
	t.clone("target", "Cargo.toml")
	if !t.has("src/main.rs") && !strings.Contains(cargo, "[[bin]]") {
		t.d.DoesntRun, t.d.Why = true, "a Rust library (no src/main.rs, no [[bin]])"
		return
	}
	t.addProcess(Process{Name: "app", Command: "cargo run"}, map[bool]string{true: "src/main.rs", false: "Cargo.toml [[bin]]"}[t.has("src/main.rs")])
	t.mapPort("PORT", "$WAKIL_PORT", "the usual variable a Rust server reads; check main reads it")
	t.port = true
}

func (t *detector) elixir() {
	mix := t.read("mix.exs")
	t.setList("setup", &t.r.Setup, "mix.exs", "mix deps.get")
	t.clone("deps", "mix.exs")
	t.clone("_build", "mix.exs")
	if strings.Contains(mix, ":phoenix") {
		t.d.Kind = "phoenix"
		t.addProcess(Process{Name: "app", Command: "mix phx.server"}, "mix.exs depends on :phoenix")
		t.mapPort("PORT", "$WAKIL_PORT", "Phoenix's config/dev.exs reads PORT")
		t.port = true
		t.readyURL("/", "the app answering on $WAKIL_PORT")
		return
	}
	t.d.Kind = "elixir"
	t.addProcess(Process{Name: "app", Command: "mix run --no-halt"}, "mix.exs")
}

func (t *detector) springReady(build string) {
	if strings.Contains(t.read(build), "spring-boot-starter-actuator") {
		t.readyURL("/actuator/health", build+" has spring-boot-starter-actuator")
		return
	}
	t.r.Ready = &Ready{Output: `/Started \S+ in /`}
	t.note("ready", "Spring Boot's start-up line")
}

func (t *detector) maven() {
	pom := t.read("pom.xml")
	mvn := "mvn"
	if t.has("mvnw") {
		mvn = "./mvnw"
	}
	t.d.Kind = "maven"
	t.build(mvn+" package", "pom.xml")
	if !strings.Contains(pom, "spring-boot") {
		t.ask("%s builds with Maven but is not a Spring Boot app; write its process by hand, or mark it doesn't run.", t.repo)
		return
	}
	t.d.Kind = "spring-maven"
	t.addProcess(Process{Name: "app", Command: mvn + " spring-boot:run"}, "pom.xml uses spring-boot")
	t.mapPort("SERVER_PORT", "$WAKIL_PORT", "Spring Boot reads SERVER_PORT")
	t.port = true
	t.springReady("pom.xml")
}

func (t *detector) gradle() {
	file := t.firstOf("build.gradle.kts", "build.gradle")
	gradle := "gradle"
	if t.has("gradlew") {
		gradle = "./gradlew"
	}
	t.d.Kind = "gradle"
	t.build(gradle+" build", file)
	if !strings.Contains(t.read(file), "org.springframework.boot") {
		t.ask("%s builds with Gradle but is not a Spring Boot app; write its process by hand, or mark it doesn't run.", t.repo)
		return
	}
	t.d.Kind = "spring-gradle"
	t.addProcess(Process{Name: "app", Command: gradle + " bootRun"}, file+" applies org.springframework.boot")
	t.mapPort("SERVER_PORT", "$WAKIL_PORT", "Spring Boot reads SERVER_PORT")
	t.port = true
	t.springReady(file)
}

func (t *detector) dotnet() {
	projects := append(t.glob("*.csproj"), t.glob("*/*.csproj")...)
	t.d.Kind = "dotnet"
	web := ""
	for _, p := range projects {
		if strings.Contains(t.read(p), "Microsoft.NET.Sdk.Web") {
			web = p
			break
		}
	}
	main := web
	if main == "" {
		main = projects[0]
	}
	t.setList("setup", &t.r.Setup, main, "dotnet restore")
	t.build("dotnet build", main)
	if web == "" {
		t.ask("%s has no web project (Microsoft.NET.Sdk.Web); write its process by hand, or mark it doesn't run.", t.repo)
		return
	}
	cmd := "dotnet run --urls http://localhost:$WAKIL_PORT"
	if strings.Contains(web, "/") || len(projects) > 1 {
		cmd = "dotnet run --project " + web + " --urls http://localhost:$WAKIL_PORT"
	}
	t.addProcess(Process{Name: "app", Command: cmd}, web+" uses Microsoft.NET.Sdk.Web; dotnet run takes --urls")
	t.port = true
	t.readyURL("/", "the app answering on $WAKIL_PORT")
}

// ---- docker ----

func (t *detector) detectCompose() {
	file := FindComposeFile(t.dir)
	if file == "" {
		return
	}
	facts, err := ParseCompose([]byte(t.read(file)), file)
	if err != nil {
		t.ask("%s", err.Error())
		return
	}
	dc := &DraftCompose{File: file, Services: []string{}, AppServices: []string{}, FixedPorts: []PortRemap{}}
	for _, s := range facts.Services {
		if s.Build {
			dc.AppServices = append(dc.AppServices, s.Name)
		} else {
			dc.Services = append(dc.Services, s.Name)
		}
	}
	res, _ := ComposeOverride(facts, "w", t.repo, PortBlockStart, nil)
	dc.Variables, dc.ContainerNames, dc.CannotRunTwice = res.Variables, res.ContainerNames, res.CannotRunTwice
	for _, rm := range res.Remaps {
		dc.FixedPorts = append(dc.FixedPorts, PortRemap{Service: rm.Service, From: rm.From, Protocol: rm.Protocol})
	}
	t.d.Compose = dc

	sail := t.d.Kind == "laravel-sail"
	// The compose file's own port variables map into the block: $WAKIL_PORT first unless a
	// process already listens there, then $WAKIL_PORT_1….
	offset := 0
	if t.port && !sail {
		offset = 1
	}
	seen := map[string]bool{}
	var vars []ComposeVariable
	if sail {
		// Sail's app port is APP_PORT on laravel.test: it is $WAKIL_PORT.
		for _, v := range dc.Variables {
			if v.Variable == "APP_PORT" {
				vars = append(vars, v)
			}
		}
	}
	vars = append(vars, dc.Variables...)
	for _, v := range vars {
		if seen[v.Variable] {
			continue
		}
		seen[v.Variable] = true
		if offset >= PortBlockSize {
			t.ask("%s publishes more port variables than a block of %d has room for; %s was not mapped.", file, PortBlockSize, v.Variable)
			continue
		}
		expr := "$WAKIL_PORT"
		if offset > 0 {
			expr = fmt.Sprintf("$WAKIL_PORT_%d", offset)
		}
		t.mapPort(v.Variable, expr, fmt.Sprintf("%s publishes %s's port from $%s, so nothing in it is rewritten", file, v.Service, v.Variable))
		offset++
	}
	if sail {
		if len(dc.Services) > 0 {
			t.setList("services", &t.r.Services, file+" (Sail)", "./vendor/bin/sail up -d "+strings.Join(dc.Services, " "))
		}
		return
	}
	if len(dc.Services) > 0 {
		t.setList("services", &t.r.Services, file+": services with an image and no build", "docker compose up -d "+strings.Join(dc.Services, " "))
	}
	t.setList("teardown", &t.r.Teardown, file, "docker compose down")
	if t.d.Kind != "" {
		return
	}
	// No stack of its own: the compose file is the app (its build services), or only services.
	t.d.Kind = "compose"
	if len(dc.AppServices) > 0 {
		// A first run builds the app's images: in setup, never under the ready timeout.
		t.setList("setup", &t.r.Setup, file+": the app's images are built in setup, not under the ready timeout",
			"docker compose build "+strings.Join(dc.AppServices, " "))
	}
	for _, s := range dc.AppServices {
		t.addProcess(Process{Name: s, Command: "docker compose up " + s}, file+": service "+s+" builds the app")
	}
	if len(dc.AppServices) > 0 && t.r.Ports != nil {
		for _, v := range t.r.Ports {
			if v == "$WAKIL_PORT" {
				t.readyURL("/", "the app's published port")
				break
			}
		}
	}
}

func dedupeStrings(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

var exposePattern = regexp.MustCompile(`(?mi)^\s*EXPOSE\s+(\d+)`)

func (t *detector) detectDockerfile() {
	if !t.has("Dockerfile") || t.d.Kind != "" {
		return
	}
	t.d.Kind = "dockerfile"
	m := exposePattern.FindStringSubmatch(t.read("Dockerfile"))
	if m == nil {
		t.ask("%s's Dockerfile exposes no port; write how to run its container by hand.", t.repo)
		return
	}
	t.addProcess(Process{Name: "app", Command: fmt.Sprintf("docker build -t $COMPOSE_PROJECT_NAME . && docker run --rm -p $WAKIL_PORT:%s $COMPOSE_PROJECT_NAME", m[1])},
		"Dockerfile EXPOSE "+m[1]+"; the image is named for the workspace")
	t.port = true
	t.readyURL("/", "the container's port on $WAKIL_PORT")
}

// ---- the repo's own entry points ----

var (
	makeTargetPattern = regexp.MustCompile(`(?m)^([A-Za-z0-9][A-Za-z0-9_.-]*)\s*:([^=]|$)`)
	justRecipePattern = regexp.MustCompile(`(?m)^@?([A-Za-z0-9][A-Za-z0-9_-]*)(?:\s+[^:\n]*)?:([^=]|$)`)
)

type entryPoints struct {
	file    string
	runner  string
	targets []string
}

func (t *detector) detectEntryPoints() {
	if t.d.DoesntRun {
		return
	}
	// Each source in priority order, first wins per field.
	processSet, setupSet, buildSet := false, false, false
	usePort := func(note string) {
		t.mapPort("PORT", "$WAKIL_PORT", note)
		t.port = true
		if t.r.Ready == nil {
			t.readyURL("/", "the app answering on $WAKIL_PORT")
		}
	}
	if t.has("bin/dev") {
		t.setProcesses("bin/dev — the repo's own entry point", Process{Name: "dev", Command: "bin/dev"})
		usePort("bin/dev reads PORT")
		processSet = true
		if t.d.Kind == "" {
			t.d.Kind = "bin-dev"
		}
	}
	if !processSet && t.has("Procfile") {
		var procs []Process
		sc := bufio.NewScanner(strings.NewReader(t.read("Procfile")))
		usesPort := false
		for sc.Scan() {
			name, cmd, ok := strings.Cut(sc.Text(), ":")
			name, cmd = strings.TrimSpace(name), strings.TrimSpace(cmd)
			if !ok || name == "" || strings.HasPrefix(name, "#") || !recipeNamePattern.MatchString(name) {
				continue
			}
			procs = append(procs, Process{Name: name, Command: cmd})
			usesPort = usesPort || strings.Contains(cmd, "$PORT") || strings.Contains(cmd, "${PORT")
		}
		if len(procs) > 0 {
			t.setProcesses("Procfile — the repo's own entry point", procs...)
			if usesPort {
				usePort("Procfile uses $PORT")
			}
			processSet = true
			if t.d.Kind == "" {
				t.d.Kind = "procfile"
			}
		}
	}
	scriptDir := t.firstOf("script", "scripts")
	scriptFile := func(names ...string) string {
		if scriptDir == "" {
			return ""
		}
		for _, n := range names {
			for _, ext := range []string{"", ".sh"} {
				if p := scriptDir + "/" + n + ext; t.has(p) {
					return p
				}
			}
		}
		return ""
	}
	if s := scriptFile("server", "dev", "start"); s != "" && !processSet {
		t.setProcesses(s+" — the repo's own entry point", Process{Name: "app", Command: s})
		usePort(s + " — check it reads PORT")
		processSet = true
	}
	if s := scriptFile("setup", "bootstrap"); s != "" {
		t.setList("setup", &t.r.Setup, s+" — the repo's own entry point", s)
		setupSet = true
	}
	if s := scriptFile("build"); s != "" {
		t.build(s, s+" — the repo's own entry point")
		buildSet = true
	}
	if scriptDir != "" && t.d.Kind == "" && (processSet || setupSet) {
		t.d.Kind = "scripts"
	}

	var sources []entryPoints
	if f := t.firstOf("Makefile", "makefile", "GNUmakefile"); f != "" {
		sources = append(sources, entryPoints{f, "make", targetsOf(makeTargetPattern, t.read(f))})
	}
	if f := t.firstOf("justfile", "Justfile", ".justfile"); f != "" {
		sources = append(sources, entryPoints{f, "just", targetsOf(justRecipePattern, t.read(f))})
	}
	if f := t.firstOf("Taskfile.yml", "Taskfile.yaml", "taskfile.yml"); f != "" {
		sources = append(sources, entryPoints{f, "task", taskfileTasks(t.read(f))})
	}
	for _, src := range sources {
		has := map[string]bool{}
		for _, n := range src.targets {
			has[n] = true
		}
		pick := func(names ...string) string {
			for _, n := range names {
				if has[n] {
					return n
				}
			}
			return ""
		}
		if n := pick("dev", "serve", "run", "start", "up"); n != "" && !processSet {
			t.setProcesses(fmt.Sprintf("%s target %s — the repo's own entry point", src.file, n), Process{Name: "app", Command: src.runner + " " + n})
			usePort(fmt.Sprintf("%s %s — check it reads PORT", src.runner, n))
			processSet = true
		}
		if n := pick("setup", "install", "bootstrap", "deps"); n != "" && !setupSet {
			t.setList("setup", &t.r.Setup, fmt.Sprintf("%s target %s — the repo's own entry point", src.file, n), src.runner+" "+n)
			setupSet = true
		}
		if n := pick("build"); n != "" && !buildSet {
			t.build(src.runner+" "+n, fmt.Sprintf("%s target %s — the repo's own entry point", src.file, n))
			buildSet = true
		}
		if t.d.Kind == "" && (processSet || setupSet || buildSet) {
			t.d.Kind = src.runner
		}
	}
}

func targetsOf(re *regexp.Regexp, body string) []string {
	var out []string
	for _, m := range re.FindAllStringSubmatch(body, -1) {
		out = append(out, m[1])
	}
	return out
}

func taskfileTasks(body string) []string {
	var tf struct {
		Tasks yaml.Node `yaml:"tasks"`
	}
	if yaml.Unmarshal([]byte(body), &tf) != nil || tf.Tasks.Kind != yaml.MappingNode {
		return nil
	}
	var out []string
	for i := 0; i < len(tf.Tasks.Content); i += 2 {
		out = append(out, tf.Tasks.Content[i].Value)
	}
	return out
}

// ---- runtimes ----

func (t *detector) detectRuntimes() {
	add := func(tool, version, file string) {
		version = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(version), "v"))
		if version != "" {
			t.d.Runtimes = append(t.d.Runtimes, RuntimeVersion{tool, version, file})
		}
	}
	for file, tool := range map[string]string{".nvmrc": "node", ".node-version": "node", ".python-version": "python", ".ruby-version": "ruby"} {
		if t.has(file) {
			add(tool, strings.SplitN(t.read(file), "\n", 2)[0], file)
		}
	}
	if t.has(".tool-versions") {
		sc := bufio.NewScanner(strings.NewReader(t.read(".tool-versions")))
		for sc.Scan() {
			f := strings.Fields(sc.Text())
			if len(f) >= 2 && !strings.HasPrefix(f[0], "#") {
				add(f[0], f[1], ".tool-versions")
			}
		}
	}
	if f := t.firstOf("mise.toml", ".mise.toml"); f != "" {
		inTools := false
		sc := bufio.NewScanner(strings.NewReader(t.read(f)))
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if strings.HasPrefix(line, "[") {
				inTools = line == "[tools]"
				continue
			}
			if k, v, ok := strings.Cut(line, "="); ok && inTools {
				add(strings.Trim(strings.TrimSpace(k), `"`), strings.Trim(strings.TrimSpace(v), `"'`), f)
			}
		}
	}
	sort.Slice(t.d.Runtimes, func(i, j int) bool {
		a, b := t.d.Runtimes[i], t.d.Runtimes[j]
		if a.File != b.File {
			return a.File < b.File
		}
		return a.Tool < b.Tool
	})
	if len(t.d.Runtimes) == 0 || t.d.DoesntRun {
		return
	}
	has := map[string]bool{}
	for _, m := range t.opts.Managers {
		has[m] = true
	}
	files := map[string]bool{}
	for _, r := range t.d.Runtimes {
		files[r.File] = true
	}
	var cmd, why string
	switch {
	case has["mise"]:
		cmd, why = "mise install", "mise is installed and reads the repo's version files"
	case has["asdf"] && files[".tool-versions"]:
		cmd, why = "asdf install", "asdf is installed and reads .tool-versions"
	case has["nvm"] && (files[".nvmrc"] || files[".node-version"]):
		cmd, why = "nvm install", "nvm is installed and reads .nvmrc"
	default:
		var pins []string
		for _, r := range t.d.Runtimes {
			pins = append(pins, fmt.Sprintf("%s %s (%s)", r.Tool, r.Version, r.File))
		}
		t.ask("%s pins %s, but none of mise, asdf or nvm was found; install those versions by hand, or install a version manager.", t.repo, strings.Join(pins, ", "))
		return
	}
	t.r.Setup = append([]string{cmd}, t.r.Setup...)
	if prev := t.r.Notes["setup"]; prev != "" {
		why = why + "; " + prev
	}
	t.note("setup", why)
}

// ---- env ----

var hostKeyPattern = regexp.MustCompile(`(^|_)HOST$`)

// sourcesDotEnv matches a script line that reads .env itself: `. ./.env`, `source .env`,
// `export $(cat .env …)`, `< .env`.
var sourcesDotEnv = regexp.MustCompile(`(?m)(^|[\s;&|(])(\.|source)\s+["']?(\./)?\.env["']?(\s|;|$)|\$\(\s*cat\s+["']?(\./)?\.env\b|<\s*["']?(\./)?\.env["']?(\s|;|$)`)

// detectEnvFileWrite turns on writing the mapped ports into the copy's .env when what runs reads
// .env itself (the walk: Sail's script sources it, so the copied APP_PORT=8001 beat the exported
// $WAKIL_PORT and the app answered only on 8001). The writer replaces the copy's own lines.
func (t *detector) detectEnvFileWrite() {
	if t.d.DoesntRun || len(t.r.Ports) == 0 {
		return
	}
	reader := ""
	if t.d.Kind == "laravel-sail" {
		reader = "Sail's script"
	}
	for _, p := range t.r.Processes {
		if reader != "" {
			break
		}
		fields := strings.Fields(p.Command)
		if len(fields) > 1 && (fields[0] == "sh" || fields[0] == "bash" || fields[0] == "zsh") {
			fields = fields[1:]
		}
		if len(fields) == 0 {
			continue
		}
		script := strings.TrimPrefix(fields[0], "./")
		if strings.Contains(script, "..") || filepath.IsAbs(script) {
			continue
		}
		if body := t.read(script); body != "" && sourcesDotEnv.MatchString(body) {
			reader = script
		}
	}
	if reader == "" {
		return
	}
	on := true
	t.r.AlsoWriteEnvFile = &on
	t.note("alsoWriteEnvFile", reader+" reads .env itself, so the copy's .env is given the mapped ports; else its own lines win over Wakil's")
}

func (t *detector) detectEnvExample() {
	example := t.firstOf(".env.example", ".env.dist", ".env.sample")
	var copies []string
	for _, f := range t.glob(".env*") {
		if f != ".env.example" && f != ".env.dist" && f != ".env.sample" {
			copies = append(copies, f)
		}
	}
	if t.has(".worktreeinclude") {
		sc := bufio.NewScanner(strings.NewReader(t.read(".worktreeinclude")))
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line != "" && !strings.HasPrefix(line, "#") && !strings.HasPrefix(line, "!") {
				copies = append(copies, line)
			}
		}
	}
	copies = dedupeStrings(copies)
	if len(copies) > 0 && !t.d.DoesntRun {
		why := "the ignored env files in your folder"
		if t.has(".worktreeinclude") {
			why += " and .worktreeinclude"
		}
		t.setList("copy", &t.r.Copy, why, copies...)
	}
	if example == "" {
		return
	}
	keys, values := orderedDotEnv(t.read(example))
	have := parseDotEnv(t.read(".env"))
	for _, k := range keys {
		if _, ok := have[k]; !ok {
			t.d.MissingEnv = append(t.d.MissingEnv, EnvSuggestion{k, values[k]})
		}
		v := values[k]
		host := ""
		if hostKeyPattern.MatchString(k) {
			host = v
		} else if u, err := url.Parse(v); err == nil && u.Host != "" && strings.Contains(v, "://") {
			host = u.Hostname()
		}
		switch strings.ToLower(host) {
		case "", "localhost", "127.0.0.1", "0.0.0.0", "::1":
			continue
		}
		t.d.Hosts = append(t.d.Hosts, EnvHost{k, host, example})
	}
}

// orderedDotEnv reads KEY=value lines in file order (comments, export and quotes handled).
func orderedDotEnv(body string) ([]string, map[string]string) {
	var keys []string
	values := map[string]string{}
	sc := bufio.NewScanner(strings.NewReader(body))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		k = strings.TrimSpace(k)
		if !ok || !envNamePattern.MatchString(k) {
			continue
		}
		v = strings.TrimSpace(v)
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			v = v[1 : len(v)-1]
		} else if i := strings.Index(v, " #"); i >= 0 {
			v = strings.TrimSpace(v[:i])
		}
		if _, seen := values[k]; !seen {
			keys = append(keys, k)
		}
		values[k] = v
	}
	return keys, values
}

func parseDotEnv(body string) map[string]string {
	_, v := orderedDotEnv(body)
	return v
}
