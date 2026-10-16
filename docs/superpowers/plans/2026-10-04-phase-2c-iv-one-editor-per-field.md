# Phase 2c-iv — one editor per field — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every field that can hold a hole (the path↔query view, each query value, each header
value, the body) becomes **one** TextKit 2 text editor. A literal is characters in it, and a
hole or a bound value is **one attachment character**, drawn by a real view whose `×` is a real
button. AppKit owns typing, the caret, selection, undo, input methods and wrapping. Wakil owns
only the token rules. The box-and-chip layout, its key catcher and its caret return are deleted.

**Architecture:** Rulings stay in WakilKit, pure and tested, as in every 2c-iv plan:
`ApiEditorText` maps a field's parts to the editor's text and back, exactly. `ApiEditorRules`
holds the token rules: the key verdict, the clip a copy carries, the paste, the move, and where
`+ hole` lands. Saved as typed (9a) moves from index-keyed boxes (`[ApiFieldRow: [Int: String]]`)
to **one held part list per field** (`ApiHeld = [ApiFieldRow: [ApiPart]]`). A flush writes a
field whole through the same surface chain. `ApiFieldEditor`, which replaces `ApiBodyTextView`,
is an `NSTextView` (TextKit 2) wrapped for SwiftUI. It asks WakilKit before any change touches a
token and reports every change as the field's parts. `ApiTokenView` is the attachment's view
(`NSTextAttachmentViewProvider`). The body moves first (Task 5), then the three single-line
fields (Task 6), then the old machinery is deleted (Task 7).

**Tech Stack:** AppKit TextKit 2 (`NSTextView(usingTextLayoutManager:)`, `NSTextAttachment`,
`NSTextAttachmentViewProvider`, macOS 14.4 target), SwiftUI (`WakilApp`, no test target),
`WakilKit` (swift-testing, `make app-test`), JSONL checks under `e2e/checks/seeded/`, the e2e
driver (`go test ./e2e/...`), `e2e/axresolve`.

**Spec:** `docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md`,
**Amendment 10** (*2026-10-04 — one editor per field*, §§10a–10c). It simplifies Amendment 9
(§9a saved as typed; §9c W4, W7, W16), so read 9a and 9c first. The code this plan edits is
what `main` holds after PR #338 (`fc5b7b6`). **Where the two earlier 2c-iv plans
(`2026-10-03-…-saved-as-typed-and-sending.md`, `2026-10-03-…-the-split-pane.md`) disagree with
the code, the code wins.** Their execution diverged: fix rounds 1–6, preflights F5–F23 and
P5–P18, and final review I2.

---

## File structure

**Created**

| Path | Responsibility |
|---|---|
| `scripts/probe/tokenview/probe-app.swift`, `README.md` | Task 1's throwaway spike: one TextKit 2 view and one attachment view. Kept, as `scripts/probe/axidentifier/` is, so the measurement can be repeated. |
| `app/Sources/WakilKit/Api/ApiEditorText.swift` | Pure: parts ↔ editor units, tokens with identity, the caret mapping across an outside change, whether the editor takes outside parts. |
| `app/Sources/WakilKit/Api/ApiEditorRules.swift` | Pure: the key verdict, the clip, the paste, the move, the `+ hole` offset. |
| `app/Sources/WakilApp/ApiTokenView.swift` | `ApiTokenAttachment`, `ApiTokenProvider`, `ApiTokenView`: the chip as a real view, its `×` a real `NSButton`. |
| `app/Tests/WakilKitTests/ApiEditorTextTests.swift`, `ApiEditorRulesTests.swift`, `ApiFieldHeldTests.swift` | The tests that fail first. |
| `e2e/checks/seeded/api-editor-json-holes.jsonl`, `api-editor-hole-drag.jsonl`, `api-editor-copy-bound.jsonl`, `api-editor-wrap.jsonl` | The new checks (10c). |

**Renamed:** `app/Sources/WakilApp/ApiBodyTextView.swift` → `ApiFieldEditor.swift` (`git mv`, then
rewritten). Spec 10b: *"`ApiBodyTextView` becomes `ApiFieldEditor`"*.

**Modified:** `ApiSaveAsTyped.swift` (held per field), `ApiActions.swift` (`apiHeldWrite`,
`apiSendPlan(held:)`), `ApiPathQuery.swift` (`apiPathViewWrite`), `ApiBodyFormat.swift`
(`holding:` overloads), `ApiRows.swift` (the held overload of `apiBoxesRemovingRow`),
`ApiPane.swift`, `ApiPane+Fields.swift`, `ApiPane+Request.swift`, `ApiPane+Sending.swift`,
`ApiPaneFlow.swift`, the checks named in Task 8, `docs/wakil/phase-2c-iv-acceptance.md`.

**Deleted (Task 7):** `ApiChipKeyCatcher.swift`, `ApiFieldItems.swift` (its two survivors move to
`ApiEditorText.swift`), `ApiBodyCaret.swift`, most of `ApiChipKeys.swift` (only `ApiChipAct`,
`apiChipAct` and `apiChipUnbindParams` stay), `ApiChipKeysTests.swift`, `ApiFieldItemsTests.swift`,
`ApiBodyHoleTests.swift`, and the index-keyed half of `ApiSaveAsTyped.swift` and `ApiActions.swift`.

---

## Global Constraints

- **Every ruling goes in WakilKit, with a test that fails first.** A string, an `if` that picks
  an action, a token rule, a caret computation, or a comparison of parts written inline in
  `ApiPane*.swift`, `ApiFieldEditor.swift` or `ApiTokenView.swift` is a ruling nothing can pin.
  Layout numbers (a token's padding in points) are drawing, not rulings. `make app-test` must
  show each new test red before its code exists.
- **Every dispatch goes through the surface doors.** That means `operateInOrder(_:)`,
  `operateFlushed(_:takingOver:)` and `flush()`, all built lazily at their turn on
  `WindowModel.enqueueFromSurface(pane:building:settled:)`. `dispatchInOrder` stays `private` in
  `ApiPane.swift`. The editor never dispatches: it reports parts (`typed`), a gesture (`gesture`),
  an unbind (`unbind`) or a refusal line (`refused`), and the pane decides.
- **Identifiers go only on an element with an accessibility action**, such as the editor's
  `NSTextView`, the token's `×` `NSButton`, or the token view, which is an AX button whose press
  selects it. **At the AppKit level, set an identifier only when it changes**
  (`if view.accessibilityIdentifier() != id { view.setAccessibilityIdentifier(id) }`). An
  unguarded set churned the tree into AXError -25200 on 10 of 10 presses (Ruling 15).
- **One shipped identifier family is retired, deliberately (10c):** the literal box
  `api.<key>.part.<i>`. A field has one identifier: `api.path`, `api.body`, `api.query.<name>`
  (`api.query[<row>].<name>` for a later same-named row), or `api.header.<name>`. **Kept:**
  `api.<key>.part.<i>.remove` and `api.<key>.part.<i>.unbind`. Here `<i>` is the token's index
  among the editor's parts, which are the field's parts with adjacent literals merged and empty
  ones dropped (`ApiEditorText.parts`). **Added, one family:** `api.<key>.part.<i>.token`. It is
  the token view, an AX button whose press selects that token. This is how a check picks a
  token up to drag it or copy it. Spell every identifier `"api.\(key)…"`, with `api` as the
  literal first segment, so that `make controls` harvests it as a family.
- **Unchanged, word for word:** the wire, `read_pane`, every action and its schema, and Decision
  27's refusal and wording (*"the operator is editing Path"*). `ApiDraftField`,
  `apiFocusMarks`, `ApiFocusTracker`, `apiRestoreCalls` and the content type's `TextField` are
  also unchanged.
- **No GUI target without the operator's OK, every time.** That means `make e2e`,
  `make e2e-new`, launching the app, and running the spike. Quit the live Wakil first. Ask the
  peer sessions before a run and tell them after (the shared-GUI memory). A step that needs the
  GUI says **STOP: controller asks the operator for a GUI window**.
- **The one-blind-fix rule.** If a GUI check fails on focus or timing, the controller may make
  ONE fix without seeing the GUI. If the rerun still fails, the controller does not guess again.
  It asks the operator for a **bounded live window for that one check**: one named check file,
  run with the operator watching, and nothing else.
- **Headless gates on every task that touches code:** `make app-test`, `make app-bundle`,
  `make controls`, and `go test ./e2e/...`.
- **New and changed checks must be seen red against `ed1af70`:**
  `make e2e-new E2E_NEW_ARGS="--base ed1af70"`. The run picks up every check the branch added
  **or changed**, so a check left untouched stays untouched, and a rewritten one needs a step
  that fails on the old layout. Read each reason, not the count. A red that comes from the
  harness failing to reach the window is red against anything, and proves nothing.
- **Design language** (`docs/wakil/design-language.md` §5, and the token look shipped in 9c): a
  hole is amber `#e8b45a` on a 0.10 amber tint, and a bound value is ink on a 0.10 cool-white
  tint. The `×` sits inside the token at its right edge, in the token's tone at 0.55. Every
  value is monospace 12. The body grows to **16** lines, then scrolls.

## Review Focus

1. **An input method composing across a token.** The operator types Japanese or uses the accent
   menu with the caret just after a token, or starts a composition over a selection that holds a
   bound value. Expected: while text is marked, Backspace edits the composition and never
   removes or unbinds the token. A composition that would replace a bound value is refused with
   the field's line. The editor reports no parts while text is marked, so no pause write
   carries half a composition. *Task 3, `aCompositionNeverActsOnAToken`; Task 5's editor skips
   `textDidChange` while `hasMarkedText()`.*
2. **Undo bringing back a bound token.** For example, ⌘Z after a same-field move, or after a
   change that later saw an unbind land. Expected: no write ever names a binding that the
   region does not hold. A binding the region no longer holds is written as its hole, because
   W16 says a write carries a binding and never makes one. Undo can never re-make a binding.
   *Task 4, `aBindingTheRegionNoLongerHoldsIsWrittenAsItsHole`.*
3. **An agent's write landing while an editor holds the cursor.** Expected: Decision 27 still
   refuses it whole, in its own words, for the path (path and query), a query value, a header
   value and the body. The editor's first-responder changes are what mark and release the
   field. *Task 5/6: the editor's `becomeFirstResponder`/`resignFirstResponder` feed
   `focusChanged`. Task 8: `api-one-author-focus.jsonl` stays green, unmodified, against the
   editors.*
4. **The editor's own text set from a snapshot in the middle of typing.** The operator types
   `/ab`, the pause writes `/a`, and its landing hands the editor `/a` while it shows `/ab`.
   Expected: an echo of the editor's own earlier typing is never taken. A real outside change,
   such as an unbind landing or an agent write on another field, is taken with the caret mapped
   across it, never thrown to the end. This is the SwiftUI re-set lesson. *Task 2,
   `anEchoOfOwnTypingIsNotTaken` and `theCaretSurvivesAnOutsideChangeBesideIt`.*
5. **A wrapping path with a token at a line edge.** In a narrow pane, the path wraps with the
   token as the last glyph of a line or the first of the next. Expected: the caret moves across
   it as one character. Backspace after it removes it whichever line the caret sits on, and
   `+ hole` lands at the caret, not after `/confirm`. *Task 8,
   `api-editor-wrap.jsonl`. WakilKit has no layout to test, so the offsets are pinned by Task 2's
   `aTokenIsOneUnitWhereverItSits`.*

---

## Ambiguities resolved in this plan

These are the plan's choices where 10a–10c leave room. Each is restated in the task that applies
it.

1. **"Within its own region" is read as "within its own field".** A query row and a header row
   are separate editors, and each holds its own row of the region. Moving a binding between two
   rows would take two writes, and the first would drop the binding. So a bound value moves only
   within the editor it sits in. Dropped anywhere else, it drops its **hole** and stays where it
   was. In the path view a move across the `?` is still refused by `apiPathBoxKeepsItsBindings`
   (*"a bound value stays in the region it was dropped in…"*), as shipped.
2. **`+ hole` in the path view, when the caret has never been in the field**, lands at the end of
   the **path**, before the `?`. It does not land at the end of the view. That keeps final
   review I4: a hole appended to the view fell into the last query value. When the caret has
   been in the field, the hole goes at the caret, wherever it is. If that is inside a query
   name, the parse refuses with *"a hole can sit only in a query value"*.
3. **`+ hole` with a selection** lands at the selection's end and replaces nothing, because a
   gesture never deletes text.
4. **A held key (auto-repeat) never acts on a token**, whether it is a hole or a bound value. P8
   is kept for both: a held Backspace eats text and stops at the token.
5. **An outside change while the editor has no cursor puts the caret at the end.** A later
   `+ hole` then lands at the end, which matches P14's stale-caret fallback.
6. **Dragging a selection that holds a bound value out to another field** gives the destination
   text and holes. The source keeps the whole selection, because deleting it would drop the
   binding. This is W16 applied whole, and it draws no line.
7. **The token's own AX identifier (`….token`) is the one new family.** The harness's `drag`
   needs a named element to pick up, and the `×` button cannot start a drag. If the operator
   vetoes the family at plan review, Task 8's drag and copy checks drop their `click`/`drag`
   on `.token`. The copy check then selects the token with `shift+Left`, and the drag is
   covered by WakilKit (`apiEditorMoving`, `ApiEditorClip`) plus the walk.

---

### Task 1: SPIKE — one TextKit 2 view, one attachment view, a pressable `×` (HARD STOP)

**Why first.** Every later task assumes the `×` inside an attachment view is in the AX tree with
its identifier, that the harness's AX press reaches it, and that AppKit treats the attachment as
one character. If any of the three is false, the design changes, and the operator decides how
(10c: *"If that fails, the operator decides before anything is built on it"*). **Nothing after
this task starts until the operator has seen the spike's result.**

**Files:**
- Create: `scripts/probe/tokenview/probe-app.swift`
- Create: `scripts/probe/tokenview/README.md`

**Interfaces:**
- Consumes: `e2e/bin/axresolve` (`make axresolve`). Its arguments are `--pid`, `--identifier`,
  `--press`, `--focus` and `--drag-to`. Also `/Applications/Orca.app/Contents/Resources/bin/orca
  computer press-key|hotkey|get-app-state` with `--app pid:<n> --restore-window
  --no-screenshot --json`, as `e2e/driver/orcaclient.go` runs it.
- Produces: a recorded answer to (a)–(c), the gate, and to (d)–(e), measurements, in the README.

- [ ] **Step 1: Write the probe app**

```swift
// scripts/probe/tokenview/probe-app.swift — Amendment 10's spike. Throwaway; kept so the answer
// can be re-measured. Build: swiftc -parse-as-library -o "$OUT/token-probe" probe-app.swift
import AppKit

/// Every event the probe sees, one per line, to $PROBE_LOG (default ./probe.log): the text as
/// `/a/⟨id⟩/b` (a token drawn as ⟨name⟩), the selection, and presses.
func log(_ line: String) {
    let path = ProcessInfo.processInfo.environment["PROBE_LOG"] ?? "probe.log"
    let data = (line + "\n").data(using: .utf8)!
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

final class ProbeAttachment: NSTextAttachment {
    let name: String
    weak var textView: ProbeTextView?
    init(name: String) {
        self.name = name
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        bounds = CGRect(x: 0, y: -4, width: 46, height: 17)
    }
    required init?(coder: NSCoder) { nil }
    override func viewProvider(
        for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = ProbeProvider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class ProbeProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        view = ProbeTokenView(attachment: textAttachment as! ProbeAttachment)
    }
}

final class ProbeTokenView: NSView {
    let attachment: ProbeAttachment
    init(attachment: ProbeAttachment) {
        self.attachment = attachment
        super.init(frame: CGRect(x: 0, y: 0, width: 46, height: 17))
        let label = NSTextField(labelWithString: attachment.name)
        label.frame = CGRect(x: 5, y: 0, width: 24, height: 16)
        addSubview(label)
        let close = NSButton(title: "×", target: self, action: #selector(closePressed))
        close.isBordered = false
        close.frame = CGRect(x: 30, y: 0, width: 14, height: 16)
        close.setAccessibilityIdentifier("probe.part.1.remove")
        addSubview(close)
        setAccessibilityIdentifier("probe.part.1.token")
    }
    required init?(coder: NSCoder) { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        log("token-pressed"); attachment.textView?.select(attachment); return true
    }
    override func mouseDown(with event: NSEvent) { attachment.textView?.select(attachment) }
    override func mouseDragged(with event: NSEvent) {
        _ = attachment.textView?.dragSelection(with: event, offset: .zero, slideBack: true)
    }
    @objc func closePressed() { log("pressed"); attachment.textView?.remove(attachment) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

final class ProbeTextView: NSTextView {
    var tag_ = ""
    func range(of attachment: ProbeAttachment) -> NSRange? {
        var found: NSRange?
        textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage!.length)) { value, range, stop in
            if (value as AnyObject) === attachment { found = range; stop.pointee = true }
        }
        return found
    }
    func select(_ attachment: ProbeAttachment) {
        guard let range = range(of: attachment) else { return }
        window?.makeFirstResponder(self); setSelectedRange(range)
    }
    func remove(_ attachment: ProbeAttachment) {
        guard let range = range(of: attachment) else { return }
        insertText("", replacementRange: range)
    }
    var shown: String {
        guard let storage = textStorage else { return "" }
        var out = ""
        let string = storage.string as NSString
        for index in 0..<string.length {
            if let a = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ProbeAttachment {
                out += "⟨\(a.name)⟩"
            } else if let a = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment {
                out += "⟨foreign:\(type(of: a))⟩"
            } else {
                out += String(utf16CodeUnits: [string.character(at: index)], count: 1)
            }
        }
        return out
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    func make(_ id: String, frame: CGRect, withToken: Bool) -> ProbeTextView {
        let view = ProbeTextView(usingTextLayoutManager: true)
        view.frame = frame
        view.tag_ = id
        view.isRichText = true
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.delegate = self
        view.setAccessibilityIdentifier(id)
        if withToken {
            let attrs: [NSAttributedString.Key: Any] = [.font: view.font!]
            let text = NSMutableAttributedString(string: "/a/", attributes: attrs)
            let token = ProbeAttachment(name: "id"); token.textView = view
            text.append(NSAttributedString(attachment: token))
            text.append(NSAttributedString(string: "/b", attributes: attrs))
            view.textStorage?.setAttributedString(text)
        }
        return view
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 160),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TokenProbe"
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.addSubview(make("probe.editor", frame: CGRect(x: 10, y: 90, width: 400, height: 40), withToken: true))
        content.addSubview(make("probe.other", frame: CGRect(x: 10, y: 20, width: 400, height: 40), withToken: false))
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("ready")
    }
    func textDidChange(_ n: Notification) {
        guard let v = n.object as? ProbeTextView else { return }
        log("\(v.tag_) text=\(v.shown)")
    }
    func textViewDidChangeSelection(_ n: Notification) {
        guard let v = n.object as? ProbeTextView else { return }
        let r = v.selectedRange()
        log("\(v.tag_) selection=\(r.location),\(r.length)")
    }
}

@main enum Probe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(); app.delegate = delegate; app.run()
    }
}
```

- [ ] **Step 2: Write the README with the exact runs and pass criteria**

Copy the "how to run" and the pass/fail table below into `scripts/probe/tokenview/README.md`.
Leave the Result column empty. Step 4 fills it.

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

| | Pass criterion (exact) | Result |
|---|---|---|
| **(a) GATE** | `axresolve --pid` lists `probe.part.1.remove` with role `AXButton`, and also `probe.editor`. `--press` answers `"ok":true`. The log then holds `pressed` followed by `probe.editor text=/a//b`. | |
| **(b) GATE** | After the Backspace, the log's last `probe.editor text=` line is exactly `/a//b`, with no `⟨id⟩` and with both slashes kept. | |
| **(c) GATE** | The `selection=` lines end `0,0` `1,0` `2,0` `3,0` `4,0` `3,1`. Four Rights pass three characters and then the token in one step, and shift+Left selects exactly the token. | |
| (d) measured | `probe.other text=` holds `⟨` (the token arrived, as `⟨id⟩` or `⟨foreign:…⟩`), and whether `probe.editor text=` lost it. | |
| (e) measured | The count is ≥ 1, or 0. | |

- [ ] **Step 3: STOP: controller asks the operator for a GUI window**

Ask in these words: *"Task 1's spike needs the GUI for about two minutes: a 420×160 window
called TokenProbe, five short runs, all driven by axresolve and orca. Live Wakil does not need
to quit, because the probe is its own app. OK to run now?"* Tell the peer sessions before the
run and after it. Run Step 2's block once, as written. **Do not retry a failed item.** A retried
measurement is not one.

- [ ] **Step 4: Record and decide**

Fill in the README's Result column with the log lines verbatim.

- **(a), (b) and (c) all pass:** commit the probe, then go on to Task 2.
- **Any of (a)–(c) fails:** **STOP. Report to the operator before any later task.** Send the
  failing log lines and the two fallbacks this plan can take:
  - (a) fails: the `×` buttons are drawn in a SwiftUI overlay placed from the text layout
    manager's fragment frames, and are not inside the attachment view.
  - (b) or (c) fails: a token becomes an atomic *range* of a placeholder string, kept atomic by
    `textView(_:willChangeSelectionFromCharacterRange:toCharacterRange:)`.

  Either one means a revised plan. The operator chooses.
- **(d) fails:** Task 8's `api-editor-hole-drag.jsonl` is not written. The hole drag is covered
  by WakilKit plus the walk, and this goes on the residue list.
- **(e) is 0:** Task 8 replaces every `expect.tree contains` that reads an editor's text with
  pane-field `expect`s. `api-query-sync`'s `limit=5&page=2` and `/orders?page=5` lines become
  `request.query[…]` reads.

- [ ] **Step 5: Commit**

```bash
git add scripts/probe/tokenview/
git commit -m "2c-iv Amendment 10 spike: a TextKit 2 attachment view's × is in the AX tree and pressable

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `ApiEditorText` — parts ↔ the editor's text, exactly

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiEditorText.swift`
- Test: `app/Tests/WakilKitTests/ApiEditorTextTests.swift`

**Interfaces:**
- Consumes: `ApiPart`, `ApiBoundValue` (`ApiDraft.swift`), `apiMergedLiterals` (internal,
  `ApiPathQuery.swift`), `liveBinding(name:)` (`ApiTestSupport.swift`).
- Produces (every later task uses these exact names):
  - `public enum ApiEditorToken { case hole(String); case bound(ApiBoundValue) }`, with `name`,
    `isBound` and `part`.
  - `public enum ApiEditorUnit { case code(UInt16); case token(ApiEditorToken) }`
  - `public struct ApiEditorText`, with `init(parts:)`, `init(units:)`, `runs`, `parts`, `units`,
    `length`, `token(at:)`, `tokens(in:)`, `ordinal(ofTokenAt:)`, `partIndex(ofTokenAt:)`,
    `slice(_:)`, `replacing(_:with:)` and `plain`.
  - `public func apiEditorTakesParts(_ incoming: [ApiPart], showing: [ApiPart], typedSinceTaken: [[ApiPart]], focused: Bool) -> Bool`
  - `public func apiEditorSelection(from old: ApiEditorText, to new: ApiEditorText, selection: Range<Int>) -> Range<Int>`

Offsets are **UTF-16 units, and a token is exactly one unit (U+FFFC)**, so an offset here is an
`NSRange` location in the editor's text storage, unchanged.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

/// Amendment 10a: a field is one editor's text, and a hole or a bound value is one token in it.

@Test("Parts round-trip exactly: adjacent literals merge, empty ones drop, tokens keep identity")
func partsRoundTripExactly() {
    let bound = liveBinding(name: "id")
    let parts: [ApiPart] = [
        .literal("/a"), .literal(""), .literal("/"), .slot("x"), .bound(bound), .literal(""),
    ]
    let text = ApiEditorText(parts: parts)
    #expect(text.parts == [.literal("/a/"), .slot("x"), .bound(bound)])
    #expect(text.parts == apiMergedLiterals(parts))
    #expect(ApiEditorText(parts: text.parts) == text)
    #expect(ApiEditorText(units: text.units) == text)
}

@Test("A token is one unit and text counts UTF-16, as NSTextView does")
func aTokenIsOneUnit() {
    let text = ApiEditorText(parts: [.literal("é😀"), .slot("id"), .literal("/b")])
    // é = 1 unit, 😀 = 2 units, the token = 1, "/b" = 2.
    #expect(text.length == 6)
    #expect(text.token(at: 3) == .hole("id"))
    #expect(text.token(at: 2) == nil)
}

@Test("Review Focus 5: a token is one unit wherever it sits — first, last, between tokens")
func aTokenIsOneUnitWhereverItSits() {
    let text = ApiEditorText(parts: [.slot("a"), .slot("b"), .literal("x"), .slot("c")])
    #expect(text.length == 4)
    #expect(text.token(at: 0) == .hole("a"))
    #expect(text.token(at: 1) == .hole("b"))
    #expect(text.token(at: 3) == .hole("c"))
    #expect(text.ordinal(ofTokenAt: 3) == 2)
    #expect(text.partIndex(ofTokenAt: 3) == 3)
    #expect(text.partIndex(ofTokenAt: 2) == nil)
}

@Test("A token's index is its index among the editor's parts — the identifiers' <i>")
func aTokensPartIndexIsAmongTheMergedParts() {
    let text = ApiEditorText(parts: [.literal("/a"), .literal("/b/"), .slot("id"), .literal("/c")])
    // Merged: ["/a/b/", <id>, "/c"]: the token is part 1, at offset 5.
    #expect(text.partIndex(ofTokenAt: 5) == 1)
    #expect(text.ordinal(ofTokenAt: 5) == 0)
}

@Test("A literal U+FFFC typed or pasted as text stays text, never a token")
func aLiteralObjectReplacementCharacterIsText() {
    let text = ApiEditorText(units: [.code(0xFFFC), .code(UInt16(ascii: "a"))])
    #expect(text.parts == [.literal("\u{FFFC}a")])
    #expect(text.tokens(in: 0..<2).isEmpty)
}

@Test("Slice and replace work in units, and keep tokens and their identity")
func sliceAndReplace() {
    let bound = liveBinding(name: "id")
    let text = ApiEditorText(parts: [.literal("ab"), .bound(bound), .literal("cd")])
    #expect(text.slice(1..<4).parts == [.literal("b"), .bound(bound), .literal("c")])
    let replaced = text.replacing(0..<2, with: ApiEditorText(parts: [.slot("x")]))
    #expect(replaced.parts == [.slot("x"), .bound(bound), .literal("cd")])
    #expect(text.tokens(in: 0..<5) == [.bound(bound)])
    #expect(text.plain == "ab<id>cd")
}

@Test("An out-of-range slice is clamped, never a trap")
func outOfRangeIsClamped() {
    let text = ApiEditorText(parts: [.literal("ab")])
    #expect(text.slice(1..<9).parts == [.literal("b")])
    #expect(text.token(at: 9) == nil)
}

@Test("Review Focus 4: an echo of the editor's own typing is not taken while it has the cursor")
func anEchoOfOwnTypingIsNotTaken() {
    let typed: [[ApiPart]] = [[.literal("/a")], [.literal("/ab")]]
    #expect(!apiEditorTakesParts([.literal("/a")], showing: [.literal("/ab")],
                                 typedSinceTaken: typed, focused: true))
    // Without the cursor it is an outside change, and taken.
    #expect(apiEditorTakesParts([.literal("/a")], showing: [.literal("/ab")],
                                typedSinceTaken: typed, focused: false))
    // Something the editor never showed is outside, cursor or not.
    #expect(apiEditorTakesParts([.literal("/z")], showing: [.literal("/ab")],
                                typedSinceTaken: typed, focused: true))
    // The same parts, merged differently, are not a change.
    #expect(!apiEditorTakesParts([.literal("/a"), .literal("b")], showing: [.literal("/ab")],
                                 typedSinceTaken: [], focused: true))
}

