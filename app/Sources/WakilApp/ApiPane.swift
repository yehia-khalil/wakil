import AppKit
import WakilKit
import SwiftUI

/// The API client pane: a method line, a URL box, the four request regions **in wire
/// order** (the Query and Headers regions as small tables), Send, and a response that says
/// nothing came back yet. Drawn in the settings form's vocabulary (`SettingsForm.swift`).
///
/// **It draws the draft and edits it in place.** Every edit — a box's typing, saved on a
/// pause (9a), `+ hole`, a chip's `×` or key, a dropped row, Send — is the same
/// `api_set_request`, `api_bind` or `api_send` the agent calls, dispatched on this pane's one
/// surface chain (`operateInOrder`), so the operator's request and the agent's are one action.
///
/// **Every decision worth asserting is `WakilKit`'s** — this target has no
/// test target and cannot have one, the same rule `TerminalPane` and
/// `DBPane` follow. The chooser's disabled-rather-than-hidden rule is
/// `apiChooserIsEnabled(entry:entries:)`; the title is `apiPaneTitle`; the
/// header region's three classes and their order are `apiHeaderRegion`;
/// how a part reads is `apiPartDrawing`. What is left here maps those
/// values to `Text` and frames.
struct ApiPane: View {
    let snapshot: ApiSnapshot
    let pane: Pane
    /// Dispatches the operator's calls, in order, on the window's one chain for this pane
    /// (`WindowModel.enqueueFromSurface(pane:building:settled:)`) — the SAME registry the agent
    /// speaks to, which is what makes "a request built in the window and a request built by the
    /// agent are the same action" true rather than aspirational.
    ///
    /// **The calls are built when the batch's turn comes** (Task 9 fix round 4): everything
    /// queued before it has completed, and the builder is handed the stored snapshot. So a
    /// flush, and Send's statement, are built on the draft they will land on. `settled` runs on
    /// the chain once the batch has run, with whether every call landed, before the next batch
    /// is built.
    ///
    /// **Private, and only `operateInOrder` calls it** (Task 8, fix round 1): every dispatch
    /// this pane makes is the operator editing or sending the draft, and each one clears the
    /// drop's result line. A call site that reached this directly would be an edit that forgot to.
    private let dispatchInOrder: (
        _ build: @escaping @MainActor (ApiSnapshot) -> [(String, JSONValue)],
        _ settled: @escaping @MainActor (_ landed: Bool) -> Void
    ) -> Void
    /// The entries the active environment declares, for the chooser.
    /// Empty is a legitimate state and the chooser says so rather than
    /// vanishing.
    let entries: [String]
    /// Decision 27 by focus: the fields the cursor is now in. Marked off the chain, in a `Task`
    /// the window starts (so just after the call returns, not during it), and set again on the
    /// chain behind any flush queued before it (`WindowModel.focusFromSurface`). **The
    /// window issues the generation**, never this view (fix round 1).
    let noteFocus: (_ fields: Set<ApiDraftField>) -> Void
    /// Releases the focus mark once every call queued before it has landed
    /// (`WindowModel.releaseFocusFromSurface`). Also called when the pane appears.
    let releaseFocus: () -> Void
    /// The operator's drop of one grid row: `WindowModel.bindFromSurface`, which is
    /// `api_bind` through the same registry and origin as every other control here, handing
    /// back what the action said so the result line can say it in this pane.
    let bind: (_ source: String, _ row: Int) async -> ApiBindOutcome
    /// Amendment 11a: the path editor's `curl …` paste — `WindowModel.fillFromCurlSurface`,
    /// `api_fill_from_curl` on this pane's chain. The fill's line and whether **Undo** is offered
    /// are pane state (`ApiSnapshot.fillLine`, `.fillUndoable`), so an agent's fill draws the same.
    let fillFromCurl: (_ text: String) async -> ApiBindOutcome
    /// The fill line's **Undo**: `WindowModel.undoFillFromSurface`, `api_undo_fill`.
    let undoFill: () async -> ApiBindOutcome
    /// A source pane's rows as the window draws them NOW — what `apiDropRow` compares the
    /// row picked up against, at the moment it lands.
    let sourceRows: (_ source: String) -> [PaneRow]
    /// ⌘K's Send for this pane (`WindowModel.apiSendRequest`): a token, answered by pressing
    /// this pane's own Send — the flush, the method's choice and the statement all live here.
    /// **Only a change presses**: a token already standing when the pane appears (a remount)
    /// is not a new press, so the `onChange` below never fires initially.
    let sendRequest: Int?

