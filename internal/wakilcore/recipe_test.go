package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const fullRecipeProject = `{
  "name": "estate",
  "org": "initech",
  "roots": [
    {
      "path": "/src/api",
      "recipe": "laravel-sail",
      "overrides": {
        "env": {
          "QUEUE_CONNECTION": "rabbitmq",
          "STRIPE_SECRET": {
            "secret": "stripe-api"
          }
        },
        "processes": [
          {
            "name": "queue",
            "command": "sail artisan queue:work rabbitmq"
          }
        ],
        "notes": {
          "processes.queue": "config/queue.php has a rabbitmq connection"
        }
      }
    },
    {
      "path": "/src/web",
      "recipe": "vite"
    },
    {
      "path": "/src/core-db"
    },
    {
      "path": "/src/components",
      "doesntRun": true
    }
  ],
  "scopes": {},
  "environments": {},
  "recipes": {
    "laravel-sail": {
      "needs": [
        "shared-db"
      ],
      "ports": {
        "APP_PORT": "$WAKIL_PORT",
        "FORWARD_DB_PORT": "$WAKIL_PORT_1"
      },
      "env": {
        "APP_ENV": "local"
      },
      "alsoWriteEnvFile": true,
      "copy": [
        ".env"
      ],
      "clone": [
        "vendor"
      ],
      "services": [
        "./vendor/bin/sail up -d mysql redis"
      ],
      "setup": [
        "composer install"
      ],
      "processes": [
        {
          "name": "app",
          "command": "./vendor/bin/sail up laravel.test"
        }
      ],
      "ready": {
        "url": "http://localhost:$WAKIL_PORT/up"
      },
      "teardown": [
        "./vendor/bin/sail down"
      ]
    },
    "shared-db": {
      "services": [
        "docker compose up -d mysql"
      ],
      "teardown": [
        "docker compose down"
      ],
      "in": "core-db"
    },
    "vite": {
      "needs": [
        "api"
      ],
      "ports": {
        "VITE_API_URL": "http://localhost:$WAKIL_PORT_API"
      },
      "clone": [],
      "setup": [
        "pnpm install"
      ],
      "processes": [
        {
          "name": "dev",
          "command": "pnpm dev --port $WAKIL_PORT --strictPort"
        }
      ],
      "build": "pnpm build",
      "ready": {
        "output": "Local:"
      }
    }
  }
}`

func writeRecipeProject(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "project.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRecipeProjectRoundTripsByteForByte(t *testing.T) {
	path := writeRecipeProject(t, fullRecipeProject)
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateRecipes(*p); err != nil {
		t.Fatalf("valid project refused: %v", err)
	}
	out, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != fullRecipeProject {
		t.Fatalf("round trip changed the file:\n%s", out)
	}
	// [] (an override to "none") survives, distinct from absent.
	if p.Recipes["vite"].Clone == nil || len(p.Recipes["vite"].Clone) != 0 {
		t.Fatalf("clone: [] lost: %#v", p.Recipes["vite"].Clone)
	}
	if p.Roots[0].Overrides.Env["STRIPE_SECRET"] != (EnvValue{Secret: "stripe-api"}) {
		t.Fatalf("secret env lost: %#v", p.Roots[0].Overrides.Env)
	}
}

func TestProjectWithoutRecipeKeysSavesUnchanged(t *testing.T) {
	const old = `{
  "name": "estate",
  "org": "initech",
  "roots": [
    {
      "path": "/src/api",
      "role": "backend"
    }
  ],
  "scopes": {},
  "environments": {
    "local": {
      "databases": [
        {
          "name": "core",
          "driver": "mysql",
          "ref": "db:estate:local:core"
        }
      ]
    }
  }
}`
	path := writeRecipeProject(t, old)
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := SaveProject(path, *p); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	if string(b) != old {
		t.Fatalf("an old project.json changed on save:\n%s", b)
	}
	if err := ValidateRecipes(*p); err != nil {
		t.Fatalf("a project with no recipes is valid: %v", err)
	}
}

func TestEnvValueRefusesOtherShapes(t *testing.T) {
	var e EnvValue
	if err := json.Unmarshal([]byte(`{"value": "x"}`), &e); err == nil {
		t.Fatal("an object without secret must be refused")
	}
	if err := json.Unmarshal([]byte(`3`), &e); err == nil {
		t.Fatal("a number must be refused")
	}
}

