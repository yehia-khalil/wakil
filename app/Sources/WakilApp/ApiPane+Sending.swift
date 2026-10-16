import AppKit
import WakilKit
import SwiftUI

extension ApiPane {
    // MARK: - Send

    /// The control that puts the request on the wire.
    ///
    /// **Which action it presses is `apiSendControl`'s**, not this view's:
    /// `WakilApp` has no test target, and routing a `GET` to `api_send`
    /// would price a read at the gate while routing a `POST` to
    /// `api_request` would let a write past one.
    ///
    /// **A `Button`, so the identifier sits on something `AXPress` can
    /// reach.** `Landing.swift:265` states the rule this follows: a tap
    /// gesture is not an accessibility action, so an identifier on one
    /// announces a button that does nothing when activated.
    ///
    /// **It is not disabled for an unready draft.** A request with an
    /// unfilled hole refuses when sent, aggregating every reason at once —
    /// and that refusal is how the operator learns what is missing. A
    /// greyed button that says nothing teaches less than a press that
    /// answers.
    ///
    /// **While a send is in flight it is Cancel, counting** (W14). The label and the press are
    /// `apiSendControl`'s and `apiSendPress`'s rulings (preflight F9). Redrawn ten times a second
    /// only while in flight (F22, accepted); **the identifier never changes**, only the label, so
    /// the harness can press the same element to cancel that it pressed to send.
    var sendControl: some View {
        TimelineView(.periodic(from: .now, by: snapshot.sending == nil ? 3600 : 0.1)) { context in
            let control = apiSendControl(
                method: snapshot.request.method, sending: snapshot.sending, now: context.date)
            // `FormButton`'s filled look, in violet: the one primary action on the surface.
            FormButton(
                title: control.label, tone: SettingsPalette.accent, filled: true,
                identifier: "api.send"
            ) { press(fromKeyboard: false) }
        }
    }

    /// Send's press, and ⌘Return's: what `apiSendPress` rules. **Cancel flushes nothing** — it
    /// ends a send, it does not read the draft — and is awaited on the chain, which a send never
    /// holds (`apiSurfaceCallDetaches`), so it is not queued behind the send it ends.
    func press(fromKeyboard: Bool) {
        switch apiSendPress(pane: pane.id, sending: snapshot.sending, fromKeyboard: fromKeyboard) {
        case .send: send()
        case .dispatch(let name, let params):
            operateInOrder { _ in ApiPaneBatch(calls: [(name, params)]) }
        case .nothing: break
        }
    }

    /// Send, and ⌘Return in the body: every held field flushed, then the send (`apiSendPlan`),
    /// as one ordered sequence (9a; B5) — what the editors show is what the operator means to
    /// send.
    /// **A path the flush cannot parse sends nothing, and says so** under the URL: the flush's
    /// refusal is drawn, never swallowed. Reached only through `press`.
    ///
    /// **The plan is built when Send's turn comes on the chain** (round 4), never at the press:
    /// `api_send` sends the stored draft, so the flush, `api_send` or `api_request`, and the
    /// statement the confirmation plane reads back are all built on the draft every gesture
    /// queued before it left. The statement and the wire come from one draft.
    func send() {
        pendingWrite?.cancel()
        pendingWrite = nil
        operateInOrder { now in
            // Every write precedes the send, and the send's statement is built on the draft with
            // every held field applied (`apiSendPlan`).
            let plan = apiSendPlan(
                draft: now.request, pane: pane.id, held: held, queued: queued,
                unpointed: apiPaneIsUnpointed(entry: now.entry, entries: now.entries),
                takenOver: takenOver)
            pathRefusal = plan.refusals[ApiFieldRow(.path)]
            sendRefusal = plan.refusal
            // Refused, nothing is dispatched, so nothing is queued either (the written side
            // gated as the calls are).
            let refused = !plan.refusals.isEmpty
            return ApiPaneBatch(calls: refused ? [] : plan.calls, written: refused ? [:] : plan.written)
        }
    }

    /// Under Send, in amber: Send's own refusal, while it still holds — "pick an entry first"
    /// goes the moment an entry is chosen.
    @ViewBuilder var sendRefusalLine: some View {
        if let line = sendRefusal, apiPaneIsUnpointed(entry: snapshot.entry, entries: snapshot.entries) {
            // No identifier: a line is read, not pressed.
            Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(amber)
                .wraps()
        }
    }

