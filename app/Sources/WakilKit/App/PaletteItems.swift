import Foundation

/// The palette's session and provider rows, and the age label they carry.
/// Pure: no window state. Moved out of `WindowModel` (PR 2 of the split); the
/// window keeps same-named forwarders for its callers and tests.
enum PaletteItems {

    /// The pure half of `sessionPaletteItems`: `session_list`'s rows in,
    /// ⌘P rows out, with no registry or process behind it — Task 12.
    ///
    /// **Title precedence is `title` → `firstPrompt` → id.** `title` is
    /// the CLI's own `ai-title` summary of the transcript (Task 2) and
    /// beats everything once it exists; `firstPrompt` is up to 200 runes
    /// of the operator's own opening line (Task 5) and is the next-best
    /// label a transcript can offer; a session with neither still has to
    /// be pickable, so the id is the last resort rather than an empty row.
    ///
    /// **Collapsing.** Sessions arrive newest first (the brief's own
    /// guarantee), so in a chain of resumes the child always precedes the
    /// parent it was forked from. A row whose id appears as *some* row's
    /// `parent` is therefore not the newest member of its conversation and
    /// is dropped — the surviving row is the one the operator would resume
    /// anyway, and its subtitle says "resumed" plus how many hops were
    /// folded in, so a collapsed entry reads differently from a plain one.
    /// Collecting every row's `parent` into one set up front, rather than
    /// only comparing a row to its immediate neighbour, is what makes a
    /// three-deep chain (A forked to B, B forked to C) collapse all the
    /// way to C instead of leaving B's drop stop short and B or A behind
    /// as a second, misleading entry for the same conversation.
    ///
    /// **A parent whose child is not in this listing is kept.** Nothing
    /// names it as a `parent`, so it never enters the drop set — it is a
    /// session in its own right (its child may belong to another project,
    /// or its transcript may not be readable), and dropping it on the
    /// strength of a resume this listing cannot see would hide it
    /// entirely.
    nonisolated internal static func sessionItems(from rows: [JSONValue]) -> [PaletteItem] {
        var fieldsById: [String: [String: JSONValue]] = [:]
        for row in rows {
            guard case .object(let fields) = row, case .string(let id)? = fields["id"] else { continue }
            fieldsById[id] = fields
        }

        var parents = Set<String>()
        for fields in fieldsById.values {
            if case .string(let parent)? = fields["parent"] { parents.insert(parent) }
        }

        return rows.compactMap { row -> PaletteItem? in
            guard case .object(let fields) = row, case .string(let id)? = fields["id"] else { return nil }
            guard !parents.contains(id) else { return nil }

            var provider = ""
            if case .string(let value)? = fields["provider"] { provider = value }

            let title: String
            if case .string(let value)? = fields["title"], !value.isEmpty {
                title = value
            } else if case .string(let value)? = fields["firstPrompt"], !value.isEmpty {
                // 2d-i: what was sent may carry the identifier note, cut or whole; title by the typed text.
                title = TurnNote.title(value)
            } else {
                title = id
            }

            // Walks this row's own `parent` chain through the rows present
            // in this listing, counting how many hops were folded into it.
            // Stops at the first ancestor this listing does not carry
            // (another project, an unreadable transcript) rather than
            // treating that as part of the chain.
            //
            // `visited` guards against a cyclic lineage, which the
            // drop-set above does NOT rule out: `parents` only protects a
            // node that is itself *inside* a cycle (every member of a
            // cycle has an in-edge, so all of them land in `parents` and
            // get filtered before reaching this loop). A node that merely
            // *points into* a cycle — B → A where A → A — is nobody's
            // `parent`, so it survives that filter and reaches here, and
            // without a visited check the walk repeats A forever. This can
            // come from a malformed or hand-edited `sessions.json`, or
            // from two `session_record_parent` calls (A→A, then B→A) that
            // the write path does not itself reject.
            var absorbed = 0
            var cursor = fields
            var visited = Set([id])
            // The parent this row names counts even when the listing lacks it.
            var chain = Set([id])
            if case .string(let named)? = fields["parent"] { chain.insert(named) }
            while case .string(let parentId)? = cursor["parent"], let parentFields = fieldsById[parentId],
                  visited.insert(parentId).inserted {
                absorbed += 1
                chain.insert(parentId)
                if case .string(let named)? = parentFields["parent"] { chain.insert(named) }
                cursor = parentFields
            }

            // **The age leads, because the list is ordered by it.**
            // `ListSessions` sorts newest-first on `modTime` and has carried
            // that field since Phase 1; nothing in `app/` read it until
            // 2026-09-20, which is how the artboards came to draw an age
            // that the palette could not produce — and how it then came to be
            // struck from them for "not existing". It exists. What was
            // missing was this.
            var subtitle = ""
            if case .string(let stamp)? = fields["modTime"], let age = Self.age(ofRFC3339: stamp) {
                subtitle = age
            }
            if !provider.isEmpty {
                subtitle = subtitle.isEmpty ? provider : "\(subtitle) \u{00b7} \(provider)"
            }
            if absorbed > 0 {
                let resumed = "resumed \(absorbed)\u{00d7}"
                subtitle = subtitle.isEmpty ? resumed : "\(subtitle) \u{00b7} \(resumed)"
            }

            return PaletteItem(
                id: "session:\(id)", kind: .session, title: title,
                subtitle: subtitle, payload: id, chain: chain)
        }
    }

