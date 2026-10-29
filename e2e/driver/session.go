package driver

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// MCPTimeout is how long a launch is given to start listening on its socket.
const MCPTimeout = 30 * time.Second

// Session is one launch's worth of driving: a staged bundle, a fixture
// instance, and the three channels pointed at it.
//
// **It is the driver's, not the command's.** It used to live in
// `wakil-e2e`'s own `main`, which was fine while one program ran checks.
// `make e2e-new` runs the same launch against a bundle built from the
// merge-base, and a second copy of this sequence would be a second place for
// the bundle-id guard, the lsof socket resolution and the teardown refusal to
// drift out of — each of which exists because getting it wrong drives the
// OPERATOR's window with the operator's credentials.
type Session struct {
	// Bundle is the Wakil.app to drive. It is staged and re-identified before
	// launch; the original is never run.
	Bundle string
	Orca   Orca
	// Resolver resolves identifiers against the live tree. All actuation
	// stays in Orca; this one presses nothing it did not resolve.
	Resolver Resolver
	// FixtureRoot is the instance's HOME and TMPDIR. Empty means a fresh
	// directory that is removed when the session ends.
	FixtureRoot string
	// EvidenceRoot is where a failing check leaves what it saw.
	EvidenceRoot string
	// Seed says whether the instance opens with an organisation. It is a
	// property of the LAUNCH: an instance either has one on disk and open or
	// it does not, and the two want opposite assertions.
	Seed        bool
	Quarantined []string
	// Settle bounds how long an assertion waits for its predicate. Zero takes
	// DefaultSettle; a caller wanting no waiting passes a negative duration.
	Settle time.Duration
	// Agent is the scripted agent this run seeds onto the provider record,
	// or the zero value for a fixture with no agent — which is what every
	// check that does not drive one wants.
	Agent AgentFixture
	// Log is where the session narrates itself. Nil is silent.
	Log func(format string, args ...interface{})
}

// readAgentLog reads what the scripted agent recorded, or says it recorded
// nothing at all — which is itself the answer when a turn never reached it.
func readAgentLog(path string) string {
	if path == "" {
		return ""
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "the agent was never run: " + path + " does not exist"
		}
		return "the agent's log could not be read: " + err.Error()
	}
	return strings.TrimSpace(string(data))
}

// settleFor picks how long this launch's assertions wait.
//
// **A launch that carries the agent waits longer**, because what its
// assertions wait for is a subprocess and not a redraw — see AgentSettle. An
// explicit Settle still wins, including a negative one: a caller that named a
// duration knows something this does not, and `--settle -1` is how a run asks
// for no waiting at all.
func settleFor(explicit time.Duration, hasAgent bool) time.Duration {
	if explicit != 0 {
		return explicit
	}
	if hasAgent {
		return AgentSettle
	}
	return DefaultSettle
}

// agentLogPath is where the scripted agent leaves its log, or empty when this
// run has no agent to leave one.
func agentLogPath(fixture Fixture, seeded Seeded, stub string) string {
	if stub == "" || seeded.Provider == "" {
		return ""
	}
	return filepath.Join(fixture.Root, "claude-"+seeded.Provider, AgentStubLogFile)
}

// FixtureProviderToken is what the scripted agent's provider record carries.
//
// **A constant, and obviously not a credential.** It reaches `buildLaunch` as
// `CLAUDE_CODE_OAUTH_TOKEN` and the scripted agent ignores it; what it is for
// is `decodeProviderCredentials`, which refuses an empty one — so without it
// the window has no agent and a check that drove it would fail for a reason
// that has nothing to do with what it was written to prove.
const FixtureProviderToken = "e2e-fixture-not-a-real-token"

// providerToken is the credential to store for this run, or none.
func (s Session) providerToken() string {
	if !s.Agent.SeedsAnAgent() {
		return ""
	}
	return FixtureProviderToken
}