@Test("Review Focus 4: the caret survives an outside change beside it")
func theCaretSurvivesAnOutsideChangeBesideIt() {
    let bound = liveBinding(name: "id")
    let old = ApiEditorText(parts: [.literal("/a/"), .bound(bound), .literal("/b")])
    let new = ApiEditorText(parts: [.literal("/a/"), .slot("id"), .literal("/b")])
    // An unbind landing: the caret just after the token stays just after it.
    #expect(apiEditorSelection(from: old, to: new, selection: 4..<4) == 4..<4)
    // Text added before the caret moves it by that much.
    let longer = ApiEditorText(parts: [.literal("/v1/a/"), .bound(bound), .literal("/b")])
    #expect(apiEditorSelection(from: old, to: longer, selection: 5..<5) == 8..<8)
    // A caret inside text that was replaced goes to the end of the replacement.
    let other = ApiEditorText(parts: [.literal("/zzzz")])
    #expect(apiEditorSelection(from: old, to: other, selection: 2..<2).lowerBound <= other.length)
}
```

- [ ] **Step 2: Run them, and see them fail**

Run: `make app-test 2>&1 | grep -E "ApiEditorText|error:" | head`
Expected: the build fails with `cannot find 'ApiEditorText' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Amendment 10a — **a field is one editor's text, and a hole is a token inside it.**
///
/// A literal is characters. A hole or a bound value is ONE attachment character (U+FFFC) that
/// carries which part it is. This file maps a field's parts to that text and back, **exactly**:
/// adjacent literals merge and empty ones drop (`apiMergedLiterals`), and a token keeps its
/// identity. Offsets are UTF-16 units, as `NSTextView` counts them, and a token is one unit, so
/// an offset here is an `NSRange` location in the editor unchanged. The editor holds no rule of
/// its own (10a): what it may do to a token is `ApiEditorRules.swift`'s.

/// A token: an unfilled hole, or a bound value under its hole's name.
public enum ApiEditorToken: Sendable, Equatable {
    case hole(String)
    case bound(ApiBoundValue)

    public var name: String {
        switch self {
        case .hole(let name): return name
        case .bound(let value): return value.name
        }
    }

    public var isBound: Bool {
        if case .bound = self { return true }
        return false
    }

    public var part: ApiPart {
        switch self {
        case .hole(let name): return .slot(name)
        case .bound(let value): return .bound(value)
        }
    }
}

/// One unit of the editor's text: a UTF-16 code unit, or a token.
public enum ApiEditorUnit: Sendable, Equatable {
    case code(UInt16)
    case token(ApiEditorToken)
}

public struct ApiEditorText: Sendable, Equatable {
    public enum Run: Sendable, Equatable {
        case text(String)
        case token(ApiEditorToken)
    }

    /// Never two text runs side by side, never an empty one.
    public private(set) var runs: [Run] = []

    public init(parts: [ApiPart]) {
        for part in parts {
            switch part {
            case .literal(let text): append(.text(text))
            case .slot(let name): append(.token(.hole(name)))
            case .bound(let value): append(.token(.bound(value)))
            }
        }
    }

    /// The text an editor holds, unit by unit. A U+FFFC that is a `.code` is a character the
    /// operator typed or pasted, never a token. Only a `.token` unit is one.
    public init(units: [ApiEditorUnit]) {
        var codes: [UInt16] = []
        func flushCodes() {
            guard !codes.isEmpty else { return }
            append(.text(String(decoding: codes, as: UTF16.self)))
            codes = []
        }
        for unit in units {
            switch unit {
            case .code(let code): codes.append(code)
            case .token(let token):
                flushCodes()
                append(.token(token))
            }
        }
        flushCodes()
    }

    private mutating func append(_ run: Run) {
        guard case .text(let text) = run else {
            runs.append(run)
            return
        }
        guard !text.isEmpty else { return }
        if case .text(let previous)? = runs.last {
            runs[runs.count - 1] = .text(previous + text)
        } else {
            runs.append(run)
        }
    }

    /// The field's parts, as the editor shows them: `apiMergedLiterals` of what it was made from.
    public var parts: [ApiPart] {
        runs.map { run in
            switch run {
            case .text(let text): return .literal(text)
            case .token(let token): return token.part
            }
        }
    }

    public var units: [ApiEditorUnit] {
        runs.flatMap { run -> [ApiEditorUnit] in
            switch run {
            case .text(let text): return text.utf16.map { .code($0) }
            case .token(let token): return [.token(token)]
            }
        }
    }

