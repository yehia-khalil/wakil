package driver

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Launch starts one fixture instance of a Wakil bundle.
type Launch struct {
	Bundle  string // path to Wakil.app
	Fixture Fixture
	// Seeded is the state Seed wrote into Fixture, and it is what names the
	// org this launch opens. The zero value launches an UNSEEDED instance,
	// which lands on the organisation plane — what e2e/checks/unseeded/org-plane.jsonl
	// asserts, and the wrong thing for any check that needs to get past it.
	Seeded   Seeded
	Orca     Orca
	BasePATH string // what the fixture bin is prepended to
	Timeout  time.Duration
	// ProviderToken, when set, is stored as the seeded provider's credential
	// once the fixture keychain exists.
	//
	// **Here rather than in Seed, because the keychain does not exist yet when
	// the seed runs.** `makeKeychain` creates it on the way into this launch,
	// and a credential written before that would land in the operator's login
	// keychain — the one thing this fixture's whole shim exists to make
	// structurally impossible.
	ProviderToken string
}

// Instance is a running fixture app.
type Instance struct {
	PID     int
	Fixture Fixture
	bundle  string
	// stopStub stops the stub Anthropic API this launch started; nil when none.
	stopStub func()
}

const keychainPassword = "e2e-fixture"

// Start launches the bundle and returns once its window can be read.
//
// **`open -n`, never a backgrounded child.** A bundle binary started as a
// child of a shell dies with that shell, and every later Orca call then fails
// `app_not_found` — which reads exactly like a capability limit and is not one
// (probe §1). `open -n` detaches through LaunchServices, and `--env` is what
// carries the fixture environment, which is necessary because a LaunchServices
// start otherwise inherits launchd's minimal one — the same fact WindowModel
// records for #238.
func (l Launch) Start() (inst *Instance, err error) {
	if l.Timeout == 0 {
		l.Timeout = 30 * time.Second
	}
	// The capacity probe talks to a local stand-in, never api.anthropic.com.
	// Started before any Env is built; stopped by Close, or here on failure.
	var stopStub func()
	if l.Fixture.AnthropicBaseURL == "" {
		url, stop, stubErr := StartAnthropicStub(DefaultStubCapacityHeaders)
		if stubErr != nil {
			return nil, stubErr
		}
		l.Fixture.AnthropicBaseURL, stopStub = url, stop
		defer func() {
			if err != nil {
				stop()
			}
		}()
	}
	if err := l.makeKeychain(); err != nil {
		return nil, err
	}

	if err := l.storeProviderCredential(); err != nil {
		l.removeKeychain()
		return nil, err
	}

	// Before the launch, not after: a stray found afterwards has already had
	// the chance to take the foreground, and the new instance would have to be
	// torn down again to report it.
	if err := refuseStrayFixtures(l.Bundle); err != nil {
		l.removeKeychain()
		return nil, err
	}
	if err := refuseLiveWakil(); err != nil {
		l.removeKeychain()
		return nil, err
	}

	before, err := runningPIDs(l.Bundle)
	if err != nil {
		l.removeKeychain()
		return nil, err
	}

	args := []string{"-n"}
	for _, assignment := range l.Fixture.Env(l.BasePATH, l.Seeded) {
		args = append(args, "--env", assignment)
	}
	args = append(args, l.Bundle)
	if out, err := exec.Command("open", args...).CombinedOutput(); err != nil {
		l.removeKeychain()
		return nil, fmt.Errorf("open -n %s: %w: %s", l.Bundle, err, out)
	}

	pid, err := l.awaitNewPID(before)
	if err != nil {
		// The keychain exists from here back to makeKeychain, and every
		// return in between used to leak one.
		l.removeKeychain()
		return nil, err
	}
	instance := &Instance{PID: pid, Fixture: l.Fixture, bundle: l.Bundle, stopStub: stopStub}

	// Close's own refusals are joined rather than discarded: when teardown
	// declines to kill, a fixture Wakil is still on the operator's screen, and
	// that must reach them rather than be swallowed by the error that caused it.
	if err := instance.verifyIsolation(l.Timeout); err != nil {
		return nil, errors.Join(err, instance.Close())
	}
	if err := l.awaitWindow(pid); err != nil {
		return nil, errors.Join(err, instance.Close())
	}
	return instance, nil
}