// Run launches an instance, executes the checks against it, and tears it down.
//
// The returned error is a fault in the RUN — a bundle that would not stage, a
// launch that did not come up, a channel that never opened, a teardown that
// refused. It is never the checks' own verdict, which is Result.Err's
// question: a caller that requires the checks to go red — `wakil-e2e-new`,
// `wakil-e2e-retrodict` — must still treat a run error as a hard failure,
// because everything going red because the harness could not work looks
// identical to success.
func (s Session) Run(checks []Check) (result Result, err error) {
	// **First, because these are the failures this harness cannot work
	// around and the cheapest to find.** A locked screen presents no window
	// and a full disk presents no agent, and each of them blames the app for
	// thirty seconds before saying anything true. See RefuseIfScreenLocked
	// and RefuseIfDiskIsTight.
	if err := RefuseIfScreenLocked(); err != nil {
		return Result{}, err
	}
	if err := RefuseIfDiskIsTight(s.FixtureRoot); err != nil {
		return Result{}, err
	}
	root := s.FixtureRoot
	if root == "" {
		root, err = os.MkdirTemp("", "wakil-e2e")
		if err != nil {
			return Result{}, err
		}
		defer os.RemoveAll(root)
	}
	fixture, err := NewFixture(root)
	if err != nil {
		return Result{}, err
	}

	// **The shell profile is seeded on every launch, not only for the check
	// that reads it.** It is what makes the fixture home look like a home:
	// Wakil sources `$HOME/.zprofile` by hand for every pane it opens, and a
	// fixture without one is a machine whose operator has no shell
	// configuration at all — a state no real run is ever in. See SeedProfile.
	if _, err := SeedProfile(fixture); err != nil {
		return Result{}, err
	}

	// **Seeded before the launch, because WAKIL_ORG has to be on the launch
	// itself.** `WakilWiring.build` reads the app's own WAKIL_ORG and passes
	// it to every spawned Go child (AppWiring.swift), and `CurrentOrg` has no
	// other source, so an instance launched without it resolves no org
	// however much state is on disk.
	var seeded Seeded
	var chatStub, pageStub string
	if s.Seed {
		spec := DefaultSeed()
		// The cancel check's slow server (W14). Alive for the whole launch, closed with it.
		stall, err := StartStallListener()
		if err != nil {
			return Result{}, err
		}
		defer stall.Close()
		spec.StallOrigin = stall.Origin()
		// The fast path's local model (3b-ix). Alive for the whole launch; a
		// check points a local provider at it with ChatStubToken.
		origin, stopChat, err := StartChatStub()
		if err != nil {
			return Result{}, err
		}
		defer stopChat()
		chatStub = origin
		// The browser checks' pages (3c-i). Alive for the whole launch; a
		// check names it with PageStubToken.
		pages, stopPages, err := StartPageStub(PageFixtures)
		if err != nil {
			return Result{}, err
		}
		defer stopPages()
		pageStub = pages
		// **The scripted agent goes on the provider record, when there is
		// one.** A run without it seeds a record with no `claudePath`, which
		// `decodeProviderCredentials` refuses — so the window opens with no
		// agent and says so, exactly as every check before #255 expected.
		// Staged into the fixture first, never named in the checkout: see
		// StageAgentStub for the Desktop-folder prompt that otherwise held
		// every first turn after a rebuild.
		stub, err := StageAgentStub(s.Agent.Stub, fixture)
		if err != nil {
			return Result{}, err
		}
		spec.AgentBinary, spec.AgentScript = stub, s.Agent.Script
		spec.SpareProvider = SpareProviderFor(stub)
		// The search-Cancel check's 200 MiB haystack, for its launch only (SeedSpec.SearchHaystack).
		spec.SearchHaystack = WantsSearchHaystack(checks)
		// 3a-ii's failing (and, on request, slow) pre-commit hook, for its launch only (SeedSpec.GitHook).
		spec.GitHook = WantsGitHook(checks)
		// 3a-iii's last clone folder, for the clone check's launch only (SeedSpec.CloneFolder).
		spec.CloneFolder = WantsCloneFolder(checks)
		// 3c-ii's staging site and production project, for the tags and production checks only.
		spec.BrowserSites = WantsBrowserSites(checks)
		spec.PageStub = pageStub
		seeded, err = Seed(fixture, spec)
		if err != nil {
			return Result{}, err
		}
		s.logf("seeded org %q, project %q, environment %q",
			seeded.Org, seeded.Project, seeded.Environment)
	} else {
		s.logf("--no-seed, so this instance opens on the organisation plane")
	}

	absBundle, err := filepath.Abs(s.Bundle)
	if err != nil {
		return Result{}, err
	}

	// **The instance runs under its own bundle id, and that is load-bearing.**
	// Orca refuses EVERY click on a second instance of a bundle id another
	// running instance also claims — by coordinate and by element index alike
	// — because its click precondition resolves the focused topmost recipient
	// through the bundle and finds the operator's window. Measured 2026-09-23:
	// same build, same fixture, same coordinates, `ok: true` from a copy
	// carrying dev.wakil.e2e. See E2EBundleIdentifier.
	staged, err := StageBundle(absBundle, fixture)
	if err != nil {
		return Result{}, err
	}
	stagedID, err := StagedBundleIdentifier(staged)
	if err != nil {
		return Result{}, err
	}
	if stagedID != E2EBundleIdentifier {
		return Result{}, fmt.Errorf(
			"the staged bundle still claims %q — a run under the operator's own bundle id "+
				"cannot be clicked at all, and must not be attempted", stagedID)
	}
	s.logf("staged %s as %s", filepath.Base(absBundle), stagedID)

	instance, err := Launch{
		Bundle:  staged,
		Fixture: fixture,
		Seeded:  seeded,
		Orca:    s.Orca,
		// **launchd's PATH, never the harness's.** A bundled app inherits the
		// system default; this process inherits a terminal's. Handing the
		// fixture the richer one makes every pane it opens find tools the
		// shipped app cannot, and 2c-iii's check 1 — the one check catching a
		// class no test can see — would pass without testing anything.
		BasePATH: LaunchdPATH,
		// **A credential only where there is an agent to use it.** A run
		// without the scripted agent seeds a record with no binary, and a
		// token stored for it would be a secret in a keychain nothing reads.
		ProviderToken: s.providerToken(),
	}.Start()
	if err != nil {
		return Result{}, err
	}
	s.logf("fixture instance pid %d, HOME %s", instance.PID, fixture.Home)

	// **Brought to the front before any check runs.** Keystrokes are refused
	// outright unless the target window is frontmost, and an app started with
	// `open -n` does not reliably become so — measured 2026-09-24, four acts
	// refused in a row with three checks around them passing. A failure here
	// is logged rather than fatal: the checks that need focus will say so
	// themselves, in Orca's own words, and a check that needs none should not
	// be stopped by it.
	if activateErr := Activate(instance.PID); activateErr != nil {
		s.logf("could not bring the fixture window forward (%v) — "+
			"any keystroke will be refused until something does", activateErr)
	}

	// Deferred, so a panic in the runner cannot leave a second Wakil on the
	// operator's screen and a keychain behind it.
	//
	// **A teardown failure fails the run.** It used to be printed to stderr
	// and dropped, so a run whose teardown REFUSED to kill still exited 0 when
	// the checks passed — a stray fixture instance, reported as success. The
	// premise of this harness is that silence is not success, and it applies
	// to the harness's own housekeeping first.
	defer func() {
		if closeErr := instance.Close(); closeErr != nil {
			if err == nil {
				err = fmt.Errorf("the run finished but teardown did not: %w", closeErr)
			} else {
				err = fmt.Errorf("%w (and teardown did not finish either: %v)", err, closeErr)
			}
		}
	}()

	// **The observation channel, opened before any check runs.** It is the
	// socket the window opened for the place it shows — Invariant 3's channel,
	// the one a real agent there speaks — found by asking `lsof` what THIS pid
	// holds, and each socket which place it is pinned to (ScreenChannel), again
	// whenever the screen moves. Never a directory scan: the fixture's sockets
	// land in the same per-user directory as the operator's (Foundation's
	// `temporaryDirectory` ignores an injected TMPDIR), nothing unlinks one at
	// exit, and a wrong choice here would dispatch actions into the operator's
	// live window.
	//
	// **A failure to open it fails the run.** The alternative is a pass that
	// proves whatever the tree happened to show, with the channel that answers
	// what the app BELIEVES silently absent.
	client, err := AwaitMCP(instance.PID, MCPTimeout)
	if err != nil {
		return Result{}, err
	}
	defer client.Close()
	server, err := client.Initialize()
	if err != nil {
		return Result{}, err
	}
	tools, err := client.Tools()
	if err != nil {
		return Result{}, err
	}
	socket, err := client.Socket()
	if err != nil {
		return Result{}, err
	}
	s.logf("%s on %s, %d action(s)", server, filepath.Base(socket), len(tools))

	// **The operator channel**: the socket the staged fixture opens beside each agent socket,
	// for the actions only the operator may run (OperatorChannel). Found the same way, by this
	// pid. A build without one — the merge-base `make e2e-new` drives — has none, and every
	// dispatch goes over the agent socket as it did there.
	operator, err := AwaitOperator(instance.PID, client)
	if err != nil {
		return Result{}, err
	}
	if operator != nil {
		defer operator.Close()
		s.logf("operator channel on %s, %d operator-only action(s)", filepath.Base(operator.Socket()), operator.Actions())
	} else {
		s.logf("no operator channel: this build opens none, so operator-only actions go over the agent socket")
	}

	// **The evidence directory is named before the checks run**, so a run
	// that dies mid-flight still says where to look.
	evidence := &Evidence{
		Dir: RunDir(s.EvidenceRoot, time.Now().UTC().Format("20060102-150405")),
		// The scripted agent writes beside the script the seed laid down, and
		// the seed puts that in the provider's config directory.
		AgentLog:    agentLogPath(fixture, seeded, s.Agent.Stub),
		GoneFixture: DescribeGoneFixture,
	}
	s.logf("evidence for any failure lands in %s", evidence.Dir)

	settle := settleFor(s.Settle, s.Agent.SeedsAnAgent())
	runner := &Runner{
		Orca:         s.Orca,
		Resolver:     s.Resolver,
		Channel:      client,
		PID:          instance.PID,
		FixtureRoot:  fixture.Root,
		ChatStub:     chatStub,
		PageStub:     pageStub,
		PageStubLive: PageStubLive(pageStub),
		Processes:    PS{},
		Journal:      FileJournal{Home: fixture.Home},
		Evidence:     evidence,
		Settle:       settle,
		Quarantined:  s.Quarantined,
		Input:        s.Resolver.WatchInput,
	}
	if operator != nil {
		runner.Operator = operator
	}
	result = runner.Run(checks)
	// **The scripted agent's log is read before teardown, always.** The
	// fixture holding it is deleted on the way out, and a turn that never
	// started looks exactly like a turn that answered wrongly from outside the
	// window — which is two runs' difference and no way to tell them apart.
	if log := readAgentLog(evidence.AgentLog); log != "" {
		s.logf("the scripted agent's log:\n%s", log)
	}
	result.Fatal = append(result.Fatal, s.agentNeverRan(evidence.AgentLog)...)
	// The denominator travels with the result rather than being written here:
	// a Session does not know where a command keeps its records, and the two
	// programs that run one keep them in different places.
	result.Tools = tools
	result.Evidence = evidence.Dir
	return result, nil
}

