package driver

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// DefaultEvidenceRoot is where a run leaves what it saw and what it observed:
// a failing check's screenshot, tree and pane snapshot under a per-run
// directory, and the action denominator beside them.
//
// **A fixed, known path, because the coverage gate has to find it without
// being told** — the reason `DefaultVerdictRoot` is one, one file over.
const DefaultEvidenceRoot = ".context/e2e"

// Evidence is where a red run leaves what it saw.
//
// **Every failure writes a screenshot, the accessibility tree and a
// `read_pane` snapshot**, so a red run is diagnosable without reproducing it.
// Reproducing a GUI failure costs a launch, a fixture and the operator's
// screen, and an intermittent one may not reproduce at all.
//
// It takes its collaborators as arguments rather than holding a Runner: the
// runner already depends on this, and a back-reference would make the two
// mutually dependent for no gain.
type Evidence struct {
	// Dir is the run's directory — `.context/e2e/<run>/`. Each failing check
	// gets a subdirectory named after it.
	Dir string

	// gaps carries, per check, what could not be gathered. It is written out
	// by Record, so a reader of a red run learns that the screenshot was
	// missing rather than wondering why there isn't one.
	gaps map[string][]string

	// AgentLog is the scripted agent's own log, when this run has one. It is
	// copied into the evidence directory on a failure, because the fixture it
	// lives in is deleted at teardown — and a turn that never started and a
	// turn that answered wrongly look identical from outside the window.
	AgentLog string

	// acts carries, per check, what the check did and what the window server
	// believed while it did it. See Evidence.Acts.
	acts map[string][]string

	// artefacts carries, per check, what WAS gathered.
	//
	// **Recorded because the directory it lands in is gitignored.** A runbook
	// can only cite this evidence by name and location, so a reader deciding
	// whether to ask for a screenshot has to be told one exists — and a
	// section that listed the three artefacts a failing check usually writes
	// would be asserting what it had not looked at.
	artefacts map[string][]string

	// GoneFixture describes a fixture whose process has gone (#15): what macOS logged for its
	// pid, and any crash report. Capture writes it to fixture-gone.txt only when the pid is no
	// longer running. Nil skips it — the session sets `DescribeGoneFixture`.
	GoneFixture func(pid int) string
}

// RunDir names a fresh evidence directory for one run.
func RunDir(root, stamp string) string { return filepath.Join(root, stamp) }

// Capture records what the window looks like RIGHT NOW.
//
// **Called at the failing step, not at the end of the check.** A capture
// taken after the remaining steps have run shows a window several acts
// further on than the one that failed, which is the state least useful for
// diagnosing it.
//
// **A failure to gather evidence never masks the failure it was gathering
// evidence about.** Each artefact is attempted independently and what could
// not be read is recorded as a gap, because a harness that lost the original
// failure when its screenshot failed would be worse than one that took no
// screenshots at all.
func (e *Evidence) Capture(orca Orca, pid int, channel Channel, check string) {
	if e == nil || e.Dir == "" {
		return
	}
	dir := filepath.Join(e.Dir, check)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		e.gap(check, fmt.Sprintf("the evidence directory could not be made: %v", err))
		return
	}

	capture, captureErr := orca.Capture(pid)
	switch {
	case captureErr != nil:
		e.gap(check, fmt.Sprintf("the tree could not be read: %v", captureErr))
		e.write(check, dir, "tree.txt", fmt.Sprintf("unavailable: %v", captureErr))
	case !capture.OK:
		e.gap(check, fmt.Sprintf("orca refused the read: %v", capture.Err))
		e.write(check, dir, "tree.txt", fmt.Sprintf("unavailable: %v", capture.Err))
	default:
		e.write(check, dir, "tree.txt", capture.Snapshot.TreeText)
	}

	// **The screenshot is copied, never referenced.** Orca's
	// `prepareComputerCliJsonResult` writes the capture to a temporary file
	// with a TTL and hands back its path, so a path recorded here would be
	// dangling by the time anyone read it.
	switch {
	case capture.ScreenshotPath != "":
		to := filepath.Join(dir, "screenshot"+filepath.Ext(capture.ScreenshotPath))
		if err := copyFile(capture.ScreenshotPath, to); err != nil {
			e.gap(check, fmt.Sprintf("the screenshot could not be copied: %v", err))
		} else {
			e.gathered(check, filepath.Base(to))
		}
	case captureErr != nil || !capture.OK:
		e.gap(check, "no screenshot was captured, because the read it comes with failed")
	default:
		e.gap(check, fmt.Sprintf("orca captured no screenshot (screenshotStatus was %q)",
			describeState(capture.ScreenshotState)))
	}

	e.write(check, dir, "panes.json", e.panes(channel, check))

	// **A fixture that went away mid-check is the fact, not a missing tree** (#15). It was seen
	// once, with no crash report, as "orca refused the read: app_not_found" — which reads like
	// the harness losing the pid. Whether the process is gone, and what macOS said about it,
	// is what tells the two apart.
	if e.GoneFixture != nil && pid > 0 && syscall.Kill(pid, 0) == syscall.ESRCH {
		e.write(check, dir, "fixture-gone.txt",
			fmt.Sprintf("the fixture (pid %d) is no longer running\n\n%s", pid, e.GoneFixture(pid)))
	}
}

