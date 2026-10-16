import Foundation

/// Which front door the palette is showing: ⌘P's *open or switch to*, or ⌘K's commands.
public enum PaletteMode: Sendable, Equatable { case open, commands }

/// One input step a `…` command pushed: its own query line over its own list.
public struct PaletteStep: Sendable, Equatable {
    public let commandId: String
    /// What the step asks for, e.g. "Environment" — the query line's placeholder.
    public let title: String
    public var query: String
    /// Filled by the caller from the command's `ChoiceSource` (`PaletteModel.provideChoices`).
    /// A choice row's `id` is the value the command runs with.
    public var choices: [PaletteEntry]
    /// A free-text step: the typed line is the value, and the window's recents suggest above it.
    public let isText: Bool
    /// A drill into a row's children (a database → its tables): each child runs its own action.
    /// `commandId` is `drill:<sourceId>:<value>`.
    public let isDrill: Bool

    public init(
        commandId: String, title: String, query: String = "", choices: [PaletteEntry] = [],
        isText: Bool, isDrill: Bool = false
    ) {
        self.commandId = commandId
        self.title = title
        self.query = query
        self.choices = choices
        self.isText = isText
        self.isDrill = isDrill
    }
}

/// What the window does after a key. At most one per key.
public enum PaletteEffect: Sendable, Equatable {
    /// `step` names the drill step the row was listed in (its `commandId`), `nil` at the root:
    /// a step's rows were read once, when it was pushed, and the window checks them against
    /// the context of that read rather than the root's.
    case run(PaletteAction, step: String? = nil)
    case runCommand(commandId: String, value: String)
    /// A choice step was pushed; the caller fills it with `provideChoices`.
    case needChoices(commandId: String)
    case close
}

/// The palette's state machine: modes, the `>` switch, input steps, selection and the one
/// run per Return. Pure — the window feeds it keys and lists and acts on the effects.
///
/// **Reopen is fresh.** A new model starts at the root with an empty query; the window makes
/// one per open, so no step outlives a close. Only `recents` carry over: the window seeds them
/// (`WindowModel.makePalette`) and keeps them back (`keepPaletteRecents`).
///
/// **`>` switches only in a palette opened with ⌘P**, and only as the first character. Its
/// commands state remembers the `>` (`line` shows it), and deleting it switches back. In one
/// opened with ⌘K, or in a step, `>` is a literal.
///
/// **Source row ids are prefixed** (`pane:`, `table:`, `database:`, `project:`, …) so they
/// never equal a catalog command id: `inFlight` holds both kinds in one set.
///
/// **Error rows never run.** A source's error row and the "No results" row are selectable so
/// they can be read, but `confirm()` on them is `nil` (rule 8).
public struct PaletteModel: Sendable, Equatable {
    public private(set) var mode: PaletteMode {
        didSet { if mode != oldValue { rootStale = true } }
    }
    /// The mode changed and `rootEntries` still hold the old mode's rows: they stay drawn, so a
    /// switch never flashes "No results", but Return runs none of them until the caller hands
    /// the new mode's list in (`rootEntries` or `contextChanged`).
    public private(set) var rootStale = false
    public private(set) var steps: [PaletteStep] = []
    public private(set) var selection: Int = 0
    /// A failed run's whole error, shown until the next keystroke.
    public private(set) var error: String?
    /// Entry ids whose run is in flight — a root row's id, or a step's `commandId`.
    public private(set) var inFlight: Set<String> = []
    /// The root list for the current mode; the caller swaps it when `mode` changes.
    public var rootEntries: [PaletteEntry] = [] {
        didSet { rootStale = false }
    }
    /// The value each step command is running with, by `commandId`: which choice row, or which
    /// typed line, carries the step's in-flight mark (`isRunning`).
    private var runningValues: [String: String] = [:]
    /// recentKey → typed values, newest first, at most `recentLimit`. This window only.
    public var recents: [String: [String]] = [:]

    public static let recentLimit = 10

    private let openedIn: PaletteMode
    /// The commands state was entered by a leading `>`.
    private var viaChevron = false
    private var rootQuery = ""
    /// The selected row under each pushed step, restored when it pops.
    private var parentSelections: [SavedSelection] = []

    private struct SavedSelection: Sendable, Equatable {
        var id: String?
        var index: Int
    }

    public init(mode: PaletteMode) {
        self.mode = mode
        self.openedIn = mode
    }

    /// The current line's query: the top step's, else the root's, without a `>` switch.
    public var query: String { steps.last?.query ?? rootQuery }

    /// What the query field shows — the query, with the `>` back in front when it switched modes.
    public var line: String { steps.isEmpty && viaChevron ? ">" + rootQuery : query }

