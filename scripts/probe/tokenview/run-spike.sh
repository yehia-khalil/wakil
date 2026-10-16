#!/usr/bin/env bash
# run-spike.sh — Amendment 10's spike, the README's block run once, as written, with a verdict.
#
# Uses the GUI: a 420x160 window called TokenProbe, five short runs. Ask the operator first.
# Runs each item ONCE — a retried measurement is not one. Quits the probe after every item and on
# exit. Safe to re-run: it rebuilds the probe, clears its own logs, and kills a stale probe.
#
#   scripts/probe/tokenview/run-spike.sh            # from the repo root
#   OUT=/some/dir scripts/probe/tokenview/run-spike.sh
#
# Every raw output lands in $OUT/results/ so the README's Result column can quote it verbatim.
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT" || exit 2
OUT=${OUT:-/private/tmp/claude-501/token-probe}
RES="$OUT/results"
ORCA=/Applications/Orca.app/Contents/Resources/bin/orca
AX="$ROOT/e2e/bin/axresolve"
PID=""

mkdir -p "$OUT" && rm -rf "$RES" && mkdir -p "$RES"

stop() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID"; wait "$PID" 2>/dev/null; fi
  PID=""
}
trap stop EXIT INT TERM
pkill -x token-probe 2>/dev/null

swiftc -parse-as-library -o "$OUT/token-probe" scripts/probe/tokenview/probe-app.swift || { echo "FAIL build"; exit 2; }
make axresolve >/dev/null || { echo "FAIL make axresolve"; exit 2; }
[ -x "$ORCA" ] || { echo "FAIL no orca at $ORCA"; exit 2; }
# No GUI: an off-screen window never ordered in. Proves the AX walk is finite (run 2 overflowed).
PROBE_LOG="$RES/selfcheck.log" "$OUT/token-probe" --self-check > "$RES/selfcheck.txt" 2>&1 \
  || { rc=$?; cat "$RES/selfcheck.txt"; echo "FAIL self-check rc=$rc — not starting the GUI runs"; exit 2; }
tail -1 "$RES/selfcheck.txt"

run() { stop; rm -f "$OUT/probe.log"; PROBE_LOG="$OUT/probe.log" "$OUT/token-probe" & PID=$!; sleep 2; }
keep() { cp "$OUT/probe.log" "$RES/$1.log" 2>/dev/null || : > "$RES/$1.log"; }
key()  { $ORCA computer press-key --app pid:$PID --key "$1" --restore-window --no-screenshot --json >> "$RES/$ITEM.orca.jsonl"; echo >> "$RES/$ITEM.orca.jsonl"; }
hot()  { $ORCA computer hotkey    --app pid:$PID --key "$1" --restore-window --no-screenshot --json >> "$RES/$ITEM.orca.jsonl"; echo >> "$RES/$ITEM.orca.jsonl"; }

# (a) the × is in the tree with its identifier, and the harness's AX press reaches it
ITEM=a; run
"$AX" --pid $PID > "$RES/a.tree.json"
"$AX" --pid $PID --identifier probe.part.1.remove --press > "$RES/a.press.json"
sleep 0.5; keep a; stop

# (b) Backspace after the attachment deletes it as one unit
ITEM=b; run
"$AX" --pid $PID --identifier probe.editor --focus > "$RES/b.focus.json"
hot cmd+Right; key Left; key Left; key Backspace
sleep 0.5; keep b; stop

# (c) caret and selection are native: the token is one unit
ITEM=c; run
"$AX" --pid $PID --identifier probe.editor --focus > "$RES/c.focus.json"
hot cmd+Left
for i in 1 2 3 4; do key Right; done
hot shift+Left
sleep 0.5; keep c; stop

# (d) MEASURED, not gated: a drag from the token view onto the other text view
ITEM=d; run
"$AX" --pid $PID --identifier probe.part.1.token --drag-to probe.other > "$RES/d.drag.json"
sleep 1; keep d; stop

# (e) MEASURED, not gated: does the tree Orca reads carry the text view's text?
ITEM=e; run
$ORCA computer get-app-state --app pid:$PID --no-screenshot --json > "$RES/e.state.json"
keep e; stop

# ---- verdicts ---------------------------------------------------------------------------------
python3 - "$RES" <<'PY'
import json, sys, os
res = sys.argv[1]
def read(name):
    try: return open(os.path.join(res, name), encoding="utf-8").read()
    except OSError: return ""
def js(name):
    try: return json.loads(read(name))
    except Exception: return None
def lines(item): return read(f"{item}.log").splitlines()
def texts(item, tag): return [l.split(" text=", 1)[1] for l in lines(item) if l.startswith(f"{tag} text=")]
def sels(item): return [l.split(" selection=", 1)[1] for l in lines(item) if l.startswith("probe.editor selection=")]
def say(label, ok, detail): print(f"{label:<16} {ok}  {detail}")
gates = []

# (a)
tree = js("a.tree.json") or {}
els = {e.get("identifier"): e for e in (tree.get("elements") or [])}
remove = els.get("probe.part.1.remove")
press = js("a.press.json") or {}
log = lines("a")
pi = next((i for i, l in enumerate(log) if l == "pressed"), None)
after = [l for l in log[(pi or 0) + 1:] if l.startswith("probe.editor text=")] if pi is not None else []
ok_a = (remove is not None and remove.get("role") == "AXButton" and "probe.editor" in els
        and press.get("ok") is True and pi is not None and "probe.editor text=/a//b" in after)
gates.append(ok_a)
say("(a) GATE", "PASS" if ok_a else "FAIL",
    f"remove={'role='+remove.get('role','?') if remove else 'absent'} editor={'probe.editor' in els} "
    f"press.ok={press.get('ok')} viewProvider-asked={'viewProvider asked' in log} log={log}")

# (b)
t = texts("b", "probe.editor")
ok_b = bool(t) and t[-1] == "/a//b"
gates.append(ok_b)
say("(b) GATE", "PASS" if ok_b else "FAIL", f"last probe.editor text={t[-1] if t else '(none)'}")

# (c)
s = sels("c")
want = ["0,0", "1,0", "2,0", "3,0", "4,0", "3,1"]
ok_c = s[-6:] == want
gates.append(ok_c)
say("(c) GATE", "PASS" if ok_c else "FAIL", f"selection lines={s}")

# (d) measured
other = texts("d", "probe.other"); ed = texts("d", "probe.editor")
arrived = any("⟨" in x for x in other)
lost = bool(ed) and "⟨" not in ed[-1]
drag = js("d.drag.json") or {}
say("(d) measured", "PASS" if arrived else "FAIL",
    f"arrived={arrived} editor-lost-it={lost} drag.ok={drag.get('ok')} "
    f"other={other[-1] if other else '(none)'} editor={ed[-1] if ed else '(unchanged)'}")

# (e) measured
state = js("e.state.json") or {}
try: tree_text = state["result"]["snapshot"]["treeText"]
except Exception: tree_text = None
count = sum(1 for l in (tree_text or "").splitlines() if "/a/" in l)
say("(e) measured", "PASS" if count >= 1 else "FAIL",
    f"count={count}" + ("" if tree_text is not None else " (no treeText in get-app-state reply)"))

print(f"GATE {'PASS' if all(gates) else 'FAIL'} — raw outputs in {res}")
sys.exit(0 if all(gates) else 1)
PY
