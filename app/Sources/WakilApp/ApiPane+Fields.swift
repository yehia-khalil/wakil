import AppKit
import WakilKit
import SwiftUI

extension ApiPane {
    // MARK: - Parts

    /// A field of parts, read-only: literals as the operator typed them,
    /// holes and bound values as chips under their own name. What a row
    /// Wakil owns draws with, and nothing here is pressable. It wraps, as every value does.
    func parts(_ parts: [ApiPart]) -> some View {
        ApiFlow {
            ForEach(Array(parts.enumerated()), id: \.offset) { part in
                switch apiPartDrawing(part.element) {
                case .text(let text):
                    Text(text).foregroundStyle(ink.opacity(0.85))
                case .chip(let name, let filled):
                    chip(name, filled: filled)
                }
            }
        }
    }

    /// What one field's `+ hole` and amber lines draw from — `fieldHole` and `fieldNotes`,
    /// which the restyle places apart from its editor: the URL box's right end, a table row's
    /// action cell, the Body heading.
    struct FieldView {
        let key: String
        let box: ApiFieldRow
        /// **The path box is a view of path AND query** (Amendment 8a): its editor holds the
        /// view, and the flush parses it back (`apiPathViewWrite`).
        let isPathView: Bool
        let typable: Bool
    }

    func fieldView(_ draftField: ApiDraftField, row: Int) -> FieldView {
        FieldView(
            key: apiFieldKey(draftField, row: row),
            box: ApiFieldRow(draftField, row: row),
            isPathView: draftField == .path,
            typable: apiFieldViewIsTypable(snapshot.request, draftField))
    }

    /// A field's `+ hole`, drawn only while the field is typable — the URL box's right end, a
    /// row's action cell, or (`heading`) the Body heading as `+ HOLE`. Every field's goes to its
    /// editor (`holeWrite`).
    @ViewBuilder
    func fieldHole(
        _ draftField: ApiDraftField, row: Int = 0, heading: Bool = false,
        refusalBelow: Bool = false
    ) -> some View {
        let field = fieldView(draftField, row: row)
        if field.typable {
            holeControl(field.key, heading: heading, refusalBelow: refusalBelow) { name in
                holeWrite(field.box, name)
            }
        }
    }

    /// A field's amber lines, drawn under it.
    @ViewBuilder
    func fieldNotes(_ draftField: ApiDraftField, row: Int = 0) -> some View {
        let field = fieldView(draftField, row: row)
        if field.isPathView, let note = apiPathBoxNote(snapshot.request) {
            // Amendment 8d: an `&` in a query value is the one reason the box is locked, and
            // the Query region, still editable, is where it is edited. Ruling 23: a `?` in
            // the path itself is noted over a box that stays typable — a commit does what
            // the view draws.
            Text(note).foregroundStyle(amber)
        }
        if let line = editorRefusals[field.box] {
            // The editor's own line (10b): a selection holding a bound value can't be deleted
            // or replaced. No identifier: a line is read, not pressed.
            Text(line).foregroundStyle(amber).wraps()
        }
    }

