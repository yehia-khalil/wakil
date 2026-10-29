package wakilcore

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func planFixture(t *testing.T) (Project, PlanInput) {
	t.Helper()
	p := loadFull(t)
	ws := t.TempDir()
	api := filepath.Join(ws, "api")
	writeTree(t, api, map[string]string{
		"docker-compose.yml": "services:\n  laravel.test:\n    build: .\n    ports: ['${APP_PORT:-80}:80']\n  mailpit:\n    image: axllent/mailpit\n    ports: ['8025:8025']\n",
	})
	return p, PlanInput{
		Org: "initech", Workspace: "ini-142", Repo: "api", MainDir: "/main/api",
		Checkouts: []CheckoutPorts{
			{Repo: "api", Path: api, Port: 41200},
			{Repo: "web", Path: filepath.Join(ws, "web"), Port: 41210},
			{Repo: "core-db", Path: "/main/core-db", Port: 41220},
		},
	}
}

func TestBuildRunPlanOrdersTheStepsAndBuildsTheEnv(t *testing.T) {
	p, in := planFixture(t)
	plan, err := BuildRunPlan(p, in)
	if err != nil {
		t.Fatal(err)
	}
	var phases []string
	for _, s := range plan.Steps {
		phases = append(phases, s.Phase+":"+s.Name+s.Target+s.Command)
	}
	want := []string{
		"need:shared-db",
		"copy:",
		"clone:",
		"service:./vendor/bin/sail up -d mysql redis",
		"setup:composer install",
		"process:app./vendor/bin/sail up laravel.test",
		"process:queuesail artisan queue:work rabbitmq",
	}
	if !reflect.DeepEqual(phases, want) {
		t.Fatalf("steps:\n got %q\nwant %q", phases, want)
	}
	if s := plan.Steps[0]; s.TargetKind != "service" || s.Once != OnceWorkspace {
		t.Fatalf("need: %+v", s)
	}
	if s := plan.Steps[1]; s.From != "/main/api" || s.Dir != in.Checkouts[0].Path || s.Paths[0] != ".env" || s.Once != OnceCheckout {
		t.Fatalf("copy: %+v", s)
	}
	if !plan.Steps[5].LongRunning || plan.Steps[4].LongRunning {
		t.Fatal("only processes run long")
	}
	for k, v := range map[string]string{
		"APP_PORT": "41200", "FORWARD_DB_PORT": "41201", "WAKIL_PORT_WEB": "41210", "APP_ENV": "local",
		"QUEUE_CONNECTION": "rabbitmq", "COMPOSE_PROJECT_NAME": "ini-142-api",
		"COMPOSE_FILE": "docker-compose.yml:.wakil/compose.ports.yml",
	} {
		if plan.Env[k] != v {
			t.Errorf("env %s = %q, want %q", k, plan.Env[k], v)
		}
	}
	if plan.Secrets["STRIPE_SECRET"] != "wakil:initech:stripe-api" {
		t.Fatalf("secret: %v", plan.Secrets)
	}
	if _, leaked := plan.Env["STRIPE_SECRET"]; leaked {
		t.Fatal("a secret is never in env")
	}
	// mailpit's fixed 8025 skips the offsets ports already use (0 and 1).
	if len(plan.Files) != 1 || !strings.Contains(plan.Files[0].Content, `"41202:8025"`) || !plan.Files[0].GitExclude {
		t.Fatalf("override file: %+v", plan.Files)
	}
	if plan.Ready == nil || plan.Ready.URL != "http://localhost:41200/up" || plan.Ready.TimeoutSeconds != DefaultReadyTimeoutSeconds {
		t.Fatalf("ready: %+v", plan.Ready)
	}
	if plan.EnvFile == nil || plan.EnvFile.Path != filepath.Join(in.Checkouts[0].Path, ".env") ||
		!reflect.DeepEqual(plan.EnvFile.Keys, []string{"APP_ENV", "APP_PORT", "FORWARD_DB_PORT", "QUEUE_CONNECTION", "STRIPE_SECRET"}) {
		t.Fatalf("env file: %+v", plan.EnvFile)
	}
	if len(plan.Teardown) != 1 || plan.Teardown[0].Command != "./vendor/bin/sail down" || plan.Build != nil {
		t.Fatalf("teardown/build: %+v %+v", plan.Teardown, plan.Build)
	}
}