    public var length: Int {
        runs.reduce(0) { total, run in
            switch run {
            case .text(let text): return total + text.utf16.count
            case .token: return total + 1
            }
        }
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> {
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        return lower..<upper
    }

    /// The token at `offset`, or `nil` for a character or a position past the end.
    public func token(at offset: Int) -> ApiEditorToken? {
        guard offset >= 0, offset < length, case .token(let token) = units[offset] else { return nil }
        return token
    }

    /// Every token inside `range`, in order.
    public func tokens(in range: Range<Int>) -> [ApiEditorToken] {
        units[clamped(range)].compactMap { unit in
            if case .token(let token) = unit { return token }
            return nil
        }
    }

    /// The token at `offset`'s place among the tokens: what `apiChipUnbindParams` takes.
    public func ordinal(ofTokenAt offset: Int) -> Int? {
        guard token(at: offset) != nil else { return nil }
        return tokens(in: 0..<offset).count
    }

    /// The token at `offset`'s index among `parts`: the `<i>` of `api.<key>.part.<i>.remove`.
    public func partIndex(ofTokenAt offset: Int) -> Int? {
        var position = 0
        for (index, run) in runs.enumerated() {
            switch run {
            case .text(let text):
                position += text.utf16.count
            case .token:
                if position == offset { return index }
                position += 1
            }
            if position > offset { return nil }
        }
        return nil
    }

    public func slice(_ range: Range<Int>) -> ApiEditorText {
        ApiEditorText(units: Array(units[clamped(range)]))
    }

    public func replacing(_ range: Range<Int>, with inserted: ApiEditorText) -> ApiEditorText {
        var all = units
        all.replaceSubrange(clamped(range), with: inserted.units)
        return ApiEditorText(units: all)
    }

    /// The text as another app reads it: each token as `<name>` (10b, copying outside Wakil).
    public var plain: String {
        runs.map { run in
            switch run {
            case .text(let text): return text
            case .token(let token): return "<\(token.name)>"
            }
        }.joined()
    }
}

/// Whether the editor takes the parts it is handed (Review Focus 4; the SwiftUI re-set lesson,
/// Task 9 fix's `apiEditorTakesText` for parts).
///
/// **Not when it already shows them**, up to merging, so the caret never resets under a
/// keystroke. **Not, while it has the cursor, when they are an earlier state of its own
/// typing.** An echo of a pause write from before the latest keystrokes would drop them.
/// Anything else is a change from outside the editor and is taken: an unbind landing, Format,
/// Escape's restore, an agent's write, or the Query region rewriting the path view.
public func apiEditorTakesParts(
    _ incoming: [ApiPart], showing: [ApiPart], typedSinceTaken: [[ApiPart]], focused: Bool
) -> Bool {
    let merged = apiMergedLiterals(incoming)
    if merged == apiMergedLiterals(showing) { return false }
    if focused, typedSinceTaken.contains(where: { apiMergedLiterals($0) == merged }) { return false }
    return true
}

/// Where the selection goes when the editor takes an outside change (Review Focus 4): mapped
/// across it, never thrown to the end. A position in the unchanged head stays. One in the
/// unchanged tail moves by the change in length. One inside the changed middle goes to the end
/// of what replaced it. A token replaced in place (an unbind landing) is a one-unit middle, so a
/// caret just after it stays just after it.
public func apiEditorSelection(
    from old: ApiEditorText, to new: ApiEditorText, selection: Range<Int>
) -> Range<Int> {
    let a = old.units
    let b = new.units
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix,
          a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
    func map(_ position: Int) -> Int {
        if position <= prefix { return min(position, b.count) }
        if position >= a.count - suffix { return position + (b.count - a.count) }
        return b.count - suffix
    }
    let lower = map(selection.lowerBound)
    return lower..<max(lower, map(selection.upperBound))
}
```

- [ ] **Step 4: Run the tests, and see them pass**

Run: `make app-test 2>&1 | grep -E "ApiEditorText|passed|failed" | tail -5`
Expected: every test in `ApiEditorTextTests.swift` passes, and nothing else regresses.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Api/ApiEditorText.swift app/Tests/WakilKitTests/ApiEditorTextTests.swift
git commit -m "2c-iv Amendment 10a: ApiEditorText — a field's parts as one editor's text, exactly

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The token rules — keys, selection, copy, paste, move, `+ hole`

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiEditorRules.swift`
- Test: `app/Tests/WakilKitTests/ApiEditorRulesTests.swift`

**Interfaces:**
- Consumes: Task 2's `ApiEditorText` and `ApiEditorToken`, `apiSingleLineText`
  (`ApiPaneLines.swift`), and `apiHoleNameRefusal` (`ApiActions.swift`, `"a hole needs a name"`).
- Produces:
  - `public enum ApiEditorKey { case backspace, delete }`
  - `public enum ApiEditorVerdict { case allow, ignore, refuse(String), unbind(ordinal: Int, name: String), substitute(String) }`
  - `public let apiBoundSelectionLine: String`
  - `public func apiEditorVerdict(_ text: ApiEditorText, replacing range: Range<Int>, with inserted: String, key: ApiEditorKey? = nil, isRepeat: Bool = false, composing: Bool = false, draggingOut: Bool = false, singleLine: Bool) -> ApiEditorVerdict`
  - `public let apiEditorPasteboardType: String` (`"com.wakil.api.editor-text"`)
  - `public struct ApiEditorClip: Codable`, with `init(_:range:)`, `plain` and `text`.
  - `public func apiEditorPasted(clip: ApiEditorClip?, plain: String?, singleLine: Bool) -> ApiEditorText?`
  - `public func apiEditorMoving(_ text: ApiEditorText, range: Range<Int>, to offset: Int) -> (text: ApiEditorText, selection: Range<Int>)?`
  - `public func apiEditorHoleOffset(_ text: ApiEditorText, selection: Range<Int>?, isPathView: Bool) -> Int`
  - `public func apiHoleNameRefused(_ name: String) -> String?`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

/// Amendment 10b: a token is one atomic character, and these are its rules.

private func text(_ parts: [ApiPart]) -> ApiEditorText { ApiEditorText(parts: parts) }

@Test("Backspace just after a hole removes it as one character")
func backspaceAfterAHoleRemovesIt() {
    let t = text([.literal("/a/"), .slot("id"), .literal("/b")])
    #expect(apiEditorVerdict(t, replacing: 3..<4, with: "", key: .backspace, singleLine: true) == .allow)
    #expect(apiEditorVerdict(t, replacing: 3..<4, with: "", key: .delete, singleLine: true) == .allow)
}

@Test("W4/W16: Backspace or Delete on a bound value unbinds it, by its ordinal among the tokens")
func aKeyOnABoundValueUnbindsIt() {
    let bound = liveBinding(name: "v")
    let t = text([.slot("x"), .literal("/"), .bound(bound)])
    #expect(apiEditorVerdict(t, replacing: 2..<3, with: "", key: .backspace, singleLine: true)
        == .unbind(ordinal: 1, name: "v"))
}

@Test("P8: a held key's repeat never acts on a token, hole or bound")
func aRepeatNeverActsOnAToken() {
    let t = text([.slot("x"), .bound(liveBinding(name: "v"))])
    #expect(apiEditorVerdict(t, replacing: 0..<1, with: "", key: .backspace, isRepeat: true,
                             singleLine: true) == .ignore)
    #expect(apiEditorVerdict(t, replacing: 1..<2, with: "", key: .backspace, isRepeat: true,
                             singleLine: true) == .ignore)
}

@Test("A selection holding holes deletes them as text")
func aSelectionWithHolesDeletesAsText() {
    let t = text([.literal("a"), .slot("x"), .literal("b"), .slot("y")])
    #expect(apiEditorVerdict(t, replacing: 0..<4, with: "", key: .backspace, singleLine: true) == .allow)
    #expect(apiEditorVerdict(t, replacing: 0..<4, with: "z", singleLine: true) == .allow)
}

@Test("W16: a selection holding a bound value is refused, deleted or replaced, on the field's line")
func aSelectionWithABoundValueIsRefused() {
    let t = text([.literal("a"), .bound(liveBinding(name: "v")), .literal("b")])
    #expect(apiEditorVerdict(t, replacing: 0..<3, with: "", key: .backspace, singleLine: true)
        == .refuse(apiBoundSelectionLine))
    #expect(apiEditorVerdict(t, replacing: 0..<3, with: "x", singleLine: true)
        == .refuse(apiBoundSelectionLine))
}

@Test("Ambiguity 6: dragging a bound value out leaves the source whole, silently")
func dragOutOfABoundSelectionIsIgnored() {
    let t = text([.literal("a"), .bound(liveBinding(name: "v"))])
    #expect(apiEditorVerdict(t, replacing: 0..<2, with: "", draggingOut: true, singleLine: true) == .ignore)
}

@Test("Review Focus 1: a composition never acts on a token")
func aCompositionNeverActsOnAToken() {
    let t = text([.literal("a"), .slot("x"), .bound(liveBinding(name: "v"))])
    // The key belongs to the input method while text is marked.
    #expect(apiEditorVerdict(t, replacing: 1..<2, with: "", key: .backspace, composing: true,
                             singleLine: true) == .ignore)
    #expect(apiEditorVerdict(t, replacing: 2..<3, with: "", key: .backspace, composing: true,
                             singleLine: true) == .ignore)
    // A composition that would replace a selection holding a bound value is refused.
    #expect(apiEditorVerdict(t, replacing: 0..<3, with: "か", composing: true, singleLine: true)
        == .refuse(apiBoundSelectionLine))
}

@Test("A single-line field takes no line break: it is substituted out")
func aSingleLineFieldTakesNoBreak() {
    let t = text([.literal("/a")])
    #expect(apiEditorVerdict(t, replacing: 2..<2, with: "b\nc", singleLine: true) == .substitute("bc"))
    #expect(apiEditorVerdict(t, replacing: 2..<2, with: "b\nc", singleLine: false) == .allow)
}

@Test("10b: copying a bound value carries its HOLE; outside Wakil it reads <name>")
func aCopyCarriesHolesOnly() {
    let t = text([.literal("/a/"), .bound(liveBinding(name: "id")), .literal("/"), .slot("x")])
    let clip = ApiEditorClip(t, range: 0..<6)
    #expect(clip.text.parts == [.literal("/a/"), .slot("id"), .literal("/"), .slot("x")])
    #expect(clip.plain == "/a/<id>/<x>")
}

@Test("10b: Wakil's own clip pastes tokens; outside text pastes literal, <id> and all")
func pastes() {
    let clip = ApiEditorClip(text([.slot("id"), .literal("\n/b")]), range: 0..<4)
    #expect(apiEditorPasted(clip: clip, plain: "<id>/b", singleLine: true)?.parts
        == [.slot("id"), .literal("/b")])
    #expect(apiEditorPasted(clip: nil, plain: "<id>/b", singleLine: true)?.parts == [.literal("<id>/b")])
    #expect(apiEditorPasted(clip: nil, plain: nil, singleLine: true) == nil)
}

@Test("The clip survives the pasteboard: it encodes and decodes to itself")
func theClipRoundTripsThroughJSON() throws {
    let clip = ApiEditorClip(text([.literal("a"), .slot("x")]), range: 0..<2)
    let data = try JSONEncoder().encode(clip)
    #expect(try JSONDecoder().decode(ApiEditorClip.self, from: data) == clip)
}

@Test("10b: a same-field drag moves the selection, the bound value with it")
func aSameFieldDragMoves() {
    let bound = liveBinding(name: "id")
    let t = text([.literal("ab"), .bound(bound), .literal("cd")])
    let moved = apiEditorMoving(t, range: 2..<3, to: 5)
    #expect(moved?.text.parts == [.literal("abcd"), .bound(bound)])
    #expect(moved?.selection == 4..<5)
    let back = apiEditorMoving(t, range: 2..<3, to: 0)
    #expect(back?.text.parts == [.bound(bound), .literal("abcd")])
    #expect(apiEditorMoving(t, range: 2..<3, to: 3) == nil)
}

@Test("10b: + hole lands at the caret, or the selection's end, and never replaces text")
func aHoleLandsAtTheCaret() {
    let t = text([.literal("{\"a\":1}")])
    #expect(apiEditorHoleOffset(t, selection: 6..<6, isPathView: false) == 6)
    #expect(apiEditorHoleOffset(t, selection: 2..<4, isPathView: false) == 4)
}

@Test("A field the caret has not been in takes + hole at the end; the path view at the PATH's end")
func aNeverFocusedFieldTakesTheHoleAtItsEnd() {
    #expect(apiEditorHoleOffset(text([.literal("{}")]), selection: nil, isPathView: false) == 2)
    // I4: before the `?`, never inside the last query value.
    let view = text([.literal("/orders?page=2")])
    #expect(apiEditorHoleOffset(view, selection: nil, isPathView: true) == 7)
    #expect(apiEditorHoleOffset(text([.literal("/orders")]), selection: nil, isPathView: true) == 7)
}

@Test("A blank hole name is refused in its own words; any other name is taken exactly")
func blankHoleNames() {
    #expect(apiHoleNameRefused("  ") == apiHoleNameRefusal)
    #expect(apiHoleNameRefused(" id ") == nil)
}
```

- [ ] **Step 2: Run them, and see them fail**

Run: `make app-test 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'apiEditorVerdict' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Amendment 10b — **the editor's one custom key rule, and what may happen to a token.**
///
/// Typing, the caret, selection, arrows, undo, input methods and wrapping are AppKit's. The
/// editor asks this file before any change that touches a token, and does what it answers.

public enum ApiEditorKey: Sendable, Equatable { case backspace, delete }

public enum ApiEditorVerdict: Sendable, Equatable {
    /// AppKit applies the change.
    case allow
    /// Nothing changes and nothing is said: a held key's repeat, a key the input method owns, or
    /// the source half of a drag out of a selection that holds a binding.
    case ignore
    /// Nothing changes, and this line is drawn under the field.
    case refuse(String)
    /// The key reached a bound value: `api_unbind` it (W4), by its place among the tokens.
    case unbind(ordinal: Int, name: String)
    /// A single-line field: insert this instead (the line breaks taken out).
    case substitute(String)
}

/// Drawn under a field when a selection holding a bound value would be deleted, replaced or cut.
public let apiBoundSelectionLine =
    "a selection holding a bound value can't be deleted or replaced — use the value's × to unbind it"

/// What a change to `text` may do (10b).
///
/// - **A key on exactly one token** (Backspace just after it, Delete just before it): a hole goes
///   as one character, and a bound value is unbound to its hole (W4, W16). A held key's repeat
///   (P8) and a key while text is marked (the input method's) do nothing.
/// - **A range holding a bound value** is refused, typed over, deleted or cut alike, because a
///   write can neither drop nor make a binding (W16). The one exception is a drag out to another
///   field (`draggingOut`): the destination got the hole, and the source stays whole, silently.
/// - **A single-line field** takes no line break.
public func apiEditorVerdict(
    _ text: ApiEditorText, replacing range: Range<Int>, with inserted: String,
    key: ApiEditorKey? = nil, isRepeat: Bool = false, composing: Bool = false,
    draggingOut: Bool = false, singleLine: Bool
) -> ApiEditorVerdict {
    let touched = text.tokens(in: range)
    if key != nil, inserted.isEmpty, range.count == 1, let token = touched.first {
        if composing || isRepeat { return .ignore }
        guard case .bound(let value) = token else { return .allow }
        return .unbind(ordinal: text.ordinal(ofTokenAt: range.lowerBound) ?? 0, name: value.name)
    }
    if touched.contains(where: \.isBound) {
        return draggingOut ? .ignore : .refuse(apiBoundSelectionLine)
    }
    if singleLine, inserted.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
        return .substitute(apiSingleLineText(inserted))
    }
    return .allow
}

/// Wakil's own pasteboard type: a clip of one field's text with its holes, so a hole moves
/// between Wakil's fields while text pasted from outside stays literal (10b).
public let apiEditorPasteboardType = "com.wakil.api.editor-text"

/// What a copy, a cut or a drag carries. **Text and holes only**: a bound value is carried as
/// its HOLE, so no pasteboard ever carries a binding (10b, W16).
public struct ApiEditorClip: Codable, Sendable, Equatable {
    public enum Run: Codable, Sendable, Equatable {
        case text(String)
        case hole(String)
    }

    public let runs: [Run]

    public init(runs: [Run]) { self.runs = runs }

    public init(_ text: ApiEditorText, range: Range<Int>) {
        runs = text.slice(range).runs.map { run in
            switch run {
            case .text(let string): return .text(string)
            case .token(let token): return .hole(token.name)
            }
        }
    }

    /// What another app reads: each hole as `<name>`.
    public var plain: String {
        runs.map { run in
            switch run {
            case .text(let string): return string
            case .hole(let name): return "<\(name)>"
            }
        }.joined()
    }

    public var text: ApiEditorText {
        ApiEditorText(parts: runs.map { run in
            switch run {
            case .text(let string): return .literal(string)
            case .hole(let name): return .slot(name)
            }
        })
    }
}

/// What a paste inserts. **Wakil's own clip** gives its tokens back as holes. **Outside text
/// stays literal**: `<id>` is not parsed into a hole (10b). A single-line field drops line
/// breaks. `nil` when the pasteboard holds neither.
public func apiEditorPasted(
    clip: ApiEditorClip?, plain: String?, singleLine: Bool
) -> ApiEditorText? {
    let pasted: ApiEditorText
    if let clip {
        pasted = clip.text
    } else if let plain {
        pasted = ApiEditorText(parts: [.literal(plain)])
    } else {
        return nil
    }
    guard singleLine else { return pasted }
    return ApiEditorText(parts: pasted.parts.map { part in
        if case .literal(let string) = part { return .literal(apiSingleLineText(string)) }
        return part
    })
}

/// A drag inside one field: `range` moved to `offset`, an offset in the text before the move.
/// **The one way a bound value moves** (10b): one write carries it, so the binding is never
/// dropped. `nil` for a drop inside the range itself, which moves nothing.
public func apiEditorMoving(
    _ text: ApiEditorText, range: Range<Int>, to offset: Int
) -> (text: ApiEditorText, selection: Range<Int>)? {
    guard !range.isEmpty, offset < range.lowerBound || offset > range.upperBound else { return nil }
    let moved = text.slice(range)
    let removed = text.replacing(range, with: ApiEditorText(parts: []))
    let at = offset > range.upperBound ? offset - range.count : offset
    return (removed.replacing(at..<at, with: moved), at..<(at + range.count))
}

/// Where `+ hole` lands (10b; W7 generalised to every field). It lands **at the caret**, or at
/// the selection's end, replacing nothing, because a gesture never deletes text. `selection` is
/// `nil` for a field the caret has not been in, and the hole then lands **at the end**. In the
/// path view that is the end of the path, before the `?` (final review I4): appended to the
/// view, it fell into the last query value.
public func apiEditorHoleOffset(
    _ text: ApiEditorText, selection: Range<Int>?, isPathView: Bool
) -> Int {
    if let selection { return min(max(selection.upperBound, 0), text.length) }
    guard isPathView else { return text.length }
    return text.units.firstIndex(of: .code(UInt16(ascii: "?"))) ?? text.length
}

/// `apiHoleNameRefusal` for a blank name, else `nil`. A name is taken exactly as typed (spec §1).
public func apiHoleNameRefused(_ name: String) -> String? {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiHoleNameRefusal : nil
}
```

- [ ] **Step 4: Run the tests, and see them pass**

Run: `make app-test 2>&1 | grep -E "ApiEditorRules|passed|failed" | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Api/ApiEditorRules.swift app/Tests/WakilKitTests/ApiEditorRulesTests.swift
git commit -m "2c-iv Amendment 10b: the token rules — keys, a bound selection, copy, paste, move, + hole

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Saved as typed, one held part list per field (WakilKit)

**Why.** 10a: *"Each field is one box holding its parts, and a flush writes the field whole in
one `api_set_request`. Focus marks, `queued`, `takenOver`, Escape's focus-in baseline, the 300 ms
pause and the surface chain stay, one box per field."* This task adds the **held** API **beside**
the index-keyed one. The pane moves to it field by field in Tasks 5 and 6, and Task 7 deletes the
old one. The new functions overload the old names by their argument labels (`held:`/`holding:`
against `boxes:`/`typed:`), so `WakilApp` keeps compiling unchanged.

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiSaveAsTyped.swift` (append the held section)
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift` (append `apiHeldWrite`, `apiSendPlan(held:)`)
- Modify: `app/Sources/WakilKit/Api/ApiPathQuery.swift` (append `apiPathViewWrite`)
- Modify: `app/Sources/WakilKit/Api/ApiBodyFormat.swift` (append the `holding:` overloads)
- Modify: `app/Sources/WakilKit/Api/ApiRows.swift` (append `apiBoxesRemovingRow(_: ApiHeld, …)`)
- Test: `app/Tests/WakilKitTests/ApiFieldHeldTests.swift`

