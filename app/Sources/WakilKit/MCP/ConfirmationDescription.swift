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
    default:
        return nil
    }
}
