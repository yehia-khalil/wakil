import Foundation

/// What an unlink did, and — more importantly — what it could not do.
///
/// A typed mirror of Go's `wakilcore.UnlinkOutcome`.
///
/// **It carries one permanent sentence: this phase creates a credential it
/// cannot destroy.** Removing the organisation's Keychain item is not the
/// same as revoking the credential that item held, and an operator who
/// reads "removed" as "revoked" has a live 365-day credential they believe
/// is gone.
public struct UnlinkReport: Sendable, Equatable, Decodable {
    public var recordRemoved: Bool
    /// Whether this organisation's Keychain item was deleted. False when
    /// there was none — which is not a failure, and is the state three
    /// bindings on this machine are in.
    public var credentialRemoved: Bool
    /// The stale pointers this unlink had to fix. **Not housekeeping**:
    /// left behind, the organisation file refuses to be written at all and
    /// the pane breaks its own form.
    public var pointersCleared: [String]
    /// Sharing records given the departing home's binary before it went.
    public var backfilled: [String]
    /// Whether no organisation holds this account any more — **the sole
    /// case where revoking is even offered**, and an offer it stays.
    public var wasLastBinding: Bool
    /// The directory left exactly as it was.
    public var configDir: String
    public var notes: [String]

    public init(
        recordRemoved: Bool = false, credentialRemoved: Bool = false,
        pointersCleared: [String] = [], backfilled: [String] = [],
        wasLastBinding: Bool = false, configDir: String = "", notes: [String] = []
    ) {
        self.recordRemoved = recordRemoved
        self.credentialRemoved = credentialRemoved
        self.pointersCleared = pointersCleared
        self.backfilled = backfilled
        self.wasLastBinding = wasLastBinding
        self.configDir = configDir
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordRemoved = try container.decodeIfPresent(Bool.self, forKey: .recordRemoved) ?? false
        credentialRemoved = try container.decodeIfPresent(Bool.self, forKey: .credentialRemoved) ?? false
        pointersCleared = try container.decodeIfPresent([String].self, forKey: .pointersCleared) ?? []
        backfilled = try container.decodeIfPresent([String].self, forKey: .backfilled) ?? []
        wasLastBinding = try container.decodeIfPresent(Bool.self, forKey: .wasLastBinding) ?? false
        configDir = try container.decodeIfPresent(String.self, forKey: .configDir) ?? ""
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case recordRemoved, credentialRemoved, pointersCleared, backfilled,
             wasLastBinding, configDir, notes
    }
}

/// What the confirmation must say before an unlink runs, and what the
/// offer afterwards may claim.
public enum UnlinkWording {
    /// The pane-local confirmation's sentence.
    ///
    /// **It states what will NOT be destroyed**, because that is the part
    /// an operator will otherwise assume. It names the account rather than
    /// rendering anything that could be a secret — the confirmation plane
    /// renders verbatim and unelided, which is exactly why this phase does
    /// not use it.
    public static func confirmation(for account: Account) -> String {
        "Unlink \(account.accountId) from \(account.org)? This removes the binding and this "
            + "organisation's stored credential. It does not delete the account's config "
            + "directory, and it cannot destroy the long-lived credential Wakil created for it — "
            + "that is revocable only in your Anthropic account."
    }

    /// The revocation offer, shown only on the last binding.
    ///
    /// **An offer, never automatic**, and it warns that the CLI lies:
    /// `claude auth logout` prints success when it revoked nothing, so
    /// anything shelling out to it reports a revocation it did not
    /// perform.
    public static let revocationOffer =
        "No organisation holds this account any more. You can revoke its credential in your "
            + "Anthropic account. Revoking through the CLI is not reliable — it reports success "
            + "even when it revoked nothing — so check the account rather than trusting a result."
}

/// Decodes `ctx_unlink_provider`'s reply.
///
/// Returns `nil` when the reply is not an unlink outcome, so the surface
/// can say the unlink's result is unknown rather than draw a report of
/// zeroes that reads as "nothing was removed".
public func decodeUnlinkReport(fromResult result: JSONValue?) -> UnlinkReport? {
    guard case .object(let object)? = result,
          case .object(let structured)? = object["structuredContent"],
          structured["recordRemoved"] != nil,
          let data = try? JSONEncoder().encode(JSONValue.object(structured))
    else { return nil }
    return try? JSONDecoder().decode(UnlinkReport.self, from: data)
}