**Interfaces:**
- Consumes: `ApiPendingWrite`, `ApiFocusedField`, `apiRestoreCalls` (unchanged),
  `apiFieldViewParts`/`apiFieldViewIsTypable` (still in `ApiFieldItems.swift` until Task 7),
  `apiFieldParts`, `apiDraftForWrite`, `apiPartsRegionWrite`, `apiPartJSON`, `apiKeepingHeld`,
  `ApiHeldBindings`, `apiPathQueryParse`, `apiPathBoxKeepsItsBindings`, `apiPathBoxWriteIsNoOp`,
  `apiPathQueryWrite`, `apiContentTypeText`, `apiContentTypeCommitIsNoOp`,
  `apiFieldWrite(field:text:pane:)`, `apiFormatBody`, `apiSendControl`, `apiSendParams`,
  `apiPickAnEntryFirst`, `apiRowField`.
- Produces:
  - `public typealias ApiHeld = [ApiFieldRow: [ApiPart]]`
  - `public func apiHeldView(_ request: ApiRequestSnapshot, _ box: ApiFieldRow) -> [ApiPart]`
  - `public func apiPendingWrite(_ request: ApiRequestSnapshot, box: ApiFieldRow, holding parts: [ApiPart], pane: String) -> ApiPendingWrite`
  - `public func apiRequestApplying(_ request: ApiRequestSnapshot, held: ApiHeld, except: ApiFieldRow? = nil) -> ApiRequestSnapshot`
  - `public struct ApiHeldFlush { writes; refusals: [ApiFieldRow: String]; written: ApiHeld }`
  - `public func apiFlush(_ request: ApiRequestSnapshot, held: ApiHeld, pane: String, queued: ApiHeld = [:], takenOver: [ApiFieldRow: ApiHeldTakeover] = [:]) -> ApiHeldFlush`
  - `public func apiQueuedSettled(_ queued: ApiHeld, written: ApiHeld) -> ApiHeld`
  - `public func apiHeldAfterLanding(_ request: ApiRequestSnapshot, held: ApiHeld, focused: ApiFieldRow?, takenOver: [ApiFieldRow: ApiHeldTakeover] = [:], queued: ApiHeld = [:]) -> ApiHeld`
  - `public struct ApiHeldTakeover { held: [ApiPart]; token: Int }`
  - `public func apiTakenOverSettled(_ takenOver: [ApiFieldRow: ApiHeldTakeover], held: ApiHeld) -> [ApiFieldRow: ApiHeldTakeover]`
  - `public func apiGestureSettled(takenOver: [ApiFieldRow: ApiHeldTakeover], held: ApiHeld, carried: [ApiFieldRow: ApiHeldTakeover], landed: Bool) -> (takenOver: [ApiFieldRow: ApiHeldTakeover], held: ApiHeld, owed: Bool)`
  - `public func apiHeldTyping(_ held: ApiHeld, box: ApiFieldRow, parts: [ApiPart], rendered: [ApiPart]) -> ApiHeld?`
  - `public func apiHeldWrite(draft: ApiRequestSnapshot, field: ApiDraftField, parts: [ApiPart], pane: String, row: Int = 0) -> JSONValue?`
  - `public func apiPathViewWrite(_ request: ApiRequestSnapshot, view: [ApiPart], pane: String) -> ApiPathBoxOutcome`
  - `public func apiSendPlan(draft: ApiRequestSnapshot, pane: String, held: ApiHeld, queued: ApiHeld = [:], unpointed: Bool = false, takenOver: [ApiFieldRow: ApiHeldTakeover] = [:]) -> ApiHeldSendPlan` (`calls`, `refusals`, `written: ApiHeld`, `refusal`)
  - `public func apiFormatBodyWrite(draft: ApiRequestSnapshot, pane: String, holding: [ApiPart]) -> JSONValue?`, `apiFormatIsNoOp(draft:holding:)`, `apiFormatIsEnabled(draft:holding:)`
  - `public func apiBoxesRemovingRow(_ held: ApiHeld, region: ApiRowRegion, name: String, row: Int) -> ApiHeld`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

/// Amendment 10a: saved as typed (9a), one held part list per field.

private func req(
    method: String = "POST", path: [ApiPart] = [], query: [ApiQueryRow] = [],
    headers: [ApiHeaderRegionRow] = ApiRequestSnapshot.empty.headers, body: [ApiPart] = []
) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: method, origin: "https://httpbin.org", path: path, query: query,
        headers: headers, body: body)
}

private func q(_ name: String, _ value: [ApiPart]) -> ApiQueryRow { ApiQueryRow(name: name, value: value) }
private let body = ApiFieldRow(.body)
private let path = ApiFieldRow(.path)

@Test("A held body is one write carrying the field whole, its holes as slots")
func aHeldBodyIsOneWrite() {
    #expect(apiPendingWrite(req(), box: body, holding: [.literal("{\"a\":"), .slot("id"), .literal("}")],
                            pane: "p")
        == .write(.object(["pane": .string("p"), "body": .array([
            .object(["literal": .string("{\"a\":")]), .object(["slot": .string("id")]),
            .object(["literal": .string("}")]),
        ])])))
}

@Test("Parts the draft already holds, merged or not, write nothing")
func heldEqualToTheDraftWritesNothing() {
    let r = req(body: [.literal("{"), .literal("}")])
    #expect(apiPendingWrite(r, box: body, holding: [.literal("{}")], pane: "p") == .unchanged)
    #expect(apiFlush(r, held: [body: [.literal("{}")]], pane: "p").writes.isEmpty)
}

@Test("W16: a binding the region holds rides along unchanged")
func aHeldBindingRidesAlong() {
    let bound = liveBinding(name: "id")
    let r = req(body: [.bound(bound)])
    #expect(apiPendingWrite(r, box: body, holding: [.bound(bound), .literal("x")], pane: "p")
        == .write(.object(["pane": .string("p"), "body": .array([
            apiPartJSON(.bound(bound), sources: [:]), .object(["literal": .string("x")]),
        ])])))
}

@Test("Review Focus 2: a binding the region no longer holds is written as its hole, never made")
func aBindingTheRegionNoLongerHoldsIsWrittenAsItsHole() {
    // Undo brought a bound token back after its unbind landed: the draft holds the hole.
    let bound = liveBinding(name: "id")
    let r = req(body: [.slot("id")])
    #expect(apiPendingWrite(r, box: body, holding: [.bound(bound), .literal("x")], pane: "p")
        == .write(.object(["pane": .string("p"), "body": .array([
            .object(["slot": .string("id")]), .object(["literal": .string("x")]),
        ])])))
    // And held twice, the second copy is a hole too: a write never makes a binding.
    let r2 = req(body: [.bound(bound)])
    guard case .write(.object(let params)) = apiPendingWrite(
        r2, box: body, holding: [.bound(bound), .bound(bound)], pane: "p"),
        case .array(let parts)? = params["body"]
    else { Issue.record("expected a body write"); return }
    #expect(parts == [apiPartJSON(.bound(bound), sources: [:]), .object(["slot": .string("id")])])
}

@Test("The path view parses back to path and query in one write")
func thePathViewIsOneWrite() {
    #expect(apiPendingWrite(req(), box: path, holding: [.literal("/test?page=2")], pane: "p")
        == .write(apiPathQueryWrite(path: [.literal("/test")], query: [q("page", [.literal("2")])], pane: "p")))
}

@Test("A path view the parse refuses is refused in its own words")
func aRefusedPathView() {
    let flush = apiFlush(req(), held: [path: [.literal("/o?=x")]], pane: "p")
    #expect(flush.writes.isEmpty)
    #expect(flush.refusals[path] == ApiPathQueryRefusal.namelessRow.line)
}

@Test("A hole at a caret in a query value of the path view lands in that value")
func aHoleInAQueryValueOfTheView() {
    let r = req(path: [.literal("/o")], query: [q("id", [.literal("7")])])
    #expect(apiPendingWrite(r, box: path, holding: [.literal("/o?id="), .slot("id")], pane: "p")
        == .write(apiPathQueryWrite(path: [.literal("/o")], query: [q("id", [.slot("id")])], pane: "p")))
}

@Test("A query value and a header value write their region whole, other rows carried")
func rowsWriteTheirRegion() {
    let r = req(query: [q("a", [.literal("1")]), q("b", [.literal("2")])])
    #expect(apiPendingWrite(r, box: ApiFieldRow(.query("b")), holding: [.literal("3")], pane: "p")
        == .write(.object(["pane": .string("p"), "query": .array([
            .object(["name": .string("a"), "value": .array([.object(["literal": .string("1")])])]),
            .object(["name": .string("b"), "value": .array([.object(["literal": .string("3")])])]),
        ])])))
}

@Test("F23: a field whose write is in flight at exactly these parts is skipped")
func anInFlightFieldIsSkipped() {
    let held: ApiHeld = [body: [.literal("x")]]
    #expect(apiFlush(req(), held: held, pane: "p", queued: held).writes.isEmpty)
    #expect(apiFlush(req(), held: [body: [.literal("xy")]], pane: "p", queued: held).writes.count == 1)
    #expect(apiQueuedSettled(held, written: held).isEmpty)
}

@Test("A field a gesture took over is never flushed at the parts it carried")
func aTakenOverFieldIsNotFlushed() {
    let held: ApiHeld = [body: [.literal("x")]]
    let takenOver = [body: ApiHeldTakeover(held: [.literal("x")], token: 1)]
    #expect(apiFlush(req(), held: held, pane: "p", takenOver: takenOver).writes.isEmpty)
}

@Test("A held field is let go once the draft shows it; kept while focused and owing")
func heldAfterLanding() {
    let r = req(body: [.literal("x")])
    #expect(apiHeldAfterLanding(r, held: [body: [.literal("x")]], focused: body).isEmpty)
    #expect(apiHeldAfterLanding(r, held: [body: [.literal("xy")]], focused: nil)[body] == [.literal("xy")])
    // A-B-A: shown, focused, but another write for it is still in flight: kept.
    #expect(apiHeldAfterLanding(r, held: [body: [.literal("x")]], focused: body,
                                queued: [body: [.literal("xy")]])[body] == [.literal("x")])
}

@Test("A set that changes nothing types nothing (round 6), up to merging")
func aSetThatChangesNothing() {
    #expect(apiHeldTyping([:], box: body, parts: [.literal("a"), .literal("b")],
                          rendered: [.literal("ab")]) == nil)
    #expect(apiHeldTyping([:], box: body, parts: [.literal("abc")], rendered: [.literal("ab")])?[body]
        == [.literal("abc")])
}

@Test("A gesture's dispatch settles only what it carried: landed lets go, refused owes")
func gestureSettled() {
    let entry = ApiHeldTakeover(held: [.literal("x")], token: 7)
    let landed = apiGestureSettled(takenOver: [body: entry], held: [body: [.literal("x")]],
                                   carried: [body: entry], landed: true)
    #expect(landed.takenOver.isEmpty && landed.held.isEmpty && !landed.owed)
    let refused = apiGestureSettled(takenOver: [body: entry], held: [body: [.literal("x")]],
                                    carried: [body: entry], landed: false)
    #expect(refused.takenOver.isEmpty && refused.held[body] == [.literal("x")] && refused.owed)
}

@Test("Send: every held field's write, then the send, built on what the screen shows")
func sendPlanCarriesHeldWritesFirst() {
    let plan = apiSendPlan(draft: req(), pane: "p", held: [body: [.literal("{}")]])
    #expect(plan.calls.map(\.0) == ["api_set_request", "api_send"])
    #expect(plan.written[body] == [.literal("{}")])
}

@Test("Format formats the held body, tokens in place")
func formatHolding() {
    guard case .object(let params)? = apiFormatBodyWrite(
        draft: req(), pane: "p",
        holding: [.literal("{\"a\":"), .slot("a"), .literal(",\"b\":"), .slot("b"), .literal("}")]),
        case .array(let parts)? = params["body"]
    else { Issue.record("expected a body write"); return }
    #expect(parts == [
        .object(["literal": .string("{\n  \"a\": ")]), .object(["slot": .string("a")]),
        .object(["literal": .string(",\n  \"b\": ")]), .object(["slot": .string("b")]),
        .object(["literal": .string("\n}")]),
    ])
}
```

- [ ] **Step 2: Run them, and see them fail**

Run: `make app-test 2>&1 | grep -E "error:" | head -3`
Expected: `extra argument 'holding' in call`, or `cannot find type 'ApiHeld'`.

- [ ] **Step 3: Write the implementation**

Append to `ApiSaveAsTyped.swift`:

```swift
// MARK: - Amendment 10a: one held part list per field

/// Each field's parts as its editor holds them, while the draft may not hold them yet (9a, 10a).
/// One entry per field, never per box: a flush writes the field whole.
public typealias ApiHeld = [ApiFieldRow: [ApiPart]]

/// What a field's editor shows when nothing is held: the path view (8a) for the path, a row's
/// value for a query or header row, the body, and the content type's text as one literal.
public func apiHeldView(_ request: ApiRequestSnapshot, _ box: ApiFieldRow) -> [ApiPart] {
    switch box.field {
    case .contentType:
        let text = apiContentTypeText(request)
        return text.isEmpty ? [] : [.literal(text)]
    case .method:
        return []
    case .path, .query, .header, .body:
        return apiFieldViewParts(request, box.field, row: box.row)
    }
}

/// What one held field would write right now (9a, one field at a time).
///
/// **A binding its region no longer holds is written as its hole** (Review Focus 2,
/// `apiKeepingHeld`): undo can bring a bound token back into an editor, and a write may carry a
/// binding but never make one (W16). The path view keeps its own refusal for a binding moved
/// across the `?` (`apiPathViewWrite`).
public func apiPendingWrite(
    _ request: ApiRequestSnapshot, box: ApiFieldRow, holding parts: [ApiPart], pane: String
) -> ApiPendingWrite {
    switch box.field {
    case .method:
        return .unchanged
    case .contentType:
        let text = apiSingleLineText(parts.compactMap { part -> String? in
            if case .literal(let string) = part { return string }
            return nil
        }.joined())
        guard !apiContentTypeCommitIsNoOp(request, text: text) else { return .unchanged }
        return .write(apiFieldWrite(field: .contentType, text: text, pane: pane))
    case .path:
        guard apiPathBoxIsTypable(request) else { return .unchanged }
        switch apiPathViewWrite(request, view: parts, pane: pane) {
        case .write(let params): return .write(params)
        case .refused(let line): return .refused(line)
        case .unchanged, .nothing: return .unchanged
        }
    case .query, .header, .body:
        guard apiFieldIsTypable(request, box.field) else { return .unchanged }
        let current = apiFieldParts(request, box.field, row: box.row)
        var pool = ApiHeldBindings(current)
        let written = apiMergedLiterals(apiKeepingHeld(parts, &pool))
        guard written != apiMergedLiterals(current),
              let params = apiHeldWrite(
                  draft: request, field: box.field, parts: written, pane: pane, row: box.row)
        else { return .unchanged }
        return .write(params)
    }
}