    /// Under Send, in amber, while the draft holds an unfilled hole: how many, and what fills
    /// them (`apiUnfilledHolesLine`). **Nothing is drawn at none.** It says the request is not
    /// ready BEFORE Send is pressed; Send still answers with its own refusal, naming each.
    @ViewBuilder var unfilledLine: some View {
        if let line = apiUnfilledHolesLine(snapshot.request) {
            // No identifier: a line is read, not pressed.
            Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(amber)
                .wraps()
        }
    }

    // MARK: - The bound-values strip

    /// The cross-cutting index of every value bound into the request.
    ///
    /// **Below all four regions, because that is what it is** (#112). A
    /// bound value belongs to no single region — the same drop fills holes
    /// in the path and the body at once — so drawing the strip inside one
    /// of them would make it read as that region's property.
    ///
    /// **Absent when there is nothing bound, unlike a region.** A region
    /// is always present because it is a place to put the first row; this
    /// is an index of what exists, and an index of nothing is chrome.
    ///
    /// **What it does NOT say is a ruling, not an omission.** No age, no
    /// clock and no expiry for a captured value (#137 ruling 3) — a number
    /// Wakil cannot stand behind would read as a guarantee about freshness
    /// that nothing checks — and no pane id, because the operator knows
    /// the grid rather than its id.
    ///
    /// The rows are `snapshot.bound` — `apiBoundValues` resolved in `WakilKit` against the
    /// panes on screen at every snapshot (W18), on `apiChooserIsEnabled`'s own precedent: which
    /// values appear and what each says are rulings, and `WakilApp` has no test target to hold
    /// one. Each is drawn as `apiBoundLine` says.
    @ViewBuilder var boundValues: some View {
        let rows = snapshot.bound
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                micro("BOUND")
                let lines = apiBoundLines(rows)
                ForEach(Array(rows.enumerated()), id: \.offset) { row in
                    // W18: `id = 3 · live · events.customers`, monospace, the pane's ink.
                    Text(lines[row.offset])
                        .foregroundStyle(ink.opacity(row.element.value == nil ? 0.45 : 0.70))
                        .wraps()
                }
            }
        }
    }

    // MARK: - The past tense

    /// The strip of sends that had an outcome.
    ///
    /// **Rows, never bodies** (#195) — and never the URL either: the pane
    /// above already names its own entry and origin, so repeating the
    /// host on every row buries the path that tells them apart. Recent is
    /// shared by every pane of the environment (W15), so a row sent to
    /// another entry names that entry first (`apiRecentRowLabel`'s
    /// `paneEntry`), and its Reopen re-points this pane at it.
    ///
    /// **Folded behind a count, and the count is always drawn.** What the
    /// fold hides is the rows; that there ARE rows is never hidden, which
    /// is the same reason a region draws at zero.
    ///
    /// **Each row reopens or copies — the two things a past send is
    /// for.** Reopening puts its whole draft back, and always lands, even
    /// under the operator's hand: it is their own gesture off their own
    /// screen, which is the one exception to Decision 27 in this pane.
    ///
    /// `shown` is how many rows are drawn (`apiRecentShownRows`, re-walk #1c): the body keeps
    /// its lines first, six at most, and the operator's unfold always takes at least one row.
    @ViewBuilder func recentStrip(rows shown: Int) -> some View {
        let rows = snapshot.recent
        VStack(alignment: .leading, spacing: 5) {
            // **The heading is text and the fold is a button beside
            // it.** With the summary inside a DISABLED button, an empty
            // strip put "none yet" nowhere the accessibility tree could
            // see it — the e2e said so: `the tree does not contain "none
            // yet" (43 elements were visible)`. What the strip says about
            // itself must be readable whether or not there is anything to
            // unfold.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                micro("RECENT")
                Text(apiRecentSummary(count: rows.count, truncated: snapshot.recentTruncated))
                    .foregroundStyle(ink.opacity(0.35))
                if !rows.isEmpty {
                    Button(recentUnfolded ? "▾" : "▸") { recentUnfolded.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(ink.opacity(0.55))
                        .accessibilityIdentifier("api.recent")
                }
            }

            // W11: unfolded, the rows sit in a strip at most `apiRecentStripMaxRows` tall,
            // scrolling within, and each row is one line — and only as many as leave the body
            // its six lines (re-walk #1c).
            if shown > 0 {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { entry in
                            HStack(spacing: 12) {
                                Text(apiRecentRowLabel(entry.element, paneEntry: snapshot.entry))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(ink.opacity(0.70))
                                Spacer(minLength: 8)
                                Button("Reopen") {
                                    // The flush first (9a), then the past draft replaces the
                                    // whole present one. Every held field goes with it: kept, it
                                    // would read as an owed write against the reopened draft
                                    // and write itself back.
                                    operateFlushed([(
                                        "api_reopen",
                                        .object([
                                            "pane": .string(pane.id),
                                            "row": .string(entry.element.id),
                                        ]))])
                                    held = [:]
                                    pathRefusal = nil
                                    formatRefusedBody = nil
                                }
                                .buttonStyle(.plain)
                                .modifier(Verb(heading: false, enabled: true))
                                // The label truncates first; a verb is never cut.
                                .fixedSize()
                                .accessibilityIdentifier("api.recent.\(entry.offset).reopen")
                                Button("Copy as cURL") {
                                    // **Composed here and copied here**, on
                                    // `TerminalPane.copyBlock`'s precedent: the
                                    // line is `apiRenderCurl`'s either way, and
                                    // the agent's `api_render_curl` and this
                                    // button differ only in where the text lands
                                    // — one returns it, one puts it on the
                                    // pasteboard. Dispatching to fetch a string
                                    // the view can already compute would be a
                                    // round trip for nothing.
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(
                                        apiRenderCurl(
                                            row: entry.element,
                                            url: entry.element.sentUrl ?? entry.element.path,
                                            credentialed: entry.element.credentialed),
                                        forType: .string)
                                }
                                .buttonStyle(.plain)
                                .modifier(Verb(heading: false, enabled: true))
                                // The label truncates first; a verb is never cut.
                                .fixedSize()
                                .accessibilityIdentifier("api.recent.\(entry.offset).curl")
                            }
                            .frame(height: recentRowHeight)
                        }
                    }
                    // Room for the overlay scroller, so it never sits on a button.
                    .padding(.trailing, 10)
                }
                .frame(height: CGFloat(shown) * recentRowHeight)
            }
        }
    }

    /// One Recent row's height, in points — drawing, not a ruling: the cap in rows is
    /// `apiRecentStripMaxRows`.
    var recentRowHeight: CGFloat { 22 }

    // MARK: - The response

    /// The response half (W10, W11): the head pinned, the body scrolling below it when the half
    /// has a height to scroll in, and Recent at its foot.
    ///
    /// The response is the bottom of the request's own surface — always present, never a pane
    /// of its own, below the split's hairline. **Branching here is safe** (plan B preflight
    /// P17): no box lives in this half, so rebuilding it loses no cursor.
    func responseHalf(scrolls: Bool, height: Double?) -> some View {
        // The body's own lines, measured (review I1): it keeps that many, six at most.
        let bodyLines = Int((Double(responseBodyHeight) / Self.bodyLineHeight).rounded(.up))
        let rows = apiRecentShownRows(
            count: snapshot.recent.count, unfolded: recentUnfolded,
            bodyRoom: responseBodyRoom(height), bodyLines: bodyLines,
            rowHeight: Double(recentRowHeight), lineHeight: Self.bodyLineHeight)
        return VStack(alignment: .leading, spacing: 0) {
            divider
            VStack(alignment: .leading, spacing: 8) {
                // Measured as ONE view (review I2): `responseHead` is several children, and a
                // background on it would measure each and keep the tallest.
                VStack(alignment: .leading, spacing: 8) { responseHead }
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ApiHeadHeightKey.self, value: geometry.size.height)
                    })
                if scrolls {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) { responseBody }
                            // The body's own height, which depends on the width alone — never on
                            // Recent — so measuring it cannot feed back.
                            .background(GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ApiBodyHeightKey.self, value: geometry.size.height)
                            })
                            // Room for the overlay scroller, so it never sits on the body.
                            .padding(.trailing, 10)
                            // Re-walk #1b: a line sliced under the pinned head fades there.
                            .padding(.vertical, CGFloat(apiScrollEdgeFade))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .edgeFade()
                    .frame(maxHeight: .infinity)
                } else {
                    responseBody
                }
            }
            divider
            recentStrip(rows: rows)
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onPreferenceChange(ApiHeadHeightKey.self) { responseHeadHeight = $0 }
        .onPreferenceChange(ApiBodyHeightKey.self) { responseBodyHeight = $0 }
    }

    /// One line of the response body, in points — the 12pt monospaced face this pane draws in.
    static let bodyLineHeight = 15.0

    /// What the body and Recent's rows share in a half `height` tall, once the head, the two
    /// dividers, the head's spacing, the body's fade padding (both ends, review I2) and Recent's
    /// header line are drawn; `nil` when the half is drawn at its own height
    /// (`apiRecentShownRows`).
    func responseBodyRoom(_ height: Double?) -> Double? {
        guard let height else { return nil }
        let dividers = 2 * (ApiPaneDivider.weight + 2 * ApiPaneDivider.spacing)
        let recentHeader = 16.0 + 5.0
        return height - Double(responseHeadHeight) - 8 - dividers - 2 * apiScrollEdgeFade
            - recentHeader - 4
    }

    /// The split's divider (re-walk #1a): a full-width hairline a person can see, with room
    /// either side. Spacing and a line, never a border (§1).
    var divider: some View {
        Rectangle()
            .fill(SettingsPalette.coolWhite.opacity(ApiPaneDivider.opacity))
            .frame(height: CGFloat(ApiPaneDivider.weight))
            .frame(maxWidth: .infinity)
            .padding(.vertical, CGFloat(ApiPaneDivider.spacing))
            .accessibilityHidden(true)
    }

    /// What stays pinned: the status chip, timing and size, the URL, and the one-line states
    /// whole. With `state` of `none` it says so plainly: a pane that has sent nothing is not a
    /// pane that failed.
    ///
    /// **The status is a chip in a reserved hue, and the body carries none** (§5: the three
    /// are spent on the status alone). What went wrong is a property of the reply, not of the
    /// document it returned — colouring the body would make a 500's JSON look different from
    /// a 200's identical JSON. Which hue is `apiStatusTone`'s.
    @ViewBuilder var responseHead: some View {
        switch snapshot.response {
        case .none:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                micro("RESPONSE")
                // A pane that has sent nothing is not a pane that failed.
                Text("nothing sent yet").foregroundStyle(ink.opacity(0.35))
            }

        case .cleared(let environment):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                micro("RESPONSE")
                Text("cleared — the environment is now \(environment)")
                    .foregroundStyle(ink.opacity(0.35))
                    .wraps()
            }

        case .cancelled(let cancelled):
            // W14: a cancelled READ. A cancelled mutation is `.unknown`, drawn below.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                micro("RESPONSE")
                Text(apiCancelledLine(waitedMs: cancelled.waitedMs))
                    .foregroundStyle(ink.opacity(0.45))
                    .wraps()
            }

        case .ok(let reply):
            responseHeading(chip: "\(reply.status)", tone: snapshot.response) {
                HStack(spacing: 12) {
                    if apiResponseOffersHeaders(snapshot.response) {
                        SegmentedChoice(
                            options: ApiResponseShows.allCases.map(\.rawValue),
                            selection: Binding(
                                get: { responseShows.rawValue },
                                set: { responseShows = ApiResponseShows(rawValue: $0) ?? .body }),
                            identifier: { label in
                                let key = ApiResponseShows(rawValue: label)?.key ?? label
                                return "api.response.\(key)"
                            })
                    }
                    Text("\(reply.durationMs) ms · \(reply.byteCount) bytes")
                        .foregroundStyle(ink.opacity(0.45))
                }
            }
            Text(reply.url).foregroundStyle(ink.opacity(0.45)).wraps()
            if reply.truncated {
                // A short body and a cut one must never look alike.
                Text("truncated").foregroundStyle(amber)
            }

        case .transport(let failure):
            // No status, no headers, no body: there was no reply to
            // take them from. The operator's first question is how far
            // it got, so the stage leads.
            responseHeading(chip: "\(failure.stage) failed", tone: snapshot.response) {
                Text("after \(failure.waitedMs) ms")
            }

        case .unknown:
            responseHeading(chip: "fate unknown", tone: snapshot.response) { EmptyView() }

        case .refusal:
            // **A refusal is not a response**, and it draws no status chip,
            // no timing and no size — the type does not carry them.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                micro("RESPONSE")
                Text("not sent").foregroundStyle(amber)
            }
        }
    }

    /// What scrolls: the reply's body, a failure's reason, a refusal's lines.
    @ViewBuilder var responseBody: some View {
        switch snapshot.response {
        case .ok(let reply):
            switch responseShows {
            case .body:
                if !reply.body.isEmpty {
                    // **Text, refused the grid** — a surface that cannot
                    // sort, filter or page must not look like one that can.
                    Text(reply.body)
                        .foregroundStyle(ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .headers:
                responseHeaders(reply)
            }
        case .transport(let failure):
            Text(failure.reason).foregroundStyle(ink.opacity(0.50)).wraps()
        case .unknown(let record):
            Text(record.reason).foregroundStyle(ink.opacity(0.50)).wraps()
        case .refusal(let refusal):
            // Every failure at once, so fixing the request is one pass.
            ForEach(Array(refusal.failures.enumerated()), id: \.offset) { failure in
                Text(apiFailureLine(failure.element))
                    .foregroundStyle(ink.opacity(0.50))
                    .wraps()
            }
        case .none, .cleared, .cancelled:
            EmptyView()
        }
    }

    /// W20: `HEADER | VALUE`, in the request tables' style. Names in byte order (the wire carries
    /// a map), values wrapping, no hue. A reply with none draws one quiet line instead of a
    /// table with nothing under it (`apiResponseHeadersEmptyLine`).
    @ViewBuilder
    func responseHeaders(_ reply: ApiResponseOK) -> some View {
        if let line = apiResponseHeadersEmptyLine(reply) {
            Text(line).foregroundStyle(ink.opacity(0.35)).wraps()
        } else {
            responseHeaderTable(reply)
        }
    }

    func responseHeaderTable(_ reply: ApiResponseOK) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ApiRowColumns {
                micro("HEADER")
                micro("VALUE")
                Color.clear.frame(width: 0, height: 0)
            }
            .padding(.vertical, 5)
            hairline(0.08)
            ForEach(Array(apiResponseHeaderRows(reply).enumerated()), id: \.offset) { row in
                ApiRowColumns {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.element.name).foregroundStyle(ink.opacity(0.55)).wraps()
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.element.value).foregroundStyle(ink.opacity(0.85)).wraps()
                    }
                    Color.clear.frame(width: 0, height: 0)
                }
                .padding(.vertical, 6)
                hairline(0.05)
            }
        }
    }

    /// `RESPONSE`, the status chip, and the measurements right-aligned in mono at low opacity.
    func responseHeading(
        chip: String, tone response: ApiResponseSnapshot,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            micro("RESPONSE")
            Chip(text: chip, tone: toneColor(apiStatusTone(response)))
            Spacer(minLength: 8)
            trailing()
                .foregroundStyle(ink.opacity(0.45))
        }
    }

    /// `apiStatusTone`'s meaning as §5's hue. `nil` never reaches a chip — the states without a
    /// tone draw none — and is the pane's quiet ink if it ever did.
    func toneColor(_ tone: ApiStatusTone?) -> Color {
        switch tone {
        case .healthy: return green
        case .caution: return amber
        case .failed: return red
        case nil: return ink.opacity(0.60)
        }
    }
}


/// The response body's measured content height (review I1): how many lines it keeps.
struct ApiBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The response head's measured height (re-walk #1c).
struct ApiHeadHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Re-walk #1b: the scroll region fades over `apiScrollEdgeFade` points at its top and bottom
    /// edges — a mask on the container, never a shadow on the data (§8). The content inside is
    /// padded by the same length, so only a cut line is ever faded.
    func edgeFade() -> some View {
        mask {
            GeometryReader { geometry in
                let fade = min(CGFloat(apiScrollEdgeFade), geometry.size.height / 4)
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: fade)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: fade)
                }
            }
        }
    }
}