    /// Which split field's `+ hole` has its name box open, by the field's key — `path`,
    /// `body`, `query.<name>`, `header.<name>` — or none.
    ///
    /// **One at a time, pane-wide.** A name box is a question the operator is answering, and
    /// two open at once would leave Return ambiguous about which one it answered.
    @State var holeNaming: String?
    /// What is typed into the open name box, taken exactly as typed (spec §1).
    @State var holeName = ""
    /// `apiHoleNameRefusal` while the open name box's last Return was refused, else nothing.
    @State var holeRefusal: String?
    /// Which SwiftUI box has the keyboard, by its identifier: an open name box, and the content
    /// type, which `+ header content-type` hands the cursor to (8b). **The editors are not in
    /// it** (Amendment 10): each is an `NSTextView`, focused through its handle
    /// (`takeOwedEditorFocus`), and the field the cursor is in is `focus`'s. A name box is not a
    /// draft field, so it notes no Decision 27 mark — only the draft fields' own `focus`
    /// callbacks do.
    @FocusState var focusedBox: String?
    /// A field focus is owed to that is not drawn yet: the row `+ query` / `+ header` added
    /// lands on the next snapshot, and its value's editor takes focus when it appears.
    @State var pendingFocus: String?
    /// `ApiHeldFlush.refusals`' line for the path box while its text cannot be parsed, else
    /// nothing — drawn in amber under the URL line, and nothing was written (Amendment 8a).
    /// Set by every flush, Send's included, so a Send refused for it is never silent.
    @State var pathRefusal: String?
    /// Send's own refusal, which is no box's: "pick an entry first" from an unpointed pane
    /// (`ApiHeldSendPlan.refusal`, fix round 1). Drawn under Send only while the pane is unpointed.
    @State var sendRefusal: String?
    /// The body as the screen showed it when `Format` was last refused. `apiNotJSONLine` is
    /// drawn on the Body heading **while the body still shows that**: a keystroke, an agent's
    /// write or a Format that lands moves it on, and the line goes with the text it was about.
    /// The flush of that same text landing does not, since the body it shows is unchanged.
    @State var formatRefusedBody: [ApiPart]?
    /// Which box the cursor is in, by its identifier (preflight F5), and the field and request
    /// it arrived at (`ApiFocusedField`, what Escape writes back).
    @State var focus = ApiFocusTracker()
    /// Amendment 10a: each field's parts that the draft may not hold yet, **one entry per
    /// field** — the path view, each query and header value, the body — and the content type as
    /// `ApiFieldRow(.contentType)` holding `[.literal(text)]`. **The pane's one model.**
    ///
    /// **Held only for the pause and while its write is in flight** (9a): it is let go once
    /// the draft holds what it shows (`apiHeldAfterLanding`).
    ///
    /// **By row, not by name** (final review, Important 2): two query or header rows may share
    /// a name (#158 draws both), and keyed by the name alone they shared one field.
    @State var held: ApiHeld = [:]
    /// One handle per editor field: `+ hole` reaches the field's text view through it.
    @State var editors = ApiEditorRegistry()
    /// Each editor field's line (`apiBoundSelectionLine`), cleared by its next change.
    @State var editorRefusals: [ApiFieldRow: String] = [:]
    /// Each field whose write is on the chain, at the parts it was dispatched with (preflight
    /// F23): set when the write's batch is built on the chain and cleared when THAT dispatch
    /// completes, landed, refused or failed (`apiQueuedSettled`). A flush skips a field still
    /// showing exactly that.
    @State var queued: ApiHeld = [:]
    /// Each field a gesture's write carried (Format's body), at the parts it carried (Task 9 fix
    /// round 2 and round 3). While that gesture is in flight, the field is never flushed or
    /// sent, and no landing lets it go. The gesture's dispatch settles it (`apiGestureSettled`):
    /// if it landed, the field is let go; if it was refused, the field owes its write again.
    /// The entry is spent once the field is let go or typed past.
    ///
    /// **Each entry holds its gesture's token** (`ApiHeldTakeover`, round 4), so only that
    /// gesture's dispatch settles it, even when a later gesture carried the same parts.
    @State var takenOver: [ApiFieldRow: ApiHeldTakeover] = [:]
    /// The last token issued to a gesture that took a box over.
    @State var takeovers = 0
    /// Every batch and drop this pane has issued, counted in the order they were made. A batch
    /// is built later, on the chain, so this order, not the build's, is what decides whether a
    /// drop's result is still current (`bindGeneration`).
    @State var issued = 0
    /// The write the current pause will make, cancelled by the next keystroke (9a).
    @State var pendingWrite: Task<Void, Never>?
    /// Whether the past tense is unfolded.
    ///
    /// **Folded by default** (#195): the strip is a log, and a log that
    /// opens itself costs the operator the space every time they are not
    /// asking about the past. The count is drawn either way, so what is
    /// hidden is the rows and never the fact that there are some.
    @State var recentUnfolded = false
    /// W20: Body or Headers under the response's pinned head. The operator's choice, kept across
    /// replies. Not published: `read_pane` already carries both.
    @State var responseShows: ApiResponseShows = .body
    /// The pinned head's measured height, which `apiRecentShownRows` needs to know what the body
    /// and Recent's rows share (re-walk #1c). The head does not depend on Recent, so measuring it
    /// cannot feed back.
    @State var responseHeadHeight: CGFloat = 0
    /// The response body's measured content height (review I1): it keeps its own lines, six at
    /// most, before Recent's rows take the half.
    @State var responseBodyHeight: CGFloat = 0
    init(
        snapshot: ApiSnapshot, pane: Pane,
        dispatchInOrder: @escaping (
            _ build: @escaping @MainActor (ApiSnapshot) -> [(String, JSONValue)],
            _ settled: @escaping @MainActor (_ landed: Bool) -> Void
        ) -> Void,
        entries: [String],
        noteFocus: @escaping (_ fields: Set<ApiDraftField>) -> Void,
        releaseFocus: @escaping () -> Void,
        bind: @escaping (_ source: String, _ row: Int) async -> ApiBindOutcome,
        // No defaults: a construction site that leaves these out does not compile.
        fillFromCurl: @escaping (_ text: String) async -> ApiBindOutcome,
        undoFill: @escaping () async -> ApiBindOutcome,
        sourceRows: @escaping (_ source: String) -> [PaneRow],
        sendRequest: Int?
    ) {
        self.snapshot = snapshot
        self.pane = pane
        self.dispatchInOrder = dispatchInOrder
        self.entries = entries
        self.noteFocus = noteFocus
        self.releaseFocus = releaseFocus
        self.bind = bind
        self.fillFromCurl = fillFromCurl
        self.undoFill = undoFill
        self.sourceRows = sourceRows
        self.sendRequest = sendRequest
    }

