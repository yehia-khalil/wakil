import AppKit
import WakilKit
import SwiftUI

extension ApiPane {
    // MARK: - The method line and the URL box

    /// The method, as a segmented control, and the entry chooser at the line's right end.
    ///
    /// **The chooser is disabled, never hidden**, and only when it has
    /// nothing to offer (`apiChooserIsEnabled`): the active environment's
    /// entries, which `api_open` publishes on the snapshot, hold none the
    /// pane is not already on.
    var methodLine: some View {
        HStack(alignment: .center, spacing: 8) {
            methodControl
            Spacer(minLength: 8)
            chooser
        }
    }

    /// The method, pressable (it was a plain `Text`, and the operator could not change it by
    /// hand). **Each segment is a `Button`** — `SegmentedChoice`'s — so `api.method.<m>` is on
    /// something `AXPress` reaches, and a press is `api_set_request {pane, method}` through
    /// `operateFlushed`, after the boxes' flush, like every other gesture here. Pressing the
    /// method already chosen writes nothing.
    var methodControl: some View {
        let method = snapshot.request.method
        return SegmentedChoice(
            options: methods,
            selection: Binding(
                get: { method },
                set: { chosen in
                    guard chosen != method else { return }
                    operateFlushed([(
                        "api_set_request",
                        apiFieldWrite(field: .method, text: chosen, pane: pane.id))])
                }),
            identifier: { "api.method.\($0)" },
            held: methods.contains(method) ? nil : method)
    }

    /// The URL: one boxed field (the settings form's `.field`) holding the resolved origin and
    /// the path↔query view's editor, wrapping at the pane's edge, with `+ hole` at its right end.
    /// The origin and the editor flow together (`ApiFlow`); wrapping inside the path is the
    /// text view's.
    ///
    /// **The origin leads the box, drawn and never typed** — it is the entry's, and a null one
    /// is the entry failing to resolve, drawn as such BEFORE anything is sent rather than as a
    /// transport error after. It sits in the box rather than on the method line so that a long
    /// origin wraps with the path instead of being cut short beside the chooser.
    var urlBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                ApiFlow {
                    // The origin leads the URL: the entry's, drawn and never typed. Without one,
                    // `apiOriginLine` says what is missing (9b W1) — an unpointed pane, an entry
                    // this environment does not declare, or one that does not resolve — in amber,
                    // BEFORE anything is sent.
                    switch apiOriginLine(snapshot) {
                    case .origin(let origin): Text(origin).foregroundStyle(ink.opacity(0.45))
                    case .caution(let line): Text(line).foregroundStyle(amber)
                    }
                    fieldEditor(.path, label: "path").layoutValue(key: ApiFlowGrows.self, value: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                fieldHole(.path)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(fieldBox)
            fieldNotes(.path)
        }
    }

