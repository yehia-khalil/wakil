import Foundation

/// One row of `ctx_list_environments`, for the context line's
/// Environment segment.
///
/// **Two fields, because the action carries two.** `wakil-ctx`'s
/// `list_environments` answers a flat `map[string]bool` of name →
/// read-only and nothing else — no database count, no API count, no
/// host. `ContextStates.dc.html` draws rows reading "3 databases · 1
/// API"; this type cannot feed them and must not invent them, so the
/// control draws what ships. See `ctx_list_environments`' own
/// registration comment for why closing that gap is a decision rather
/// than a detail.
public struct EnvironmentListing: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// True when NOTHING in this environment is configured for
    /// writing — no database carries a write credential, and the
    /// environment declares no API entry (#182: the Go rule widened,
    /// because an environment reachable by `api_send` is writable
    /// through it, and there is no read-only HTTP). True *vacuously*
    /// for an environment declaring nothing at all, so it is never
    /// evidence that an environment IS configured.
    public let isReadOnly: Bool

    /// Whether selecting this row turns the room red and arms the write
    /// gate.
    ///
    /// **Stored, and read off the tool** (Decision 26, #182). It used to
    /// be `isProductionEnvironment(name)` — computed here, from the name
    /// — which was the right move while a name was all there was, and is
    /// the wrong one now: `list_environments` publishes the flag's
    /// EFFECT, and re-deriving it in the app is precisely the second copy
    /// of the rule the flag exists to remove. An environment declaring
    /// `production: false` would otherwise be drawn red in the picker and
    /// treated as staging everywhere else.
    public let isProduction: Bool

    /// A sentence about THIS environment when a reader of the
    /// configuration would misread it, and `nil` otherwise (#182).
    ///
    /// **On the row, because it is about the row.** The tool used to
    /// answer a flat `notices` array beside the environments, which
    /// could not say which environment each notice was about — so the
    /// menu drew them in a heap above the list, detached from the thing
    /// they named and truncated to a row's width. Carried here, each is
    /// drawn under its own environment.
    public let notice: String?

    public init(name: String, isReadOnly: Bool, isProduction: Bool, notice: String? = nil) {
        self.name = name
        self.isReadOnly = isReadOnly
        self.isProduction = isProduction
        self.notice = notice
    }
}