func loadFull(t *testing.T) Project {
	t.Helper()
	var p Project
	if err := json.Unmarshal([]byte(fullRecipeProject), &p); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestEffectiveRecipeMergesAndSaysWhereEachFieldCameFrom(t *testing.T) {
	p := loadFull(t)
	eff, err := EffectiveRecipe(p, "api")
	if err != nil {
		t.Fatal(err)
	}
	if eff.RecipeName != "laravel-sail" || eff.DoesntRun {
		t.Fatalf("header: %+v", eff)
	}
	wantProcs := []Process{{"app", "./vendor/bin/sail up laravel.test"}, {"queue", "sail artisan queue:work rabbitmq"}}
	if !reflect.DeepEqual(eff.Recipe.Processes, wantProcs) {
		t.Fatalf("processes: %#v", eff.Recipe.Processes)
	}
	wantEnv := map[string]EnvValue{"APP_ENV": {Value: "local"}, "QUEUE_CONNECTION": {Value: "rabbitmq"}, "STRIPE_SECRET": {Secret: "stripe-api"}}
	if !reflect.DeepEqual(eff.Recipe.Env, wantEnv) {
		t.Fatalf("env: %#v", eff.Recipe.Env)
	}
	for key, want := range map[string]string{
		"env.APP_ENV": FieldShared, "env.STRIPE_SECRET": FieldRepo, "processes.app": FieldShared,
		"processes.queue": FieldRepo, "setup": FieldShared, "ready": FieldShared, "ports.APP_PORT": FieldShared,
	} {
		if eff.From[key] != want {
			t.Errorf("from[%s] = %q, want %q", key, eff.From[key], want)
		}
	}
	if eff.Recipe.Notes["processes.queue"] == "" {
		t.Error("the repo's note was not carried")
	}
}

func TestMergeReplacesListsAndScalarsAndRemovesAProcess(t *testing.T) {
	shared := Recipe{
		Setup:     []string{"a"},
		Clone:     []string{"vendor"},
		Build:     ptr("make"),
		Processes: []Process{{"app", "serve"}, {"queue", "work"}},
		Ports:     map[string]string{"A": "$WAKIL_PORT"},
	}
	over := Recipe{
		Setup:     []string{"b", "c"},
		Clone:     []string{},
		Build:     ptr("make all"),
		Processes: []Process{{"queue", ""}},
		Ports:     map[string]string{"B": "$WAKIL_PORT_1"},
	}
	r, from := MergeRecipe(shared, over)
	if !reflect.DeepEqual(r.Setup, []string{"b", "c"}) || from["setup"] != FieldRepo {
		t.Errorf("setup: %v %s", r.Setup, from["setup"])
	}
	if r.Clone == nil || len(r.Clone) != 0 || from["clone"] != FieldRepo {
		t.Errorf("clone: [] must replace: %#v", r.Clone)
	}
	if *r.Build != "make all" || from["build"] != FieldRepo {
		t.Errorf("build: %v", *r.Build)
	}
	if !reflect.DeepEqual(r.Processes, []Process{{"app", "serve"}}) {
		t.Errorf("an empty override command removes the process: %#v", r.Processes)
	}
	if _, ok := from["processes.queue"]; ok {
		t.Error("a removed process has no from")
	}
	if len(r.Ports) != 2 || from["ports.A"] != FieldShared || from["ports.B"] != FieldRepo {
		t.Errorf("ports: %v %v", r.Ports, from)
	}
}

func TestEffectiveRecipeOfARepoThatDoesntRunOrIsUnknown(t *testing.T) {
	p := loadFull(t)
	eff, err := EffectiveRecipe(p, "components")
	if err != nil || !eff.DoesntRun || eff.Recipe.Processes != nil {
		t.Fatalf("doesn't run: %+v %v", eff, err)
	}
	if _, err := EffectiveRecipe(p, "nope"); err == nil || !strings.Contains(err.Error(), "api, web, core-db, components") {
		t.Fatalf("unknown repo: %v", err)
	}
}

func TestValidateRecipesListsEveryProblemWhole(t *testing.T) {
	p := Project{
		Name: "estate", Org: "initech",
		Roots: []Root{
			{Path: "/src/api", RepoRun: RepoRun{Recipe: "missing"}},
			{Path: "/src/web", RepoRun: RepoRun{Recipe: "Bad Name", DoesntRun: true}},
			{Path: "/src/a", RepoRun: RepoRun{Overrides: &Recipe{Needs: []string{"b"}}}},
			{Path: "/src/b", RepoRun: RepoRun{Overrides: &Recipe{Needs: []string{"a", "b"}}}},
		},
		Recipes: map[string]Recipe{
			"Bad Name": {},
			"r": {
				Needs:     []string{"ghost", "app-recipe"},
				Ports:     map[string]string{"1X": "", "OK": "$WAKIL_PORT"},
				Env:       map[string]EnvValue{"A-B": {Value: "x"}, "S": {Secret: "has space"}},
				Copy:      []string{"/etc/passwd", "../up", ""},
				Setup:     []string{" "},
				Processes: []Process{{"app", ""}, {"app", "x"}, {"Bad", "y"}},
				Build:     ptr(""),
				Ready:     &Ready{URL: "localhost:1", TimeoutSeconds: -1},
				In:        ptr("nowhere"),
			},
			"app-recipe": {Services: []string{"x"}, Processes: []Process{{"p", "q"}}},
			"both":       {Ready: &Ready{URL: "http://x", Output: "y"}},
			"neither":    {Ready: &Ready{}},
			"badre":      {Ready: &Ready{Output: "/(/"}},
		},
	}
	err := ValidateRecipes(p)
	if err == nil {
		t.Fatal("expected problems")
	}
	msg := err.Error()
	for _, want := range []string{
		`repo "api" names recipe "missing", which project.json does not define under recipes.`,
		`repo "web" is marked doesn't run, so it cannot also name a recipe or override one`,
		`Recipe name "Bad Name" must be lower-case`,
		`recipe "r" needs "ghost", which is neither a repo of this project nor a shared service.`,
		`recipe "r" needs "app-recipe", a recipe that is not a shared service`,
		`maps port variable "1X", which is not a valid variable name.`,
		`maps port variable 1X to nothing`,
		`sets env variable "A-B", which is not a valid variable name.`,
		`secret under Keychain ref "has space"`,
		`copy entry "/etc/passwd" must be a path inside the repo`,
		`copy entry "../up"`,
		`copy entry ""`,
		`setup command 1 is empty.`,
		`process "app" has no command.`,
		`has two processes named "app".`,
		`process 3 is named "Bad"`,
		`build is empty; remove it instead.`,
		`ready url "localhost:1" must start with http:// or https://.`,
		`ready timeout is negative.`,
		`runs in "nowhere", which is not a repo of this project.`,
		`recipe "both"'s ready has both a url and an output line; keep one.`,
		`recipe "neither"'s ready has neither a url nor an output line.`,
		`recipe "badre"'s ready output /(/ is not a valid regular expression`,
		`repo "b" needs itself`,
		`The needs form a loop (a → b → a)`,
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("missing problem %q in:\n%s", want, msg)
		}
	}
	if _, ok := IsUserError(err); !ok {
		t.Error("validation is a user error")
	}
}

