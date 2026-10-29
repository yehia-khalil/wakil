import Foundation

// Path translation (call 2) and confinement (call 13): a path in Main's folder of a repo the
// workspace has a checkout of is the checkout's; a path in another workspace's checkout is refused.

private func standard(_ p: String) -> String { (p as NSString).standardizingPath }

/// `path` with `prefix` replaced by `with`, when `path` is `prefix` or under it.
private func rebase(_ path: String, from prefix: String, to with: String) -> String? {
    let p = standard(path), from = standard(prefix)
    if p == from { return with }
    guard p.hasPrefix(from + "/") else { return nil }
    return with + p.dropFirst(from.count)
}

/// The checkout path of a path in Main's folder of a repo `workspace` has a made checkout of; nil
/// for any other path.
public func workspacePath(_ path: String, in workspace: Workspace) -> String? {
    for co in workspace.checkouts {
        guard let dest = co.path, !co.inMain else { continue }
        if let hit = rebase(path, from: co.repo, to: dest) { return hit }
    }
    return nil
}

/// The Main path of a path inside one of `workspace`'s checkouts; nil for any other path.
public func mainPath(_ path: String, in workspace: Workspace) -> String? {
    for co in workspace.checkouts {
        guard let from = co.path else { continue }
        if let hit = rebase(path, from: from, to: co.repo) { return hit }
    }
    return nil
}

/// The workspace whose made checkout holds `path`, if any.
public func workspaceHolding(_ path: String, in all: [Workspace]) -> Workspace? {
    all.first { w in w.checkouts.contains { co in co.path.map { rebase(path, from: $0, to: $0) != nil } ?? false } }
}

/// Why an agent in `workspace` (nil: Main) may not write `path`: it is inside another workspace's
/// checkout. Nil when it may (Main's folders and its own checkouts).
public func confinementRefusal(_ path: String, workspace: Workspace?, all: [Workspace], action: String) -> String? {
    guard let other = workspaceHolding(path, in: all), other.id != workspace?.id else { return nil }
    let name = other.name.isEmpty ? other.slug : other.name
    return "\(action): \(standard(path)) is in workspace ‘\(name)’; this conversation writes only in its own workspace"
}

/// What a workspace's canvas is filed under (`LayoutScope.lineageRoot`): its view key, marked so it
/// can never equal a conversation's lineage root.
public func workspaceCanvasRoot(_ w: Workspace) -> String { "workspace-" + w.viewKey }

/// The tag the editor and a terminal carry for a folder (spec, piece 1): a workspace's copy, or
/// the operator's own folder in Main.
public func checkoutTag(for path: String, in all: [Workspace]) -> String {
    workspaceHolding(path, in: all) != nil ? "workspace copy" : "Main · your folder"
}