    /// What the last drop said (spec §2's result line), or nothing.
    ///
    /// **Cleared by the operator's next edit or send**, and by nothing else: the line is about
    /// the draft as the drop left it, and once they have changed that draft it is about a
    /// request that no longer exists.
    @State var bindLine: ApiBindLine?
    /// Moves on every edit, send and drop, so a drop's result that arrives after the operator
    /// has moved on is dropped rather than drawn (final review, Minor 1). `bind` is awaited:
    /// an edit committed during the await clears the line, and without this the drop's Task
    /// would then set it again, beside a draft it no longer describes.
    ///
    /// **It holds the `issued` number of the latest edit or drop** (round 4). An edit's batch
    /// is built on the chain, after the moment it was made, so a flush made BEFORE a drop may
    /// be built after it. It moves this only up to its own number, and the drop keeps its line.
    @State var bindGeneration = 0
    /// 11a: moves on each successful paste-fill; the path editor puts its caret at the end of
    /// the fill on the update that carries it (`ApiFieldEditor.caretToEnd`).
    @State var fillCaret = 0
    /// Whether a grid row is over the pane right now — the drop outline's one input.
    @State var dropTargeted = false

    let ink = Color(red: 0.910, green: 0.925, blue: 0.965)
    /// `#e8b45a` — design-language.md §5's reserved amber, "pending ·
    /// caution", the same constant `TerminalPane.amber` names. An entry
    /// that does not resolve is caution and not failure: nothing has gone
    /// wrong yet, and nothing can be sent until it is configured. An
    /// unfilled hole is the same species — the request is not ready, and
    /// nothing has gone wrong.
    ///
    /// §5's rule is that text is cool white stepped down by OPACITY,
    /// never by a different hue, and that the three reserved hues are
    /// never decorative. This is the one hue in this pane, and it uses the
    /// documented value rather than one near it — the terminal pane's
    /// carve-out for a program's own SGR colours does not reach Wakil's
    /// own chrome. **The body carries no hue at all**: §5's reserved three
    /// are spent on the status code alone.
    let amber = Color(red: 0.910, green: 0.706, blue: 0.353)

