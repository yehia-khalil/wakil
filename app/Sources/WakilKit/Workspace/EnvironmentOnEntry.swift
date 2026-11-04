import Foundation

// Workspaces, piece 3 walk: the organisation's home selects no environment, and a door from it into
// a project landed there with none chosen — the badge read UNKNOWN and drew no picker, though the
// project declares environments (Invariant 8: the active environment is always visible).

/// The environment a door into a project switches to, or nil to leave the one there. `declared` is
/// the project's, `current` what the window holds after the project switch, `remembered` the one
/// the operator last used in that project. The remembered one first, when still declared; else
/// `current` when declared; else the first declared that is not production (Rule 9: defaults
/// suggest), else the first declared — a red one rather than none. Nil for a project declaring none.
public func environmentOnEntry(declared: [EnvironmentListing], current: String, remembered: String?) -> String? {
    let names = declared.map(\.name)
    guard !names.isEmpty else { return nil }
    if let remembered, names.contains(remembered) { return remembered == current ? nil : remembered }
    if names.contains(current) { return nil }
    return declared.first { !$0.isProduction }?.name ?? names.first
}

/// The Environment badge's words: the environment, else *none chosen* while the project declares
/// some, else *unknown* — a project declaring none, or one not read yet.
public func environmentBadgeLabel(environment: String, declaredCount: Int) -> String {
    if !environment.isEmpty { return environment }
    return declaredCount > 0 ? "none chosen" : "unknown"
}

/// Whether the Environment segment opens a picker: more than one declared, or any while none is
/// chosen — then even one is a choice to make.
public func environmentHasChoice(environment: String, declaredCount: Int) -> Bool {
    declaredCount > 1 || (environment.isEmpty && declaredCount > 0)
}
