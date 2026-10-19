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

/// A local provider's status line: its last error whole (Rule 8), else "reachable".
public func localProviderStatus(id: String, errors: [String: String]) -> String {
    errors[id] ?? "reachable"
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