// makeKeychain creates the throwaway keychain the shim redirects to. It is
// deliberately NOT added to the search list — the shim names it explicitly, so
// nothing else on the machine ever sees it.
func (l Launch) makeKeychain() error {
	_ = exec.Command(SystemSecurity, "delete-keychain", l.Fixture.Keychain).Run()
	if out, err := exec.Command(SystemSecurity, "create-keychain", "-p", keychainPassword, l.Fixture.Keychain).CombinedOutput(); err != nil {
		return fmt.Errorf("creating the fixture keychain: %w: %s", err, out)
	}
	if out, err := exec.Command(SystemSecurity, "unlock-keychain", "-p", keychainPassword, l.Fixture.Keychain).CombinedOutput(); err != nil {
		return fmt.Errorf("unlocking the fixture keychain: %w: %s", err, out)
	}
	// **Unlocked is not the same as staying unlocked.** Measured 2026-09-25:
	// `security create-keychain` hands back a keychain with `lock-on-sleep
	// timeout=300s`, so a fixture five minutes old, or one whose machine
	// slept, relocks itself — and the window's credential lookup then fails
	// with `errSecInteractionNotAllowed` for a reason that has nothing to do
	// with the check it is running. `set-keychain-settings` with no flags
	// clears both, leaving `no-timeout`.
	//
	// #284 is why this is not left as a small risk. A run whose agent will
	// not start is the most expensive failure this harness has, because it
	// looks the same however it was caused; a five-minute fuse inside the
	// fixture is exactly the kind of cause that makes one look intermittent.
	if out, err := exec.Command(SystemSecurity, "set-keychain-settings", l.Fixture.Keychain).CombinedOutput(); err != nil {
		return fmt.Errorf("clearing the fixture keychain's auto-lock: %w: %s", err, out)
	}
	return nil
}

// storeProviderCredential puts the seeded provider's token in the fixture
// keychain, through the shipped CLI.
//
// **Through `wakil secrets set`, not by writing the item here.** Invariant 4
// stores secrets at `wakil:<org>:<ref>` and `secrets.go` is the only thing
// that knows that scheme — including its refusal to fall back to an unscoped
// name. A second writer here would not fail loudly when it drifted; it would
// store a credential the app then could not find, and the check would report
// that as an agent that would not start.
//
// **The CLI out of the bundle, not out of bin/.** It is the copy the app
// itself resolves, so this also exercises the binary the bundle ships — which
// is exactly what was missing until 2026-09-24, when a window in a staged
// bundle could not look up a credential at all.
func (l Launch) storeProviderCredential() error {
	if l.ProviderToken == "" || l.Seeded.Provider == "" {
		return nil
	}
	cli := filepath.Join(l.Bundle, "Contents", "Resources", "wakil")
	if err := executable(cli); err != nil {
		return fmt.Errorf("the bundle at %s ships no `wakil` to store a credential with (%w) — "+
			"the window runs the same binary for every provider credentials lookup", l.Bundle, err)
	}
	for _, provider := range []string{l.Seeded.Provider, l.Seeded.SpareProvider} {
		if provider == "" {
			continue
		}
		command := exec.Command(cli, "secrets", "set", "provider:"+provider)
		command.Env = append(l.Fixture.Env(l.BasePATH, l.Seeded), "HOME="+l.Fixture.Home)
		command.Stdin = strings.NewReader(l.ProviderToken)
		if out, err := command.CombinedOutput(); err != nil {
			return fmt.Errorf("storing provider %s's credential: %w: %s", provider, err, out)
		}
	}
	return nil
}

// removeKeychain deletes the throwaway keychain, best effort. It is called on
// every path out of Start that created one, and unconditionally by Close.
func (l Launch) removeKeychain() {
	_ = exec.Command(SystemSecurity, "delete-keychain", l.Fixture.Keychain).Run()
}

func (l Launch) awaitNewPID(before []int) (int, error) {
	deadline := time.Now().Add(l.Timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		after, err := runningPIDs(l.Bundle)
		if err != nil {
			return 0, err
		}
		pid, err := NewPID(before, after)
		if err == nil {
			return pid, nil
		}
		lastErr = err
		time.Sleep(250 * time.Millisecond)
	}
	return 0, fmt.Errorf("no fixture instance appeared within %s: %w", l.Timeout, lastErr)
}

