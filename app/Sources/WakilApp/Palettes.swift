import AppKit
import WakilKit
import SwiftUI

// MARK: - One palette's life

/// One open palette, from ⌘P or ⌘K to its close: the `PaletteModel` it drives and the window
/// calls each key turns into. **Made per open and dropped on close**, so a reopen is fresh
/// (`PaletteModel`'s own rule) and nothing it started can land in the next one — except the
/// window's recents, seeded at open and kept back after every run, pop and close.
///
/// Everything here is plumbing between `PaletteModel` (pure, tested) and `WindowModel`'s four
/// palette calls (tested): which list to ask for when the mode changes, which in-flight key a
/// run finishes under, when to close and what gets the keyboard back. `WakilApp` has no test
/// target, so this stays as thin as that list.
@MainActor @Observable
final class PaletteController {
    let model: WindowModel
    private(set) var palette: PaletteModel
    private(set) var closed = false

    /// Called once, on close. The window drops this controller and the plane with it.
    @ObservationIgnored var onClose: () -> Void = {}

    /// The mode whose root list was last asked for, and which ask is the current one: a list
    /// that lands for a mode the palette has left, or for an older ask, is dropped.
    @ObservationIgnored private var loadedMode: PaletteMode?
    @ObservationIgnored private var loadSerial = 0

    /// The generation of the root rows on screen (`WindowModel.PaletteRoot`): a root row's run
    /// names it, so it is checked against where those rows were read, not where a refresh still
    /// loading is reading.
    @ObservationIgnored private var shownGeneration: Int?

    /// `WindowModel.paletteEpoch` at open: recents typed here are kept only while it holds.
    @ObservationIgnored private let recentsEpoch: Int

    /// What held the keyboard when the palette opened, handed back on a close that moved it
    /// nowhere else (rule 6: stay where the operator was). `holder` says whether that was a real
    /// AppKit view or a SwiftUI focusable behind the hosting view (`PaletteFocusReturn`).
    @ObservationIgnored private let previous = ResponderBox()
    @ObservationIgnored private let holder: PaletteFocusReturn.Holder
    @ObservationIgnored private let focusRequestsAtOpen: Int

    init(model: WindowModel, mode: PaletteMode) {
        self.model = model
        palette = model.makePalette(mode: mode)
        recentsEpoch = model.paletteEpoch
        focusRequestsAtOpen = model.keyboardFocusRequests
        let window = NSApp.keyWindow
        previous.value = window?.firstResponder
        holder = ResponderBox.holder(window?.firstResponder, in: window)
        model.paletteOpened()
    }

    // MARK: Keys

    func type(_ text: String) {
        guard !closed else { return }
        palette.type(text)
        syncRoot()
        syncTickets()
    }

    /// Open mode's ticket rows follow the line: the last read's at once, and a fresh read's when a `#`
    /// or key-shaped line asked for one (`WindowModel.paletteTicketsTyped`).
    private func syncTickets() {
        guard palette.steps.isEmpty, palette.mode == .open else { return }
        let line = palette.line
        palette.replaceTickets(model.paletteTicketsTyped(line: line) { [weak self] rows in
            guard let self, !self.closed, self.palette.mode == .open, self.palette.line == line else { return }
            self.palette.replaceTickets(rows)
        })
    }

    func move(_ delta: Int) {
        guard !closed else { return }
        palette.move(delta)
    }

    /// ⌘P / ⌘K while open.
    func modeKey(_ mode: PaletteMode) {
        guard !closed else { return }
        palette.modeKey(mode)
        syncRoot()
        syncTickets()
    }

    /// A click on a row: select it, then Return.
    func choose(_ index: Int) {
        guard !closed else { return }
        palette.move(index - palette.selection)
        confirm()
    }

    /// Return. The selected row's id is read **before** `confirm()`, which may push a step and
    /// change what is selected: a root or drill row's run is in flight under its own id, a
    /// step's run under the step's `commandId` (`PaletteModel.inFlight`).
    func confirm() {
        guard !closed else { return }
        let selectedId = palette.selected?.id ?? ""
        guard let effect = palette.confirm() else { return }
        switch effect {
        case .needChoices(let commandId):
            Task {
                let rows = await model.paletteChoices(for: commandId)
                guard !closed else { return }
                palette.provideChoices(rows, for: commandId)
            }
        case .close:
            close()
        case .run:
            run(effect, inFlight: selectedId)
        case .runCommand(let commandId, _):
            keepRecents()
            run(effect, inFlight: commandId)
        }
    }

