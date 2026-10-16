import Foundation

/// Whether `name` names the production environment.
///
/// **One function, two callers, deliberately.** `writeGate` decides whether a
/// mutation is refused outright; `VoidPalette.forEnvironment` decides whether
/// the room and the badge turn red. `VoidPalette` has always *claimed* the two
/// agree — *"a treatment that disagreed with the gate about what production is
/// would paint a safe-looking room around a refusal"* — and until 2026-09-14
/// they did not. The palette trimmed its input and the gate did not, so
/// `" production"` with a leading space painted the room red while the gate
/// saw an unrecognised name and returned `.gate`: an alarming room around a
/// *confirmable* write, the inverse of the failure that comment guards
/// against, and reachable because `WindowModel.setEnvironment` does not
/// normalise and `WakilWindow`'s environment field hands it a `TextField`'s
/// contents verbatim.
///
/// Deriving both from one function makes the claim true by construction rather
/// than by two implementations agreeing to stay in step — the same reason
/// `ProviderTokenRef` is derived from the provider id rather than stored, and
/// `ResolveProviderClaudePath` is read rather than copied in at registration:
/// a second copy of a rule is a second thing that can drift.
///
/// `nil` is not production — an action that names no target cannot be entering
/// one.
///
/// **Only the exact word matches, trimmed and case-folded.** `prod`, `prd` and
/// `live` deliberately do not, and that is not an oversight this function
/// should quietly correct. `writeGate`'s own note records the asymmetry as
/// intended: a `.mutate` against an unrecognised environment already returns
/// `.gate`, so those environments are *confirmed* rather than unguarded, and
/// widening the set here would silently convert a confirmable write into a
/// refused one for anyone whose production environment is spelled `prod`.
/// Whether it should is a product decision, and it belongs in the charter
/// before it belongs in this function.
/// **`declared` is Decision 26's flag, and it wins outright** (#182). The
/// environment says whether it is production; the name is consulted only
/// when it does not. Passing `nil` is "it declares nothing", not "it
/// declares false" — the distinction the Go side spends a `*bool` on.
///
/// Callers holding a whole project should use `EnvironmentProduction`
/// rather than looking a flag up themselves, so that the gate, the room and
/// the listing cannot come to different answers.
public func isProductionEnvironment(_ name: String?, declared: Bool? = nil) -> Bool {
    if let declared { return declared }
    guard let name else { return false }
    return foldEnvironmentName(name) == "production"
}

/// Which environments DECLARE whether they are production, read off the
/// active project (Decision 26, #182).
///
/// **One value, three readers.** The write gate, the void palette and the
/// environment listing all take this rather than each consulting a
/// predicate of their own. That is the same construction `isProductionEnvironment`
/// itself was created by on 2026-09-14: the palette and the gate had each
/// grown a copy of the rule, the copies drifted on whitespace, and
/// `" production"` painted a red room around a merely *confirmable* write.
/// A flag makes that failure mode cheaper to reach, not dearer — so the
/// answer travels as a value instead of being recomputed.
///
/// **Only declared environments appear.** Absent is not false: an
/// environment that declares nothing falls back to the name, which is what
/// every project on disk relies on. Materialising the default here would
/// stop every shipped project's production environment being production on
/// one release, silently.
public struct EnvironmentProduction: Equatable, Sendable {
    /// Name → declared flag, keyed by the folded name so a declaration
    /// reaches a name the operator typed with different case or a stray
    /// space — the whitespace bug again, one level up.
    public let declarations: [String: Bool]

    /// Nothing declared: every answer comes from the name, exactly as it
    /// did before Decision 26. The default everywhere, so a caller that has
    /// not been given the project's declarations behaves as this build's
    /// predecessor did rather than as though every environment declared
    /// false.
    public static let undeclared = EnvironmentProduction(declarations: [:])

    /// **Two names that fold alike resolve to `true` if either does.**
    /// `Dictionary.map` has no defined order and Swift seeds its hashing
    /// per process, so `{ _, last in last }` would let a safety property be
    /// decided by the hash seed — a different answer on a different launch,
    /// from the same configuration. `||` is deterministic and fails toward
    /// production, which is the direction this value is allowed to be
    /// wrong in.
    ///
    /// The case is pathological rather than expected: Go evaluates each
    /// environment against its own literal key and `setEnvironment`
    /// requires an exact match, so `"Prod"` and `"prod "` are two
    /// environments there and only one of them can ever be active. The
    /// fold exists so a declaration still reaches a name typed with
    /// different case or a stray space, which is the whitespace bug of
    /// 2026-09-14 one level up.
    public init(declarations: [String: Bool]) {
        self.declarations = Dictionary(
            declarations.map { (foldEnvironmentName($0.key), $0.value) },
            uniquingKeysWith: { a, b in a || b })
    }

    /// Whether `name` is production: its own declaration when it has one,
    /// and otherwise the name.
    public func isProduction(_ name: String?) -> Bool {
        guard let name else { return false }
        return isProductionEnvironment(name, declared: declarations[foldEnvironmentName(name)])
    }
}

/// `name` trimmed and case-folded — the comparison form used everywhere a
/// name is matched, so the trim cannot be present in one place and missing
/// in another.
func foldEnvironmentName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