/// The request as the screen shows it: the draft with every held field applied. `except`
/// leaves one field out. A path view the parse refuses, or one that would move a binding,
/// applies nothing.
public func apiRequestApplying(
    _ request: ApiRequestSnapshot, held: ApiHeld, except: ApiFieldRow? = nil
) -> ApiRequestSnapshot {
    var path = request.path
    var query = request.query
    var headers = request.headers
    var body = request.body
    let keys = held.keys.sorted { $0.field != $1.field ? $0.field < $1.field : $0.row < $1.row }
    for key in keys where key != except {
        let parts = apiDroppingEmptyLiterals(held[key] ?? [])
        switch key.field {
        case .path:
            guard apiPathBoxIsTypable(request),
                  case .success(let parsed) = apiPathQueryParse(parts),
                  apiPathBoxKeepsItsBindings(request, path: parsed.path, query: parsed.query)
            else { continue }
            path = parsed.path
            query = parsed.query
        case .query(let name):
            var seen = 0
            query = query.map { row in
                guard row.name == name else { return row }
                defer { seen += 1 }
                return seen == key.row ? ApiQueryRow(name: name, value: parts) : row
            }
        case .header(let name):
            var seen = 0
            headers = headers.map { row in
                guard row.name == name, row.isEditable, row.value != nil else { return row }
                defer { seen += 1 }
                return seen == key.row
                    ? ApiHeaderRegionRow(
                        name: name, value: parts, provenance: row.provenance, rowClass: row.rowClass)
                    : row
            }
        case .contentType:
            let text = apiSingleLineText(parts.compactMap { part -> String? in
                if case .literal(let string) = part { return string }
                return nil
            }.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
            headers = headers.map { row in
                guard row.rowClass == .derived else { return row }
                return ApiHeaderRegionRow(
                    name: row.name, value: text.isEmpty ? nil : [.literal(text)],
                    provenance: row.provenance, rowClass: .derived)
            }
        case .body:
            body = parts
        case .method:
            continue
        }
    }
    return ApiRequestSnapshot(
        method: request.method, origin: request.origin, path: path, query: query,
        headers: headers, body: body)
}

public struct ApiHeldFlush {
    public let writes: [(String, JSONValue)]
    public let refusals: [ApiFieldRow: String]
    /// Each field in `writes`, at the parts it was written with: `queued` until it completes.
    public let written: ApiHeld
}

/// The writes that make the draft hold what the editors show, in wire order (9a, per field).
/// A field in flight at exactly these parts (F23), or taken over by a gesture at them, is
/// skipped.
public func apiFlush(
    _ request: ApiRequestSnapshot, held: ApiHeld, pane: String,
    queued: ApiHeld = [:], takenOver: [ApiFieldRow: ApiHeldTakeover] = [:]
) -> ApiHeldFlush {
    var writes: [(String, JSONValue)] = []
    var refusals: [ApiFieldRow: String] = [:]
    var written: ApiHeld = [:]
    let keys = held.keys.sorted { $0.field != $1.field ? $0.field < $1.field : $0.row < $1.row }
    for key in keys where queued[key] != held[key] && takenOver[key]?.held != held[key] {
        switch apiPendingWrite(request, box: key, holding: held[key] ?? [], pane: pane) {
        case .write(let params):
            writes.append(("api_set_request", params))
            written[key] = held[key]
        case .refused(let line):
            refusals[key] = line
        case .unchanged:
            break
        }
    }
    return ApiHeldFlush(writes: writes, refusals: refusals, written: written)
}

/// `queued` once the dispatch that carried `written` completed, whatever its outcome (F23).
public func apiQueuedSettled(_ queued: ApiHeld, written: ApiHeld) -> ApiHeld {
    queued.filter { key, parts in written[key] != parts }
}

/// The held fields still worth keeping once a snapshot lands (9a; round 5; A-B-A).
///
/// A field taken over by a gesture still in flight is kept. **A field whose editor shows what
/// the view now draws is let go, focused or not**, so that a change from elsewhere redraws it,
/// unless it is focused and a write of OTHER parts is still in flight for it (A-B-A). Otherwise
/// it is kept while focused, or while it owes a write.
public func apiHeldAfterLanding(
    _ request: ApiRequestSnapshot, held: ApiHeld, focused: ApiFieldRow?,
    takenOver: [ApiFieldRow: ApiHeldTakeover] = [:], queued: ApiHeld = [:]
) -> ApiHeld {
    held.filter { key, parts in
        if takenOver[key]?.held == parts { return true }
        if key.field == .method { return false }
        let shown = apiMergedLiterals(parts) == apiMergedLiterals(apiHeldView(request, key))
        if shown {
            return key == focused && queued[key].map { $0 != parts } == true
        }
        return key == focused
            || apiPendingWrite(request, box: key, holding: parts, pane: "") != .unchanged
    }
}

/// One gesture's hold on a field (Task 9 fix rounds 2–4): the parts it carried, and the token
/// of the dispatch that carried them.
public struct ApiHeldTakeover: Equatable, Sendable {
    public let held: [ApiPart]
    public let token: Int

    public init(held: [ApiPart], token: Int) {
        self.held = held
        self.token = token
    }
}

public func apiTakenOverSettled(
    _ takenOver: [ApiFieldRow: ApiHeldTakeover], held: ApiHeld
) -> [ApiFieldRow: ApiHeldTakeover] {
    takenOver.filter { key, entry in held[key] == entry.held }
}

public func apiGestureSettled(
    takenOver: [ApiFieldRow: ApiHeldTakeover], held: ApiHeld,
    carried: [ApiFieldRow: ApiHeldTakeover], landed: Bool
) -> (takenOver: [ApiFieldRow: ApiHeldTakeover], held: ApiHeld, owed: Bool) {
    var takenOver = takenOver
    var held = held
    var owed = false
    for (key, entry) in carried where takenOver[key] == entry {
        takenOver[key] = nil
        if landed, held[key] == entry.held { held[key] = nil }
        if !landed, held[key] != nil { owed = true }
    }
    return (takenOver, held, owed)
}

/// Round 6, per field: the held fields after the editor reported `parts`, or `nil` when they
/// are what it shows already, up to merging. `nil` means no hold and no pause.
public func apiHeldTyping(
    _ held: ApiHeld, box: ApiFieldRow, parts: [ApiPart], rendered: [ApiPart]
) -> ApiHeld? {
    guard apiMergedLiterals(parts) != apiMergedLiterals(held[box] ?? rendered) else { return nil }
    var next = held
    next[box] = parts
    return next
}
```

Append to `ApiActions.swift`. This is `apiPartsWrite`'s field switch, taking the part list
whole:

```swift
/// What a held field writes (10a): **the field whole**, its holes as `{"slot":}`, a binding as
/// published (W16), and a row's region with every other row carried (`apiPartsRegionWrite`).
public func apiHeldWrite(
    draft: ApiRequestSnapshot, field: ApiDraftField, parts: [ApiPart], pane: String, row: Int = 0
) -> JSONValue? {
    let written = apiDroppingEmptyLiterals(parts).map { apiPartJSON($0, sources: [:]) }
    var params: [String: JSONValue] = ["pane": .string(pane)]
    switch field {
    case .path:
        params["path"] = .array(written)
    case .body:
        params["body"] = .array(written)
    case .query(let name):
        let rows = apiDraftForWrite(draft).query.map { (name: $0.name, value: $0.value) }
        params["query"] = apiPartsRegionWrite(rows, editing: name, row: row, written: written)
    case .header(let name):
        let rows = apiDraftForWrite(draft).headers.map { (name: $0.name, value: $0.value) }
        params["headers"] = apiPartsRegionWrite(rows, editing: name, row: row, written: written)
    case .method, .contentType:
        return nil
    }
    return .object(params)
}

public struct ApiHeldSendPlan {
    public let calls: [(String, JSONValue)]
    public let refusals: [ApiFieldRow: String]
    public let written: ApiHeld
    public var refusal: String? = nil
}

/// `apiSendPlan`, per field (10a): built at Send's turn on the chain (round 4). Every held
/// field's write comes first, then the send, built on the request the screen shows. Nothing is
/// sent while a write is refused (F8).
public func apiSendPlan(
    draft: ApiRequestSnapshot, pane: String, held: ApiHeld, queued: ApiHeld = [:],
    unpointed: Bool = false, takenOver: [ApiFieldRow: ApiHeldTakeover] = [:]
) -> ApiHeldSendPlan {
    let control = apiSendControl(method: draft.method)
    let flush = apiFlush(draft, held: held, pane: pane, queued: queued, takenOver: takenOver)
    guard flush.refusals.isEmpty else {
        return ApiHeldSendPlan(calls: [], refusals: flush.refusals, written: [:])
    }
    if unpointed {
        return ApiHeldSendPlan(
            calls: flush.writes, refusals: [:], written: flush.written, refusal: apiPickAnEntryFirst)
    }
    let calls = flush.writes + [(
        control.action,
        apiSendParams(draft: apiRequestApplying(draft, held: held), pane: pane, origin: draft.origin)
    )]
    return ApiHeldSendPlan(calls: calls, refusals: [:], written: flush.written)
}
```

Append to `ApiPathQuery.swift`:

```swift
/// The path view, as its editor holds it, parsed back to path and query (8a, 10a). Refused in
/// the parse's own words, or `boundMoved` for a binding carried across the `?` (W16). A view
/// that parses to the draft it was typed over is `.unchanged`.
public func apiPathViewWrite(
    _ request: ApiRequestSnapshot, view: [ApiPart], pane: String
) -> ApiPathBoxOutcome {
    switch apiPathQueryParse(apiDroppingEmptyLiterals(view)) {
    case .success(let parsed):
        guard apiPathBoxKeepsItsBindings(request, path: parsed.path, query: parsed.query) else {
            return .refused(ApiPathQueryRefusal.boundMoved.line)
        }
        if apiPathBoxWriteIsNoOp(request: request, path: parsed.path, query: parsed.query) {
            return .unchanged
        }
        return .write(apiPathQueryWrite(path: parsed.path, query: parsed.query, pane: pane))
    case .failure(let refusal):
        return .refused(refusal.line)
    }
}
```

Append to `ApiBodyFormat.swift`:

```swift
/// `Format` over the body as its editor holds it (10a): re-indented, tokens in place, or `nil`
/// when that does not tokenize as JSON.
public func apiFormatBodyWrite(
    draft: ApiRequestSnapshot, pane: String, holding: [ApiPart]
) -> JSONValue? {
    guard let formatted = apiFormatBody(apiDroppingEmptyLiterals(holding)) else { return nil }
    let written: [JSONValue] = formatted.compactMap { part in
        if case .literal(let text) = part, text.isEmpty { return nil }
        return apiPartJSON(part, sources: [:])
    }
    return .object(["pane": .string(pane), "body": .array(written)])
}

public func apiFormatIsNoOp(draft: ApiRequestSnapshot, holding: [ApiPart]) -> Bool {
    guard let formatted = apiFormatBody(apiDroppingEmptyLiterals(holding)) else { return false }
    return formatted == apiMergedLiterals(draft.body)
}

public func apiFormatIsEnabled(draft: ApiRequestSnapshot, holding: [ApiPart]) -> Bool {
    apiFieldIsTypable(draft, .body) && !apiDroppingEmptyLiterals(holding).isEmpty
}
```

Append to `ApiRows.swift`:

```swift
/// A row's `×`, per field (10a): every held field of that region at or after the removed row
/// goes, because their rows shift.
public func apiBoxesRemovingRow(
    _ held: ApiHeld, region: ApiRowRegion, name: String, row: Int
) -> ApiHeld {
    let field = apiRowField(region, name)
    return held.filter { key, _ in !(key.field == field && key.row >= row) }
}
```

- [ ] **Step 4: Run the tests, and see them pass**

Run: `make app-test 2>&1 | tail -5`
Expected: `ApiFieldHeldTests` all pass. Every existing test still passes, because nothing old
changed.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Api/ApiSaveAsTyped.swift app/Sources/WakilKit/Api/ApiActions.swift \
  app/Sources/WakilKit/Api/ApiPathQuery.swift app/Sources/WakilKit/Api/ApiBodyFormat.swift \
  app/Sources/WakilKit/Api/ApiRows.swift app/Tests/WakilKitTests/ApiFieldHeldTests.swift
git commit -m "2c-iv Amendment 10a: saved as typed, one held part list per field

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `ApiFieldEditor` and `ApiTokenView`, in the body

**Files:**
- Rename: `app/Sources/WakilApp/ApiBodyTextView.swift` → `app/Sources/WakilApp/ApiFieldEditor.swift`
  (`git mv`, then replace its contents)
- Create: `app/Sources/WakilApp/ApiTokenView.swift`
- Modify: `app/Sources/WakilApp/ApiPane.swift` (held state for the body, the editor registry,
  the flush, Send, the landing)
- Modify: `app/Sources/WakilApp/ApiPane+Fields.swift` (`fieldEditor`, `holeWrite` for the body,
  `unbind`, `restore`; delete `editorBox` and the `multiline` branch of `field`)
- Modify: `app/Sources/WakilApp/ApiPane+Request.swift` (`bodyRegion`, `formatControl`)
- Modify: `app/Sources/WakilApp/ApiPane+Sending.swift` (`send()`, Reopen's reset)

**Interfaces:**
- Consumes: Task 2 (`ApiEditorText`, `apiEditorTakesParts`, `apiEditorSelection`), Task 3 (all
  of it), and Task 4 (`ApiHeld`, `apiHeldView`, `apiHeldTyping`, `apiFlush(_:held:…)`,
  `apiRequestApplying(_:held:)`, `apiHeldAfterLanding`, `ApiHeldTakeover`,
  `apiGestureSettled(…held:…)`, `apiQueuedSettled(ApiHeld…)`, the `holding:` Format API).
  Unchanged: `apiChipUnbindParams`, `focusChanged(_:_:_:)`, `restore(_:)`, `press(fromKeyboard:)`.
- Produces (Task 6 reuses these unchanged):
  - `struct ApiFieldEditor: NSViewRepresentable`, with `identifier`, `key`, `parts`,
    `singleLine`, `editable`, `isPathView`, `handle: ApiEditorHandle` and
    `actions: ApiEditorActions`.
  - `struct ApiEditorActions`, with `typed([ApiPart])`, `gesture()`, `commit()`, `discard?()`,
    `focusChanged(Bool)`, `unbind(ordinal, name)` and `refused(String?)`.
  - `@MainActor final class ApiEditorHandle`, with `insertHole(_ name: String) -> Bool` and
    `focus()`.
  - `@MainActor final class ApiEditorRegistry`, with `handle(_ box: ApiFieldRow) -> ApiEditorHandle`.
  - `final class ApiFieldTextView: NSTextView`
  - In `ApiPane`: `fieldEditor(_:row:label:) -> some View`, `unbind(_:ordinal:name:)`, and the
    state `held`, `heldQueued`, `heldTakenOver`, `editors` and `editorRefusals`.

**Transitional until Task 6:** the body is held per field (`held`). Every other field is still
held by index (`boxes`). The flush and Send compose the two, and the body goes last because it is
last in wire order. Task 6 deletes `boxes` and renames `heldQueued` to `queued` and
`heldTakenOver` to `takenOver`.

- [ ] **Step 1: `git mv` the body view, then write `ApiFieldEditor.swift`**

```bash
git mv app/Sources/WakilApp/ApiBodyTextView.swift app/Sources/WakilApp/ApiFieldEditor.swift
```

Replace the file's contents with:

```swift
import AppKit
import WakilKit
import SwiftUI

/// Amendment 10 — **one editor per field.** The path view, each query value, each header value
/// and the body are each ONE `NSTextView` on TextKit 2. A literal is characters, and a hole or a
/// bound value is one attachment character drawn by `ApiTokenView`.
///
/// **AppKit owns typing, the caret, selection, arrows, undo, input methods and wrapping**
/// (10b). Nothing here moves the caret except taking an outside change, which maps it across
/// (`apiEditorSelection`). **No ruling lives here.** Before a change touches a token, this view
/// asks `apiEditorVerdict` and does what it answers. It reports every change as the field's
/// parts, and the pane decides what to write.
///
/// Kept from `ApiBodyTextView` (Ruling 11): every substitution is off, because a value is bytes
/// on the wire. The identifier is set only when it changes (Ruling 15). Escape restores the
/// field and leaves it. The text storage is the undo target that gets cleared when outside text
/// is taken (Ruling 12). In the body Tab inserts two spaces and ⌘Return sends (9a). The body
/// grows to 16 lines, then scrolls.
struct ApiFieldEditor: NSViewRepresentable {
    let identifier: String
    /// `apiFieldKey`: what the tokens' identifiers are built on.
    let key: String
    /// What the field shows: its held parts, or the view's.
    let parts: [ApiPart]
    let singleLine: Bool
    /// `false` only for the path view over an `&` (8d).
    let editable: Bool
    let isPathView: Bool
    let handle: ApiEditorHandle
    let actions: ApiEditorActions

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// The pane's ink at 0.85.
    static let ink = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 0.85)
    static let maxBodyLines = 16

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ApiFieldTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        // Rich, because attachments live in the storage. What a paste inserts is ours
        // (`readSelection`), so no foreign style or image ever arrives.
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Self.font
        textView.textColor = Self.ink
        textView.insertionPointColor = Self.ink
        textView.typingAttributes = [.font: Self.font, .foregroundColor: Self.ink]
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = editable
        textView.key = key
        textView.takeOutside(ApiEditorText(parts: parts))
        textView.refreshTokens(editable: editable)
        textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
        textView.setAccessibilityIdentifier(identifier)
        handle.textView = textView
        handle.isPathView = isPathView

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = !singleLine
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scroll.documentView as? ApiFieldTextView else { return }
        handle.textView = textView
        handle.isPathView = isPathView
        textView.key = key
        // Ruling 15: only when it changed.
        if textView.accessibilityIdentifier() != identifier {
            textView.setAccessibilityIdentifier(identifier)
        }
        if textView.isEditable != editable { textView.isEditable = editable }
        let showing = textView.editorText
        if showing == ApiEditorText(parts: parts) { coordinator.typedSinceTaken = [] }
        let focused = textView.window?.firstResponder === textView
        // Review Focus 4: never an echo of its own typing, and never what it already shows.
        guard apiEditorTakesParts(
            parts, showing: showing.parts, typedSinceTaken: coordinator.typedSinceTaken,
            focused: focused)
        else {
            textView.refreshTokens(editable: editable)
            return
        }
        coordinator.typedSinceTaken = []
        let incoming = ApiEditorText(parts: parts)
        let selected = textView.selectedRange()
        // Mapped across the change while it has the cursor; at the end otherwise (ambiguity 5).
        let next = focused
            ? apiEditorSelection(
                from: showing, to: incoming,
                selection: selected.location..<NSMaxRange(selected))
            : incoming.length..<incoming.length
        textView.takeOutside(incoming)
        textView.refreshTokens(editable: editable)
        textView.setSelectedRange(NSRange(location: next.lowerBound, length: next.count))
        // Ruling 12: the undo stack names ranges in the text just replaced.
        if let storage = textView.textStorage {
            textView.undoManager?.removeAllActions(withTarget: storage)
        }
        textView.undoManager?.removeAllActions(withTarget: textView)
    }

    /// One line empty, then the text's own height, measured on a copy (never the live view).
    /// The body is capped at 16 lines; a single-line field wraps and grows.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        let padding = (nsView.documentView as? NSTextView)?.textContainer?.lineFragmentPadding ?? 5
        let line = NSLayoutManager().defaultLineHeight(for: Self.font)
        let measured = NSMutableAttributedString(
            attributedString: apiEditorAttributed(ApiEditorText(parts: parts), editor: nil))
        measured.append(NSAttributedString(string: " ", attributes: [.font: Self.font]))
        let natural = measured.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        var width = natural.width + 2 * padding + 2
        if let proposed = proposal.width, proposed.isFinite { width = proposed }
        width = max(width, 60)
        let wrapped = measured.boundingRect(
            with: NSSize(width: max(width - 2 * padding, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let cap = singleLine ? CGFloat.greatestFiniteMagnitude : line * CGFloat(Self.maxBodyLines)
        return CGSize(width: width, height: ceil(min(max(ceil(wrapped.height), line), cap)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ApiFieldEditor
        /// Every part list this editor reported since it last matched what it was handed.
        var typedSinceTaken: [[ApiPart]] = []
        /// Whether the caret has ever been here: where `+ hole` lands (`apiEditorHoleOffset`).
        var hadCaret = false

        init(_ parent: ApiFieldEditor) { self.parent = parent }

        /// Every change the text system is about to make, asked of `apiEditorVerdict` first.
        func textView(
            _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
        ) -> Bool {
            guard let view = textView as? ApiFieldTextView, !view.bypassVerdict,
                  let replacementString
            else { return true }
            switch apiEditorVerdict(
                view.editorText, replacing: range.location..<NSMaxRange(range),
                with: replacementString, key: view.pendingKey, isRepeat: view.pendingKeyRepeats,
                composing: view.hasMarkedText(), draggingOut: view.draggingOut,
                singleLine: parent.singleLine)
            {
            case .allow:
                return true
            case .ignore:
                return false
            case .refuse(let line):
                parent.actions.refused(line)
                return false
            case .unbind(let ordinal, let name):
                parent.actions.unbind(ordinal, name)
                return false
            case .substitute(let text):
                DispatchQueue.main.async { view.insertText(text, replacementRange: range) }
                return false
            }
        }

        /// Every change, reported as the field's parts. **Not while text is marked** (Review
        /// Focus 1): half a composition is no part list. The commit reports it.
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ApiFieldTextView, !view.settingOutside,
                  !view.hasMarkedText()
            else { return }
            view.refreshTokens(editable: parent.editable)
            let parts = view.editorText.parts
            typedSinceTaken.append(parts)
            parent.actions.refused(nil)
            parent.actions.typed(parts)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.singleLine {
                    parent.actions.commit()
                    return true
                }
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                    parent.actions.commit()
                    return true
                }
                return false
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // Option-Return: a single-line field takes no break at all.
                return parent.singleLine
            case #selector(NSResponder.insertTab(_:)):
                if parent.singleLine {
                    textView.window?.selectNextKeyView(nil)
                } else {
                    textView.insertText("  ", replacementRange: textView.selectedRange())
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                guard let discard = parent.actions.discard else { return false }
                discard()
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// What the pane hands an editor, and what the editor calls back. No ruling in any of them.
struct ApiEditorActions {
    /// Every change the operator made, as the field's parts: the pause starts (9a).
    var typed: ([ApiPart]) -> Void
    /// A token's `×` on a hole, a move, or `+ hole`: the field writes at once (9a).
    var gesture: () -> Void
    /// Return in a single-line field (write now); ⌘Return in the body (Send).
    var commit: () -> Void
    var discard: (() -> Void)?
    /// Decision 27 by focus: the cursor arrived (`true`) or left (`false`).
    var focusChanged: (Bool) -> Void
    /// Backspace, Delete or `×` on a bound value: `api_unbind`, by its place among the tokens.
    var unbind: (_ ordinal: Int, _ name: String) -> Void
    /// The field's line (`apiBoundSelectionLine`), or `nil` to clear it.
    var refused: (String?) -> Void
}

/// The pane's way to reach one field's text view: `+ hole` inserts at its caret, and a row
/// `+ query` / `+ header` adds hands it the cursor.
@MainActor final class ApiEditorHandle {
    weak var textView: ApiFieldTextView?
    var isPathView = false

    /// `+ hole` (10b): at the caret, or at the end of a field the caret has not been in
    /// (`apiEditorHoleOffset`). The insertion is the text system's, so ⌘Z takes it back. Then the
    /// cursor returns to the field, just after the hole, so typing carries on.
    func insertHole(_ name: String) -> Bool {
        guard let textView, let coordinator = textView.coordinator else { return false }
        let selected = textView.selectedRange()
        let offset = apiEditorHoleOffset(
            textView.editorText,
            selection: coordinator.hadCaret ? selected.location..<NSMaxRange(selected) : nil,
            isPathView: isPathView)
        guard textView.insertHole(name, at: offset) else { return false }
        textView.window?.makeFirstResponder(textView)
        return true
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

/// One handle per field, kept for the pane's life.
@MainActor final class ApiEditorRegistry {
    private var handles: [ApiFieldRow: ApiEditorHandle] = [:]

    func handle(_ box: ApiFieldRow) -> ApiEditorHandle {
        if let handle = handles[box] { return handle }
        let handle = ApiEditorHandle()
        handles[box] = handle
        return handle
    }
}

extension NSPasteboard.PasteboardType {
    static let apiEditor = NSPasteboard.PasteboardType(apiEditorPasteboardType)
}

/// The editor's attributed text for `text`: characters in the field's font and ink, and each
/// token an `ApiTokenAttachment`.
@MainActor func apiEditorAttributed(_ text: ApiEditorText, editor: ApiFieldTextView?) -> NSAttributedString {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: ApiFieldEditor.font, .foregroundColor: ApiFieldEditor.ink,
    ]
    let out = NSMutableAttributedString()
    for run in text.runs {
        switch run {
        case .text(let string):
            out.append(NSAttributedString(string: string, attributes: attributes))
        case .token(let token):
            let attachment = ApiTokenAttachment(token: token)
            attachment.editor = editor
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
            out.append(piece)
        }
    }
    return out
}

/// The editor's text read back: a U+FFFC carrying an `ApiTokenAttachment` is a token, and every
/// other unit is a character, including a U+FFFC with no attachment of ours.
func apiEditorText(of storage: NSAttributedString) -> ApiEditorText {
    let string = storage.string as NSString
    var units: [ApiEditorUnit] = []
    units.reserveCapacity(string.length)
    for index in 0..<string.length {
        if let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil)
            as? ApiTokenAttachment
        {
            units.append(.token(attachment.token))
        } else {
            units.append(.code(string.character(at: index)))
        }
    }
    return ApiEditorText(units: units)
}

/// The text view an editor draws.
final class ApiFieldTextView: NSTextView {
    weak var coordinator: ApiFieldEditor.Coordinator?
    var key = ""
    /// Taking outside text: neither asked of the verdict nor reported as typing.
    private(set) var settingOutside = false
    /// One of this view's own gestures (a hole inserted, a move): reported, not asked.
    private(set) var bypassVerdict = false
    /// The key being handled, so the verdict can tell a key from a selection delete.
    private(set) var pendingKey: ApiEditorKey?
    private(set) var pendingKeyRepeats = false
    /// Set from a drag out of this view until the next mouse or key event here (ambiguity 6):
    /// the only change a source sees in that window is the drag-out's own delete.
    private(set) var draggingOut = false
    private var focusedThrough: ((Bool) -> Void)?

    var editorText: ApiEditorText { apiEditorText(of: textStorage ?? NSTextStorage()) }

    /// Outside parts (a landing, Format, Escape, an agent): replaced whole, not undoable.
    func takeOutside(_ text: ApiEditorText) {
        settingOutside = true
        defer { settingOutside = false }
        textStorage?.setAttributedString(apiEditorAttributed(text, editor: self))
    }

    /// One of this view's own edits, undoable, reported.
    private func applyOwn(_ attributed: NSAttributedString, in range: NSRange) -> Bool {
        bypassVerdict = true
        defer { bypassVerdict = false }
        guard shouldChangeText(in: range, replacementString: attributed.string) else { return false }
        textStorage?.replaceCharacters(in: range, with: attributed)
        didChangeText()
        return true
    }

    func insertHole(_ name: String, at offset: Int) -> Bool {
        let attributed = apiEditorAttributed(ApiEditorText(parts: [.slot(name)]), editor: self)
        guard applyOwn(attributed, in: NSRange(location: offset, length: 0)) else { return false }
        setSelectedRange(NSRange(location: offset + 1, length: 0))
        coordinator?.parent.actions.gesture()
        return true
    }

    /// Re-numbers every token (its `<i>` among the parts) and sets each token view's
    /// identifiers, only where they changed.
    func refreshTokens(editable: Bool) {
        guard let storage = textStorage else { return }
        let text = editorText
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let attachment = value as? ApiTokenAttachment,
                  let index = text.partIndex(ofTokenAt: range.location)
            else { return }
            attachment.editor = self
            attachment.apply(key: key, index: index, editable: editable)
        }
    }

    func range(of attachment: ApiTokenAttachment) -> NSRange? {
        guard let storage = textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if (value as AnyObject) === attachment {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// A press on the token (its AX press, or a click): the cursor here, the token selected.
    func selectToken(_ attachment: ApiTokenAttachment) -> Bool {
        guard let range = range(of: attachment) else { return false }
        window?.makeFirstResponder(self)
        setSelectedRange(range)
        return true
    }

    /// The token's `×` (spec §3): a hole is removed as one character, through the verdict, so
    /// ⌘Z brings it back. A bound value is unbound.
    func tokenAct(_ attachment: ApiTokenAttachment) {
        guard let range = range(of: attachment) else { return }
        switch attachment.token {
        case .hole:
            guard shouldChangeText(in: range, replacementString: "") else { return }
            textStorage?.deleteCharacters(in: range)
            didChangeText()
            coordinator?.parent.actions.gesture()
        case .bound(let value):
            coordinator?.parent.actions.unbind(editorText.ordinal(ofTokenAt: range.location) ?? 0, value.name)
        }
    }

    // MARK: Focus (Decision 27 by focus), deferred a turn as `BodyNSTextView` did (F5).

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took {
            coordinator?.hadCaret = true
            draggingOut = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let changed = self.coordinator?.parent.actions.focusChanged else { return }
                self.focusedThrough = changed
                changed(true)
            }
        }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let changed = self.focusedThrough ?? self.coordinator?.parent.actions.focusChanged
                self.focusedThrough = nil
                changed?(false)
            }
        }
        return resigned
    }

    // MARK: Keys

    override func deleteBackward(_ sender: Any?) { keyed(.backspace) { super.deleteBackward(sender) } }
    override func deleteForward(_ sender: Any?) { keyed(.delete) { super.deleteForward(sender) } }

    private func keyed(_ key: ApiEditorKey, _ body: () -> Void) {
        pendingKey = key
        // `isARepeat` raises on anything but a key event (a menu's Delete, say).
        pendingKeyRepeats = NSApp.currentEvent.map { $0.type == .keyDown && $0.isARepeat } ?? false
        defer {
            pendingKey = nil
            pendingKeyRepeats = false
        }
        body()
    }

    override func keyDown(with event: NSEvent) {
        draggingOut = false
        if Self.isCommandReturn(event), coordinator?.parent.singleLine == false {
            coordinator?.parent.actions.commit()
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘Return before the menu's Maximize Pane takes it, in the body (9a).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, Self.isCommandReturn(event),
           coordinator?.parent.singleLine == false
        {
            coordinator?.parent.actions.commit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isCommandReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76)
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    // MARK: Copy, cut, paste (10b)

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.apiEditor, .string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.apiEditor, .string] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.apiEditor, .string] }

    /// A copy, a cut or a drag carries text and holes, and a bound value as its hole.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        let clip = ApiEditorClip(editorText, range: range.location..<NSMaxRange(range))
        guard let data = try? JSONEncoder().encode(clip) else { return false }
        pboard.declareTypes([.apiEditor, .string], owner: nil)
        return pboard.setData(data, forType: .apiEditor) && pboard.setString(clip.plain, forType: .string)
    }

    /// A paste or a drop: Wakil's clip as tokens, outside text as literal text.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let clip = pboard.data(forType: .apiEditor).flatMap {
            try? JSONDecoder().decode(ApiEditorClip.self, from: $0)
        }
        guard let pasted = apiEditorPasted(
            clip: clip, plain: pboard.string(forType: .string),
            singleLine: coordinator?.parent.singleLine ?? true)
        else { return false }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound else { return false }
        let attributed = apiEditorAttributed(pasted, editor: self)
        // Through the verdict: pasting over a selection that holds a bound value is refused.
        guard shouldChangeText(in: range, replacementString: attributed.string) else { return false }
        textStorage?.replaceCharacters(in: range, with: attributed)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
        return true
    }

    /// W16: a cut is a delete, refused as one when it holds a bound value.
    override func cut(_ sender: Any?) {
        let range = selectedRange()
        if case .refuse(let line) = apiEditorVerdict(
            editorText, replacing: range.location..<NSMaxRange(range), with: "",
            singleLine: coordinator?.parent.singleLine ?? true)
        {
            coordinator?.parent.actions.refused(line)
            return
        }
        super.cut(sender)
    }

    // MARK: Drag (10b)

    override func mouseDown(with event: NSEvent) {
        draggingOut = false
        super.mouseDown(with: event)
    }

    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        draggingOut = true
        return super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }

    /// A drag inside this editor is a COPY to AppKit, so its own source never deletes. The move
    /// is ours (`performDragOperation`), carrying a bound value as itself.
    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        movesWithin(dragInfo) ? .copy : super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard movesWithin(sender) else { return super.performDragOperation(sender) }
        let to = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let range = selectedRange()
        guard let moved = apiEditorMoving(
            editorText, range: range.location..<NSMaxRange(range), to: to)
        else { return false }
        let all = NSRange(location: 0, length: textStorage?.length ?? 0)
        guard applyOwn(apiEditorAttributed(moved.text, editor: self), in: all) else { return false }
        setSelectedRange(NSRange(location: moved.selection.lowerBound, length: moved.selection.count))
        draggingOut = false
        coordinator?.parent.actions.gesture()
        return true
    }

    private func movesWithin(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as AnyObject?) === self
            && info.draggingPasteboard.types?.contains(.apiEditor) == true
    }
}
```

- [ ] **Step 2: Write `ApiTokenView.swift`**

```swift
import AppKit
import WakilKit

