import WakilKit
import SwiftUI

/// A database pane: what it is looking at, the rows that came back, and
/// where in them it is.
///
/// **The query line exists because the pane's identity has to be
/// visible.** 2c-i's walk recorded the complaint — "a pane titled EVENTS
/// showing customer rows has a lying title" — and the fix for a lying
/// title is to show the query, not to guess a better title. It is also
/// what makes the routing rule legible: a pane that says what it is
/// showing is a pane the operator can see has been refined rather than
/// replaced.
struct DBPane: View {
    let table: PaneTable
    let pane: Pane
    let dispatch: (String, JSONValue) -> Void
    /// Handed to `DataSurface` unchanged — see its doc comment.
    let isFocusedPane: Bool
    let keyboardFocusRequests: Int
    /// Runs `text` against this pane. Separate from `dispatch` because it
    /// may raise the confirmation plane rather than dispatch a read — see
    /// `WindowModel.runFromQueryLine`.
    let run: (String) -> Void
    /// The gate's own sentence, when THIS pane's own last run was neither a
    /// read nor a mutation — `WindowModel.queryLineRefusal(pane:)`, read at
    /// this pane's id by `Canvas.paneView`. Drawn as a single dim line
    /// beneath the query line when non-nil.
    ///
    /// **Fix round 1: this used to be one `String?` per WINDOW**, passed
    /// into every open `DBPane` unconditionally — so typing a refused
    /// statement into one pane's line painted the refusal under every
    /// other open pane too, telling the operator that a pane they never
    /// touched had refused a statement they never typed there. Keying the
    /// refusal by pane id on `WindowModel` and reading only this pane's
    /// entry is what fixes it; nothing in this view had to change once the
    /// value handed in was scoped correctly.
    let refusal: String?
    /// The databases the active environment defines, for the chooser at
    /// the head of the line — `WindowModel.databases`, read once per draw.
    let databases: [String]
    /// The database this pane's next run goes against:
    /// `WindowModel.databaseForQueryLine(pane:)`, which is the operator's
    /// own choice while it is current and the pane's own subject
    /// otherwise. Never computed here — see that method.
    let database: String?
    /// Points this pane's line at another database
    /// (`WindowModel.chooseDatabase`). It runs nothing: choosing a database
    /// is not asking a question, the next Return is.
    let choose: (String) -> Void
    /// What the line must go back to showing after a run that did not
    /// become this pane's subject — a mutation, or a refusal
    /// (`WindowModel.queryLineRestore(pane:)`). Its token is what makes two
    /// identical restorations two events rather than one; see
    /// `WindowModel.QueryLineRestore`.
    let restore: WindowModel.QueryLineRestore?
    /// This pane's `PaneEditable` — `WindowModel.editable(paneId:)`, read
    /// at this pane's id by `Canvas.paneView`. **Per pane id, not per
    /// window**, the same discipline `refusal` above already documents:
    /// a single shared value would paint one pane's editability under
    /// every other open pane, offering an editor over a cell it never
    /// checked.
    let editable: PaneEditable?
    /// Enter in an edited cell — `WindowModel.commitCellEdit`, closed over
    /// this pane by `Canvas.paneView`. Handed to `DataSurface` unchanged;
    /// this view makes no editing decision of its own.
    let editing: (
        (_ rowKey: String, _ column: String, _ columnType: String?, _ value: String) async
            -> WindowModel.CellEditOutcome
    )?
    /// What the chosen database's driver speaks — `WindowModel.queryDialect(pane:)`. Picks how
    /// the query line is styled and how Format reflows it.
    let dialect: QueryDialect
    /// 3b-viii ghost-text in the query line, for THIS pane: whether it is on, the schema a request
    /// names tables from, the window's suggestion, and the release of a pending request.
    var ghostTextEnabled = false
    var ghostSchema: () async -> [GhostTable] = { [] }
    var ghostSuggest: (InfillRequest) async -> String? = { _ in nil }
    var ghostCancel: () -> Void = {}

    @State private var text: String = ""
    /// What `text` last agreed with the pane's own subject — either
    /// adopted from `pane.fetch` or set at the moment the operator last
    /// submitted. `shouldAdoptSubject` compares `text` against this to
    /// decide whether the line has unsaved edits; see that function's own
    /// doc comment (`PaneFetch.swift`) for the fix round 1 this replaces.
    @State private var lastRendered: String = ""
    /// Format's reason for leaving the text alone, until the next edit. Blocks nothing.
    @State private var notFormatted: String?
    /// Bumped by the Format control; `QueryLineEditor` formats once per new value.
    @State private var formatRequest = 0
    /// Whether the query line has keyboard focus: its field's border brightens, never glows.
    @State private var lineFocused = false

