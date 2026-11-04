package wakilcore

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// Try across real app stacks (Workspaces, piece 2): each test makes a tiny runnable app in a temp
// folder (no network installs), saves a recipe for it, and runs the real Try — prepare, services,
// setup, the processes, ready on $WAKIL_PORT, then the processes stopped and teardown run. They run
// under `make test-live` (WAKIL_LIVE_TRY=1), and each is skipped, saying why, when its runtime is
// not on this machine.

func liveTry(t *testing.T, tools ...string) {
	t.Helper()
	if os.Getenv("WAKIL_LIVE_TRY") != "1" {
		t.Skip("the stacks' Try runs real runtimes; make test-live sets WAKIL_LIVE_TRY=1")
	}
	for _, tool := range tools {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not on PATH on this machine", tool)
		}
	}
}

// tryApp writes files into Main's folder and the checkout, saves recipe as the repo's, and runs
// Try on port.
func tryApp(t *testing.T, files map[string]string, recipe string, port int) TryResult {
	t.Helper()
	root := t.TempDir()
	main, checkout := filepath.Join(root, "main", "app"), filepath.Join(root, "ws", "app")
	for _, dir := range []string{main, checkout} {
		for name, body := range files {
			p := filepath.Join(dir, name)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
				t.Fatal(err)
			}
		}
	}
	var r Recipe
	if err := json.Unmarshal([]byte(recipe), &r); err != nil {
		t.Fatal(err)
	}
	p := Project{Name: "live", Org: "initech", Roots: []Root{{Path: main, Recipe: "app"}}, Recipes: map[string]Recipe{"app": r}}
	if err := ValidateRecipes(p); err != nil {
		t.Fatal(err)
	}
	plan, err := BuildRunPlan(p, PlanInput{Org: "initech", Workspace: fmt.Sprintf("try-%d", port), Repo: "app", MainDir: main,
		Checkouts: []CheckoutPorts{{Repo: "app", Path: checkout, Port: port}}})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	return TryRecipe(ctx, plan, TryOptions{})
}

func block(t *testing.T, n int) []int {
	t.Helper()
	want := make([]string, n)
	for i := range want {
		want[i] = fmt.Sprintf("live-%d", i)
	}
	a, err := AllocatePortBlocks(map[string]int{}, want, ListeningProbe)
	if err != nil {
		t.Fatal(err)
	}
	out := make([]int, n)
	for i, k := range want {
		out[i] = a.Blocks[k]
	}
	return out
}

func wantPassed(t *testing.T, res TryResult) {
	t.Helper()
	if !res.Passed || res.Ready == nil || !res.Ready.Ready {
		var b strings.Builder
		for _, s := range res.Steps {
			fmt.Fprintf(&b, "%s %s %s ok=%v %s\n%s\n", s.Phase, s.Name, s.Command, s.OK, s.Detail, s.Output)
		}
		t.Fatalf("Try did not pass: ready %+v\n%s", res.Ready, b.String())
	}
	if last := res.Steps[len(res.Steps)-1]; len(res.Steps) > 0 && last.Phase != PhaseTeardown && last.Phase != PhaseProcess {
		t.Errorf("the last step is %s", last.Phase)
	}
}

const readyURL = `"ready": {"url": "http://localhost:$WAKIL_PORT/", "timeoutSeconds": 60}`

func TestLiveTryPython(t *testing.T) {
	liveTry(t, "python3")
	res := tryApp(t, map[string]string{"index.html": "ok\n"},
		`{"processes": [{"name": "web", "command": "python3 -u -m http.server $WAKIL_PORT"}], `+readyURL+`, "teardown": ["true"]}`,
		block(t, 1)[0])
	wantPassed(t, res)
}

func TestLiveTryNode(t *testing.T) {
	liveTry(t, "node", "npm")
	res := tryApp(t, map[string]string{
		"package.json": `{"name":"live","version":"1.0.0","scripts":{"start":"node server.js"}}`,
		"server.js":    "require('http').createServer((q, s) => s.end('ok')).listen(process.env.PORT)\n",
	}, `{"ports": {"PORT": "$WAKIL_PORT"}, "setup": ["npm install --offline --no-audit --no-fund"], "processes": [{"name": "web", "command": "npm start"}], `+readyURL+`}`,
		block(t, 1)[0])
	wantPassed(t, res)
}

