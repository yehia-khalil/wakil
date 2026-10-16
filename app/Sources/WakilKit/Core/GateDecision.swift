import Foundation

/// What `writeGate` decided about a proposed action.
///
/// `.allow` runs unconditionally. `.gate` runs only if the caller supplied
/// the exact confirmation string `dispatch` requires. `.block` never runs,
/// regardless of confirmation — production mutation is not something a
/// caller can opt back into by passing the right string.
public enum GateDecision: Equatable, Sendable {
    case allow
    case gate
    case block
}