// awaitWindow polls until the instance has a readable window.
func (l Launch) awaitWindow(pid int) error {
	deadline := time.Now().Add(l.Timeout)
	var last string
	for time.Now().Before(deadline) {
		response, err := l.Orca.GetAppState(pid)
		switch {
		case err != nil:
			last = err.Error()
		case !response.OK:
			last = response.Err.Error()
		case response.Snapshot.ElementCount > 0:
			return nil
		default:
			last = "the window reported no elements"
		}
		time.Sleep(500 * time.Millisecond)
	}
	// **The screen can lock in the middle of a run**, and this is where that
	// shows up: `Session.Run` refuses a launch that starts behind a lock, but
	// a suite long enough to reach the idle timer gets locked out partway
	// through and every launch after it lands here. Without this the message
	// blames the app for it — #284, which cost an afternoon.
	if locked, lockErr := ScreenLocked(); lockErr == nil && locked {
		return fmt.Errorf(
			"pid %d never presented a readable window within %s, because this Mac's screen is "+
				"locked: AppKit presents nothing to the accessibility API behind a lock, so the "+
				"app is not what went wrong here. Unlock the screen and run again. Orca said: %s",
			pid, l.Timeout, last)
	}
	return fmt.Errorf("pid %d never presented a readable window within %s: %s", pid, l.Timeout, last)
}