    /// The ranked rows. A choice step lists its choices; a text step lists its recents above a
    /// row for the typed line; the root lists `rootEntries`. A query with words that matches
    /// nothing is one "No results" error row.
    public var results: [PaletteEntry] {
        let q = query
        let hasWords = !PaletteSearch.words(q).isEmpty
        guard let step = steps.last else { return orNoResults(PaletteSearch.rank(rootEntries, query: q), q, .commands) }
        guard step.isText else { return orNoResults(PaletteSearch.rank(step.choices, query: q), q, .choices) }
        let typed = trimmed(q)
        let suggestions = (recents[recentKey(step) ?? ""] ?? []).filter { $0 != typed }.map { value in
            PaletteEntry(id: "recent:\(value)", group: .choices, title: value, subtitle: "recent",
                         kindLabel: "recent", verb: "choose", action: .pushStep(commandId: step.commandId))
        }
        let ranked = PaletteSearch.rank(suggestions, query: q)
        guard hasWords else { return ranked }
        return ranked + [PaletteEntry(id: Self.lineId, group: .choices, title: typed, subtitle: step.title,
                                      kindLabel: "text", verb: "run", action: .pushStep(commandId: step.commandId))]
    }

    /// The selected row, if any.
    public var selected: PaletteEntry? {
        let r = results
        return r.indices.contains(selection) ? r[selection] : nil
    }

    public var placeholder: String {
        if let step = steps.last { return step.title }
        return mode == .open ? "open or switch to…" : "run an action…"
    }

    /// The footer's `⏎ <verb>`: the selected row's. Empty on an error or "No results" row and
    /// with nothing selected — the view then hides `⏎ <verb>`, since Return does nothing.
    public var footerVerb: String {
        if steps.isEmpty && rootStale { return "" }
        return selected.map { $0.isError ? "" : $0.verb } ?? ""
    }

    /// Replaces the line's text. Clears the error and resets the selection.
    public mutating func type(_ text: String) {
        error = nil
        if !steps.isEmpty {
            steps[steps.count - 1].query = text
        } else if openedIn == .open, mode == .open, text.hasPrefix(">") {
            mode = .commands
            viaChevron = true
            rootQuery = String(text.dropFirst())
        } else if viaChevron {
            if text.hasPrefix(">") {
                rootQuery = String(text.dropFirst())
            } else {
                // The `>` was deleted: back to open, keeping whatever followed it.
                mode = .open
                viaChevron = false
                rootQuery = text
            }
        } else {
            rootQuery = text
        }
        selection = defaultSelection
    }

    /// ↑/↓: wraps at both ends.
    public mutating func move(_ delta: Int) {
        let n = results.count
        guard n > 0 else { selection = 0; return }
        selection = ((selection + delta) % n + n) % n
    }

    /// Return on the selected row. `nil` when nothing runs: an error row, an empty line, or a
    /// row whose run is already in flight.
    public mutating func confirm() -> PaletteEffect? {
        guard let entry = selected, !entry.isError, !(steps.isEmpty && rootStale) else { return nil }
        guard let step = steps.last, !step.isDrill else { return runRow(entry, step: steps.last?.commandId) }
        if step.isText, entry.id != Self.lineId {
            // A recent fills the line; that runs nothing, so a run in flight does not block it.
            steps[steps.count - 1].query = entry.title
            selection = defaultSelection
            return nil
        }
        if case .drill(let sourceId, let value) = entry.action { return pushDrill(sourceId, value) }
        guard !inFlight.contains(step.commandId) else { return nil }
        if step.isText {
            let value = trimmed(step.query)
            remember(step)
            inFlight.insert(step.commandId)
            runningValues[step.commandId] = value
            return .runCommand(commandId: step.commandId, value: value)
        }
        if case .pushStep(let commandId) = entry.action { return push(commandId) }
        inFlight.insert(step.commandId)
        runningValues[step.commandId] = entry.id
        return .runCommand(commandId: step.commandId, value: entry.id)
    }

    /// Esc: pops one step, restoring the parent's query and selection; at the root, `.close`.
    ///
    /// A text step's typed line is never thrown away (rule 2): popping it keeps the line as a
    /// recent, so the next time the step opens it is there to choose.
    public mutating func escape() -> PaletteEffect? {
        guard !steps.isEmpty else { return .close }
        remember(steps.removeLast())
        restore(parentSelections.popLast())
        error = nil
        return nil
    }

    /// The palette is closing — Esc at the root, a click outside, a run that succeeded, a plane
    /// that took over. A text step's typed line becomes a recent (rule 2), as on a pop.
    public mutating func closing() {
        steps.forEach { remember($0) }
    }

    /// ⌘P / ⌘K while open: switches mode at the root, keeping the query minus any `>`. Inside a
    /// step it does nothing, so the step's typed input is never thrown away (rule 2).
    public mutating func modeKey(_ mode: PaletteMode) {
        guard steps.isEmpty, mode != self.mode || viaChevron else { return }
        self.mode = mode
        viaChevron = false
        error = nil
        selection = 0
    }

    /// The caller's answer to `.needChoices`. Ignored once that step is no longer on the stack.
    public mutating func provideChoices(_ choices: [PaletteEntry], for commandId: String) {
        guard let i = steps.lastIndex(where: { $0.commandId == commandId }) else { return }
        steps[i].choices = choices
        if i == steps.count - 1 { selection = defaultSelection }
    }

