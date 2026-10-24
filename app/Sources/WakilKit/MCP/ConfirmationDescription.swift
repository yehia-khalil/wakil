import Foundation

/// What the confirmation plane shows for a gated action that carries no
/// `statement` of its own — a `.control` action such as `ctx_set_environment`
/// gated by D10 (`writeGate`'s either-side production rule), which has a
/// `name` param, not a `statement`.
///
/// **A `switch` over known action names, not string-building over
/// arbitrary params.** An action that gains a gate later must state its own
/// sentence; inheriting a generic one would put a machine-shaped
/// description in front of a human being asked to approve it.
///
/// Returns `nil` for anything else, which preserves `parkAndAwait`'s
/// existing refusal for an action that genuinely has nothing to show.
public func confirmationDescription(action: String, params: JSONValue) -> String? {
    switch action {
    case "ctx_set_environment":
        guard case .object(let object) = params,
              case .string(let name)? = object["name"] else { return nil }
        return "switch the active environment to \(name)"
    // 3a-iv (Decision 46): the git writes the agent price gates carry no statement of their own.
    case "editor_changes_branch_delete":
        guard case .object(let o) = params, case .string(let branch)? = o["branch"] else { return nil }
        return "delete branch \(branch) in \(rootName(o))" + (o["force"] == .bool(true) ? ", and the commits only it has" : "")
    case "editor_changes_stash_drop":
        guard case .object(let o) = params, case .string(let id)? = o["id"] else { return nil }
        return "drop stash \(id.prefix(7)) in \(rootName(o))"
    case "editor_changes_stash_drop_all":
        guard case .object(let o) = params, case .array(let ids)? = o["ids"] else { return nil }
        return "drop \(ids.count) stash\(ids.count == 1 ? "" : "es") in \(rootName(o))"
    default:
        return nil
    }
}

/// The root's folder name, which is how the Changes view names a root.
private func rootName(_ o: [String: JSONValue]) -> String {
    guard case .string(let root)? = o["root"] else { return "this root" }
    return (root as NSString).lastPathComponent
}