// verifyIsolation proves the fixture environment actually reached the app and
// the Go children it spawns, and waits for a child to exist so the question
// can be answered at all.
//
// **Without this the Keychain isolation is a hope.** A launcher that dropped
// PATH or `WAKIL_KEYCHAIN` would write into the operator's login keychain —
// and nothing anywhere would say so. The decision itself lives in
// VerifyIsolation, where it is tested; this half is the waiting.
//
// **Both variables are read back, and #301 is why both.** The keychain
// selector is the one the product reads (`wakilcore` invokes
// /usr/bin/security by absolute path, so PATH does not reach it); the PATH
// shim is what still covers `claude`. Reading only PATH is how this
// function passed every run for the four days the product was writing to
// the login keychain.
func (i *Instance) verifyIsolation(timeout time.Duration) error {
	app, _, err := processEnv(i.PID, "HOME", "PATH", KeychainSelectorEnv)
	if err != nil {
		return err
	}

	var child map[string]string
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		pid, err := spawnedChild(i.bundle)
		if err == nil && pid != 0 {
			env, _, envErr := processEnv(pid, "HOME", "PATH", KeychainSelectorEnv)
			if envErr == nil && len(env) > 0 {
				child = env
				break
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	return VerifyIsolation(i.Fixture, app, child)
}

// Close stops the instance and removes its keychain.
//
// **It identifies its own instance by HOME, never by process name.** Killing
// "the Wakil process" would kill the operator's.
//
// **The keychain is removed on every path**, including the paths that decline
// to kill. It belongs to this run whatever the process turned out to be, and
// each early return that skipped it leaked one — most easily on the ordinary
// path where the instance had already exited.
func (i *Instance) Close() error {
	if i == nil || i.PID == 0 {
		return nil
	}
	if i.stopStub != nil {
		defer i.stopStub()
	}
	env, alive, inspectErr := processEnv(i.PID, "HOME")
	plan := PlanTeardown(i.Fixture, alive, inspectErr, env["HOME"])

	var killErr error
	if plan.Kill {
		if err := exec.Command("kill", strconv.Itoa(i.PID)).Run(); err != nil {
			killErr = fmt.Errorf("killing pid %d: %w", i.PID, err)
		} else {
			killErr = i.awaitExit()
		}
	}
	_ = exec.Command(SystemSecurity, "delete-keychain", i.Fixture.Keychain).Run()
	return errors.Join(plan.Refusal, killErr)
}

// teardownDeadline bounds the wait below.
//
// **Measured rather than chosen.** Twenty teardowns across a full `make e2e`
// on 2026-09-26 took **10.2ms to 21.4ms**, median ~11ms — and the 10ms floor
// is `existencePoll` itself, so the true figure is below the instrument's
// resolution for most of them. Ten seconds is roughly 470x the worst
// observation, which is headroom for a loaded machine without being a wait
// anybody sits through: it is a ceiling reached only when something is wrong,
// never a toll.
//
// **The suite cost is ~0.2s across twenty instances**, and most of even that
// was already being spent — the teardown happened anyway, concurrently with
// the next check's staging, which is precisely why the race existed. This
// serialises work rather than adding it.
const teardownDeadline = 10 * time.Second

// existencePoll is how often the cheap question is asked.
const existencePoll = 10 * time.Millisecond

// awaitExit waits until the instance has actually left the process table.
//
// **`kill` returns when the SIGNAL is delivered, not when the process is
// gone**, and that gap is a defect rather than a detail. `refuseStrayFixtures`
// scans at the start of the next launch; with nothing between the two, a
// single run on a clean machine can refuse ITSELF, because the previous
// check's instance is still shutting down. Measured 2026-09-26: a run failed
// at `agent-pane-is-drawn` naming a pid from the check before it.
//
// **And the overlap was never only a false-positive source.** Until this
// waited, every check boundary had a window in which two fixture processes
// were genuinely alive — so the foreground theft #299 exists for had a second
// source nobody had named: the previous check's fixture, still up and still
// able to take the screen while the next instance launches. Serialising the
// teardown closes that window too, and it is the more interesting half.
//
// **Two questions, and only the cheap one is asked per iteration.**
// Existence is what the wait waits on — `signal 0`, no process spawned.
// Identity is what the KILL decision needs, and `processEnv` costs a `ps`, so
// it is paid only at the two moments it changes a decision: before escalating,
// and when reporting an expiry. Polling the expensive question would spawn a
// process per iteration and be slow enough to mask the race by accident,
// which is exactly the trap `Activate` fell into.
//
// **A pid that is alive but is no longer OURS counts as gone.** Pids are
// reused, and SIGKILL to a recycled one is the single outcome here with no
// recovery. `PlanTeardown` already encodes "is this ours" from the fixture's
// own HOME — a stronger identity than the staged bundle path, which every
// instance shares — so re-running it before escalating gets the pid-reuse
// guard out of the function that already answers the question.
func (i *Instance) awaitExit() error {
	deadline := time.Now().Add(teardownDeadline)
	for time.Now().Before(deadline) {
		if !processAlive(i.PID) {
			return nil
		}
		time.Sleep(existencePoll)
	}
	// Still there. Ask the expensive question ONCE: is it still ours?
	env, alive, inspectErr := processEnv(i.PID, "HOME")
	plan := PlanTeardown(i.Fixture, alive, inspectErr, env["HOME"])
	if !plan.Kill {
		// Gone, or somebody else's now. Either way this is not ours to kill.
		return nil
	}
	if err := exec.Command("kill", "-9", strconv.Itoa(i.PID)).Run(); err != nil {
		return fmt.Errorf(
			"pid %d ignored SIGTERM for %s and could not be killed: %w", i.PID, teardownDeadline, err)
	}
	return fmt.Errorf(
		"pid %d ignored SIGTERM for %s and had to be killed — an instance that will not die is "+
			"the leftover that refuses the NEXT run, so this is reported here, while it can "+
			"still be named, rather than found later as a stray with no evidence",
		i.PID, teardownDeadline)
}

// processAlive asks only whether a pid exists, without spawning anything.
//
// Signal 0 performs the permission and existence checks and delivers nothing.
// ESRCH means gone; EPERM means alive and owned by somebody else, which for
// this caller is still "there".
func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// processEnv reads a process's environment, distinguishing a process that is
// gone from an inspection that failed.
//
// `ps -p` exits 1 when the pid does not exist, which is an answer rather than
// an error. Anything else is a failure to look, and the caller must not treat
// the resulting empty environment as a fact about the process — the previous
// version discarded this distinction and reported a broken `ps` as a HOME
// mismatch.
func processEnv(pid int, keys ...string) (map[string]string, bool, error) {
	out, err := exec.Command("ps", "-Ewww", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == 1 {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("ps -p %d: %w", pid, err)
	}
	return EnvFromPS(string(out), keys...), true, nil
}

// runningPIDs lists the processes running THIS bundle's main executable. The
// full path matters: `pgrep -f Wakil` matched three different worktrees'
// bundles on this machine (probe §2).
func runningPIDs(bundle string) ([]int, error) {
	pattern := filepath.Join(bundle, "Contents", "MacOS") + "/"
	return pgrep(pattern)
}

// spawnedChild returns one Go child of this bundle, or 0.
func spawnedChild(bundle string) (int, error) {
	pids, err := pgrep(filepath.Join(bundle, "Contents", "Resources", "wakil-"))
	if err != nil || len(pids) == 0 {
		return 0, err
	}
	return pids[0], nil
}

func pgrep(pattern string) ([]int, error) {
	out, err := exec.Command("pgrep", "-f", pattern).Output()
	if err != nil {
		// pgrep exits 1 when nothing matched, which is not a failure here.
		if exit, ok := err.(*exec.ExitError); ok && exit.ExitCode() == 1 {
			return nil, nil
		}
		return nil, fmt.Errorf("pgrep %q: %w", pattern, err)
	}
	var pids []int
	for _, field := range strings.Fields(string(out)) {
		if pid, convErr := strconv.Atoi(field); convErr == nil && pid != os.Getpid() {
			pids = append(pids, pid)
		}
	}
	return pids, nil
}

// strayBundleName is the bundle name StrayFixtures scans the whole machine
// for: StagedBundleName. Only the tests change it, to a name no other process
// on the machine runs, because the scan is machine-wide and a decoy from a
// second test binary (or a real fixture) would otherwise land in their counts.
var strayBundleName = StagedBundleName

// StrayFixtures lists OTHER fixture instances — any process running a staged
// bundle that is not the one about to be launched.
//
// **Usually a concurrent run, not a leftover.** Two agents driving `make e2e`
// on one machine is the case this was actually built for, and it is the common
// one: each run stages its own copy, both are called `dev.wakil.e2e`, and each
// calls Activate to pull ITS fixture to the front. They take the foreground
// from each other, and whichever loses has its keystrokes delivered into the
// other run's window. A fixture surviving a run that was interrupted is the
// same hazard from a different source, and both are found the same way.
//
// **They are invisible to every other guard, and that is the point.**
// `runningPIDs` scopes by the bundle PATH, and each run stages its own copy
// under a fresh temp root, so a stray from a previous run matches nothing:
// `NewPID`'s before/after difference cannot see it, and the isolation guard
// looks only at this instance's children. What it DOES share is the bundle
// identifier, which is the one thing `NSWorkspace` sorts the foreground by.
//
// **Measured, and it cost three checks.** A run whose fixture was pid 6522
// had `dev.wakil.e2e (pid 6809)` take the foreground mid-act; the keystrokes
// that followed were refused with `window_not_focused`, and the failure read
// as the app ignoring a keypress. Nothing in the run named the second
// instance, because nothing in the run could see it — and it was diagnosed as
// machine flakiness for most of a day on exactly that account.
func StrayFixtures(bundle string) ([]int, error) {
	all, err := pgrep(filepath.Join(strayBundleName, "Contents", "MacOS") + "/")
	if err != nil {
		return nil, err
	}
	mine, err := runningPIDs(bundle)
	if err != nil {
		return nil, err
	}
	ours := make(map[int]bool, len(mine))
	for _, pid := range mine {
		ours[pid] = true
	}
	var strays []int
	for _, pid := range all {
		if !ours[pid] {
			strays = append(strays, pid)
		}
	}
	sort.Ints(strays)
	return strays, nil
}

// refuseStrayFixtures stops a launch that would race a leftover instance.
//
// **A refusal rather than a warning**, for `NewPID`'s reason one file over: an
// instance the runner cannot identify is one it must not drive, and this is
// worse than ambiguous — it is a second app with this one's bundle id, free to
// take the foreground at any moment and swallow the keystrokes meant for the
// fixture. A run made under that condition produces verdicts nobody can trust,
// which is more expensive than the run that did not happen.
//
// **So two runs on one machine take turns, and are told so.** That is a real
// cost and it is the cheaper side: the alternative is two runs that both
// finish and neither of which means anything.
func refuseStrayFixtures(bundle string) error {
	strays, err := StrayFixtures(bundle)
	if err != nil || len(strays) == 0 {
		return err
	}
	return fmt.Errorf(
		"%d other fixture instance(s) are running (%s) — another e2e run on this machine, or "+
			"one left over from a run that was interrupted. They share this one's bundle "+
			"identifier, so they can take the foreground mid-act and the keystrokes meant for "+
			"this fixture go to them. Wait for the other run to finish, or close them with "+
			"`kill %s`, and retry",
		len(strays), joinInts(strays), joinInts(strays))
}