    /// Continue's rows without the chains live conversations hold: a row whose chain contains any
    /// of `sessions` is a conversation already running, listed once, among the live ones.
    nonisolated internal static func continueItems(
        _ items: [PaletteItem], excluding sessions: Set<String>
    ) -> [PaletteItem] {
        items.filter { $0.chain.isDisjoint(with: sessions) }
    }

    /// How long ago, in the artboards' own vocabulary: `2h 14m` inside a
    /// day, then `yesterday`, then `4d`, then a plain date.
    ///
    /// **Coarse on purpose, and never a future time.** The value is a file's
    /// mtime on this machine, so a clock that moved backwards or a transcript
    /// copied from elsewhere can date it ahead of now; that reads as "in 3h",
    /// which is nonsense about a session you already had. A non-positive
    /// interval falls through to `now`.
    ///
    /// `nonisolated` and `static` so a fixture test can pin it with no
    /// registry behind it, like every other mapper on this type.
    nonisolated internal static func age(
        ofRFC3339 stamp: String, now: Date = Date()
    ) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: stamp)
            ?? {
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: stamp)
            }()
        guard let date = parsed else { return nil }

        let seconds = now.timeIntervalSince(date)
        guard seconds > 0 else { return "now" }

        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return hours > 0 && minutes % 60 > 0 ? "\(hours)h \(minutes % 60)m" : "\(hours)h" }

        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 14 { return "\(days)d" }

        let display = DateFormatter()
        display.dateFormat = "d MMM"
        return display.string(from: date)
    }

    /// The pure half of `providerPaletteItems`: `ctx_list_providers`'s
    /// rows in, ⌘P rows out, with no registry or process behind it.
    ///
    /// **`payload` is the provider id, never the label.** `runPaletteItem`
    /// hands `payload` straight to `setProvider(_:)`, which takes an id —
    /// `LoadProviderFor` (Go side) resolves accounts by id, never by the
    /// human-facing label, so a row whose payload was its label would
    /// send `setProvider` a string it can never find a credential for.
    ///
    /// **Title prefers the label, falling back to the id.** A label is
    /// what an operator chose to call the account (`wakil provider add
    /// --label`); an id with no label is still shown, as the id, rather
    /// than producing a blank row — the identical "still pickable" logic
    /// `sessionItems(from:)` applies when a session has neither a title
    /// nor a first prompt.
    ///
    /// **Marking the running provider is the whole point of this
    /// method existing at all**: an operator opening ⌘P mid-switch must
    /// be able to see, without leaving the palette, which account is the
    /// one already running in this window — the same fact
    /// `WindowModel.providerLabel` puts on the bottom-edge indicator
    /// (Task 10), surfaced here a second way because the picker that
    /// lets you leave an account is exactly where you most want to be
    /// told you are still on it. `running` is compared against the row's
    /// id, never its label, for the same reason `payload` is the id
    /// above: `providerId` (what this window is actually running) is
    /// always an id, and a comparison against a label would silently
    /// never match a provider that happens to have one.
    nonisolated internal static func providerItems(
        from rows: [JSONValue], running: String, capacity: [CapacityReading] = [], now: Date = Date()
    ) -> [PaletteItem] {
        rows.compactMap { row -> PaletteItem? in
            guard case .object(let fields) = row, case .string(let id)? = fields["id"] else { return nil }

            var kind = ""
            if case .string(let value)? = fields["kind"] { kind = value }
            var label = ""
            if case .string(let value)? = fields["label"] { label = value }

            let title = label.isEmpty ? id : label
            // **The subtitle leads with "account", and that is the one row
            // kind in this palette that names itself.** No other does —
            // a project row's subtitle is its provider or its path, a
            // session row's is the provider it ran under — because until
            // 2b-vi nothing in ⌘P shared a *vocabulary* with anything else,
            // so the kind was always inferable from the row's shape.
            // Provider rows broke that: a session's subtitle is a provider
            // id, and a provider's title is the same id, so searching
            // "main" returns four session rows subtitled `main` and one
            // provider row titled `main` (the operator's walk, 2026-09-11).
            // Naming the kind here is what separates them; the word is
            // "account" rather than "provider" because ACCOUNT is what the
            // indicator says at the bottom edge, and the window should use
            // one word for one thing.
            var subtitle = kind.isEmpty ? "account" : "account \u{00b7} \(kind)"
            if id == running {
                subtitle += " \u{00b7} running"
            }
            var caution = false
            if let reading = capacity.first(where: { $0.account == id }) {
                let shown = CapacityDisplay.paletteText(reading, now: now)
                if !shown.text.isEmpty { subtitle += " \u{00b7} \(shown.text)" }
                caution = shown.low
            }

            return PaletteItem(
                id: "provider:\(id)", kind: .provider, title: title,
                subtitle: subtitle, payload: id, caution: caution)
        }
    }
}