/// Amendment 10a — **a token is one attachment character, and its chip is a real view.** Amber
/// on an amber tint for a hole. Ink on a cool-white tint for a bound value. Its `×` is a real
/// `NSButton` inside the chip at its right edge (9c W4), carrying the shipped identifiers
/// `api.<key>.part.<i>.remove` / `….unbind`. The chip itself is an AX button,
/// `api.<key>.part.<i>.token`, whose press selects it. That is how a check picks a token up.
final class ApiTokenAttachment: NSTextAttachment {
    let token: ApiEditorToken
    weak var editor: ApiFieldTextView?
    weak var tokenView: ApiTokenView?
    private(set) var key = ""
    private(set) var index = 0
    private(set) var editable = true

    init(token: ApiEditorToken) {
        self.token = token
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        bounds = ApiTokenView.frame(for: token)
    }

    required init?(coder: NSCoder) { nil }

    func apply(key: String, index: Int, editable: Bool) {
        self.key = key
        self.index = index
        self.editable = editable
        tokenView?.apply()
    }

    override func viewProvider(
        for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = ApiTokenProvider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class ApiTokenProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? ApiTokenAttachment else {
            super.loadView()
            return
        }
        let view = ApiTokenView(attachment: attachment)
        attachment.tokenView = view
        self.view = view
    }
}

