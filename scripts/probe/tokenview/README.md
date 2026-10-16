# The token-view spike (Amendment 10, Task 1)

A throwaway probe that answers whether Amendment 10's foundation holds: one TextKit 2
`NSTextView` whose hole is an attachment **view** (`NSTextAttachmentViewProvider`) carrying a real
`×` `NSButton`. Three questions gate the plan — (a) the `×` is in the AX tree with its identifier
and the harness's AX press reaches it, (b) Backspace deletes the attachment as one unit, (c) the
caret and selection treat it as one character — and two are measured, not gated: (d) a drag from
the token view onto another text view, (e) whether the tree Orca reads carries the editor's text.

Kept so the answer can be re-measured against a later macOS or Orca rather than re-argued.

**It uses the GUI** (a 420×160 window called TokenProbe, five short runs). Ask the operator and
the peer sessions first. Run it once; a retried measurement is not one.

## Run it

`run-spike.sh` is the block below, run once as written, with a PASS/FAIL line per item and every
raw output kept under `$OUT/results/` for the Result column. From the repo root:

```sh
scripts/probe/tokenview/run-spike.sh
```

Before the GUI items it runs `token-probe --self-check` (no GUI: an off-screen window never
ordered in, the app never activated), which walks the editor's AX children through both entry
points and stops the run if that walk does not come back (spike run 2 overflowed the stack there).

The block it runs, item by item:

```sh
OUT=/private/tmp/claude-501/token-probe; mkdir -p "$OUT"   # or the session scratchpad
swiftc -parse-as-library -o "$OUT/token-probe" scripts/probe/tokenview/probe-app.swift
make axresolve
ORCA=/Applications/Orca.app/Contents/Resources/bin/orca
run() { rm -f "$OUT/probe.log"; PROBE_LOG="$OUT/probe.log" "$OUT/token-probe" & PID=$!; sleep 2; }

# (a) the × is in the tree with its identifier, and the harness's AX press reaches it
run
e2e/bin/axresolve --pid $PID | grep -E 'probe\.(part|editor)'
e2e/bin/axresolve --pid $PID --identifier probe.part.1.remove --press
grep -E 'pressed|probe.editor text=' "$OUT/probe.log"; kill $PID

# (b) Backspace after the attachment deletes it as one unit
run
e2e/bin/axresolve --pid $PID --identifier probe.editor --focus
$ORCA computer hotkey    --app pid:$PID --key cmd+Right --restore-window --no-screenshot --json
$ORCA computer press-key --app pid:$PID --key Left      --restore-window --no-screenshot --json
$ORCA computer press-key --app pid:$PID --key Left      --restore-window --no-screenshot --json
$ORCA computer press-key --app pid:$PID --key Backspace --restore-window --no-screenshot --json
grep 'probe.editor text=' "$OUT/probe.log"; kill $PID

# (c) caret and selection are native: the token is one unit
run
e2e/bin/axresolve --pid $PID --identifier probe.editor --focus
$ORCA computer hotkey    --app pid:$PID --key cmd+Left   --restore-window --no-screenshot --json
for i in 1 2 3 4; do $ORCA computer press-key --app pid:$PID --key Right --restore-window --no-screenshot --json; done
$ORCA computer hotkey    --app pid:$PID --key shift+Left --restore-window --no-screenshot --json
grep 'probe.editor selection=' "$OUT/probe.log"; kill $PID

# (d) MEASURED, not gated: a drag from the token view onto the other text view
run
e2e/bin/axresolve --pid $PID --identifier probe.part.1.token --drag-to probe.other
grep 'text=' "$OUT/probe.log"; kill $PID

# (e) MEASURED, not gated: does the tree Orca reads carry the text view's text?
run
$ORCA computer get-app-state --app pid:$PID --no-screenshot --json |
  python3 -c "import sys,json;print(json.load(sys.stdin)['result']['snapshot']['treeText'])" | grep -c '/a/'
kill $PID
```

## Result

| | Pass criterion (exact) | Result |
|---|---|---|
| **(a) GATE** | `axresolve --pid` lists `probe.part.1.remove` with role `AXButton`, and also `probe.editor`. `--press` answers `"ok":true`. The log then holds `pressed` followed by `probe.editor text=/a//b`. | |
| **(b) GATE** | After the Backspace, the log's last `probe.editor text=` line is exactly `/a//b`, with no `⟨id⟩` and with both slashes kept. | |
| **(c) GATE** | The `selection=` lines end `0,0` `1,0` `2,0` `3,0` `4,0` `3,1`. Four Rights pass three characters and then the token in one step, and shift+Left selects exactly the token. | |
| (d) measured | `probe.other text=` holds `⟨` (the token arrived, as `⟨id⟩` or `⟨foreign:…⟩`), and whether `probe.editor text=` lost it. | |
| (e) measured | The count is ≥ 1, or 0. | |