// agentNeverRan reports the one agent failure that no assertion can be trusted
// to catch: the window never launched the agent at all.
//
// **Fatal rather than an assertion failure, and that is the point.** A launch
// that seeded an agent and never ran one produced no turn, so every assertion
// downstream of a send failed for a reason that has nothing to do with what it
// was written to prove — and under `make e2e-new`, where red is the wanted
// outcome, that red would be read as proof. `Verdict` already refuses to count
// a run with a `Fatal`.
//
// **It is also what keeps `AgentSettle` honest.** A twenty-second deadline is
// for a turn that is slow; it must never be what a turn that never happened
// hides behind. Waiting longer cannot turn this green, because it is not an
// assertion and no amount of re-reading produces a log file that was never
// written.
func (s Session) agentNeverRan(logPath string) []string {
	if !s.Agent.SeedsAnAgent() || logPath == "" {
		return nil
	}
	if _, err := os.Stat(logPath); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return []string{fmt.Sprintf(
			"the scripted agent's log at %s could not be read (%v), so whether the window ever "+
				"launched the agent is unknown — and a check that drove one cannot be believed "+
				"either way", logPath, err)}
	}
	return []string{fmt.Sprintf(
		"the window never launched the scripted agent: nothing wrote %s. Every assertion after a "+
			"send therefore failed for a reason that has nothing to do with what it asserts. This "+
			"is #284's original symptom; see that issue before reading anything else in this run",
		logPath)}
}

func (s Session) logf(format string, args ...interface{}) {
	if s.Log == nil {
		return
	}
	s.Log(format, args...)
}