final class ApiTokenView: NSView {
    static let amber = NSColor(red: 0.910, green: 0.706, blue: 0.353, alpha: 1)
    static let coolWhite = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 1)
    static let closeWidth: CGFloat = 12

    /// The chip's size: its name, 6 leading, 4 between, the `×`, 4 trailing. Its baseline sits
    /// on the line's.
    static func frame(for token: ApiEditorToken) -> CGRect {
        let font = ApiFieldEditor.font
        let name = ceil((token.name as NSString).size(withAttributes: [.font: font]).width)
        let height = ceil(font.ascender - font.descender) + 2
        return CGRect(x: 0, y: font.descender - 1, width: 6 + name + 4 + closeWidth + 4, height: height)
    }

    private let attachment: ApiTokenAttachment
    private let label: NSTextField
    private let close: NSButton

    init(attachment: ApiTokenAttachment) {
        self.attachment = attachment
        let tone = attachment.token.isBound ? Self.coolWhite.withAlphaComponent(0.85) : Self.amber
        label = NSTextField(labelWithString: attachment.token.name)
        label.font = ApiFieldEditor.font
        label.textColor = tone
        close = NSButton(title: "×", target: nil, action: nil)
        close.isBordered = false
        close.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        close.contentTintColor = tone.withAlphaComponent(0.55)
        super.init(frame: Self.frame(for: attachment.token))
        close.target = self
        close.action = #selector(closePressed)
        label.frame = CGRect(x: 6, y: 1, width: bounds.width - 6 - 4 - Self.closeWidth - 4, height: bounds.height - 2)
        close.frame = CGRect(x: bounds.width - 4 - Self.closeWidth, y: 1, width: Self.closeWidth, height: bounds.height - 2)
        addSubview(label)
        addSubview(close)
        apply()
    }

    required init?(coder: NSCoder) { nil }

    /// Identifiers set only when they change (Ruling 15). A hole's `×` is not drawn on the
    /// `&`-locked path (8d). A bound value's always is (spec §3).
    func apply() {
        let key = attachment.key
        let index = attachment.index
        let closeId = attachment.token.isBound
            ? "api.\(key).part.\(index).unbind" : "api.\(key).part.\(index).remove"
        if close.accessibilityIdentifier() != closeId { close.setAccessibilityIdentifier(closeId) }
        let tokenId = "api.\(key).part.\(index).token"
        if accessibilityIdentifier() != tokenId { setAccessibilityIdentifier(tokenId) }
        let hidden = !attachment.editable && !attachment.token.isBound
        if close.isHidden != hidden { close.isHidden = hidden }
    }

    @objc private func closePressed() { attachment.editor?.tokenAct(attachment) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { attachment.token.name }
    override func accessibilityPerformPress() -> Bool { attachment.editor?.selectToken(attachment) ?? false }

    override func mouseDown(with event: NSEvent) { _ = attachment.editor?.selectToken(attachment) }

    override func mouseDragged(with event: NSEvent) {
        _ = attachment.editor?.dragSelection(with: event, offset: .zero, slideBack: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = attachment.token.isBound
            ? Self.coolWhite.withAlphaComponent(0.10) : Self.amber.withAlphaComponent(0.10)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}
```

- [ ] **Step 3: Put the body on the held model in the pane**

In `ApiPane.swift`, add the state beside `boxes`:

```swift
    /// Amendment 10a: each editor field's parts that the draft may not hold yet, one entry per
    /// field. **Transitional (Task 5 → Task 6): only the body.** The other fields are still in
    /// `boxes`.
    @State var held: ApiHeld = [:]
    /// `queued` for `held` (F23).
    @State var heldQueued: ApiHeld = [:]
    /// `takenOver` for `held`: Format's hold on the body.
    @State var heldTakenOver: [ApiFieldRow: ApiHeldTakeover] = [:]
    /// One handle per editor field: `+ hole` reaches the field's text view through it.
    @State var editors = ApiEditorRegistry()
    /// Each editor field's line (`apiBoundSelectionLine`), cleared by its next change.
    @State var editorRefusals: [ApiFieldRow: String] = [:]
```

Give `ApiPaneBatch` a `heldWritten: ApiHeld = [:]` field. Give `ApiPaneWritten` a
`held: ApiHeld = [:]`. Change `operateInOrder` to take
`carryingHeld heldCarried: [ApiFieldRow: ApiHeldTakeover] = [:]` and to settle both models:

```swift
        dispatchInOrder({ now in
            let batch = build(now)
            if !batch.calls.isEmpty {
                bindGeneration = max(bindGeneration, number)
                bindLine = nil
            }
            written.boxes = batch.written
            written.held = batch.heldWritten
            queued.merge(batch.written) { _, dispatched in dispatched }
            heldQueued.merge(batch.heldWritten) { _, dispatched in dispatched }
            return batch.calls
        }, { landed in
            queued = apiQueuedSettled(queued, written: written.boxes)
            heldQueued = apiQueuedSettled(heldQueued, written: written.held)
            var owed = false
            if !carried.isEmpty {
                let settled = apiGestureSettled(
                    takenOver: takenOver, boxes: boxes, carried: carried, landed: landed)
                takenOver = settled.takenOver
                boxes = settled.boxes
                owed = owed || settled.owed
            }
            if !heldCarried.isEmpty {
                let settled = apiGestureSettled(
                    takenOver: heldTakenOver, held: held, carried: heldCarried, landed: landed)
                heldTakenOver = settled.takenOver
                held = settled.held
                owed = owed || settled.owed
            }
            if owed { keystroke() }
        })
```

`applied` becomes `apiRequestApplying(apiRequestApplying(snapshot.request, boxes: boxes), held: held)`.

In `operateFlushed`, add `takingOverHeld heldBox: ApiFieldRow? = nil`. It takes `held[heldBox]`
over under a fresh token, the same way `box` is taken. Then build:

```swift
        operateInOrder(carrying: carried, carryingHeld: heldCarried) { now in
            let flush = apiFlush(
                now.request, boxes: boxes, pane: pane.id, queued: queued, takenOver: takenOver)
            // The body last: it is last in wire order, and independent of the boxes' writes.
            let fields = apiFlush(
                now.request, held: held, pane: pane.id, queued: heldQueued, takenOver: heldTakenOver)
            pathRefusal = flush.refusals[ApiFieldRow(.path)]
            return ApiPaneBatch(
                calls: flush.writes + fields.writes + calls, written: flush.written,
                heldWritten: fields.written)
        }
```

`flushNow()` does the same, built now. In `.onChange(of: snapshot.request)`, add
`held = apiHeldAfterLanding(now, held: held, focused: focusedIn?.box, takenOver: heldTakenOver, queued: heldQueued)`.
In `.onChange(of: held)`, add `heldTakenOver = apiTakenOverSettled(heldTakenOver, held: $1)`.
The same two calls go into `focusArrived`'s `left != nil` branch and into `focusLost`, beside
their `apiBoxesAfterLanding` calls.

In `ApiPane+Sending.swift`, `send()` becomes:

```swift
        operateInOrder { now in
            // Transitional (Task 5 → Task 6): the body's write ahead of the boxes' and the send.
            let fields = apiFlush(
                now.request, held: held, pane: pane.id, queued: heldQueued, takenOver: heldTakenOver)
            let plan = apiSendPlan(
                draft: apiRequestApplying(now.request, held: held), pane: pane.id, boxes: boxes,
                queued: queued,
                unpointed: apiPaneIsUnpointed(entry: now.entry, entries: now.entries),
                takenOver: takenOver)
            pathRefusal = plan.refusals[ApiFieldRow(.path)]
            sendRefusal = plan.refusal
            let refused = !plan.refusals.isEmpty || !fields.refusals.isEmpty
            return ApiPaneBatch(
                calls: refused ? [] : fields.writes + plan.calls, written: plan.written,
                heldWritten: refused ? [:] : fields.written)
        }
```

Reopen's reset (`boxes = [:]`) also clears `held = [:]`.

- [ ] **Step 4: Draw the body with the editor**

In `ApiPane+Fields.swift`, add the editor view and its gestures, and delete `editorBox` together
with the `multiline` branch of `field(…)`:

```swift
    /// One editor field (10a): its held parts, or the view's, in ONE text view.
    func fieldEditor(_ draftField: ApiDraftField, row: Int = 0, label: String) -> some View {
        let box = ApiFieldRow(draftField, row: row)
        let key = apiFieldKey(draftField, row: row)
        let identifier = "api.\(key)"
        let view = apiHeldView(snapshot.request, box)
        let parts = held[box] ?? view
        return ApiFieldEditor(
            identifier: identifier, key: key, parts: parts,
            singleLine: draftField != .body,
            editable: apiFieldViewIsTypable(snapshot.request, draftField),
            isPathView: draftField == .path,
            handle: editors.handle(box),
            actions: ApiEditorActions(
                typed: { parts in
                    // Round 6: a report of what it already shows types nothing.
                    guard let next = apiHeldTyping(held, box: box, parts: parts, rendered: view)
                    else { return }
                    held = next
                    keystroke()
                },
                gesture: { flush() },
                commit: draftField == .body ? { press(fromKeyboard: true) } : { flush() },
                discard: { restore(box) },
                focusChanged: { focusChanged(box, identifier, $0) },
                unbind: { ordinal, name in unbind(box, ordinal: ordinal, name: name) },
                refused: { line in
                    if editorRefusals[box] != line { editorRefusals[box] = line }
                }))
            // No `TextField` placeholder to borrow: the label, quiet, while the field is empty.
            .overlay(alignment: .topLeading) {
                if parts.isEmpty {
                    Text(label).foregroundStyle(ink.opacity(0.3)).allowsHitTesting(false)
                }
            }
    }

    /// Backspace, Delete or `×` on a bound value (W4, W16): **built on the chain** (P10), behind
    /// the flush, against the draft it left. Nothing is sent if that token is no longer that
    /// binding (`apiChipUnbindParams`).
    func unbind(_ box: ApiFieldRow, ordinal: Int, name: String) {
        operateFlushed([])
        operateInOrder { now in
            let params = apiChipUnbindParams(
                now.request, field: box.field, row: box.row, ordinal: ordinal, name: name,
                pane: pane.id)
            return ApiPaneBatch(calls: params.map { [("api_unbind", $0)] } ?? [])
        }
    }
```

`holeWrite(_:_:)` sends the body to its editor:

```swift
    func holeWrite(_ box: ApiFieldRow, _ name: String) -> String? {
        if let refusal = apiHoleNameRefused(name) { return refusal }
        if box.field == .body {
            // 10b: at the caret, as text the editor owns. Its change reports the parts, and
            // `insertHole` calls `gesture`, which flushes at once.
            return editors.handle(box).insertHole(name) ? nil : apiHoleNameRefusal
        }
        // Not yet an editor (Task 6): the index-keyed append, unchanged.
        guard let params = apiPartsWrite(
            draft: apiRequestApplying(snapshot.request, boxes: boxes, except: box),
            field: box.field, edit: .appendHole(name), pane: pane.id, row: box.row,
            typed: boxes[box] ?? [:])
        else { return apiHoleNameRefusal }
        operateFlushed([("api_set_request", params)], takingOver: box)
        return nil
    }
```

`restore(_:)` also sets `held[box] = nil` and `editorRefusals[box] = nil`. `fieldNotes(_:row:)`
also draws `editorRefusals[box]` in amber (`.wraps()`), with no identifier, under the field.

In `ApiPane+Request.swift`, `bodyRegion` replaces `fieldFlow(.body, label: "body", multiline: true)`
with `fieldEditor(.body, label: "body")`, keeping every modifier after it. `formatControl` reads
the held body:

```swift
    var formatControl: some View {
        let body = ApiFieldRow(.body)
        let holding = held[body] ?? snapshot.request.body
        let enabled = apiFormatIsEnabled(draft: snapshot.request, holding: holding)
        return Button("FORMAT") {
            guard let params = apiFormatBodyWrite(draft: snapshot.request, pane: pane.id, holding: holding)
            else {
                formatRefusedBody = applied.body
                return
            }
            if apiFormatIsNoOp(draft: snapshot.request, holding: holding) {
                held[body] = nil
                return
            }
            operateFlushed([("api_set_request", params)], takingOverHeld: body)
        }
        .buttonStyle(.plain)
        .modifier(Verb(heading: true, enabled: enabled))
        .accessibilityIdentifier("api.body.format")
        .disabled(!enabled)
    }
```

Remove the body's uses of `bodyCaret`, `bodyFocusOwed`, `bodyFocusOffset`,
`apiBodyHoleEdit` and `apiCaretAfterHole`. Task 7 deletes their declarations.

- [ ] **Step 5: Build, test, harvest**

Run: `make app-test && make app-bundle && make controls`
Expected: tests green and the bundle builds. In `make controls`, the family
`api.<…>.part.<…>.token` appears, and `.remove`/`.unbind` are still harvested.

- [ ] **Step 6: Commit**

```bash
git add -A app/Sources/WakilApp/
git commit -m "2c-iv Amendment 10: the body is one editor; ApiFieldEditor and ApiTokenView

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The path view, query values and header values become editors

**Files:**
- Modify: `app/Sources/WakilApp/ApiPane.swift`, `ApiPane+Fields.swift`, `ApiPane+Request.swift`,
  `ApiPane+Sending.swift`, `ApiPaneFlow.swift`

**Interfaces:**
- Consumes: Task 5's `fieldEditor(_:row:label:)`, `ApiEditorRegistry`, `unbind(_:ordinal:name:)`,
  and Task 4's held API including `apiSendPlan(draft:pane:held:…)` and
  `apiBoxesRemovingRow(_: ApiHeld, …)`.
- Produces: one model. `@State var held: ApiHeld`, `@State var queued: ApiHeld`, and
  `@State var takenOver: [ApiFieldRow: ApiHeldTakeover]`. `ApiPaneBatch { calls; written: ApiHeld }`.
  The content type is the held field `ApiFieldRow(.contentType)`, which holds
  `[.literal(text)]`.

- [ ] **Step 1: Draw the three fields with the editor**

- `urlBox`: the origin and the editor flow together. The flow stays for this one use, and
  wrapping inside the path is the text view's:

```swift
            HStack(alignment: .top, spacing: 8) {
                ApiFlow {
                    switch apiOriginLine(snapshot) {
                    case .origin(let origin): Text(origin).foregroundStyle(ink.opacity(0.45))
                    case .caution(let line): Text(line).foregroundStyle(amber)
                    }
                    fieldEditor(.path, label: "path").layoutValue(key: ApiFlowGrows.self, value: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                fieldHole(.path)
            }
```

- `queryRegion` and `headerValue`: `fieldFlow(field, row: occurrence, label: "value")` becomes
  `fieldEditor(field, row: occurrence, label: "value")`.
- `fieldHole`'s submit becomes `{ name in holeWrite(field.box, name) }` for every field.
  `holeWrite` loses its index-keyed branch, so every field goes to its editor
  (`editors.handle(box).insertHole(name)`).
- The content type stays a `TextField` (10a). Its binding becomes:

```swift
                text: Binding(
                    get: { held[box].map(apiPlainLiteral) ?? contentType },
                    set: { text in
                        let parts: [ApiPart] = text.isEmpty ? [] : [.literal(apiSingleLineText(text))]
                        guard let next = apiHeldTyping(held, box: box, parts: parts, rendered: apiHeldView(snapshot.request, box))
                        else { return }
                        held = next
                        keystroke()
                    }),
```

Add to WakilKit, in `ApiEditorText.swift`, with a test in `ApiEditorTextTests.swift` that fails
first (`apiPlainLiteral([.literal("a"), .slot("x"), .literal("b")]) == "ab"`):

```swift
/// The text of a part list's literals, joined: the content type's box, which holds no token.
public func apiPlainLiteral(_ parts: [ApiPart]) -> String {
    parts.compactMap { part -> String? in
        if case .literal(let text) = part { return text }
        return nil
    }.joined()
}
```

The content type's `TextField` is drawn inline in `headerValue`, with the same modifiers
`lineBox` gave it. `lineBox`, `field(…)` and `literalBox` are deleted in this task, because
nothing else calls them.

- [ ] **Step 2: One model**

Delete `boxes`, the index-keyed `queued` and `takenOver`, `ApiPaneBatch.written`'s old type and
`ApiPaneWritten.boxes`. Rename `heldQueued` to `queued` and `heldTakenOver` to `takenOver`. Each
`apiFlush(…boxes:…)` call becomes the `held:` one, and `apiSendPlan(…boxes:…)` becomes
`apiSendPlan(draft: now.request, pane: pane.id, held: held, queued: queued, unpointed: …, takenOver: takenOver)`.
`apiBoxesAfterLanding` becomes `apiHeldAfterLanding`, `apiBoxesRemovingRow(boxes, …)` becomes
`apiBoxesRemovingRow(held, …)`, and `applied` becomes `apiRequestApplying(snapshot.request, held: held)`.
`pathWrite` is deleted: every path gesture is now an edit in the path's editor, then `flush()`.
`chipGesture`, `oweChipFocus` and `takeChipFocus` are deleted, along with the state they used:
`chipFocus`, `lineCaretOwed`, `bodyFocusOwed`, `bodyFocusOffset`, `bodyCaret`, `ApiChipFocus` and
`ApiOwedCaret`. The `.onChange(of: snapshot.request)` branch that read `chipFocus` goes too.
`pathRefusal` is set from `flush.refusals[ApiFieldRow(.path)]` as before. `FieldView` loses
`items` and `parts` (both from `apiFieldItems`), and `fieldFlow` is deleted. `fieldHole` and
`fieldNotes` keep `FieldView` for its `key`, `box`, `isPathView` and `typable`.

- [ ] **Step 3: A row's value takes the cursor after `+ query` / `+ header` (W5)**

`takeOwedFocus(_:stillOpen:)` handles a name box through `focusedBox`, as before. For a value
identifier (`api.query.<name>` / `api.header.<name>`), the editor is not a `@FocusState`. So the
row's `fieldEditor` gets `.onAppear { takeOwedEditorFocus(box, identifier) }`:

```swift
    /// W5 for an editor: the row `+ query` / `+ header` just added takes the cursor once drawn,
    /// a turn later, and only while nothing else took it (`takeOwedFocus`'s guard).
    func takeOwedEditorFocus(_ box: ApiFieldRow, _ identifier: String) {
        guard pendingFocus == identifier else { return }
        pendingFocus = nil
        let was = focusedBox
        DispatchQueue.main.async {
            guard focusedBox == was || focusedBox == nil else { return }
            editors.handle(box).focus()
        }
    }
```

- [ ] **Step 4: Trim `ApiPaneFlow.swift`**

`ApiFlow` and `ApiFlowGrows` stay, for the URL line's origin plus editor and for the read-only
`parts(_:)` (Wakil's rows, the Bound list). Update the doc comments: the typing box is gone, and
the one grower is the path editor.

- [ ] **Step 5: Build, test, harvest, and confirm the retirement**

Run: `make app-test && make app-bundle && make controls`
Expected: green. In `make controls`, the literal-box family `api.<…>.part.<…>` (no suffix) is
gone, retired as 10c says. `.remove`, `.unbind` and `.token` are present. `grep -rn
'part\.\\\\(' app/Sources/WakilApp` finds only the three suffixed spellings in `ApiTokenView.swift`.

- [ ] **Step 6: Commit**

```bash
git add -A app/Sources/WakilApp/ app/Sources/WakilKit/Api/ApiEditorText.swift app/Tests/WakilKitTests/ApiEditorTextTests.swift
git commit -m "2c-iv Amendment 10: path, query and header values are editors; one held model per field

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Delete what the editor replaced

**Files:**
- Delete: `app/Sources/WakilApp/ApiChipKeyCatcher.swift`, `app/Sources/WakilKit/Api/ApiFieldItems.swift`,
  `app/Sources/WakilKit/Api/ApiBodyCaret.swift`, `app/Tests/WakilKitTests/ApiChipKeysTests.swift`,
  `app/Tests/WakilKitTests/ApiFieldItemsTests.swift`, `app/Tests/WakilKitTests/ApiBodyHoleTests.swift`
- Modify: `app/Sources/WakilKit/Api/ApiChipKeys.swift`, `ApiSaveAsTyped.swift`, `ApiActions.swift`,
  `ApiPathQuery.swift`, `ApiBodyFormat.swift`, `ApiRows.swift`, `ApiEditorText.swift`
- Modify (port): `ApiSaveAsTypedTests.swift`, `ApiTakenOverTests.swift`, `ApiHandBindTests.swift`,
  `ApiEnvironmentTests.swift`, `ApiBodyFormatTests.swift`, `ApiRowsTests.swift`,
  `ApiPathQueryTests.swift`, `WindowModelTests.swift` (`PaneHeld`, around `:6517–6631`)
- Create: `app/Tests/WakilKitTests/ApiChipUnbindTests.swift` (the four unbind tests kept from
  `ApiChipKeysTests.swift`)

**Interfaces:**
- Consumes: everything from Tasks 2–6.
- Produces: no new names. `apiFieldViewParts` and `apiFieldViewIsTypable` move into
  `ApiEditorText.swift` unchanged, and `ApiChipKeys.swift` keeps `ApiChipAct`, `apiChipAct` and
  `apiChipUnbindParams` only.

- [ ] **Step 1: Move the survivors, then delete**

Move `apiFieldViewParts(_:_:row:)` and `apiFieldViewIsTypable(_:_:)` verbatim into
`ApiEditorText.swift`. In `ApiChipKeys.swift`, delete everything except `ApiChipAct`,
`apiChipAct(_:)` and `apiChipUnbindParams(…)`. That removes `ApiChipKey`, `ApiChipTarget`,
`apiChipBeside`, `apiChipKeyApplies`, `apiChipKeyIsThisBox`, `apiChipOrdinal`, `apiChipCount`,
`apiChipRemoveLanded`, `apiRemovingPart`, `apiChipRemoveCaret`, `ApiChipRemoveTarget` and
`apiChipRemoveTarget`. Update the file's header comment to say the keys are now the editor's
verdict (`apiEditorVerdict`).

Delete the index-keyed save-as-typed: `apiPendingWrite(_:box:typed:pane:)`,
`apiRequestApplying(_:boxes:except:)`, `ApiFlush`, `apiFlush(_:boxes:…)`,
`apiQueuedSettled([ApiFieldRow: [Int: String]]…)`, `apiBoxesAfterLanding`,
`apiBoxesInWireOrder`, `apiTakenOverSettled(_:boxes:)`, `ApiTakeover`,
`apiGestureSettled(takenOver:boxes:…)` and `apiBoxesTyping`.

In `ApiActions.swift`, delete `ApiPartsEdit`, `apiPartsWrite`, `apiTyped`, `apiTypedParts`,
`apiTypingBoxIndex`, `apiTypingBoxIdentifier`, `ApiSendPlan` and `apiSendPlan(…boxes:…)`.
`apiDroppingEmptyLiterals`, `apiPartsRegionWrite`, `apiFieldParts`, `apiFieldRows` and
`ApiFieldRow` stay.

In `ApiPathQuery.swift`, delete `apiPathBoxWrite(_:edit:typed:pane:)`.
In `ApiBodyFormat.swift`, delete the `typed:` overloads. In `ApiRows.swift`, delete the
index-keyed `apiBoxesRemovingRow`.

```bash
git rm app/Sources/WakilApp/ApiChipKeyCatcher.swift app/Sources/WakilKit/Api/ApiFieldItems.swift \
  app/Sources/WakilKit/Api/ApiBodyCaret.swift app/Tests/WakilKitTests/ApiChipKeysTests.swift \
  app/Tests/WakilKitTests/ApiFieldItemsTests.swift app/Tests/WakilKitTests/ApiBodyHoleTests.swift
```

- [ ] **Step 2: Port the tests, keeping every ruling that still exists**

- Retype mechanically: `boxes: [K: [0: "x"]]` becomes `held: [K: [.literal("x")]]`, and
  `typed:` becomes `holding:`. `apiPartsWrite(draft:field:edit: .text(index: i, s), …)` becomes
  `apiHeldWrite(draft:field:parts:…)` with the whole part list. `ApiTakeover(typed:token:)`
  becomes `ApiHeldTakeover(held:token:)`. `PaneHeld` in `WindowModelTests.swift` holds
  `held: ApiHeld` and `takenOver: [ApiFieldRow: ApiHeldTakeover]`.
- **Delete, each with a one-line reason in the commit message:** tests whose subject no longer
  exists. These are box indices that "fit", a trailing box at `parts.count`, an index on a chip,
  `apiTypingBoxIndex`, and `apiEditorTakesText` (ported as Task 2's `apiEditorTakesParts`
  tests).
- Create `ApiChipUnbindTests.swift` from the four `apiChipUnbindParams` tests in the old
  `ApiChipKeysTests.swift`: *"Review Focus 3: an unbind after an emptied box targets the same
  chip"*, *"P10: an unbind whose chip is no longer that binding sends nothing"*, *"A chip the
  path box draws from a query value unbinds in its row"*, and *"A body chip unbinds by its
  index in the body"*. Copy each body verbatim, computing the ordinal from
  `ApiEditorText(parts:).ordinal(ofTokenAt:)` where the old test called `apiChipOrdinal`.

- [ ] **Step 3: Nothing still names the old machinery**

Run:
`grep -rnE "apiChipBeside|apiChipKeyApplies|ChipKeyCatcher|apiFieldItems|ApiFieldItem|ApiBodyCaret|apiBodyHoleEdit|apiCaretAfterHole|ApiPartsEdit|apiPartsWrite|apiTypingBox|chipFocus|lineCaretOwed|bodyFocusOwed|ApiBodyTextView|BodyNSTextView" app/`
Expected: no output.

- [ ] **Step 4: Headless gates**

Run: `make app-test && make app-bundle && make controls && go test ./e2e/...`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add -A app/
git commit -m "2c-iv Amendment 10: delete the chip key catcher, the field items, the body caret and the index-keyed boxes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The checks — retire the box identifiers, rewrite the readers, add four

**Files:**
- Modify: `e2e/checks/seeded/api-hole.jsonl`, `api-chip-keys-second-chip.jsonl`, `api-bound-locks.jsonl`
- Create: `e2e/checks/seeded/api-editor-json-holes.jsonl`, `api-editor-hole-drag.jsonl`,
  `api-editor-copy-bound.jsonl`, `api-editor-wrap.jsonl`
- Possibly modify (only if Step 5 shows they fail on the editor): `api-query-sync.jsonl`,
  `api-body-hole-cursor.jsonl`, `api-chip-keys.jsonl`, `api-chip-keys-text-after.jsonl`,
  `api-body-editor.jsonl`, `api-saved-as-typed.jsonl`, `api-rows.jsonl`, `api-surface.jsonl`,
  `api-the-rest.jsonl`

**Interfaces:**
- Consumes: the identifiers `api.path`, `api.body`, `api.query.<name>`,
  `api.<key>.part.<i>.remove|unbind|token`, `api.body.format`, `api.<key>.hole(.name)`, and the
  line `apiBoundSelectionLine`. Also Task 1's (d) and (e) results.
- Produces: the checks the runbook renders from.

**Caret rules every rewritten check relies on** (from Tasks 5–6): `focus` on an editor that
never had the cursor finds the caret **at the end**. `cmd+Up` and `cmd+Down` reach the start and
the end of the field. In a wrapped single-line field `cmd+Right` ends the *visual* line, so use
`cmd+Down` for the field's end. Before Step 5, check the key names against
`orca computer press-key --help`.

- [ ] **Step 1: Rewrite the three box readers.** Each keeps a step that fails on `ed1af70`.

`api-hole.jsonl`: replace lines 11–13 (`focus api.path.part.0`, `cmd+a`, `keys /v2/bookings/`)
with:

```json
{"do":{"focus":"api.path"}}
{"do":{"hotkey":"cmd+Up"}}
{"do":{"press":"Right"}}
{"do":{"press":"Right"}}
{"do":{"press":"Right"}}
{"do":{"press":"Backspace"}}
{"do":{"keys":"2"}}
```

The rest stays as it is. Red on `ed1af70`: `api.path` there is the `/confirm` box, so the `1`
never moves and `request.path[0].literal` is not `/v2/bookings/`.

`api-chip-keys-second-chip.jsonl`: line 3 becomes `{"do":{"focus":"api.path"}}`, followed by
six `{"do":{"press":"Left"}}` (past `/c`, the `y` token and `/b/`) in place of the three. Line
14 becomes `{"do":{"focus":"api.body"}}`, followed by five `Left`s (past `]`, `q` and `2, `).
Every expect stays. Red on `ed1af70`: from the old typing box, the sixth Left stops at its
start and Backspace removes `y`, not `x`.

`api-bound-locks.jsonl`: replace lines 17–19 (`focus api.path`, `cmd+a`, `keys /cancel`) with:

```json
{"do":{"focus":"api.path"}}
{"do":{"hotkey":"cmd+a"}}
{"do":{"keys":"x"}}
{"expect":{"tree":"contains","text":"a selection holding a bound value can't be deleted or replaced"}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"do":{"hotkey":"cmd+Down"}}
{"do":{"keys":"cancel"}}
```

Line 20's expect becomes `request.path[2].literal` equals `"/cancel"`. Red on `ed1af70`: no
such line is drawn.

- [ ] **Step 2: Write the four new checks**

`api-editor-json-holes.jsonl`: a multi-line JSON body with two holes, formatted, and the tokens
in place. The caret then crosses lines.

```json
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"post","body":[{"literal":"{\"a\": "},{"slot":"a"},{"literal":", \"b\": "},{"slot":"b"},{"literal":"}"}]}}}
{"do":{"click":"api.body.format"}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","equals":"{\n  \"a\": "}}
{"expect":{"pane":"api-1","field":"request.body[1].slot","equals":"a"}}
{"expect":{"pane":"api-1","field":"request.body[2].literal","equals":",\n  \"b\": "}}
{"expect":{"pane":"api-1","field":"request.body[3].slot","equals":"b"}}
{"expect":{"pane":"api-1","field":"request.body[4].literal","equals":"\n}"}}
{"do":{"focus":"api.body"}}
{"do":{"hotkey":"cmd+Up"}}
{"do":{"press":"Down"}}
{"do":{"keys":"x"}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","equals":"{\nx  \"a\": "}}
{"do":{"press":"Down"}}
{"do":{"hotkey":"cmd+Right"}}
{"do":{"press":"Backspace"}}
{"expect":{"pane":"api-1","field":"request.body[3]","present":false}}
{"expect":{"pane":"api-1","field":"request.body[2].literal","equals":",\n  \"b\": \n}"}}
```

Red on `ed1af70`: there `api.body` is the trailing box `\n}`, so `x` lands in it.

`api-editor-hole-drag.jsonl` (only if Task 1 (d) passed): a hole dragged between fields.

```json
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"post","path":[{"literal":"/v1/"},{"slot":"id"}]}}}
{"do":{"drag":{"from":"api.path.part.1.token","to":"api.body"}}}
{"expect":{"pane":"api-1","field":"request.body[0].slot","equals":"id"}}
{"expect":{"pane":"api-1","field":"request.path[1]","present":false}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/v1/"}}
```

`api-editor-copy-bound.jsonl`: a bound value copied into another region pastes its hole, and a
cut of it is refused.

```json
{"dispatch":{"action":"db_set_dsn","params":{"projectPath":"{fixtureRoot}/e2e-project/.wakil/project.json","environment":"staging","name":"bookings","driver":"sqlite","dsn":"{fixtureRoot}/bookings.db","grantWrite":true,"writeDsn":"{fixtureRoot}/bookings.db"}}}
{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}
{"dispatch":{"action":"db_run_query","params":{"pane":"db-1","database":"bookings","query":"SELECT * FROM bookings ORDER BY id"}}}
{"expect":{"pane":"db-1","field":"rowCount","equals":"2"}}
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"pane_move","params":{"id":"api-2","x":740,"y":60}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-2","method":"post","path":[{"literal":"/v1/bookings/"},{"slot":"id"}]}}}
{"do":{"drag":{"from":"db.row.0.grip","to":"api.pane"}}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"do":{"click":"api.path.part.1.token"}}
{"do":{"hotkey":"cmd+c"}}
{"do":{"focus":"api.body"}}
{"do":{"hotkey":"cmd+v"}}
{"expect":{"pane":"api-2","field":"request.body[0].slot","equals":"id"}}
{"expect":{"pane":"api-2","field":"request.body[0].binding","present":false}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"do":{"click":"api.path.part.1.token"}}
{"do":{"hotkey":"cmd+x"}}
{"expect":{"tree":"contains","text":"a selection holding a bound value can't be deleted or replaced"}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
```

If the operator vetoed `….token` (ambiguity 7), replace each `click api.path.part.1.token` with
`focus api.path`, `hotkey cmd+Down` and `hotkey shift+Left`.

`api-editor-wrap.jsonl` (Review Focus 5): a token at a wrapping edge, and `+ hole` at the caret
in the path.

```json
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"pane_resize","params":{"id":"api-1","width":360,"height":600}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","path":[{"literal":"/v1/organisations/acme/projects/wakil/bookings/"},{"slot":"id"},{"literal":"/confirm"}]}}}
{"do":{"focus":"api.path"}}
{"do":{"hotkey":"cmd+Down"}}
{"do":{"press":"Left"}}
{"do":{"press":"Left"}}
{"do":{"press":"Left"}}
{"do":{"press":"Left"}}
{"do":{"press":"Left"}}
{"do":{"press":"Left"}}
{"do":{"press":"Left"}}
{"do":{"press":"Left"}}
{"do":{"press":"Backspace"}}
{"expect":{"pane":"api-1","field":"request.path[1]","present":false}}
{"do":{"keys":"x"}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/v1/organisations/acme/projects/wakil/bookings/x/confirm"}}
{"do":{"click":"api.path.hole"}}
{"do":{"type":{"into":"api.path.hole.name","text":"id"}}}
{"do":{"press":"Return"}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/v1/organisations/acme/projects/wakil/bookings/x"}}
{"expect":{"pane":"api-1","field":"request.path[1].slot","equals":"id"}}
{"expect":{"pane":"api-1","field":"request.path[2].literal","equals":"/confirm"}}
```

Red on `ed1af70`: the path's `+ hole` appends there, so `path[2]` is absent.

- [ ] **Step 3: Parse the new files headless**

Run: `go test ./e2e/...`
Expected: green. `ParseChecks` accepts every file, because every step kind is one of
`do`/`dispatch`/`expect`/`parity`.

- [ ] **Step 4: STOP: controller asks the operator for a GUI window**

Ask: *"Task 8 needs the GUI: `make e2e-new E2E_NEW_ARGS="--base ed1af70"` (about 15 minutes)
and then `make e2e` (about 40). Live Wakil must quit. OK to run, and are the peer sessions
clear?"* Tell the peers before and after.

- [ ] **Step 5: Seen red, then seen green**

Run: `make e2e-new E2E_NEW_ARGS="--base ed1af70"`. Read `.context/e2e/new/latest.json`. Every
added or changed check must be red **for the reason named in Steps 1–2**. A check that went red
because it "matched no element" is acceptable only for the `.token` drag and copy checks. Then
run `make e2e` and check its exit status itself, not a piped `tail`.

A check left untouched in Step 1 that now fails on the editor is rewritten here. The rewrite
needs a step that fails on `ed1af70`, and its own Step-5 run.

**One blind fix, then a live window.** If a check fails on focus or timing (a caret not where
the check expects, a cursor that fell out, a press answering -25200), make ONE fix without
watching and rerun that check. If it fails again, **STOP: controller asks the operator for a
bounded live window**: that single check file, run once with the operator watching.

- [ ] **Step 6: Commit**

```bash
git add e2e/checks/seeded/
git commit -m "2c-iv Amendment 10c: checks reach a position by the caret; the box identifiers retired; four new checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The runbook, and the re-walk

**Files:**
- Modify: `docs/wakil/phase-2c-iv-acceptance.md` (the hand text: check 4 and *Also look at*;
  the machine section is rendered, never typed)

**Interfaces:**
- Consumes: Task 8's green run records.
- Produces: the operator's re-walk.

- [ ] **Step 1: Edit check 4's hand text**

Set check 4 back to `- [ ]`. That is the re-walk: the operator ticks it, nobody else. Make
these changes in its text:
- Replace *"(the path's `+ hole` appends at the end; only the body's lands at the cursor)"* with
  *"`+ hole` lands at the cursor in every field, the path too"*.
- After the Backspace sentence, add: *"Select text that runs across the filled chip and type,
  or press ⌘X: it is refused, in amber, and the chip stays. Click the chip, ⌘C, click into the
  body, ⌘V: its **hole** arrives, not the binding. Drag the unfilled `id` chip from the path
  into the body: it moves."*
- Replace *"Type a multi-line JSON body (Return is a newline), put the cursor between two keys
  and press `+ HOLE`"* with *"Type a multi-line JSON body with two holes in it (Return is a
  newline, `+ HOLE` at the cursor each time), then press **Format**: **each chip sits in its
  line, after its key, exactly where text would.** Arrow up and down across the chips. Type
  on the line after one."*

In *Also look at*, replace the four chip bullets (*Backspace held*, *After deleting a chip*,
*`×` inside the chip*, *`+ HOLE` in the body*) with:
- *"**The body with holes** reads as JSON with values missing, never as boxes beside text.
  Lines align, a chip takes one character's place, and wrapping moves it like a word."*
- *"**Undo** (⌘Z) after removing a hole brings the hole back, in place. After an unbind it does
  nothing to the binding."*
- *"**An input method** (accent menu, or Japanese) right after a chip composes normally, and
  Backspace while composing never removes the chip."*
- *"**Paste from another app** of `<id>` stays the text `<id>`, never a hole."*

- [ ] **Step 2: Render the machine section**

Run: `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2c-iv-acceptance.md`
Expected: exit 0, with §0 between its markers rewritten from the records. Nothing else in the
file changes.

- [ ] **Step 3: Commit both together**

```bash
git add docs/wakil/phase-2c-iv-acceptance.md
git commit -m "2c-iv Amendment 10: the runbook — check 4 re-walked on one editor per field

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: STOP: the operator re-walks check 4 and looks at the body**

Hand it over in these words: *"Ready for the Walk rung: re-walk check 4, with a look at a
multi-line body holding holes. The machine section is green and rendered. The next step after
your walk is the phase log entry, and then the PR."* No agent ticks a box.

---

## Self-review

- **Spec coverage.** 10a: the editor for the four fields is Tasks 5–6, the attachment view and
  its identifiers are Task 5, `ApiEditorText` is Task 2, and the per-field box is Task 4.
  10b: AppKit owns the text (Task 5). The atomic token, the key rule and the selection refusal
  are Task 3 (rules) and Task 5 (wiring). `+ hole` at the caret everywhere is Tasks 3 and 5–6.
  Copy, cut, paste and drag are Tasks 3 and 5. Return is Task 5. Format, the drop, the path↔query
  split and 8d are unchanged, carried through Tasks 4–6. The deletions are Task 7. 10c: the
  retired family is a Global Constraint, and Tasks 6 and 8 carry it out. The four rewrites and
  the four new checks are Task 8. The spike and its hard stop are Task 1.
- **Wire unchanged.** No action, schema or `read_pane` key is touched. Decision 27's text is not
  edited, and its check runs unmodified.
- **Types.** `ApiHeld`, `ApiHeldTakeover`, `ApiHeldFlush` and `ApiHeldSendPlan` are named the same
  in Tasks 4–7. So are `ApiEditorActions`, `ApiEditorHandle.insertHole(_:)`,
  `ApiFieldTextView.insertHole(_:at:)`, `apiEditorAttributed(_:editor:)` and
  `ApiTokenAttachment.apply(key:index:editable:)` in Tasks 5–6.