func TestLiveTryGo(t *testing.T) {
	liveTry(t, "go")
	res := tryApp(t, map[string]string{
		"go.mod":  "module live\n\ngo 1.22\n",
		"main.go": "package main\n\nimport (\n\t\"net/http\"\n\t\"os\"\n)\n\nfunc main() {\n\thttp.ListenAndServe(\":\"+os.Getenv(\"PORT\"), http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte(\"ok\")) }))\n}\n",
	}, `{"ports": {"PORT": "$WAKIL_PORT"}, "setup": ["go build -o app ."], "processes": [{"name": "web", "command": "./app"}], `+readyURL+`}`,
		block(t, 1)[0])
	wantPassed(t, res)
}

// Laravel's shape (php artisan serve, composer install) with no framework to fetch: artisan serves
// public/ with PHP's built-in server, and composer installs an empty require offline.
func TestLiveTryLaravelShape(t *testing.T) {
	liveTry(t, "php", "composer")
	res := tryApp(t, map[string]string{
		"composer.json":    `{"name":"initech/live","require":{}}`,
		"artisan":          "<?php\npassthru('php -S 127.0.0.1:' . getenv('WAKIL_PORT') . ' -t public');\n",
		"public/index.php": "<?php echo 'ok';\n",
	}, `{"setup": ["composer install --no-interaction --no-progress"], "processes": [{"name": "app", "command": "php artisan serve"}], `+readyURL+`}`,
		block(t, 1)[0])
	wantPassed(t, res)
}

// Ruby's shape with the standard library alone; a Rails app needs `rails new`, which fetches gems.
func TestLiveTryRuby(t *testing.T) {
	liveTry(t, "ruby")
	res := tryApp(t, map[string]string{
		"server.rb": "require 'socket'\ns = TCPServer.new('127.0.0.1', ENV['WAKIL_PORT'].to_i)\nloop do\n  c = s.accept\n  c.gets\n  c.print \"HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok\"\n  c.close\nend\n",
	}, `{"processes": [{"name": "web", "command": "ruby server.rb"}], `+readyURL+`}`, block(t, 1)[0])
	wantPassed(t, res)
}

func TestLiveTryRails(t *testing.T) {
	liveTry(t, "ruby", "rails")
	t.Skip("a Rails app needs `rails new`, which fetches its gems from the network; TestLiveTryRuby runs Ruby's shape, and Detect's goldens cover Rails")
}

// A compose app from an image this machine already has (pulling needs the network).
func TestLiveTryCompose(t *testing.T) {
	liveTry(t, "docker")
	image := ""
	for _, i := range []string{"nginx:alpine", "nginx", "httpd:alpine", "httpd"} {
		if exec.Command("docker", "image", "inspect", i).Run() == nil {
			image = i
			break
		}
	}
	if image == "" {
		t.Skip("no nginx or httpd image on this machine, and pulling one needs the network")
	}
	res := tryApp(t, map[string]string{
		"compose.yaml": "services:\n  web:\n    image: " + image + "\n    ports:\n      - \"${WAKIL_PORT}:80\"\n",
	}, `{"services": ["docker compose up -d web"], `+readyURL+`, "teardown": ["docker compose down"]}`, block(t, 1)[0])
	if !res.Passed {
		wantPassed(t, res)
	}
}

// Two Trys at once get their own port blocks, and both come up.
func TestLiveTryTwoAtOnceGetTheirOwnPorts(t *testing.T) {
	liveTry(t, "python3")
	ports := block(t, 2)
	if ports[0] == ports[1] {
		t.Fatalf("one block for both: %v", ports)
	}
	var wg sync.WaitGroup
	results := make([]TryResult, 2)
	for i := range ports {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = tryApp(t, map[string]string{"index.html": "ok\n"},
				`{"processes": [{"name": "web", "command": "python3 -u -m http.server $WAKIL_PORT"}], `+readyURL+`}`, ports[i])
		}(i)
	}
	wg.Wait()
	for _, r := range results {
		wantPassed(t, r)
	}
}