    private static let ink = Color(red: 0.910, green: 0.925, blue: 0.965)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            queryLine()
            if let refusal {
                Text(refusal)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.361, blue: 0.361).opacity(0.75))
            }
            // Not a failure of the statement, so the dim text colour, never the refusal's red.
            if let notFormatted {
                Text("not formatted: \(notFormatted)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
                    .accessibilityIdentifier("db.\(pane.id).notFormatted")
            }
            if let failure = table.failure {
                // D12. "No rows" said "I looked in `docs` and found
                // nothing"; the truth was "`docs` is not a database in this
                // environment". The error was known and journalled, and
                // every caller discarded it with `_ =`. Drawn here, in this
                // pane, because a message about pane B under pane A is the
                // same class of lie in a smaller font.
                Text(failure)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.361, blue: 0.361).opacity(0.75))
                    .textSelection(.enabled)
            }
            // **Final review, Important 3.** Spec §3.3 argued the failure
            // belongs BESIDE the rows — "a pane showing its last good
            // result under a red line saying the refetch failed is
            // honest" — and `PaneStore` keeps the retained rows precisely
            // so this can draw both. Drawing `Text(failure)` alone used to
            // return early, so a pane with rows still on hand from before
            // a failed refetch showed nothing but the error — which also
            // made `read_pane`'s own claim that "a non-null failure beside
            // non-empty rows means the fetch failed and what is shown is
            // stale" false as written. The failure line above is drawn
            // unconditionally; whether the rows are drawn beneath it turns
            // only on whether there are any to draw.
            if table.columns.isEmpty {
                // A fresh launch into an environment where the pane's
                // database is absent, or any other subject that never had
                // rows to retain — the failure line above already says
                // why, so this only adds "no rows" when there is no
                // failure to explain the emptiness.
                if table.failure == nil {
                    Text("no rows")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.30))
                }
                Spacer()
            } else {
                DataSurface(
                    table: table, pane: pane, dispatch: dispatch,
                    isFocusedPane: isFocusedPane, keyboardFocusRequests: keyboardFocusRequests,
                    drill: drill(),
                    editable: editable, editing: editing)
            }
            pageControls()
        }
        .onAppear {
            let described = pane.fetch?.query.describedForOperator ?? ""
            text = described
            lastRendered = described
        }
        // The pane's subject can change underneath the line — an agent
        // refined it, a header click sorted a truncated result and
        // re-queried, ‹ › moved the page. The line follows, EXCEPT when the
        // operator has unsaved edits — see `shouldAdoptSubject`'s own doc
        // comment (`PaneFetch.swift`) for why that decision is NOT "does
        // this field have focus", and lives in WakilKit rather than here.
        .onChange(of: pane.fetch) { _, new in
            let incoming = new?.query.describedForOperator ?? ""
            guard shouldAdoptSubject(
                currentText: text, lastRendered: lastRendered, incoming: incoming,
                refused: refusal != nil)
            else { return }
            text = incoming
            lastRendered = incoming
        }
        // A mutation and a refusal both leave the pane's subject alone, so
        // the line has to be put back to it — `shouldAdoptSubject` cannot
        // do this job, because after a submit `lastRendered` IS what was
        // typed and the line therefore counts as untouched (final review,
        // Important 9). The value is computed in `WindowModel`; this
        // adopts it unconditionally, because it is only ever published for
        // a run that did NOT become the subject.
        .onChange(of: restore) { _, new in
            guard let new else { return }
            text = new.text
            lastRendered = new.text
        }
        // Format's reason is about the text it saw. Any change to the text — typed, formatted,
        // or arriving from outside (a sort, a page, the agent, a restore) — makes it stale. An
        // `.unchanged` Format changes nothing, so its reason survives.
        .onChange(of: text) { _, _ in notFormatted = nil }
    }

    /// `database ▸ SELECT * FROM events`, editable, run with Return. The line
    /// wraps and grows to six lines (`QueryLineEditor`); ⇧Return breaks it.
    ///
    /// **Return, not ⌘↩, and the probe is the reason.** A per-pane
    /// `Button(…).keyboardShortcut(.return, modifiers: .command)` is
    /// window-scoped and fires the FIRST REGISTERED pane's button whatever
    /// has focus — measured, with focus in `db-2` and again with focus in
    /// the window's message field, both firing `db-1`. Typing in one pane
    /// would silently run another pane's query. `.onSubmit` on the focused
    /// field routed correctly in all three positions. The editor keeps that
    /// property: Return is handled by the focused text view itself, so it can
    /// only ever run its own pane's line.
    ///
    /// **No `.keyboardShortcut` may be added to this view, ever.** If ⌘↩
    /// is wanted later it is ONE window-level shortcut that dispatches to
    /// the focused pane id. That applies to the chooser below as much as
    /// to the field: a `Menu` carries no shortcut and must not be given
    /// one.
    ///
    /// **The database is CHOSEN here, not merely displayed** (spec §5;
    /// final review, Important 8). It used to render only a database the
    /// pane had inherited, so in an environment defining two the operator
    /// could reach the second only by having the agent seed the pane
    /// first — 2c-i's recorded open item, left open. The chooser is
    /// present whether or not the pane has a fetch, because a fresh ⌘K
    /// pane with nothing to inherit is exactly the case it exists for.
    @ViewBuilder
    private func queryLine() -> some View {
        HStack(alignment: .center, spacing: 10) {
            // One field: the database, the ▸ and the line read as a single control. A faint
            // inset well with a hairline border that brightens while the line has focus —
            // brightness only, never a glow (§8: the anchor row's edge is the one luminous
            // element).
            HStack(alignment: .top, spacing: 6) {
                // The database is part of the pane's identity: the same
                // statement against staging and against production are
                // different questions.
                databaseChooser()
                Text("▸")
                    .font(.system(size: 9))
                    .foregroundStyle(Self.ink.opacity(0.25))
                QueryLineEditor(
                    text: $text,
                    identifier: "db.\(pane.id).queryLine",
                    dialect: dialect,
                    run: { submitted in
                        // Submitting is itself a point where the line and the
                        // subject are known to agree, ahead of any async round
                        // trip — so a LATER external change (a sort, a page)
                        // is free to adopt rather than being blocked by an
                        // edit that was already committed.
                        lastRendered = submitted
                        run(submitted)
                    },
                    reportFormat: { notFormatted = $0 },
                    formatRequest: formatRequest,
                    cancel: {
                        guard table.runningSince != nil else { return false }
                        dispatch("db_cancel", .object(["pane": .string(pane.id)]))
                        return true
                    },
                    focusChanged: { lineFocused = $0 },
                    readRunning: table.runningSince != nil,
                    ghostTextEnabled: ghostTextEnabled,
                    ghostPrepare: { [dialect, ghostSchema] text, caret in
                        // The line is a file of its dialect to the model.
                        let (path, language) = dialect == .sql ? ("query.sql", "sql") : ("query.js", "javascript")
                        return ghostRequest(
                            text: text, caret: caret, path: path, language: language, schema: await ghostSchema())
                    },
                    ghostSuggest: ghostSuggest,
                    ghostCancel: ghostCancel)
                    // The field always fills the row up to Format and Run, so formatting changes
                    // its height and never its width.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // An empty line says what it is for. Drawn under the text view and never
                    // hit-tested, so a click still lands in the editor.
                    .background(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("query…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Self.ink.opacity(0.28))
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Self.ink.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Self.ink.opacity(lineFocused ? 0.28 : 0.12), lineWidth: 1))
            // Not a registered action, and runs nothing: it reflows whitespace or says why not.
            // No `.keyboardShortcut` (see above) — ⌥⇧F lives in the editor, on focus.
            Button("Format") { formatRequest += 1 }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Self.ink.opacity(0.45))
                .accessibilityIdentifier("db.\(pane.id).format")
            // Interaction Rule 2: Return is never the only way. Run does what Return does; while
            // a read is in flight it becomes Cancel, as Esc in the line does (Rule 4). No
            // `.keyboardShortcut`, for the reason above.
            if table.runningSince != nil {
                Button("Cancel") { dispatch("db_cancel", .object(["pane": .string(pane.id)])) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Self.ink.opacity(0.85))
                    .accessibilityIdentifier("db.\(pane.id).lineCancel")
            } else {
                Button("Run") {
                    lastRendered = text
                    run(text)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Self.ink.opacity(text.isEmpty ? 0.25 : 0.85))
                .disabled(text.isEmpty)
                .accessibilityIdentifier("db.\(pane.id).run")
            }
        }
        .padding(.bottom, 2)
    }

    /// The database this pane runs against, and the environment's others
    /// beside it.
    ///
    /// **A `Menu` rather than a `Picker`**: the rows are the environment's
    /// databases, which change with the active environment, and a `Picker`
    /// bound to a selection would need a stable identity for "none chosen
    /// yet" — a pane with no fetch and no choice has exactly that state,
    /// and inventing a sentinel for it is how "no database" becomes a
    /// database named "no database".
    ///
    /// The label is the effective database, `DATABASE` when there is none
    /// to name — an environment's single unnamed connection, or a fresh
    /// pane before anything has been chosen. The list is whatever
    /// `db_list_databases` last answered; an empty one leaves a label that
    /// opens an empty menu, which is honest about an environment that
    /// defines no databases.
    @ViewBuilder
    private func databaseChooser() -> some View {
        Menu {
            ForEach(databases, id: \.self) { name in
                Button(name) { choose(name) }
            }
        } label: {
            Text((database?.isEmpty == false ? database! : "database").uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.7)
                .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(databases.isEmpty)
    }

    /// The row action a table-list surface offers, or `nil` on every other
    /// subject.
    ///
    /// **Decided by asking the subject directly, not by probing row 0.**
    /// The brief's own sketch computed this as
    /// `table.drillTarget(row: 0, subject:) == nil ? nil : { ... }`, which
    /// makes an empty table list — zero rows, subject still `.tables` —
    /// indistinguishable from a subject that never offers a drill at all,
    /// because there is no row 0 to probe. The rule is "the SUBJECT
    /// decides, never the column names"; row 0's contents are exactly a
    /// column-shaped fact, so asking them is the same mistake the rule
    /// already forbids, one level removed. Checking `pane.fetch?.query`
    /// itself answers the question the rule actually asks, and does so
    /// whether the table list is empty or not. The per-row target still
    /// comes from `drillTarget(row:subject:)` — this only decides whether
    /// to offer the closure at all.
    ///
    /// **The predicate itself lives in `WakilKit`, not here** —
    /// `offersDrill(subject:listsTables:)` — because this view's target
    /// has no test target and cannot have one, and a value-level decision
    /// like this one has to live somewhere a regression would be caught by
    /// a test rather than by a human clicking around (fix round 1).
    ///
    /// **`listsTables` comes off `table`, not off the subject.** A typed
    /// `SHOW TABLES` is a `.sql` subject like any other; the walked
    /// failure was exactly that this predicate used to ask only the
    /// subject, so an agent's `db_list_tables` pane offered the drill and
    /// an operator's own `show tables` did not (D2).
    private func drill() -> ((Int) -> Void)? {
        guard offersDrill(subject: pane.fetch?.query, listsTables: table.listsTables) else {
            return nil
        }
        return { row in
            guard let name = table.drillTarget(row: row, subject: pane.fetch?.query) else { return }
            var params: [String: JSONValue] = ["table": .string(name)]
            // The same database the line would run against, so a drill and
            // a Return from one pane cannot reach two different databases.
            if let database, !database.isEmpty {
                params["database"] = .string(database)
            }
            // No `pane`: a table opened from a schema browse is a new
            // question, so it gets its own pane and sits beside the list
            // it came from. Comparing two things side by side is what the
            // canvas is for.
            dispatch("db_read_table", .object(params))
        }
    }

    /// ‹ › and the row range, at the footer's leading edge.
    ///
    /// Absent entirely when the result cannot be paged — an `EXPLAIN`, a
    /// `SHOW`, a table list. Offering a control that returns a syntax
    /// error is worse than offering none.
    @ViewBuilder
    private func pageControls() -> some View {
        if table.pageable, table.truncated || table.offset > 0 {
            HStack(spacing: 8) {
                Button("‹") { dispatch("db_page", .object([
                    "pane": .string(pane.id), "to": .string("previous"),
                ])) }
                .disabled(table.offset == 0 || table.runningSince != nil)
                Button("›") { dispatch("db_page", .object([
                    "pane": .string(pane.id), "to": .string("next"),
                ])) }
                .disabled(!table.truncated || table.runningSince != nil)
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.55))
        }
    }
}
