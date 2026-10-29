package wakilcore

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeTree(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for name, body := range files {
		p := filepath.Join(root, name)
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func sailRepo(queue bool, dbHost string) map[string]string {
	q := "sync"
	if queue {
		q = "rabbitmq"
	}
	return map[string]string{
		"composer.json": `{"require-dev":{"laravel/sail":"^1"}}`,
		"artisan":       "",
		"docker-compose.yml": `services:
  laravel.test:
    build: .
    ports: ['${APP_PORT:-80}:80']
  mysql:
    image: mysql:8
    ports: ['${FORWARD_DB_PORT:-3306}:3306']
`,
		".env.example": "DB_HOST=mysql\nQUEUE_CONNECTION=" + q + "\nDB_SHARED_HOST=" + dbHost + "\n",
	}
}

func draftTree(t *testing.T) []Draft {
	t.Helper()
	root := t.TempDir()
	repos := map[string]map[string]string{
		"reservations": sailRepo(true, "umbrella_mysql"),
		"rewards":      sailRepo(false, "umbrella_mysql"),
		"pricing":      sailRepo(false, "umbrella_mysql"),
		"umbrella": {"docker-compose.yml": `services:
  mysql:
    image: mysql:8
    container_name: umbrella_mysql
  redis:
    image: redis:7
`},
		"components": {"composer.json": `{"type":"library"}`},
		"web":        {"package.json": `{"scripts":{"dev":"vite"}}`, "pnpm-lock.yaml": "", "vite.config.ts": "", ".env.example": "API=http://orphan_api:8000\n"},
		"admin":      {"package.json": `{"scripts":{"dev":"vite"}}`, "pnpm-lock.yaml": "", "vite.config.ts": "", ".env.example": "API=http://orphan_api:8000\n"},
	}
	var drafts []Draft
	for name, files := range repos {
		dir := filepath.Join(root, name)
		writeTree(t, dir, files)
		d, err := DetectRecipe(dir, DetectOptions{})
		if err != nil {
			t.Fatal(err)
		}
		drafts = append(drafts, d)
	}
	return drafts
}

func TestDraftAllGroupsAlikeReposAndKeepsDifferences(t *testing.T) {
	all := DraftAllRecipes(draftTree(t))

	sail, ok := all.Recipes["laravel-sail"]
	if !ok {
		t.Fatalf("no laravel-sail recipe: %v", sortedKeys(all.Recipes))
	}
	if !reflect.DeepEqual(sail.Processes, []Process{{"app", "./vendor/bin/sail up laravel.test"}}) {
		t.Fatalf("shared processes: %+v", sail.Processes)
	}
	if !reflect.DeepEqual(sail.Needs, []string{"umbrella-services"}) {
		t.Fatalf("every sail repo reads umbrella_mysql, so the need is shared: %v", sail.Needs)
	}
	var g DraftGroup
	for _, x := range all.Groups {
		if x.Recipe == "laravel-sail" {
			g = x
		}
	}
	if !reflect.DeepEqual(g.Repos, []string{"pricing", "reservations", "rewards"}) {
		t.Fatalf("group: %+v", g)
	}
	if !reflect.DeepEqual(g.Differences, map[string][]string{"reservations": {"processes"}}) {
		t.Fatalf("differences: %+v", g.Differences)
	}
	res := all.Repos["reservations"]
	if res.Recipe != "laravel-sail" || res.Overrides == nil ||
		!reflect.DeepEqual(res.Overrides.Processes, []Process{{"queue", "./vendor/bin/sail artisan queue:work"}}) {
		t.Fatalf("reservations keeps its queue: %+v", res.Overrides)
	}
	if all.Repos["pricing"].Overrides != nil {
		t.Fatalf("pricing is exactly the recipe: %+v", all.Repos["pricing"].Overrides)
	}

	// The shared service: umbrella's compose defines umbrella_mysql, three repos read it.
	if len(all.SharedServices) != 1 {
		t.Fatalf("shared services: %+v", all.SharedServices)
	}
	ss := all.SharedServices[0]
	if ss.Name != "umbrella-services" || ss.In != "umbrella" || ss.Host != "umbrella_mysql" ||
		!reflect.DeepEqual(ss.Repos, []string{"pricing", "reservations", "rewards"}) {
		t.Fatalf("shared service: %+v", ss)
	}
	svc := all.Recipes["umbrella-services"]
	if !IsSharedService(svc) || svc.Services[0] != "docker compose up -d mysql redis" || *svc.In != "umbrella" {
		t.Fatalf("shared service recipe: %+v", svc)
	}
	if all.Repos["umbrella"].Recipe != "umbrella-services" {
		t.Fatalf("the repo that only hosts the services runs as the shared service: %+v", all.Repos["umbrella"])
	}

	if !reflect.DeepEqual(all.NothingToRun, []NothingToRun{{"components", `a composer library (composer.json type "library"), with no entry point`}}) ||
		!all.Repos["components"].DoesntRun {
		t.Fatalf("nothing to run: %+v", all.NothingToRun)
	}
	found := false
	for _, q := range all.Questions {
		if strings.HasPrefix(q, "2 repos point at orphan_api (admin/.env.example API, web/.env.example API), but no repo's compose file starts it") {
			found = true
		}
	}
	if !found {
		t.Fatalf("an unowned host becomes a question: %q", all.Questions)
	}
	if all.Recipes["vite-pnpm"].Processes == nil || all.Repos["web"].Recipe != "vite-pnpm" {
		t.Fatalf("vite group: %+v", all.Repos["web"])
	}

	// What it proposes is a project ValidateRecipes accepts, and each repo's effective recipe is
	// exactly its own draft (with the need added).
	p := Project{Name: "estate", Org: "initech", Recipes: all.Recipes}
	for _, repo := range sortedKeys(all.Repos) {
		p.Roots = append(p.Roots, Root{Path: "/src/" + repo, RepoRun: all.Repos[repo]})
	}
	if err := ValidateRecipes(p); err != nil {
		t.Fatalf("proposal invalid: %v", err)
	}
	eff, _ := EffectiveRecipe(p, "reservations")
	if len(eff.Recipe.Processes) != 2 || eff.From["processes.queue"] != FieldRepo || eff.From["processes.app"] != FieldShared {
		t.Fatalf("effective: %+v", eff)
	}
}

func TestSplitSharedTakesTheMajorityAndOverridesTheRest(t *testing.T) {
	rs := []Recipe{
		{Setup: []string{"a"}, Build: ptr("b"), Ports: map[string]string{"P": "$WAKIL_PORT"}, Processes: []Process{{"app", "x"}}},
		{Setup: []string{"a"}, Ports: map[string]string{"P": "$WAKIL_PORT", "Q": "$WAKIL_PORT_1"}, Processes: []Process{{"app", "y"}}},
		{Setup: []string{"c"}, Build: ptr("b"), Ports: map[string]string{"P": "$WAKIL_PORT"}, Processes: []Process{{"app", "x"}}},
	}
	shared, over := splitShared(rs)
	if !reflect.DeepEqual(shared.Setup, []string{"a"}) || *shared.Build != "b" || shared.Ports["P"] != "$WAKIL_PORT" || len(shared.Ports) != 1 {
		t.Fatalf("shared: %+v", shared)
	}
	if !reflect.DeepEqual(over[2].Setup, []string{"c"}) || over[1].Build == nil || *over[1].Build != "" || over[1].Ports["Q"] != "$WAKIL_PORT_1" {
		t.Fatalf("overrides: %+v", over)
	}
	for i, r := range rs {
		got, _ := MergeRecipe(shared, over[i])
		if jsonKey(got.Setup) != jsonKey(r.Setup) || jsonKey(got.Processes) != jsonKey(r.Processes) || jsonKey(got.Ports) != jsonKey(r.Ports) {
			t.Errorf("recipe %d does not come back: %+v vs %+v", i, got, r)
		}
	}
}