    /// ⌘↩: the selected row's alternate — a ticket handed to an agent. Answers whether there was one,
    /// so ⌘↩ on any other row is left to whatever else wants it.
    @discardableResult
    func confirmAlternate() -> Bool {
        guard !closed else { return false }
        let selectedId = palette.selected?.id ?? ""
        guard let effect = palette.confirmAlternate() else { return false }
        run(effect, inFlight: selectedId)
        return true
    }

    /// Esc: one step back, or closed at the root. A popped text step's line is kept as a recent.
    func escape() {
        guard !closed else { return }
        if palette.escape() == .close { close() } else { keepRecents() }
    }

    private func keepRecents() {
        model.keepPaletteRecents(palette.recents, openedAt: recentsEpoch)
    }

    // MARK: Lists

    /// Asks for the root list when the mode it holds is not the mode showing — on open, on
    /// ⌘P/⌘K while open, and when a leading `>` switches modes.
    func syncRoot() {
        guard !closed, palette.mode != loadedMode else { return }
        load()
    }

    /// The window moved while the palette is open — a pane opened or closed, focus moved, the
    /// project or environment switched: the current mode's list is read again and reaches
    /// `PaletteModel.contextChanged`, which keeps the selection on its row and drops a step whose
    /// command left the list. WindowModel's generation drops whatever an older read delivers.
    func refresh() {
        guard !closed else { return }
        load()
    }

    /// Asks for the current mode's root list. The rows on screen stay until it lands, so a
    /// mode switch never flashes "No results" on the way.
    private func load() {
        let mode = palette.mode
        loadedMode = mode
        loadSerial += 1
        let serial = loadSerial
        Task {
            // Held strongly, briefly: `WindowModel` stops delivering once `paletteClosed()` bumps
            // its generation, and `landed` drops anything after a close.
            let root = await model.paletteRoot(mode: mode, line: palette.line) { late in
                Task { @MainActor in self.landed(late, mode: mode, serial: serial) }
            }
            landed(root, mode: mode, serial: serial)
        }
    }

    private func landed(_ root: WindowModel.PaletteRoot, mode: PaletteMode, serial: Int) {
        guard !closed, serial == loadSerial, palette.mode == mode else { return }
        shownGeneration = root.generation
        palette.contextChanged(rootEntries: root.rows)
        // A step dropped because its command left the list keeps its typed line (rule 2).
        keepRecents()
    }

    // MARK: Run and close

    /// A failure stays in the palette, whole, with the input as it was (rule 8); a success
    /// closes it, and `performPalette` has already focused the pane it acted on.
    private func run(_ effect: PaletteEffect, inFlight key: String) {
        let shown = shownGeneration
        Task {
            let error = await model.performPalette(effect, shown: shown)
            guard !closed else { return }
            palette.runFinished(entryId: key, error: error)
            if error == nil { close() }
        }
    }

    /// Every close goes through here, so `paletteClosed()` runs on every path. With
    /// `restoringFocus`, the keyboard goes back to what held it at open — unless a run already
    /// moved it to a pane. A plane that takes over (the org plane, a confirmation) passes
    /// `false`: it focuses its own field.
    func close(restoringFocus: Bool = true) {
        guard !closed else { return }
        closed = true
        // A text step's typed line survives the close as a recent (rule 2).
        palette.closing()
        keepRecents()
        model.paletteClosed()
        let moved = model.keyboardFocusRequests != focusRequestsAtOpen
        onClose()
        let decision = PaletteFocusReturn.decide(restoringFocus: restoringFocus, runMovedFocus: moved, heldBy: holder)
        guard decision != .leave else { return }
        let previous = self.previous
        let model = self.model
        // After this turn's update has taken the query field out of the window, and the panes
        // own the keyboard again (`isKeyboardOwner` reads `paletteShowing`).
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                switch decision {
                case .responder: previous.restore()
                case .focusedPane: model.returnKeyboardToFocusedPane()
                case .leave: break
                }
            }
        }
    }
}

/// The responder to hand the keyboard back to. A box, so the run loop's `@Sendable` block can
/// carry it; it is only ever touched on the main thread.
private final class ResponderBox: @unchecked Sendable {
    weak var value: NSResponder?

