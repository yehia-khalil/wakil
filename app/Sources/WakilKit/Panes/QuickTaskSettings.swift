import Foundation

/// The Quick tasks picker's options (3b-viii): "Same as agent" first, then each provider that
/// serves any quick operation, by its label or, without one, its id.
public func quickTaskOptions(_ tree: SettingsTree) -> [(id: String, label: String)] {
    [(id: "", label: "Same as agent")]
        + tree.providers.filter { !$0.serves.isEmpty }.map { (id: $0.id, label: $0.label.isEmpty ? $0.id : $0.label) }
}

/// Why ghost-text will not appear, or nil: neither the chosen quick provider nor the active one
/// serves `infill`.
public func quickTaskNote(_ tree: SettingsTree, activeProvider: String) -> String? {
    let serving = Set(tree.providers.filter { $0.serves.contains("infill") }.map(\.id))
    let chosen = tree.org.quickProvider
    if !chosen.isEmpty, serving.contains(chosen) { return nil }
    if serving.contains(activeProvider) { return nil }
    return "Ghost-text needs a Claude or local provider"
}

/// The line under the Quick tasks picker: which provider code completion goes to first, by its
/// label or, without one, its id. Nil until quick tasks are built.
public func quickTaskRouteLine(_ tree: SettingsTree, routed: String?) -> String? {
    guard let routed else { return nil }
    let provider = tree.providers.first { $0.id == routed }
    let name = provider.map { $0.label.isEmpty ? $0.id : $0.label } ?? routed
    return "Code completion goes to \(name)"
}

/// A local provider's status line: its last error whole (Rule 8), else "reachable" once it has
/// answered, else "not tried yet".
public func localProviderStatus(id: String, errors: [String: String], answered: Set<String>) -> String {
    errors[id] ?? (answered.contains(id) ? "reachable" : "not tried yet")
}

/// What a new local model serves until the operator ticks more: code completion only.
public func newLocalProviderServes() -> [String] { ["infill"] }

/// The picker's segments keyed by provider id. A display text two segments share, or a provider
/// labelled like the "Same as agent" segment, is suffixed with its id so every segment is distinct.
public func quickTaskChoices(_ tree: SettingsTree) -> [(id: String, display: String)] {
    let options = quickTaskOptions(tree)
    return options.map { option in
        if option.id.isEmpty { return (id: option.id, display: option.label) }
        let clash = option.label == "Same as agent" || options.filter { $0.label == option.label }.count > 1
        return (id: option.id, display: clash ? "\(option.label) (\(option.id))" : option.label)
    }
}

/// Fast path's hint under QUICK TASKS: what it is, and, when the value is the default for the
/// chosen model, why — naming that model. A hint only: either value can be chosen (Rule 9).
public func fastPathHint(_ tree: SettingsTree) -> String {
    let base = "one-line commands without the agent"
    let chosen = tree.org.quickProvider
    let local = tree.providers.contains { $0.id == chosen && $0.kind == "local" }
    guard tree.org.fastPath == local else { return base }
    if local { return base + " · on: the model is local" }
    let model = quickTaskChoices(tree).first { $0.id == chosen }?.display ?? chosen
    return base + " · off: on \(model) each line would wait for Claude first"
}

/// The ⓘ beside QUICK TASKS: what the two features do and, as plainly, what the fast path won't,
/// so an operator does not expect an edit or a query from it (3b-ix walk). Markdown, inline only;
/// the deadlines are the ones the fast path runs under, so the text cannot drift from them.
public var quickTasksAbout: String {
    func seconds(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return String(format: "%g s", ms / 1000)
    }
    let local = seconds(WindowModel.fastPathLocalDeadline)
    let other = seconds(WindowModel.fastPathSessionDeadline)
    return """
    **Ghost-text** suggests the rest of the line as you type in the editor. Tab accepts it.

    **Fast path** runs a short command the moment you press Return, without the agent: "open checkout.go", "line 40", "switch to staging", "show tables in core". If it guessed wrong, click **Ask the agent instead**.

    It only opens, shows, switches and closes things Wakil knows (files, tables, panes, environments). It never edits, queries or runs commands, and does one thing per line. Anything else, or a model slower than \(local) (\(other) if not local), goes to the agent.

    Best with a local model. On *Same as agent* it is off by default, since every line would wait for Claude first.
    """
}