func TestBuildRunPlanForASharedServiceAndAFrontend(t *testing.T) {
	p, in := planFixture(t)
	in.Repo = "shared-db"
	plan, err := BuildRunPlan(p, in)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Dir != "/main/core-db" || plan.Env["COMPOSE_PROJECT_NAME"] != "ini-142-core-db" || plan.Steps[0].Command != "docker compose up -d mysql" {
		t.Fatalf("shared service: %+v", plan)
	}
	in.Repo = "web"
	plan, err = BuildRunPlan(p, in)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Env["VITE_API_URL"] != "http://localhost:41200" || plan.Steps[0].Target != "api" || plan.Steps[0].TargetKind != "repo" {
		t.Fatalf("web: %+v", plan)
	}
	if plan.Build == nil || plan.Build.Command != "pnpm build" || plan.Ready.Output != "Local:" || plan.Ready.URL != "" {
		t.Fatalf("web build/ready: %+v %+v", plan.Build, plan.Ready)
	}
	for _, s := range plan.Steps {
		if s.Phase == PhaseClone {
			t.Fatal("clone: [] means no clone step")
		}
	}
}

func TestBuildRunPlanRefusals(t *testing.T) {
	p, in := planFixture(t)
	for repo, want := range map[string]string{
		"components": "components is marked doesn't run",
		"core-db":    "core-db has no recipe yet",
		"nope":       `has no repo or shared service named "nope"`,
		"vite":       `has no repo or shared service named "vite"`,
	} {
		in.Repo = repo
		if _, err := BuildRunPlan(p, in); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v", repo, err)
		}
	}
	in.Repo = "web"
	in.Checkouts = in.Checkouts[1:] // the api is not in the workspace: $WAKIL_PORT_API is unknown
	if _, err := BuildRunPlan(p, in); err == nil || !strings.Contains(err.Error(), "VITE_API_URL") || !strings.Contains(err.Error(), "$WAKIL_PORT_API") {
		t.Fatalf("unknown variable: %v", err)
	}
}

func TestMergeDotEnv(t *testing.T) {
	got := MergeDotEnv("# app\nAPP_PORT=80\nexport KEEP=1\nSECRET=old\n", map[string]string{"APP_PORT": "41200", "SECRET": "a b#c", "NEW": "x"})
	want := "# app\nAPP_PORT=41200\nexport KEEP=1\nSECRET=\"a b#c\"\n\n# Added by Wakil for this workspace\nNEW=x\n"
	if got != want {
		t.Fatalf("merge:\n%q\nwant\n%q", got, want)
	}
	if got := MergeDotEnv("", map[string]string{"A": "1"}); got != "# Added by Wakil for this workspace\nA=1\n" {
		t.Fatalf("empty: %q", got)
	}
	if got := MergeDotEnv("A=1", map[string]string{"A": "1"}); got != "A=1" {
		t.Fatalf("unchanged: %q", got)
	}
}

func TestMatchReadyOutput(t *testing.T) {
	for _, c := range []struct {
		pattern, text string
		want          bool
	}{
		{"Local:", "  ➜  Local:   http://localhost:41200/", true},
		{"Local:", "starting", false},
		{`/Started \S+ in /`, "Started Application in 3.2 seconds", true},
		{`/Started \S+ in /`, "Starting", false},
	} {
		got, err := MatchReadyOutput(c.pattern, c.text)
		if err != nil || got != c.want {
			t.Errorf("%q in %q = %v, %v", c.pattern, c.text, got, err)
		}
	}
	if _, err := MatchReadyOutput("/(/", "x"); err == nil {
		t.Fatal("bad regexp")
	}
}

func TestWaitReadyURL(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) < 3 {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	res := WaitReadyURL(context.Background(), nil, srv.URL+"/up", 5*time.Second, 10*time.Millisecond)
	if !res.Ready || !strings.Contains(res.Detail, "answered 200") {
		t.Fatalf("ready: %+v", res)
	}

	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) }))
	defer down.Close()
	res = WaitReadyURL(context.Background(), nil, down.URL, 100*time.Millisecond, 10*time.Millisecond)
	if res.Ready || !strings.Contains(res.Detail, "did not answer within 100ms; it last answered 500.") {
		t.Fatalf("timeout: %+v", res)
	}

	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(30 * time.Millisecond); cancel() }()
	res = WaitReadyURL(ctx, nil, down.URL, 10*time.Second, 10*time.Millisecond)
	if res.Ready || res.Detail != "the ready check was cancelled" {
		t.Fatalf("cancel: %+v", res)
	}
}