    /// `#8be0c8` and `#e85c5c` — §5's reserved green and red, spent on the response's status
    /// chip and nowhere else in this pane (`apiStatusTone` rules which).
    let green = Color(red: 0.545, green: 0.878, blue: 0.784)
    let red = Color(red: 0.910, green: 0.361, blue: 0.361)
    /// The five methods the segmented control offers. A draft holding any other (an agent may
    /// set one) draws it as a sixth, read-only segment (`SegmentedChoice.held`).
    let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    /// Which table row the pointer is over, by `rowKey` — the one input of the hover reveal.
    @State var hoveredRow: String?

    var body: some View {
        GeometryReader { geometry in
            let split = apiPaneSplit(
                total: Double(geometry.size.height), response: snapshot.response)
            // **One layout path, whatever the response says** (plan B preflight P17): the
            // request half is never in a branch, so the first reply, an environment switch or a
            // cancel moves only its frame and never rebuilds a box — the cursor stays, and a
            // focused body is not torn down without its focus-out. Both frames are always
            // applied; the split only says what they hold.
            VStack(alignment: .leading, spacing: 0) {
                requestHalf
                    .frame(height: split.requestHeight.map { CGFloat($0) }, alignment: .top)
                    .frame(maxHeight: split.requestHeight == nil ? .infinity : nil, alignment: .top)
                // Re-walk #1a: the split's divider is the response half's first line, a
                // visible hairline with room either side, rather than half a point at 0.08
                // laid over its padding.
                responseHalf(scrolls: split.responseScrolls, height: split.responseHeight)
                    // A one-line response is drawn at its own height, so the request takes the
                    // rest; a shared one is exactly its half.
                    .fixedSize(horizontal: false, vertical: !split.responseScrolls)
                    .frame(height: split.responseHeight.map { CGFloat($0) }, alignment: .top)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(ink.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // W10: nothing draws outside the pane — not under the window's chrome, not over a
        // neighbour. The walk saw a 200 KB reply push the request under the old top buttons.
        .clipped()
        // Ruling 13: no field-editor mutation for the single-line boxes. A probe found the
        // window's shared field editor already has smart quotes and dashes off (text replacement
        // and spelling correction on). Fix round 1 turned those off on focus through a
        // process-wide static, and AX presses on this pane's buttons then failed intermittently
        // (-25200) while a box held focus, so it was removed. Whether text replacement or
        // autocorrect touching a single-line box matters is the operator's walk to judge.
        // **The whole pane is the drop target** (spec §2): `api_bind` fills every matching
        // hole at once, so there is no single hole to aim at. `.contain` makes the pane one
        // element the harness can drop on by name while every control inside it stays its
        // own; `.contentShape` makes the empty space below the last region part of it.
        .contentShape(Rectangle())
        // Fix round 1: a view SwiftUI tore down (the pane left the canvas and came back under
        // the same id) never delivered its focus-out. Whatever focus it left marked is cleared
        // on the chain, so the agent is not refused for a cursor that is no longer anywhere.
        // **A view SwiftUI kept** (a lazy re-appear) still holds its cursor, and re-notes that
        // field instead of releasing a live mark (`ApiFocusTracker.held`).
        .onAppear {
            if let fields = focus.held { noteFocus(fields) } else { releaseFocus() }
        }
        // A pause still running when the pane leaves the canvas would never fire on a view
        // that is gone: what it owed is written now.
        .onDisappear { flushNow() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("api.pane")
        // 9a: a field is let go once the draft holds what it shows (`apiHeldAfterLanding`).
        .onChange(of: snapshot.request) { _, now in
            held = apiHeldAfterLanding(
                now, held: held, focused: focusedIn?.box, takenOver: takenOver, queued: queued)
            if held[ApiFieldRow(.path)] == nil { pathRefusal = nil }
        }
        .onChange(of: held) { _, now in takenOver = apiTakenOverSettled(takenOver, held: now) }
        .onChange(of: sendRequest) { _, now in
            if now != nil { press(fromKeyboard: false) }
        }
        // 11a: a new fill line — an agent's, or the operator's — forgets the pane's own line,
        // which was about the draft the fill replaced.
        .onChange(of: snapshot.fillLine) { old, now in
            bindLine = apiBindLineAfterFill(bindLine, from: old, to: now)
        }
        // A SwiftUI box (the content type, a name box) that loses the cursor without seeing it
        // go: it was removed with its row. Its own `onChange` then never reports, and the mark
        // would stick. The tracker ignores a loss from a box that no longer holds the cursor,
        // so the box's own report and this one release once between them.
        .onChange(of: focusedBox) { old, now in
            if let old, old != now { focusLost(old) }
        }
        // Only a grid row is accepted — `ApiDragPayload`'s type is Wakil's own — so
        // nothing else dragged over the pane draws the outline or lands.
        .dropDestination(for: ApiDragPayload.self) { items, _ in
            guard let picked = items.first else { return false }
            drop(picked)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            // **At the pane's own edge weight, and flat** — not a second luminous element,
            // which §8 forbids. The canvas draws no focus ring to borrow from (the system's
            // is disabled throughout, `DataSurface`'s `.focusEffectDisabled()`), so this is
            // the slab's half-pixel edge doubled and lifted, which reads as "here" without
            // glowing.
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(ink.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The request half (W10): everything that composes and sends, scrolling on its own.
    var requestHalf: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    methodLine
                    urlBox
                    if let refusal = pathRefusal {
                        // No identifier: a line is read, not pressed.
                        Text(refusal).foregroundStyle(amber).wraps()
                    }
                }
                // Wire order — path, query, headers, body — here as in the
                // JSON and as in the bytes. The surface reads in the order
                // the request leaves. The path is the URL box's own, which
                // is where #109 put it.
                queryRegion
                headerRegion
                bodyRegion
                boundValues
                VStack(alignment: .leading, spacing: 6) {
                    resultLine
                    sendControl
                    // W1 (plan B preflight P18): "pick an entry first" stays under Send.
                    sendRefusalLine
                    unfilledLine
                }
            }
            // Room for the overlay scroller, so it never sits on a value.
            .padding(.trailing, 10)
            // Re-walk #1b: padded by the fade's length at both ends, so at rest only padding
            // sits under it and a cut line is what fades.
            .padding(.vertical, CGFloat(apiScrollEdgeFade))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .edgeFade()
    }

    // MARK: - The operator's dispatches

    /// Every dispatch this pane makes: the operator editing the draft or sending it, as one
    /// ordered sequence.
    ///
    /// **It clears the drop's result line once its batch builds calls, and it is the one door**
    /// (spec §2: the line is "cleared by the operator's next edit or send"). The line describes
    /// the draft as the drop left it — "Filled 1" beside a hole the operator just unbound is a
    /// line about a request that no longer exists. Every control here edits or sends, so the
    /// ruling is structural rather than a list of action names: `dispatchInOrder` is private
    /// and nothing else calls it. The drop does not come through here — it goes through `bind`,
    /// and SETS the line. It moves `bindGeneration` up to its own `issued` number, once, for
    /// the one gesture the sequence is.
    ///
    /// `build` makes the batch **when its turn comes on the chain** (round 4), from the stored
    /// snapshot and the fields as they then are. Its `written` is the flush's fields among its
    /// calls (`ApiHeldFlush.written`): held in `queued` until THIS dispatch completes, whatever
    /// its outcome (preflight F23). A batch that builds no calls is no edit, and leaves the line.
    ///
    /// `carried` is the fields a gesture among the calls took over (`takenOver`), each with its
    /// gesture's token. When THIS dispatch completes, still on the chain and before the next
    /// batch is built, `apiGestureSettled` settles them by its outcome. If it landed, they are
    /// let go. If it was refused, they owe their write again, and the pause is started for it.
    func operateInOrder(
        carrying carried: [ApiFieldRow: ApiHeldTakeover] = [:],
        _ build: @escaping @MainActor (ApiSnapshot) -> ApiPaneBatch
    ) {
        issued += 1
        let number = issued
        let written = ApiPaneWritten()
        dispatchInOrder({ now in
            let batch = build(now)
            if !batch.calls.isEmpty {
                bindGeneration = max(bindGeneration, number)
                bindLine = nil
            }
            written.held = batch.written
            queued.merge(batch.written) { _, dispatched in dispatched }
            return batch.calls
        }, { landed in
            queued = apiQueuedSettled(queued, written: written.held)
            guard !carried.isEmpty else { return }
            let settled = apiGestureSettled(
                takenOver: takenOver, held: held, carried: carried, landed: landed)
            takenOver = settled.takenOver
            held = settled.held
            // Refused or failed, a carried field survives owing its write, and the gesture
            // cancelled the pause that would have written it: start it again (final review,
            // Minor 4).
            if settled.owed { keystroke() }
        })
    }

    /// The request as the screen shows it, with every held field applied. Every gesture is
    /// built on this.
    var applied: ApiRequestSnapshot {
        apiRequestApplying(snapshot.request, held: held)
    }

    /// A keystroke: the write lands `apiTypingPause` after the LAST one.
    func keystroke() {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor in
            try? await Task.sleep(for: apiTypingPause)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// Writes, at once, whatever the editors hold that the draft does not. Return, focus out, the
    /// end of a pause. **`operateFlushed` with no gesture after it** (preflight F14b).
    func flush() { operateFlushed([]) }

    /// The last flush, **only as the pane leaves the canvas.** A view SwiftUI has removed may no
    /// longer read its own state by the time its batch's turn comes, so what it owes is CAPTURED
    /// now — and the flush is still BUILT at its turn, on the draft every call queued before it
    /// left (Task 4 carry). Built now, on the draft as it stood, it could revert a gesture still
    /// on the chain: a body holding a bound value whose unbind is in flight would write the
    /// binding back after it (`theLastFlushIsBuiltAtItsTurnNeverBeforeAGestureLands`).
    private func flushNow() {
        pendingWrite?.cancel()
        pendingWrite = nil
        let held = held
        let queued = queued
        let takenOver = takenOver
        let pane = pane.id
        operateInOrder { now in
            let flush = apiFlush(
                now.request, held: held, pane: pane, queued: queued, takenOver: takenOver)
            return ApiPaneBatch(calls: flush.writes, written: flush.written)
        }
    }

    /// A gesture that reads or rewrites the draft: the flush, then `calls`, as one ordered
    /// sequence. The caller builds `calls` against `applied`, or carries its own field's parts.
    /// The flush's refusal, if the path view cannot be parsed, is drawn under the URL.
    ///
    /// `takingOver` is the field whose held parts `calls` carries (Format's body). It is taken
    /// over now, under a token of its own, so the flush leaves it to the gesture, and it is
    /// settled by this dispatch's outcome (`apiGestureSettled`).
    ///
    /// **The flush is built at the batch's turn** (round 4), on the draft everything before it
    /// left and the fields as they then are. `calls` are the gesture's, built now on what the
    /// screen shows.
    ///
    /// `afterFlush` runs at that turn, once the flush is built: what a gesture lets go of (a
    /// removed row's fields) is let go only after the flush has written it, never before.
    func operateFlushed(
        _ calls: [(String, JSONValue)], takingOver box: ApiFieldRow? = nil,
        afterFlush: (@MainActor () -> Void)? = nil
    ) {
        pendingWrite?.cancel()
        pendingWrite = nil
        var carried: [ApiFieldRow: ApiHeldTakeover] = [:]
        if let box, let parts = held[box] {
            takeovers += 1
            let entry = ApiHeldTakeover(held: parts, token: takeovers)
            carried[box] = entry
            takenOver[box] = entry
        }
        operateInOrder(carrying: carried) { now in
            let flush = apiFlush(
                now.request, held: held, pane: pane.id, queued: queued, takenOver: takenOver)
            pathRefusal = flush.refusals[ApiFieldRow(.path)]
            afterFlush?()
            return ApiPaneBatch(calls: flush.writes + calls, written: flush.written)
        }
    }

    // MARK: - The drop

    /// Lands one picked-up row: binds it if it is still the row it was, and says what
    /// happened either way.
    ///
    /// **Whether the row moved is `apiDropRow`'s ruling**, and a moved row dispatches
    /// nothing — binding whatever now sits at that index is the guess `api_bind`'s own
    /// description forbids.
    ///
    /// **The fields are flushed first** (9a): `WindowModel.bindFromSurface` waits for the chain,
    /// so the drop lands on a draft that already holds what was typed, and nothing is lost.
    private func drop(_ picked: ApiDragPayload) {
        guard let row = apiDropRow(picked, current: sourceRows(picked.pane)) else {
            bindLine = apiDropMovedLine
            return
        }
        flush()
        issued += 1
        let generation = issued
        bindGeneration = generation
        Task { @MainActor in
            let line = apiBindSummary(await bind(picked.pane, row))
            // Something moved while the bind was in flight — an edit, a send, a later drop:
            // this result is about a draft that is no longer the one on screen.
            guard bindGeneration == generation else { return }
            bindLine = line
        }
    }

    // MARK: - The cURL fill (Amendment 11a)

    /// The path's `curl …` paste. The fields are flushed first, so the fill lands after what was
    /// typed (`fillFromCurlSurface` waits on the chain). No dialog, the pane stays put: a fill
    /// draws its line from the snapshot (`fillLine`), with **Undo**; a refusal draws here, amber,
    /// under any fill line still showing (`apiPaneResultLines`).
    func pasteCurl(_ text: String) {
        flush()
        issued += 1
        let generation = issued
        bindGeneration = generation
        Task { @MainActor in
            let outcome = await fillFromCurl(text)
            guard bindGeneration == generation else { return }
            guard case .result = outcome else {
                bindLine = apiCurlFillSummary(outcome)
                return
            }
            // The snapshot carries the fill's line; the pane's own line no longer applies.
            bindLine = nil
            // The typing the fill replaced was written by the flush above; the editors draw
            // the filled draft.
            held = [:]
            // Rule 3: the path editor's caret goes to its end on the update that carries the
            // fill — the surface door returned after the snapshot was published.
            fillCaret += 1
        }
    }

    /// The fill line's **Undo**: `api_undo_fill`. **Flushed first**, like the paste: anything
    /// typed since the fill lands before it (and forgets the fill, so Undo is then refused in
    /// amber) rather than writing over the restored draft after it. A refusal is drawn in amber
    /// under the fill line; a success draws nothing here — the snapshot clears the fill's line.
    func undoCurlFill() {
        flush()
        issued += 1
        let generation = issued
        bindGeneration = generation
        Task { @MainActor in
            let outcome = await undoFill()
            guard bindGeneration == generation else { return }
            if case .refused(let message) = outcome {
                bindLine = ApiBindLine(text: message, caution: true)
            } else {
                bindLine = nil
            }
        }
    }

    /// The pane's result line (spec §2), as `apiPaneResultLines` rules: a fill's
    /// (`ApiSnapshot.fillLine`, quiet ink, with **Undo** while `fillUndoable`) — the operator's
    /// paste or an agent's fill alike — and under it the pane's own (`bindLine`): the drop's, or a
    /// refused paste's or Undo's, in amber when it is caution, quiet ink otherwise.
    @ViewBuilder private var resultLine: some View {
        let lines = apiPaneResultLines(
            fill: snapshot.fillLine, undoable: snapshot.fillUndoable, bind: bindLine)
        if lines.fill != nil || lines.below != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let fill = lines.fill {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // **No identifier** on a line: it is read, not pressed.
                        Text(fill)
                            .foregroundStyle(ink.opacity(0.7))
                            .wraps()
                        if lines.undo {
                            Button("Undo") { undoCurlFill() }
                                .buttonStyle(.plain)
                                .foregroundStyle(ink)
                                .accessibilityIdentifier("api.fill.undo")
                        }
                    }
                }
                if let line = lines.below {
                    // **No identifier**: identifiers go only on elements with an accessibility
                    // action, and a line is read, not pressed. Checks read it by its words.
                    Text(line.text)
                        .foregroundStyle(line.caution ? amber : ink.opacity(0.7))
                        .wraps()
                }
            }
        }
    }
}

/// One batch of `ApiPane`'s calls, as its builder makes it at the batch's turn on the chain:
/// the calls, and the flush's fields among them (`ApiHeldFlush.written`).
struct ApiPaneBatch {
    var calls: [(String, JSONValue)]
    var written: ApiHeld = [:]
}

/// What one batch's builder wrote, read back by its `settled` once the batch has run. A class,
/// so the two closures share it.
@MainActor private final class ApiPaneWritten {
    var held: ApiHeld = [:]
}