    /// The window, or its content view, as first responder means a SwiftUI focusable inside
    /// the hosting view holds the keyboard — `ComposerBar.escapeBelongsToComposer` reads the
    /// same two as "nothing in particular" for the same reason.
    @MainActor static func holder(_ responder: NSResponder?, in window: NSWindow?) -> PaletteFocusReturn.Holder {
        guard let responder else { return .nothing }
        // A text view first: a SwiftUI `TextField`'s keyboard is AppKit's field editor, and
        // `restore()` hands it back to its field.
        if responder is NSText { return .appKitView }
        if responder === window || responder === window?.contentView { return .swiftUIFocus }
        // Any other hosting view SwiftUI put between the window and the pane.
        if NSStringFromClass(type(of: responder)).contains("SwiftUI") { return .swiftUIFocus }
        return .appKitView
    }

    @MainActor func restore() {
        guard var target = value else { return }
        // A text field's keyboard is the window's shared field editor; the field is what to focus.
        if let editor = target as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
            target = field
        }
        guard let view = target as? NSView, let window = view.window, window.isKeyWindow else { return }
        window.makeFirstResponder(view)
    }
}

// MARK: - The plane

/// ⌘P and ⌘K: one plane after `Palette.dc.html` — OrgPlane's geometry (a `black.opacity(0.86)`
/// slab, radius 12, 520 wide, over the `rgba(3,4,8,0.58)` dimmer), no sheet and no Cancel
/// button. The query line, the rows with their matched letters lit, and a footer that names
/// what Return does.
///
/// **The keys are taken by a local event monitor while the plane is up**, not by the query
/// field: ↑/↓ belong to the list and Return and Esc to the palette, wherever the keyboard is
/// inside the window, and a field editor would take ↑/↓ for its caret first. ⌘P and ⌘K are
/// the menu's (`AppScene`), which is the one path no focused view can keep from them.
struct PalettePlane: View {
    let controller: PaletteController

    @FocusState private var queryFocused: Bool
    @State private var monitor: Any?
    /// The window this plane is drawn in: the key monitor answers only its events.
    @State private var host: NSWindow?
    /// The rows' own height, so the plane hugs a short list (`PaletteListHeightKey`).
    @State private var listHeight: CGFloat = 0

    private var palette: PaletteModel { controller.palette }
    private var words: [String] { PaletteSearch.words(palette.query) }

    private static let ink = Color(red: 0.910, green: 0.925, blue: 0.965)          // #e8ecf6
    private static let production = Color(red: 0.910, green: 0.361, blue: 0.361)   // #e85c5c
    /// §5's amber, caution: a provider row's capacity at 20% or less (`PaletteEntry.isCaution`).
    private static let caution = Color(red: 0.910, green: 0.706, blue: 0.353)      // #e8b45a
    private static let anchor = Color(red: 0.620, green: 0.510, blue: 1.0)         // #9e82ff
    /// The rail's working tick (`RailTreatment`): a run in flight on this row (rule 5).
    private static let working = Color(RailTreatment.workingTickColour)

