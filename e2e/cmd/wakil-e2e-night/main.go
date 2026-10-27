// Command wakil-e2e-night is the e2e night run.
//
// Once a night, between 23:00 and 07:00, it runs `make e2e-full` on the latest
// origin/main when it has moved since the last green night, has a headless
// Claude session fix what went red on one branch for the night, re-runs those
// checks, and writes a result any worktree can read. The spec is
// docs/superpowers/specs/2026-10-27-e2e-night-run-design.md.
//
//	go run ./e2e/cmd/wakil-e2e-night install   # make e2e-night-install
//	go run ./e2e/cmd/wakil-e2e-night status    # make e2e-night-status
//	wakil-e2e-night run --repo <checkout>      # what launchd runs at 23:00
//
// **The running process is the lock.** A daytime session waits while
// `pgrep -f '[w]akil-e2e-night run'` matches, so a crash leaves nothing stale.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"

	"github.com/yehia-khalil/wakil/e2e/night"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: wakil-e2e-night run|status|install [--repo <dir>]")
		os.Exit(2)
	}
	flags := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	repo := flags.String("repo", ".", "a checkout of the repository")
	flags.Parse(os.Args[2:])

	var err error
	switch os.Args[1] {
	case "run":
		err = run(*repo)
	case "status":
		err = status(*repo)
	case "install":
		err = install(*repo)
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e-night:", err)
		os.Exit(1)
	}
}

func run(repo string) error {
	store, err := night.OpenStore(repo)
	if err != nil {
		return err
	}
	fmt.Printf("== e2e night run starting %s\n", time.Now().Format(time.RFC3339))
	steps, err := night.RealSteps(repo, store, os.Stdout)
	if err != nil {
		return err
	}
	r := night.Run(steps, store)
	fmt.Printf("== e2e night run: %s, result in %s\n", r.Outcome, store.ResultPath(r.Night))
	return nil
}

// status prints the latest night, and fails when the last night that should
// have run left no result: a night that never ran must not look like a quiet one.
func status(repo string) error {
	store, err := night.OpenStore(repo)
	if err != nil {
		return err
	}
	latest, body, err := store.Latest()
	if err != nil {
		return err
	}
	if want := night.LastNight(time.Now()); latest.Before(want) {
		fmt.Printf("no result for the night of %s: the job did not run (log: %s)\n\n",
			want.Format("2006-01-02"), filepath.Join(store.Dir, "night.log"))
		fmt.Print(body)
		os.Exit(1)
	}
	fmt.Print(body)
	return nil
}

// install builds the command into the store and loads the launchd job. The job
// runs against the main checkout, which outlives any feature worktree.
func install(repo string) error {
	store, err := night.OpenStore(repo)
	if err != nil {
		return err
	}
	common, err := night.CommonDir(repo)
	if err != nil {
		return err
	}
	binary := filepath.Join(store.Dir, "bin", "wakil-e2e-night")
	build := exec.Command("go", "build", "-o", binary, "./e2e/cmd/wakil-e2e-night")
	build.Dir, build.Stdout, build.Stderr = repo, os.Stdout, os.Stderr
	if err := build.Run(); err != nil {
		return fmt.Errorf("building: %w", err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	plist := filepath.Join(home, "Library", "LaunchAgents", night.Label+".plist")
	body := night.Plist(binary, filepath.Dir(common), filepath.Join(store.Dir, "night.log"), os.Getenv("PATH"))
	if err := os.WriteFile(plist, []byte(body), 0o644); err != nil {
		return err
	}
	domain := "gui/" + strconv.Itoa(os.Getuid())
	exec.Command("launchctl", "bootout", domain+"/"+night.Label).Run() // not loaded yet is fine
	if out, err := exec.Command("launchctl", "bootstrap", domain, plist).CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl bootstrap: %w: %s", err, out)
	}
	fmt.Printf("installed %s: every night at 23:00, %s run --repo %s\n", plist, binary, filepath.Dir(common))
	return nil
}
