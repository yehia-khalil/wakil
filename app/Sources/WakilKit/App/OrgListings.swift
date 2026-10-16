import Foundation

/// The org plane's and the context line's listings, parsed from `ctx_*` results.
/// Pure: no window state. Moved out of `WindowModel` (PR 2 of the split); the
/// window keeps same-named forwarders for its callers and tests.
enum OrgListings {
    typealias OrgListing = WindowModel.OrgListing
    typealias MachineProviderListing = WindowModel.MachineProviderListing
    typealias ProjectListing = WindowModel.ProjectListing

    /// Reads `structured[key]` as `Int`, accepting either `JSONValue` numeric
    /// case (§`JSONValue.integer`'s own doc comment: a whole number the JSON
    /// wire may have carried as either).
    nonisolated static func intField(_ structured: [String: JSONValue], _ key: String) -> Int {
        switch structured[key] {
        case .integer(let value)?: return Int(value)
        case .number(let value)?: return Int(value)
        default: return 0
        }
    }

    nonisolated static func stringField(_ structured: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let value)? = structured[key], !value.isEmpty else { return nil }
        return value
    }

    /// The pure half of `listOrgs()`: `ctx_list_orgs`'s rows in, `OrgListing`
    /// rows out, with no registry or process behind it — the same split
    /// `PaletteItems.sessionItems(from:)` and `providerItems(from:)` already use.
    nonisolated internal static func orgListings(from rows: [JSONValue]) -> [OrgListing] {
        rows.compactMap { row -> OrgListing? in
            guard case .object(let fields) = row, case .string(let id)? = fields["id"] else { return nil }
            return OrgListing(
                name: id, displayName: stringField(fields, "displayName"),
                jiraBase: stringField(fields, "jiraBase"),
                accounts: intField(fields, "accounts"))
        }
    }

    nonisolated internal static func machineProviderListings(
        from rows: [JSONValue]
    ) -> [MachineProviderListing] {
        rows.compactMap { row -> MachineProviderListing? in
            guard case .object(let fields) = row,
                  case .string(let org)? = fields["org"],
                  case .string(let id)? = fields["id"],
                  case .string(let kind)? = fields["kind"]
            else { return nil }
            return MachineProviderListing(
                org: org, providerId: id, kind: kind,
                label: stringField(fields, "label"),
                configDir: stringField(fields, "configDir"),
                homeOrg: stringField(fields, "homeOrg"))
        }
    }

    /// The pure half of `listProjects()` — the same split `orgListings`,
    /// `sessionItems` and `providerItems` already use, so the row mapping is
    /// pinnable by a fixture test with no registry or child process behind
    /// it.
    ///
    /// **Sorted by name**, matching `projectPaletteItems`' own
    /// `projects.keys.sorted()`: a dictionary has no order, and two controls
    /// listing the same projects in two different orders is a defect the
    /// operator sees long before anyone reads the code.
    nonisolated internal static func projectListings(
        from projects: [String: JSONValue]
    ) -> [ProjectListing] {
        projects.keys.sorted().map { name in
            guard case .object(let entry)? = projects[name] else {
                return ProjectListing(name: name, provider: nil, path: nil)
            }
            return ProjectListing(
                name: name,
                provider: stringField(entry, "provider"),
                path: stringField(entry, "path"))
        }
    }

    /// The pure half of `listEnvironments()`.
    ///
    /// **The rows live under an `environments` key** (Decision 26, #182).
    /// The tool used to answer a flat `map[string]bool` and the whole
    /// `structuredContent` object WAS the map; it could say one thing, and
    /// the `production` flag had nowhere to go, so the app went on deciding
    /// production by comparing the name. Each row now carries `readOnly` and
    /// `production`, and the object has room for `notices` beside them.
    ///
    /// **A flat boolean is still accepted, and degrades to the name rule.**
    /// `bin/` is per-worktree and routinely stale, so a window may open
    /// against a `wakil-ctx` built before this change — the same hazard
    /// `parseActiveContext` handles for `RootPaths`. The fallback is the
    /// rule every build before this one used, and the alternative is a
    /// context line with no environments in it at all.
    ///
    /// **Sorted by name** for `projectListings`' reason. A row whose shape is
    /// neither is dropped rather than coerced: an environment whose
    /// read-only state cannot be read must not be drawn as writable, which
    /// is the direction a `?? false` would fail in.
    nonisolated internal static func environmentListings(
        from structured: [String: JSONValue]
    ) -> [EnvironmentListing] {
        if case .object(let rows)? = structured["environments"] {
            return rows.keys.sorted().compactMap { name in
                guard case .object(let row)? = rows[name],
                      case .bool(let readOnly)? = row["readOnly"] else { return nil }
                guard case .bool(let isProduction)? = row["production"] else { return nil }
                var notice: String?
                if case .string(let text)? = row["notice"], !text.isEmpty { notice = text }
                return EnvironmentListing(
                    name: name, isReadOnly: readOnly, isProduction: isProduction, notice: notice)
            }
        }
        return structured.keys.sorted().compactMap { name in
            guard case .bool(let readOnly)? = structured[name] else { return nil }
            return EnvironmentListing(name: name, isReadOnly: readOnly,
                                      isProduction: isProductionEnvironment(name))
        }
    }

    nonisolated public static func adoptionCandidates(
        from rows: [MachineProviderListing], excluding org: String
    ) -> [MachineProviderListing] {
        func identity(_ row: MachineProviderListing) -> String {
            if let configDir = row.configDir, !configDir.isEmpty {
                return "dir:\(configDir)"
            }
            return "id:\(row.homeOrg ?? row.org)/\(row.providerId)"
        }
        let alreadyIn = Set(rows.filter { $0.org == org }.map(identity))
        var seen = Set<String>()
        var result: [MachineProviderListing] = []
        for row in rows where row.org != org {
            let key = identity(row)
            guard !alreadyIn.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(row)
        }
        return result
    }

    /// Derives a candidate org identifier from a human display name, for
    /// the Creating state's identifier field (spec §8.1.1 / §9): typing
    /// "Initech Labs" proposes `initech-labs`. `public static`, not merely
    /// `internal`, for the same reason `adoptionCandidates(from:excluding:)`
    /// above is — `OrgPlane` (`WakilApp`, no `@testable import` available to
    /// it) calls this directly, and `WakilApp` has no test target, so this
    /// is where the rule has to live to be testable at all.
    ///
    /// Must produce a token `validateOrgToken` accepts
    /// (`internal/wakilcore/paths.go`'s `orgFileTokenPattern`): starts with
    /// a letter or digit, then only letters, digits, dot, dash or
    /// underscore. Rather than special-case every punctuation mark the
    /// pattern forbids, this collapses EVERYTHING that is not an ASCII
    /// letter or digit — including whitespace, `.`/`-`/`_` themselves, and
    /// any non-ASCII character — into a single `-`, and drops a separator
    /// run entirely at the very start (the pattern's first-character rule)
    /// and at the very end (nothing to flush once the loop ends). One rule
    /// handles spaces, case, leading/trailing junk, repeated separators and
    /// non-ASCII input alike, rather than five special cases that could
    /// drift out of step with each other.
    ///
    /// Returns `nil` when nothing survives (an all-punctuation or
    /// all-non-ASCII name) — the caller leaves the identifier field EMPTY
    /// in that case, never a generated placeholder like "org" or "new",
    /// which would look like a proposal the operator never made.
    nonisolated public static func slugForOrgIdentifier(from name: String) -> String? {
        var slug = ""
        var pendingSeparator = false
        for ch in name.lowercased() where ch.isASCII {
            if ch.isLetter || ch.isNumber {
                if pendingSeparator && !slug.isEmpty {
                    slug.append("-")
                }
                pendingSeparator = false
                slug.append(ch)
            } else if !slug.isEmpty {
                pendingSeparator = true
            }
        }
        // Any character that failed `ch.isASCII` above (including every
        // non-ASCII letter) never reaches either branch, so it is handled
        // implicitly — it is simply skipped, exactly as an ASCII separator
        // is, rather than needing its own case.
        return slug.isEmpty ? nil : slug
    }
}