    var body: some View {
        ZStack(alignment: .top) {
            // The dimmer, as OrgPlane's: it swallows clicks meant for the canvas, and a click on
            // it dismisses, as Esc does — nothing runs.
            Color(red: 0.012, green: 0.016, blue: 0.031).opacity(0.58)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.close() }
                .accessibilityHidden(true)
            plane
                .padding(.top, 150)
        }
        .background(WindowReader(window: $host))
        .onAppear {
            installMonitor()
            queryFocused = true      // rule 3: type at once, no click
            controller.syncRoot()
        }
        .onChange(of: host) { _, _ in
            removeMonitor()
            installMonitor()
        }
        .onDisappear { removeMonitor() }
        // Rule 3 again: every step pushed or popped hands the line the keyboard.
        .onChange(of: palette.steps.count) { _, _ in queryFocused = true }
    }

    private var plane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            queryLine
                .padding(.horizontal, 22)
                .padding(.bottom, palette.error == nil ? 16 : 10)
            if let error = palette.error {
                // A run's error, whole (rule 8): wrapped, never truncated, selectable.
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Self.ink.opacity(0.86))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
                    .accessibilityIdentifier("palette.error")
            }
            rows
                .padding(.bottom, 8)
            footer
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 18)
        }
        .padding(.top, 22)
        .frame(width: 520)
        .background(.black.opacity(0.86))
        // **Opaque underneath.** The slab alone let the Landing's rows read through it, between
        // and behind the palette's own (walk, 2026-10-24); over the dimmer's colour it looks the
        // same against the void and shows nothing of what is under it.
        .background(Color(red: 0.012, green: 0.016, blue: 0.031))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 30)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("palette.plane")
    }

    // MARK: Header and query

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let step = palette.steps.last {
                // What the step asks for, where the mode's name was: "Environment", a
                // database's name for its tables.
                micro(step.title.uppercased())
                    .accessibilityIdentifier("palette.step")
            } else {
                micro(modeTitle)
            }
            Spacer()
            Text(palette.mode == .commands ? "⌘K" : "⌘P")
                .font(.system(size: 9, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Self.ink.opacity(0.52))
        }
    }

    private var modeTitle: String {
        switch palette.mode {
        case .open: "OPEN OR SWITCH TO"
        case .commands: "RUN A COMMAND"
        case .tickets: "TICKETS IN FLIGHT"
        }
    }

    private var queryLine: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Self.ink.opacity(0.52))
            // No box around it: the line is the plane's only input (`Palette.dc.html`).
            TextField(palette.placeholder, text: Binding(
                get: { controller.palette.line },
                set: { controller.type($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Self.ink)
                .focused($queryFocused)
                .accessibilityIdentifier("palette.query")
            Text(count)
                .font(.system(size: 9, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Self.ink.opacity(0.52))
                .fixedSize()
        }
    }

    /// "5 of 26" while a query narrows the list, the whole count when nothing is typed.
    private var count: String {
        let total: Int
        if let step = palette.steps.last {
            total = step.isText ? palette.results.count : step.choices.count
        } else {
            total = palette.rootRows.count
        }
        let shown = palette.results.filter { $0.id != "no-results" }.count
        return words.isEmpty ? "\(total)" : "\(shown) of \(total)"
    }

    // MARK: Rows

    private var rows: some View {
        let results = palette.results
        let list = VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                row(entry, index: index, selected: index == palette.selection)
            }
        }
        return ScrollViewReader { proxy in
            // As tall as the list, up to 440 pt, then it scrolls inside the plane (OrgPlane's
            // `scrollingWhenTall`). Measured rather than `.frame(maxHeight:)` around a
            // `ViewThatFits`, which took all 440 pt and centred a short list in them.
            ScrollView(.vertical) {
                list.background(GeometryReader { geometry in
                    Color.clear.preference(key: PaletteListHeightKey.self, value: geometry.size.height)
                })
            }
            .scrollIndicators(.automatic)
            .frame(height: min(listHeight, 440))
            .onPreferenceChange(PaletteListHeightKey.self) { listHeight = $0 }
            .onChange(of: palette.selected?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ entry: PaletteEntry, index: Int, selected: Bool) -> some View {
        let loading = entry.isError && entry.id.hasPrefix("loading:")
        // An error row, or the old mode's rows while the new mode's list loads (`rootStale`):
        // drawn, never run.
        let dim = entry.isError || (palette.steps.isEmpty && palette.rootStale)
        let tone = entry.isProduction ? Self.production : Self.ink
        // A command row's kind would read "command" on every row (`Palette.dc.html`).
        let showsKind = !entry.kindLabel.isEmpty && entry.kindLabel != "command"
        let running = palette.isRunning(entry)
        // One mark, as on the rail: working outranks selected, which the wash still shows.
        let tick: Color? = running ? Self.working : (selected ? Self.anchor : nil)
        return Button {
            controller.choose(index)
        } label: {
            HStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // A live conversation's row: its state's dot, as its chip and the Landing's
                    // Running row draw it. No other row has one (running and past never mix).
                    if let state = entry.state {
                        ChipDot(colour: state.hue, breathes: state == .working && !dim)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            .opacity(dim ? 0.4 : 1)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title(entry, selected: selected, dim: dim))
                            .font(.system(size: 14))
                            .italic(loading)
                            .lineLimit(1)
                        if !entry.subtitle.isEmpty {
                            Text(entry.subtitle)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(entry.isCaution && !dim
                                    ? Self.caution
                                    : tone.opacity(entry.isProduction ? 0.66 : (dim || entry.isDimmed ? 0.38 : 0.50)))
                                // A source's error is its subtitle, and an error is drawn whole.
                                .lineLimit(entry.isError && !loading ? nil : 1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: entry.isError && !loading)
                        }
                    }
                }
                Spacer(minLength: 0)
                if showsKind {
                    Text(entry.kindLabel.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.7)
                        .foregroundStyle(tone.opacity(entry.isProduction ? 0.72 : 0.52))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Self.ink.opacity(0.06) : .clear)
            // §8's anchor mark on the row you are on; the rail's green working tick, with its
            // glow, on a row whose run is in flight (rule 5).
            .overlay(alignment: .leading) {
                if let tick {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tick)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                        .shadow(color: tick.opacity(running ? 0.85 : 0.7), radius: running ? 5 : 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A plain button over a custom label reads as a bare "button": the row names itself.
        // The title is the label; what the row is and where it points (its subtitle, and its
        // kind where one is drawn) is the hint. The value stays the in-flight mark (rule 5).
        .accessibilityLabel(entry.title)
        .accessibilityHint(accessibilityHint(entry, showsKind: showsKind))
        .accessibilityValue(running ? "working" : (entry.state?.spoken ?? ""))
        .accessibilityIdentifier("palette.row.\(entry.id)")
        .id(entry.id)
    }

    private func accessibilityHint(_ entry: PaletteEntry, showsKind: Bool) -> String {
        [entry.subtitle, showsKind ? entry.kindLabel : ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The title with the query's matched letters bright and the rest dim; with no query, the
    /// whole title at the row's own brightness. Production is red in every channel (§5).
    private func title(_ entry: PaletteEntry, selected: Bool, dim: Bool) -> AttributedString {
        let tone = entry.isProduction ? Self.production : Self.ink
        var text = AttributedString(entry.title)
        if dim {
            text.foregroundColor = tone.opacity(0.40)
            return text
        }
        // An ignored file (`isDimmed`, 3b-ii) is drawn in the dimmed token, as an inert row is, yet
        // runs: its matched letters still stand out, one step up.
        let lit = PaletteSearch.highlights(entry, words: words)
        guard !words.isEmpty, !lit.isEmpty else {
            text.foregroundColor = tone.opacity(entry.isDimmed ? 0.40 : (selected || entry.isProduction ? 1 : 0.86))
            return text
        }
        text.foregroundColor = tone.opacity(entry.isDimmed ? 0.40 : 0.55)
        for range in lit {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].foregroundColor = entry.isDimmed ? tone.opacity(0.86) : tone
        }
        return text
    }

    // MARK: Footer

    /// `↑↓ move · ⏎ <verb> · esc to dismiss`, the verb the selected row's; with nothing
    /// Return would run, `⏎` is left out rather than promised. A ticket or PR row adds ⌘↩:
    /// `↑↓ move · ⏎ open · ⌘↩ hand to agent · esc to dismiss`.
    private var footer: some View {
        let verb = palette.footerVerb
        let parts = ["↑↓ move", verb.isEmpty ? "" : "⏎ \(verb)", palette.footerAlt, "esc to dismiss"]
        let hint = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        return Text(hint)
            .font(.system(size: 10, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Self.ink.opacity(0.52))
    }

    private func micro(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .tracking(1.7)
            .foregroundStyle(Self.ink.opacity(0.52))
    }

    // MARK: Keys

    /// ↑ ↓ Return Esc, unmodified, and ⌘↩ on a row that has an alternate, in this plane's own window
    /// while it is key. Mid-composition (marked text) every one is the input method's.
    private func installMonitor() {
        guard monitor == nil, let host else { return }
        let controller = self.controller
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak host] event in
            let taken: Bool = MainActor.assumeIsolated {
                guard !controller.closed, let host, event.window === host, host.isKeyWindow else { return false }
                let flags = event.modifierFlags.intersection([.command, .control, .option])
                if flags == .command, [36, 76].contains(event.keyCode) {
                    if let editor = host.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                    return controller.confirmAlternate()
                }
                guard flags.isEmpty, [126, 125, 36, 76, 53].contains(event.keyCode) else { return false }
                if let editor = host.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                switch event.keyCode {
                case 126: controller.move(-1)
                case 125: controller.move(1)
                case 53: controller.escape()
                default: controller.confirm()
                }
                return true
            }
            return taken ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The palette's rows measured inside their scroll view, so the plane is as tall as the list
/// up to its cap. A preference rather than `onGeometryChange`, which is macOS 15 while this
/// app targets 14.4.
private struct PaletteListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