    /// A run ended. With an error the palette stays as it is and shows it whole; the caller
    /// closes it on success. A success leaves another run's error showing.
    public mutating func runFinished(entryId: String, error: String?) {
        inFlight.remove(entryId)
        runningValues[entryId] = nil
        if let error { self.error = error }
    }

    /// Rule 5: whether `entry`'s run is in flight, for the view's quiet load mark. A root or
    /// drill row is marked by its own id — a `…` command's root row too, while its step runs. In a
    /// command step the row it ran with is marked: the chosen choice, or the typed line.
    public func isRunning(_ entry: PaletteEntry) -> Bool {
        if inFlight.contains(entry.id) { return true }
        guard let step = steps.last, !step.isDrill, inFlight.contains(step.commandId),
              let value = runningValues[step.commandId] else { return false }
        return step.isText ? entry.id == Self.lineId && entry.title == value : entry.id == value
    }

    /// The window state moved while open. The selection stays on the same row if it still
    /// exists, else on the row now in its place. A command step whose command left the list is
    /// dropped, so a closed pane's command can never run; a drill step stays.
    public mutating func contextChanged(rootEntries: [PaletteEntry]) {
        let current = SavedSelection(id: selected?.id, index: selection)
        self.rootEntries = rootEntries
        if let first = steps.first, !first.isDrill,
           !rootEntries.contains(where: { $0.action == .pushStep(commandId: first.commandId) }) {
            let root = parentSelections.first
            steps.forEach { remember($0) }
            steps = []
            parentSelections = []
            restore(root)
        } else if steps.isEmpty {
            restore(current)
        }
    }

    // MARK: - Private

    private static let lineId = "line"

    /// The first row, except a text step with a typed line selects the line (last).
    private var defaultSelection: Int {
        guard let step = steps.last, step.isText, !PaletteSearch.words(step.query).isEmpty else { return 0 }
        return results.count - 1
    }

    /// Runs a row's own action — at the root and inside a drill — or pushes its step.
    private mutating func runRow(_ entry: PaletteEntry, step: String? = nil) -> PaletteEffect? {
        guard !inFlight.contains(entry.id) else { return nil }
        switch entry.action {
        case .pushStep(let commandId): return push(commandId)
        case .drill(let sourceId, let value): return pushDrill(sourceId, value)
        default:
            inFlight.insert(entry.id)
            return .run(entry.action, step: step)
        }
    }

    private mutating func pushDrill(_ sourceId: String, _ value: String) -> PaletteEffect {
        let commandId = "drill:\(sourceId):\(value)"
        pushStep(PaletteStep(commandId: commandId, title: value, isText: false, isDrill: true))
        return .needChoices(commandId: commandId)
    }

    private mutating func pushStep(_ step: PaletteStep) {
        parentSelections.append(SavedSelection(id: selected?.id, index: selection))
        steps.append(step)
        selection = 0
        error = nil
    }

    /// Same row by id, else the same index clamped to the current results, else 0.
    private mutating func restore(_ saved: SavedSelection?) {
        let r = results
        if let id = saved?.id, let i = r.firstIndex(where: { $0.id == id }) {
            selection = i
        } else {
            selection = clamp(saved?.index ?? 0, r.count)
        }
    }

    private mutating func push(_ commandId: String) -> PaletteEffect? {
        guard let input = CommandCatalog.command(id: commandId)?.input else { return nil }
        let step: PaletteStep
        switch input {
        case .choice(_, let placeholder): step = PaletteStep(commandId: commandId, title: placeholder, isText: false)
        case .text(let placeholder, _): step = PaletteStep(commandId: commandId, title: placeholder, isText: true)
        }
        pushStep(step)
        return step.isText ? nil : .needChoices(commandId: commandId)
    }

    /// A text step's line, trimmed, as the newest recent; an empty line, or a choice step, adds
    /// nothing.
    private mutating func remember(_ step: PaletteStep) {
        guard step.isText, let key = recentKey(step) else { return }
        let value = trimmed(step.query)
        guard !value.isEmpty else { return }
        recents[key] = Array(([value] + (recents[key] ?? []).filter { $0 != value }).prefix(Self.recentLimit))
    }

    private func recentKey(_ step: PaletteStep) -> String? {
        if case .text(_, let key)? = CommandCatalog.command(id: step.commandId)?.input { return key }
        return nil
    }

    private func orNoResults(_ ranked: [PaletteEntry], _ q: String, _ group: PaletteGroup) -> [PaletteEntry] {
        guard ranked.isEmpty, !PaletteSearch.words(q).isEmpty else { return ranked }
        return [PaletteEntry(id: "no-results", group: group, title: "No results for '\(trimmed(q))'",
                             subtitle: "", kindLabel: "", verb: "", action: .pushStep(commandId: ""), isError: true)]
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func clamp(_ i: Int, _ n: Int) -> Int { n == 0 ? 0 : min(max(i, 0), n - 1) }
}
