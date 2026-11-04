package wakilcore

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// The stacks the operator listed (piece 2's walk), each held to what a right answer needs beyond its
// golden: where Detect cannot be sure, it says so (a question, the drafting path), never a guess.
func TestDetectAnswersEachStackOrSaysWhatItCannot(t *testing.T) {
	detect := func(name string) Draft {
		t.Helper()
		d, err := DetectRecipe(filepath.Join("testdata", "recipes", name), DetectOptions{})
		if err != nil {
			t.Fatal(err)
		}
		return d
	}
	asks := func(d Draft, part string) bool {
		return slices.ContainsFunc(d.Questions, func(q string) bool { return strings.Contains(q, part) })
	}
	procs := func(d Draft) (out []string) {
		for _, p := range d.Recipe.Processes {
			out = append(out, p.Command)
		}
		return out
	}

	if d := detect("node-npm-express"); d.Recipe.Ports["PORT"] != "$WAKIL_PORT" || !slices.Equal(procs(d), []string{"npm run dev"}) ||
		!slices.Equal(d.Recipe.Setup, []string{"npm ci"}) || len(d.Questions) != 0 {
		t.Errorf("Express with npm: %+v", d)
	}
	// Two apps run together by turbo cannot share one port: Detect asks, it does not guess.
	if d := detect("monorepo-pnpm-turbo"); !asks(d, "2 apps") || !asks(d, "apps/api") || !asks(d, "$WAKIL_PORT_1") {
		t.Errorf("a pnpm and turbo workspace of two apps: %v", d.Questions)
	}
	// air rebuilds a Go server on change when the repo configures it.
	if d := detect("go-air"); !slices.Equal(procs(d), []string{"air"}) {
		t.Errorf("Go with an air config: %v", procs(d))
	}
	// Rails: the database is prepared in setup; Procfile.dev's pinned port collides between workspaces.
	if d := detect("rails-procfile"); !slices.Equal(d.Recipe.Setup, []string{"bundle install", "bin/rails db:prepare"}) ||
		!slices.Equal(procs(d), []string{"bin/dev"}) || !asks(d, "Procfile.dev") || !asks(d, "3000") {
		t.Errorf("Rails with bin/dev and Procfile.dev: setup %v, processes %v, questions %v", d.Recipe.Setup, procs(d), d.Questions)
	}
	// A compose app builds its images in setup, never under the ready timeout.
	if d := detect("compose-app"); !slices.Equal(d.Recipe.Setup, []string{"docker compose build web"}) ||
		!slices.Equal(procs(d), []string{"docker compose up web"}) || d.Recipe.Ports["WEB_PORT"] != "$WAKIL_PORT" {
		t.Errorf("a compose app: setup %v, processes %v, ports %v", d.Recipe.Setup, procs(d), d.Recipe.Ports)
	}
	// Sail: the queue after ready, its images built in setup.
	if d := detect("laravel-sail"); !slices.Contains(d.Recipe.Setup, "./vendor/bin/sail build") ||
		!slices.ContainsFunc(d.Recipe.Processes, func(p Process) bool { return p.Name == "queue" && p.AfterReady }) {
		t.Errorf("Sail: %+v", d.Recipe)
	}
	// Nothing to run: Doesn't run, with why.
	if d := detect("library"); !d.DoesntRun || d.Why == "" {
		t.Errorf("a library: %+v", d)
	}
	// Two commands: Detect runs one and asks which serves.
	if d := detect("go"); !asks(d, "Pick the one that serves the app") {
		t.Errorf("Go with two commands: %v", d.Questions)
	}
}