// panes renders what every pane in the window contains.
//
// **`read_pane` per pane, not `read_layout` alone.** The layout says which
// panes exist; what a pane CONTAINS is `read_pane`'s question, and it is the
// one the tree cannot answer — a data-surface row is one element with its
// cells deliberately hidden.
func (e *Evidence) panes(channel Channel, check string) string {
	if channel == nil {
		e.gap(check, "no agent channel was open, so no pane snapshot could be taken")
		return "unavailable: no agent channel was open"
	}
	layout, err := channel.Call("read_layout", nil)
	if err != nil {
		e.gap(check, fmt.Sprintf("read_layout failed: %v", err))
		return fmt.Sprintf("unavailable: %v", err)
	}
	body := ResultBody(layout)

	snapshot := map[string]interface{}{"layout": json.RawMessage(body)}
	panes := map[string]interface{}{}
	for _, id := range paneIDs(body) {
		pane, err := channel.Call("read_pane", map[string]interface{}{"paneId": id})
		if err != nil {
			e.gap(check, fmt.Sprintf("read_pane %q failed: %v", id, err))
			panes[id] = fmt.Sprintf("unavailable: %v", err)
			continue
		}
		panes[id] = json.RawMessage(ResultBody(pane))
	}
	snapshot["panes"] = panes

	encoded, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		e.gap(check, fmt.Sprintf("the pane snapshot could not be encoded: %v", err))
		return string(body)
	}
	return string(encoded)
}

// paneIDs reads the pane ids out of a read_layout reply. A reply it cannot
// read yields no ids rather than an error: the layout itself is already
// written out, so the ids are a convenience on top of it.
func paneIDs(body []byte) []string {
	var layout struct {
		Panes []struct {
			ID string `json:"id"`
		} `json:"panes"`
	}
	if err := json.Unmarshal(body, &layout); err != nil {
		return nil
	}
	var ids []string
	for _, pane := range layout.Panes {
		if pane.ID != "" {
			ids = append(ids, pane.ID)
		}
	}
	return ids
}

// Record writes the failures themselves, and whatever could not be gathered
// alongside them.
func (e *Evidence) Record(check string, failures []string) error {
	if e == nil || e.Dir == "" {
		return nil
	}
	dir := filepath.Join(e.Dir, check)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// **This one is returned rather than recorded as a gap.** The gaps file
	// explains why an artefact is missing; if the failures themselves cannot
	// be written there is nothing left to explain them to.
	if err := os.WriteFile(filepath.Join(dir, "failure.txt"),
		[]byte(joinNewlines(failures)+"\n"), 0o644); err != nil {
		return err
	}
	e.gathered(check, "failure.txt")
	if gaps := e.gaps[check]; len(gaps) > 0 {
		e.write(check, dir, "evidence-gaps.txt", joinNewlines(gaps))
	}
	// **A turn that never started is EVIDENCE, not a missing artefact.**
	// #284: this copied the file and recorded a gap when it was absent, so
	// the single most important fact about the commonest agent failure —
	// the window never launched the agent at all — was filed as "the agent's
	// log could not be copied: no such file", which reads like the harness
	// broke. `readAgentLog` already has the sentence for it, and is what the
	// session prints; writing what IT returns means a reader of the evidence
	// and a reader of the console are told the same thing.
	if body := readAgentLog(e.AgentLog); body != "" {
		e.write(check, dir, "agent-log.txt", body)
	}
	// **What the check DID, beside what it saw. #284.** The screenshot and
	// the tree describe the window at the failing step; neither says which
	// acts got there, and the failure this was added for is an act that
	// reported success and did nothing — invisible in every other artefact
	// by construction. See Runner.logAct.
	if len(e.acts[check]) > 0 {
		e.write(check, dir, "acts.txt", joinNewlines(e.acts[check]))
	}
	return nil
}