    /// A hole or a bound value, as a chip under its own name: an unfilled hole in amber on an
    /// amber tint — caution: the request is not ready and nothing has gone wrong — and a
    /// filled one in the pane's ink on a cool-white tint. **Its `×` sits inside it, at its right
    /// edge** (W4), so the chip and its control are one shape.
    func chip<Close: View>(
        _ name: String, filled: Bool, trailing: CGFloat = 4, @ViewBuilder close: () -> Close
    ) -> some View {
        HStack(spacing: 4) {
            Text(name).lineLimit(1)
            close()
        }
        .padding(.leading, 6)
        .padding(.trailing, trailing)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(filled ? SettingsPalette.coolWhite.opacity(0.10) : amber.opacity(0.10)))
        .foregroundStyle(filled ? ink.opacity(0.85) : amber)
        .fixedSize()
    }

    /// The read-only chip: Wakil's rows, the Bound list. With no `×`, it is padded 6 a side,
    /// **inside its tint**.
    func chip(_ name: String, filled: Bool) -> some View {
        chip(name, filled: filled, trailing: 6) { EmptyView() }
    }

    /// A row's `×` (8b). **A `Button`, so the identifier is on something `AXPress` reaches.**
    /// A token's `×` is the editor's own (`ApiTokenClose`).
    func chipButton(
        _ identifier: String, tone: Color, action: @escaping () -> Void
    ) -> some View {
        Button("×", action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(tone.opacity(0.55))
            .accessibilityIdentifier(identifier)
    }

    /// `+ hole`, and the name box it opens in its place (spec §1).
    ///
    /// **Return inserts it into the field's editor; a blank name is refused here and nothing is
    /// inserted** (`apiHoleNameRefused`), its line drawn beside the box in amber, because a hole
    /// with no name is caution and not failure. Escape closes the box having written nothing.
    func holeControl(
        _ key: String, heading: Bool = false, refusalBelow: Bool = false,
        submit: @escaping (String) -> String?
    ) -> some View {
        nameControl(
            key, button: heading ? "+ HOLE" : "+ hole", buttonId: "api.\(key).hole",
            nameId: "api.\(key).hole.name", heading: heading, refusalBelow: refusalBelow,
            submit: submit)
    }

    /// A button that opens a name box in its place — `+ hole`, `+ QUERY`, `+ HEADER`.
    ///
    /// **One name box at a time, pane-wide** (`holeNaming`), keyed by `slot`. Return calls
    /// `submit`, which answers the refusal's words — drawn beside the box in amber, the box left
    /// open — or nil having dispatched, which closes it. Escape closes it having written nothing.
    ///
    /// **The box takes the cursor when it opens** (W5), through `focusedBox` — the pane's one
    /// focus state — owed by `pendingFocus` and taken a turn after it is drawn
    /// (`takeOwedFocus`). `refusalBelow` (W6): the refusal is drawn by the table under its row,
    /// the pane's full width (`nameRefusal`), rather than beside the box in a narrow cell.
    @ViewBuilder
    func nameControl(
        _ slot: String, button: String, buttonId: String, nameId: String,
        enabled: Bool = true, heading: Bool = false, refusalBelow: Bool = false,
        submit: @escaping (String) -> String?
    ) -> some View {
        if holeNaming == slot {
            TextField("name", text: $holeName)
                .textFieldStyle(.plain)
                // M5: a name is matched exactly as typed (spec §1), so nothing may correct it.
                .autocorrectionDisabled()
                .frame(width: 90)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(fieldBox)
                .accessibilityIdentifier(nameId)
                // W5: the one focus state the pane has, so the box the operator was in lets go.
                .focused($focusedBox, equals: nameId)
                .onAppear { takeOwedFocus(nameId) { holeNaming == slot } }
                .onChange(of: holeName) { _, _ in holeRefusal = nil }
                .onSubmit {
                    // `submit` answers the refusal's words, or nil having dispatched.
                    if let refusal = submit(holeName) {
                        holeRefusal = refusal
                        return
                    }
                    closeHole()
                }
                .onExitCommand { closeHole() }
            if !refusalBelow, let refusal = holeRefusal {
                Text(refusal).foregroundStyle(amber).wraps()
            }
        } else {
            Button(button) {
                holeName = ""
                holeRefusal = nil
                holeNaming = slot
                pendingFocus = nameId
            }
            .buttonStyle(.plain)
            .modifier(Verb(heading: heading, enabled: enabled))
            .accessibilityIdentifier(buttonId)
            .disabled(!enabled)
        }
    }

    func closeHole() {
        holeNaming = nil
        holeName = ""
        holeRefusal = nil
    }

    /// W6: an open name box's refusal, drawn the pane's full width under a table's row rather
    /// than squeezed into its last cell (`ApiRowColumns` caps that cell at 45%).
    @ViewBuilder func nameRefusal(_ slots: [String]) -> some View {
        if let open = holeNaming, slots.contains(open), let line = holeRefusal {
            Text(line).foregroundStyle(amber).wraps()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
        }
    }

    /// `+ hole` on any field (10b). Answers a refusal's words, or nil having inserted it.
    ///
    /// **It is the field's editor's**: inserted at its caret, or at its end when the caret has
    /// not been there — the path view's end of PATH, before its `?` (`apiEditorHoleOffset`) —
    /// as text the editor owns, so ⌘Z takes it back. Its change reports the parts, and
    /// `insertHole` calls `gesture`, which flushes at once; a path the parse then refuses says
    /// so under the URL (`pathRefusal`). A field that took no hole (not drawn, not editable)
    /// says so in its own words (M8), not the blank-name line.
    func holeWrite(_ box: ApiFieldRow, _ name: String) -> String? {
        if let refusal = apiHoleNameRefused(name) { return refusal }
        return editors.handle(box).insertHole(name) ? nil : apiEditorHoleNotPlaced
    }

    /// The field the cursor is in, and the request when it arrived — what Escape writes back.
    var focusedIn: ApiFocusedField? { focus.focused }

    /// Focus in marks the field for Decision 27. Focus out releases it, after the field's write.
    /// **Only the box that last took focus may release** (`ApiFocusTracker`, preflight F5),
    /// because moving from A to B can deliver B's focus-in before A's focus-out, and the boxes
    /// around a chip share one field.
    ///
    /// **A focus-in that replaces another field** (`left`, preflight F6) flushes the old field
    /// first, then marks the new field off the chain and keeps the old one marked: the new marks
    /// replace the old on the chain, behind that flush.
    ///
    /// **A focus out flushes, then releases** (Review Focus 1): the release is queued after the
    /// flush, so the agent stays refused until the field's last write is on the draft. Either
    /// way the held fields are then trimmed with the old field no longer focused (preflight F7):
    /// a field that writes nothing (`/o?`) lands no snapshot to let it go, and kept, it would
    /// read as an owed write once an agent changed the draft.
    func focusChanged(_ box: ApiFieldRow, _ identifier: String, _ took: Bool) {
        if took {
            focusArrived(box, identifier)
        } else {
            focusLost(identifier)
        }
    }

    func focusArrived(_ box: ApiFieldRow, _ identifier: String) {
        switch focus.took(box, identifier: identifier, request: snapshot.request) {
        case .arrived(let fields, let left):
            if left != nil {
                flush()
                held = apiHeldAfterLanding(
                    snapshot.request, held: held, focused: box, takenOver: takenOver,
                    queued: queued)
            }
            noteFocus(fields)
            // **The Escape baseline is taken again on the chain** (plan B preflight P7), on
            // every arrival: the field the cursor came from flushes behind `took`'s read, here
            // or in its own focus-out, and Escape in the path box writes the query too. This
            // builds behind that flush and ahead of any edit in this box. It builds no calls, so
            // it dispatches nothing and leaves the drop's line alone.
            operateInOrder { now in
                _ = focus.rebased(identifier: identifier, request: now.request)
                return ApiPaneBatch(calls: [])
            }
        case .released, .ignored:
            break
        }
    }

    func focusLost(_ identifier: String) {
        switch focus.lost(identifier: identifier) {
        case .released:
            flush()
            held = apiHeldAfterLanding(
                snapshot.request, held: held, focused: nil, takenOver: takenOver, queued: queued)
            releaseFocus()
        case .arrived, .ignored:
            break
        }
    }

    /// Escape (9a): the field goes back to what it held when the cursor arrived, as one write,
    /// and the cursor leaves it. The pause is cancelled and the field let go, so nothing typed
    /// since the last write is written. **The restore is built at its turn, against the stored
    /// draft** (`apiRestoreCalls`), never against `applied`: behind any write already on the
    /// chain, it undoes what reached the draft, landed or in flight. Compared against `applied`,
    /// a box typed back to its focus-in text hid an earlier write, and the draft kept it.
    func restore(_ box: ApiFieldRow) {
        pendingWrite?.cancel()
        pendingWrite = nil
        let focused = focusedIn
        operateInOrder { now in
            ApiPaneBatch(calls: apiRestoreCalls(
                focused, box: box, draft: now.request, pane: pane.id))
        }
        held[box] = nil
        editorRefusals[box] = nil
        if box.field == .path { pathRefusal = nil }
        if holeNaming == apiFieldKey(box.field, row: box.row) { closeHole() }
        // Escape leaves the field: the content type's `TextField` by its focus state; an editor
        // resigns itself (`ApiFieldEditor`'s `cancelOperation:`).
        focusedBox = nil
    }

    // MARK: - One editor per field (Amendment 10)

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
                },
                // 11a: the path editor only; every other field's paste stays text.
                pastedCurl: draftField == .path ? { text in pasteCurl(text) } : nil),
            caretToEnd: draftField == .path ? fillCaret : 0)
            // No `TextField` placeholder to borrow: the label, quiet, while the field is empty.
            .overlay(alignment: .topLeading) {
                if parts.isEmpty {
                    Text(label).foregroundStyle(ink.opacity(0.3)).allowsHitTesting(false)
                }
            }
            // W5: a row `+ query` / `+ header` just added takes the cursor in its value.
            .onAppear { takeOwedEditorFocus(box, identifier) }
    }

    /// W5 for an editor: the row `+ query` / `+ header` just added takes the cursor once drawn,
    /// a turn later, and only while nothing else took it (`takeOwedFocus`'s guard).
    ///
    /// **Guarded on both cursors** (preflight M11): `focusedBox` sees only the SwiftUI boxes (a
    /// name box, the content type), and an editor holding the cursor is `focusedIn`'s. A cursor
    /// the operator put in another editor during that turn is left there.
    func takeOwedEditorFocus(_ box: ApiFieldRow, _ identifier: String) {
        guard pendingFocus == identifier else { return }
        pendingFocus = nil
        let was = focusedBox
        let wasIn = focusedIn?.box
        DispatchQueue.main.async {
            guard focusedBox == was || focusedBox == nil else { return }
            guard focusedIn?.box == wasIn || focusedIn == nil else { return }
            editors.handle(box).focus()
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

    /// Gives `identifier` the focus owed it — a name box just opened (W5), or the content type
    /// a `+ header content-type` hands the cursor to — once its box is drawn. **One run-loop turn later**: a field appearing
    /// in this update is not in the window's responder chain yet, and focus set now is dropped.
    ///
    /// **Guarded at its turn**: only while the cursor is still where it
    /// was when the focus was owed and the box is still drawn (`stillOpen`: a name box while
    /// `holeNaming` still names it) — a box the operator closed, or a cursor they put
    /// elsewhere, in that turn is left alone.
    func takeOwedFocus(_ identifier: String, stillOpen: @escaping () -> Bool = { true }) {
        guard pendingFocus == identifier else { return }
        pendingFocus = nil
        let was = focusedBox
        DispatchQueue.main.async {
            guard focusedBox == was || focusedBox == nil, stillOpen() else { return }
            if focusedBox != identifier { focusedBox = identifier }
        }
    }
}