func TestApplyRecipePatchValidatesAndReplaces(t *testing.T) {
	p := loadFull(t)
	err := ApplyRecipePatch(&p, RecipePatch{
		Recipes: map[string]*Recipe{"vite": nil},
	})
	if err == nil || !strings.Contains(err.Error(), `names recipe "vite"`) {
		t.Fatalf("deleting a used recipe must be refused: %v", err)
	}
	p = loadFull(t)
	err = ApplyRecipePatch(&p, RecipePatch{
		Recipes: map[string]*Recipe{"go": {Processes: []Process{{"app", "go run ."}}}},
		Repos:   map[string]RepoRun{"core-db": {Recipe: "go"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if root, _ := FindRoot(p, "core-db"); root.Recipe != "go" {
		t.Fatalf("repo not updated: %+v", root)
	}
	if err := ApplyRecipePatch(&p, RecipePatch{Repos: map[string]RepoRun{"nope": {}}}); err == nil {
		t.Fatal("unknown repo must be refused")
	}
}

func TestSaveRecipesReadsModifiesWritesAndRefusesAnotherOrg(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	path := writeRecipeProject(t, fullRecipeProject)
	if err := SaveRecipes(path, RecipePatch{Repos: map[string]RepoRun{"components": {}}}); err != nil {
		t.Fatal(err)
	}
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if root, _ := FindRoot(*p, "components"); root.DoesntRun {
		t.Fatal("doesntRun not cleared")
	}
	if len(p.Recipes) != 3 {
		t.Fatal("recipes lost on save")
	}
	t.Setenv("WAKIL_ORG", "umbrella")
	if err := SaveRecipes(path, RecipePatch{}); err == nil || !strings.Contains(err.Error(), "another organisation") {
		t.Fatalf("another org: %v", err)
	}
}