    /// The settings form's `.field`: a faint fill and a half-pixel stroke, radius 5 — the
    /// exception §1 already makes for a field, so it is never mistaken for a label.
    var fieldBox: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(SettingsPalette.coolWhite.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(SettingsPalette.coolWhite.opacity(0.14), lineWidth: 0.5))
    }

    /// §6's micro-label: uppercase, tracked, small, low opacity.
    func micro(_ text: String) -> some View {
        Text(text)
            .font(.system(size: SettingsScale.micro, weight: .semibold))
            .tracking(SettingsScale.microTracking)
            .foregroundStyle(ink.opacity(0.42))
    }

    /// The entry chooser.
    ///
    /// **A `Menu`, so the identifier lands on something `AXPress` can
    /// reach** — the same rule the Send control follows. Enabled by
    /// `apiChooserIsEnabled(entry:entries:)`: with several entries, or
    /// when the pane's entry is not among a non-empty list (so a pane the
    /// environment no longer declares can be re-pointed); disabled rather
    /// than hidden otherwise.
    ///
    /// **Re-pointing keeps every region.** `api_set_request {entry:}` is a
    /// re-point rather than a reset — the request is written against a
    /// NAME, so the same draft runs against staging and then production.
    var chooser: some View {
        Menu {
            ForEach(entries, id: \.self) { entry in
                Button(entry) {
                    operateFlushed([(
                        "api_set_request",
                        .object(["pane": .string(pane.id), "entry": .string(entry)]))])
                }
                .accessibilityIdentifier("api.entry.\(entry)")
            }
        } label: {
            HStack(spacing: 3) {
                Text(snapshot.entry.isEmpty ? "no entry" : snapshot.entry)
                Text("▾")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("api.entry")
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.05)))
        .foregroundStyle(ink.opacity(chooserIsEnabled ? 0.85 : 0.40))
        .disabled(!chooserIsEnabled)
    }

    /// Whether the chooser has something to offer (`apiChooserIsEnabled`): the active
    /// environment's entries, read from the snapshot `api_open` publishes them on.
    ///
    /// **It used to be a count alone**, first `snapshot.entry.isEmpty ? 0 : 1` (#296's audit:
    /// *"a true branch that nothing in the app can reach"*), then `entries.count`. The count
    /// left a dead end (final review, W1): a pane keeping an entry its one-entry environment
    /// lacks reads "pick one" beside a disabled chooser. So the ruling is handed the pane's
    /// entry too.
    var chooserIsEnabled: Bool {
        apiChooserIsEnabled(entry: snapshot.entry, entries: entries)
    }

    /// The path region, drawn on the URL line. Empty is drawn as the root
    /// rather than as nothing, so the line reads as a URL rather than as a
    /// gap.
    @ViewBuilder var path: some View {
        if snapshot.request.path.isEmpty {
            Text("/").foregroundStyle(ink.opacity(0.55))
        } else {
            parts(snapshot.request.path)
        }
    }

    // MARK: - The three regions below it

    /// The Query region as a small table: `QUERY | VALUE`, with `+ QUERY` in the header row's
    /// right cell, and each operator row's `+ hole` and `×` at its right end, revealed on hover.
    var queryRegion: some View {
        table(.query, name: "QUERY", value: "VALUE", empty: "+ add a parameter") {
            // **Each row's identity is its name and occurrence, not its position** (8b): a `×`
            // shifts every later row up one place, and a view keyed by position would see its
            // parts change under it and forget the text typed into a row nobody touched.
            ForEach(rowSlots(.query)) { slot in
                let row = (offset: slot.offset, element: snapshot.request.query[slot.offset])
                // W16: a bound value locks only itself — the rest of the value and its
                // neighbours stay typable, and every write carries the token back. **Which of
                // the rows sharing its name** (Important 2): two `tag` rows are two fields,
                // each drawing and writing its own row.
                let field = ApiDraftField.query(row.element.name)
                let occurrence = apiRowOccurrence(snapshot.request, field, at: row.offset)
                tableRow(
                    "query:\(slot.id)", holeKey: apiFieldKey(field, row: occurrence),
                    name: {
                        // Name and value apart, drawn apart: nobody types a `?` or an `&` and
                        // hopes Wakil finds the boundary.
                        Text(row.element.name).foregroundStyle(ink.opacity(0.55))
                    },
                    value: {
                        fieldEditor(field, row: occurrence, label: "value")
                        fieldNotes(field, row: occurrence)
                    },
                    actions: {
                        fieldHole(field, row: occurrence, refusalBelow: true)
                            .opacity(holeOpacity("query:\(slot.id)", apiFieldKey(field, row: occurrence)))
                        removeControl(.query, row.element.name, at: row.offset)
                    })
            }
        }
    }

    /// The header region's **three classes**, all drawn, name-sorted with
    /// Wakil's own rows last — the same list and the same order the arm
    /// publishes, because both come out of `apiHeaderRegion`.
    ///
    /// The `authorization` row draws its provenance in place of a value
    /// and **names no ref**: the credential resolves inside the capability
    /// layer at the moment a request leaves, so there is nothing here to
    /// draw and nothing to mask.
    var headerRegion: some View {
        let rows = snapshot.request.headers
        return table(.header, name: "HEADER", value: "VALUE", empty: "+ add a header") {
            // Keyed by name and occurrence, for the Query region's reason — and headers are
            // name-sorted, so an added row lands mid-list and shifts every one after it.
            ForEach(rowSlots(.header)) { slot in
                let row = (offset: slot.offset, element: rows[slot.offset])
                let field = ApiDraftField.header(row.element.name)
                // Wakil's rows count among themselves, so only an operator's row has an
                // occurrence `apiRowOccurrence` would give, and only it splits.
                let splits = row.element.isEditable && row.element.rowClass != .derived
                    && row.element.value != nil
                let occurrence = splits
                    ? apiRowOccurrence(snapshot.request, field, at: row.offset) : 0
                tableRow(
                    "header:\(slot.id)",
                    // Wakil's rows have no `+ hole`, so no name box to refuse under them.
                    holeKey: splits ? apiFieldKey(field, row: occurrence) : nil,
                    name: {
                        Text(row.element.name)
                            .foregroundStyle(ink.opacity(row.element.isEditable ? 0.55 : 0.40))
                    },
                    value: { headerValue(row.element, at: row.offset) },
                    actions: {
                        // Wakil's rows draw plain: `fieldHole` draws only on a split field and
                        // `removeControl` only where `apiRowDrawsRemove` says.
                        if splits {
                            fieldHole(field, row: occurrence, refusalBelow: true)
                                .opacity(holeOpacity(
                                    "header:\(slot.id)", apiFieldKey(field, row: occurrence)))
                        }
                        removeControl(.header, row.element.name, at: row.offset)
                    })
            }
        }
    }

    /// One header row's value cell, by its class.
    @ViewBuilder
    func headerValue(_ element: ApiHeaderRegionRow, at offset: Int) -> some View {
        let row = (offset: offset, element: element)
        if row.element.rowClass == .derived {
            // **`content-type` is editable even when unset**,
            // which is precisely when the operator wants it —
            // an unset row draws "not set" and has no value to
            // seed from. It is a STRING field, not a row of
            // parts: #116 makes it the one field on the draft
            // that admits none, so it commits through
            // `apiFieldWrite` rather than `apiRowWrite`.
            //
            // **It is held like any other field** (9a, 10a): `ApiFieldRow(.contentType)`
            // holding `[.literal(text)]`, written on a pause, on Return and on focus out, and
            // let go once the draft holds it (`apiHeldAfterLanding`). **It stays a `TextField`**
            // (10a): it holds no token, so it needs no editor.
            let contentType = apiContentTypeText(snapshot.request)
            let box = ApiFieldRow(.contentType)
            let identifier = "api.contentType"
            // **Line breaks never reach its text** (`apiSingleLineText`): a vertical field takes
            // one from Option-Return or a paste, and a content type is one line on the wire.
            // **`axis: .vertical`, so a long value wraps** at the cell's edge instead of
            // scrolling inside it. Return still fires `onSubmit` in a vertical field on macOS.
            // W19: the placeholder is the default an empty box stands for.
            TextField(
                apiContentTypePlaceholder,
                text: Binding(
                    get: { held[box].map(apiPlainLiteral) ?? contentType },
                    // No keystroke for a set of what it already shows (round 6).
                    set: { text in
                        let parts: [ApiPart] = text.isEmpty ? [] : [.literal(apiSingleLineText(text))]
                        guard let next = apiHeldTyping(
                            held, box: box, parts: parts,
                            rendered: apiHeldView(snapshot.request, box))
                        else { return }
                        held = next
                        keystroke()
                    }),
                axis: .vertical
            )
            .lineLimit(1...)
            .textFieldStyle(.plain)
            // Final review M5: autocorrect and text replacement would rewrite a content type —
            // bytes on the wire. Per view, so no shared field editor is touched (Ruling 13).
            .autocorrectionDisabled()
            .accessibilityIdentifier(identifier)
            .focused($focusedBox, equals: identifier)
            .onAppear { takeOwedFocus(identifier) }
            .onSubmit { flush() }
            .onChange(of: focusedBox == identifier) { _, now in
                focusChanged(box, identifier, now)
            }
            // Escape restores the field to what it held when the cursor arrived (9a).
            .onExitCommand { restore(box) }
            // B2: a content type beside no sent body is omitted from the wire, so its cell dims.
            .opacity(apiContentTypeIsSent(snapshot.request) ? 1 : 0.4)
        } else if row.element.isEditable, row.element.value != nil {
            // **Only the operator's own rows split.** Wakil's rows
            // (`isEditable == false`, `authorization`) keep their
            // provenance below: there is nothing of theirs to type.
            let field = ApiDraftField.header(row.element.name)
            let occurrence = apiRowOccurrence(snapshot.request, field, at: row.offset)
            fieldEditor(field, row: occurrence, label: "value")
            fieldNotes(field, row: occurrence)
        } else if let provenance = row.element.provenance {
            Text(provenance).foregroundStyle(ink.opacity(0.35))
        } else if let value = row.element.value {
            parts(value)
        } else {
            // `content-type` with nothing named. What happens
            // then is the send tool's to decide, not this
            // pane's to predict — so this draws the absence
            // rather than the default that might apply.
            Text("not set").foregroundStyle(ink.opacity(0.35))
        }
    }

    // MARK: - The two tables

    /// A region drawn as a small table: a header row of §6 micro-labels with the region's add
    /// control in its right cell, hairline-divided rows, and — at zero rows — a dim line.
    ///
    /// **Always present, even at zero rows** (#158): a region that vanishes when empty is one
    /// the operator cannot find in order to put the first row in it.
    func table(
        _ region: ApiRowRegion, name: String, value: String, empty: String,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        let count = region == .query
            ? snapshot.request.query.count : snapshot.request.headers.count
        return VStack(alignment: .leading, spacing: 0) {
            ApiRowColumns {
                micro(name)
                micro(value)
                HStack(spacing: 6) { addControl(region) }
            }
            .padding(.vertical, 5)
            // W6: the add's refusal, the pane's full width under the heading row.
            nameRefusal([region == .query ? "+query" : "+header"])
            hairline(0.08)
            rows()
            if count == 0 {
                // **A mouse's way to the same name box `+ QUERY` / `+ HEADER` opens**, and
                // only that: hidden from the accessibility tree, where the add control in the
                // header row is the one door, so the gate and the checks see one control.
                let slot = region == .query ? "+query" : "+header"
                Button(empty) {
                    holeName = ""
                    holeRefusal = nil
                    holeNaming = slot
                    // W5: the name box it opens takes the cursor.
                    pendingFocus = addNameId(region)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ink.opacity(0.30))
                .disabled(!apiRowAddIsEnabled(snapshot.request, region))
                .accessibilityHidden(true)
                .padding(.vertical, 6)
            }
        }
    }

    /// One table row: name ≈30% and wrapping, value wrapping, and the row's own controls at its
    /// right end — `+ hole` and `×`. `key` names the row for the hover, which raises its
    /// `+ hole` (`holeOpacity`, §8's hover-revealed row actions).
    ///
    /// **Quiet at rest, never hidden**, on the row grip's precedent (`paneGripOpacity`): a
    /// control drawn only on hover would be missing from the accessibility tree for every row
    /// the pointer is not over, and the checks press these by identifier. The reveal changes
    /// opacity and nothing else — no identifier, no existence — because an identifier that
    /// changes on update makes presses fail (-25200, Ruling 15).
    ///
    /// `holeKey` (W6): the row's `+ hole` name box, whose refusal is drawn under the row at the
    /// pane's full width; `nil` for a row with no `+ hole`.
    func tableRow(
        _ key: String,
        holeKey: String?,
        @ViewBuilder name: () -> some View,
        @ViewBuilder value: () -> some View,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            ApiRowColumns {
                VStack(alignment: .leading, spacing: 0) { name() }
                VStack(alignment: .leading, spacing: 3) { value() }
                HStack(spacing: 8) { actions() }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredRow = key
                } else if hoveredRow == key {
                    hoveredRow = nil
                }
            }
            nameRefusal([holeKey].compactMap { $0 })
            hairline(0.05)
        }
    }

    /// A table row's `+ hole` opacity: **quiet at rest and raised while the row is in use** —
    /// the pointer over it, the cursor in its value's editor, or its own name box open. Only
    /// `+ hole` is quieted, as the mockup's `.addhole.quiet`; the row's `×` keeps its own low
    /// opacity, since quieting it twice left it near invisible.
    func holeOpacity(_ rowKey: String, _ holeKey: String) -> Double {
        // The editor is not in `focusedBox`: the field the cursor is in is the tracker's.
        let focused = focusedIn.map { apiFieldKey($0.box.field, row: $0.box.row) == holeKey } ?? false
        return hoveredRow == rowKey || focused || holeNaming == holeKey ? 1 : 0.25
    }

    /// §8's row hairline, at `opacity`.
    func hairline(_ opacity: Double) -> some View {
        Rectangle()
            .fill(SettingsPalette.coolWhite.opacity(opacity))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }

    /// One row of a region as a `ForEach` identifies it: by name and occurrence (and class, so
    /// Wakil's own row never shares an identity with one of the operator's), with its position
    /// in the snapshot to draw from.
    struct RowSlot: Identifiable {
        let offset: Int
        let name: String
        let occurrence: Int
        let wakils: Bool

        /// Name, occurrence and class — never `offset`, which is what moves.
        var id: String { "\(wakils ? "r" : "o")\u{1F}\(occurrence)\u{1F}\(name)" }
    }

    func rowSlots(_ region: ApiRowRegion) -> [RowSlot] {
        let request = snapshot.request
        switch region {
        case .query:
            return request.query.indices.map { index in
                let name = request.query[index].name
                return RowSlot(
                    offset: index, name: name,
                    occurrence: apiRowOccurrence(request, .query(name), at: index), wakils: false)
            }
        case .header:
            return request.headers.indices.map { index in
                let row = request.headers[index]
                // Wakil's rows count among themselves: `apiRowOccurrence` counts the operator's.
                let wakils = row.rowClass != .authored
                let occurrence = wakils
                    ? request.headers.prefix(index).filter {
                        $0.name == row.name && $0.rowClass == row.rowClass
                    }.count
                    : apiRowOccurrence(request, .header(row.name), at: index)
                return RowSlot(
                    offset: index, name: row.name, occurrence: occurrence, wakils: wakils)
            }
        }
    }

    // MARK: - Adding and removing rows (8b)

    /// `+ query` / `+ header` on the region's heading line, and the name box it opens.
    ///
    /// **What Return does is `apiRowAdd`'s**: a write, a hand-off to Wakil's own content-type
    /// row, or a refusal drawn in amber under the heading row, the pane's full width (W6), with
    /// nothing dispatched. The write is
    /// built on the request as the screen shows it, after the flush (9a).
    @ViewBuilder func addControl(_ region: ApiRowRegion) -> some View {
        let enabled = apiRowAddIsEnabled(snapshot.request, region)
        switch region {
        case .query:
            nameControl(
                "+query", button: "+ QUERY", buttonId: "api.query.add",
                nameId: addNameId(.query), enabled: enabled, heading: true,
                refusalBelow: true
            ) { addRow(.query, $0) }
        case .header:
            nameControl(
                "+header", button: "+ HEADER", buttonId: "api.header.add",
                nameId: addNameId(.header), enabled: enabled, heading: true,
                refusalBelow: true
            ) { addRow(.header, $0) }
        }
    }

    /// The add name box's identifier — one place, since the empty table's mouse-only line owes
    /// it the cursor too (W5).
    func addNameId(_ region: ApiRowRegion) -> String {
        switch region {
        case .query: "api.query.add.name"
        case .header: "api.header.add.name"
        }
    }

    /// Return in an add name box. Answers the refusal's words, or nil having acted.
    func addRow(_ region: ApiRowRegion, _ name: String) -> String? {
        let request = applied
        switch apiRowAdd(draft: request, region: region, name: name, pane: pane.id) {
        case .write(let params):
            let added = apiRowAddedKey(request, region, name: name)
            pendingFocus = "api.\(added)"
            operateFlushed([("api_set_request", params)])
            return nil
        case .focusContentType:
            focusedBox = "api.contentType"
            return nil
        case .refused(let line):
            return line
        }
    }

    /// A row's `×` (8b), on the operator's rows only and not on a row holding a binding of its
    /// own, whose chip unbinds first — `apiRowDrawsRemove`. **It writes the region whole**,
    /// the row dropped and its neighbours' bindings carried (`apiRowRemoveWrite`, W16), built on
    /// the request as the screen shows it, after the flush (9a): a later twin's typing rides the
    /// write, so nothing waits.
    @ViewBuilder
    func removeControl(_ region: ApiRowRegion, _ name: String, at index: Int) -> some View {
        let request = snapshot.request
        if apiRowDrawsRemove(request, region, at: index) {
            let field: ApiDraftField = region == .query ? .query(name) : .header(name)
            let row = apiRowOccurrence(request, field, at: index)
            // Ruling 14: the region spelled literally in each identifier, so the harvester reads
            // four families the coverage gate can match — `apiFieldKey`'s shape, written out.
            let identifier = switch (region, row) {
            case (.query, 0): "api.query.\(name).remove"
            case (.query, _): "api.query[\(row)].\(name).remove"
            case (.header, 0): "api.header.\(name).remove"
            case (.header, _): "api.header[\(row)].\(name).remove"
            }
            chipButton(identifier, tone: ink) {
                guard let params = apiRowRemoveWrite(
                    draft: applied, region: region, name: name, row: row, pane: pane.id)
                else { return }
                // The flush first, built at its turn on the fields as they are, the removed
                // row's and every later twin's included; only then do their keys go (Task 6
                // carry). Trimmed at the press, the flush never saw them.
                operateFlushed([("api_set_request", params)]) {
                    held = apiBoxesRemovingRow(held, region: region, name: name, row: row)
                }
            }
        }
    }

    /// **A JSON body is text, refused the grid** on §8's own rule that a
    /// surface which cannot do the thing must not look like it can.
    ///
    /// A `BODY · JSON` / `BODY · TEXT` micro-label (W2) with `+ HOLE` and `FORMAT` on its right,
    /// and the boxed body below.
    ///
    /// **The box draws at zero parts, always** — #158's rule one level deeper. That ruling
    /// made a region visible at zero rows, because "a region that vanishes when empty is one
    /// the operator cannot find in order to put the first row in it". A region the operator
    /// can find and cannot TYPE INTO is no better: the body starts empty, and hiding its field
    /// at zero meant there was no way to write a first body at all. The e2e found it —
    /// "api.body matched no element, so there is nothing to act on".
    var bodyRegion: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                // W2: `BODY · JSON` / `BODY · TEXT`, from the content type as the screen shows
                // it — `applied`, so it follows a content type typed and not yet written.
                micro(apiBodyHeading(applied))
                Spacer(minLength: 8)
                if apiFormatRefusalShows(refused: formatRefusedBody, body: applied.body) {
                    // No identifier: a line is read, not pressed.
                    Text(apiNotJSONLine).foregroundStyle(amber).wraps()
                }
                fieldHole(.body, heading: true)
                formatControl
            }
            // W16: a bound value locks only itself — the text around it stays typable, and
            // every write carries the token back. **One editor** (Amendment 10a): Return is a
            // newline, and ⌘Return sends (9a).
            fieldEditor(.body, label: "body")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(fieldBox)
                // B1: a read sends no body, so its box dims. No line is drawn.
                .opacity(apiBodyIsSent(snapshot.request) ? 1 : 0.4)
            fieldNotes(.body)
        }
    }

    /// `Format` on the Body heading line (8c): the body as its editor holds it, re-indented and
    /// written after the flush — `apiFormatBodyWrite`, whose `nil` is the amber `apiNotJSONLine`
    /// and no write. Live over any body there is to format, a bound one too since W16: the
    /// binding is one value token, carried (`apiFormatIsEnabled`). A token is an opaque value.
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
            // Final review M7: the held body is let go here only when Format changes nothing —
            // no write would land to let it go. Otherwise it keeps its parts until the write
            // lands and the gesture's settling lets it go.
            if apiFormatIsNoOp(draft: snapshot.request, holding: holding) {
                held[body] = nil
                return
            }
            operateFlushed([("api_set_request", params)], takingOver: body)
        }
        .buttonStyle(.plain)
        .modifier(Verb(heading: true, enabled: enabled))
        .accessibilityIdentifier("api.body.format")
        .disabled(!enabled)
    }
}