// Acts records what a check did, for Record to write beside what it saw.
//
// **Handed in rather than accumulated here.** The runner is what performs the
// acts and the only thing that knows their order; an evidence writer that
// collected them would have to be told about every arm of `Runner.act`.
func (e *Evidence) Acts(check string, acts []string) {
	if e == nil || len(acts) == 0 {
		return
	}
	if e.acts == nil {
		e.acts = map[string][]string{}
	}
	e.acts[check] = acts
}

// write puts one artefact down, and records its own failure as a gap.
//
// **A discarded write is the same silence this harness exists to refuse.**
// The gap note is the thing that tells a reader an artefact is missing, so
// dropping the error from writing it would defeat the mechanism twice over.
func (e *Evidence) write(check, dir, name, body string) {
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body+"\n"), 0o644); err != nil {
		e.gap(check, fmt.Sprintf("%s could not be written: %v", name, err))
		return
	}
	e.gathered(check, name)
}

// gathered records that one artefact was written.
func (e *Evidence) gathered(check, name string) {
	if e.artefacts == nil {
		e.artefacts = map[string][]string{}
	}
	e.artefacts[check] = append(e.artefacts[check], name)
}

// Gathered lists what this check's evidence directory actually holds, and
// Missing what could not be gathered. Both travel into the run record, because
// the directory itself does not travel anywhere: it is gitignored.
func (e *Evidence) Gathered(check string) []string {
	if e == nil {
		return nil
	}
	return e.artefacts[check]
}

func (e *Evidence) Missing(check string) []string {
	if e == nil {
		return nil
	}
	return e.gaps[check]
}

func (e *Evidence) gap(check, note string) {
	if e.gaps == nil {
		e.gaps = map[string][]string{}
	}
	e.gaps[check] = append(e.gaps[check], note)
}

// describeState names an empty screenshot state rather than printing `""`.
func describeState(state string) string {
	if state == "" {
		return "absent from the reply"
	}
	return state
}

func copyFile(from, to string) error {
	source, err := os.Open(from)
	if err != nil {
		return err
	}
	defer source.Close()
	destination, err := os.Create(to)
	if err != nil {
		return err
	}
	defer destination.Close()
	if _, err := io.Copy(destination, source); err != nil {
		return err
	}
	return destination.Close()
}

// DescribeGoneFixture is GoneFixture's shipped answer: the unified log's last ten minutes for
// the pid — an exit, a watchdog or a jetsam kill leaves a line there and no crash report — and
// any Wakil crash report written in the same ten minutes.
func DescribeGoneFixture(pid int) string {
	var b strings.Builder
	out, err := exec.Command("/usr/bin/log", "show", "--last", "10m", "--style", "compact",
		"--predicate", fmt.Sprintf("processID == %d", pid)).CombinedOutput()
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(lines) > 200 {
		lines = lines[len(lines)-200:]
	}
	fmt.Fprintf(&b, "unified log, last 10 minutes, processID == %d", pid)
	if err != nil {
		fmt.Fprintf(&b, " (log show: %v)", err)
	}
	b.WriteString(":\n" + strings.Join(lines, "\n") + "\n\ncrash reports from the last 10 minutes:\n")
	reports := filepath.Join(os.Getenv("HOME"), "Library", "Logs", "DiagnosticReports")
	entries, _ := os.ReadDir(reports)
	found := false
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil || !strings.Contains(entry.Name(), "Wakil") || time.Since(info.ModTime()) > 10*time.Minute {
			continue
		}
		b.WriteString(filepath.Join(reports, entry.Name()) + "\n")
		found = true
	}
	if !found {
		b.WriteString("none\n")
	}
	return b.String()
}
