import Foundation

/// Which workspace cards the operator expanded on the home, kept across relaunch (Rule 6: the home
/// stays as it was left). Per workspace id, every organisation's in one set (an organisation
/// switch keeps the other's); compact by default.
public final class HomeExpansionStore {
    private let defaults: UserDefaults
    private let key: String
    private var expanded: Set<String>

    public init(defaults: UserDefaults = .standard, key: String = "home.expandedWorkspaces") {
        self.defaults = defaults
        self.key = key
        expanded = Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func isExpanded(_ workspace: String) -> Bool { expanded.contains(workspace) }

    /// ⌄ and ⌃ on a card.
    public func toggle(_ workspace: String) {
        if expanded.remove(workspace) == nil { expanded.insert(workspace) }
        save()
    }

    private func save() { defaults.set(expanded.sorted(), forKey: key) }
}
