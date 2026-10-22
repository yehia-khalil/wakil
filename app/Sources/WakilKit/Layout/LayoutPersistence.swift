import Foundation

/// Reads and writes one `LayoutScope`'s pane arrangement under
/// `~/.wakil/layouts/<org>/<project>@<environment>.json`.
///
/// **Keyed by the same value both stores are keyed by**, which is the
/// whole of `LayoutScope`'s reason to exist: while this layer keyed on
/// `(org, project)` and the two stores keyed on a project name alone,
/// memory and disk could disagree about what an arrangement belonged to.
///
/// **Machine-local, and deliberately nowhere near `project.json`.** Where
/// someone likes their panes is not a property of the project that other
/// people check out, and `project.json` is committable. Nothing written
/// here is secret: pane ids, kinds, titles and rectangles.
///
/// **A bad file must never stop the app opening.** `load` returns `nil`
/// plus a human-readable note rather than throwing, and the window shows
/// that note in the same list that reports a missing Go binary or a socket
/// that would not bind — visible degradation over silent failure, which is
/// the convention 2a set.
public struct LayoutPersistence: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `<home>/.wakil/layouts`. Takes `home` rather than reading it, for
    /// the same reason `WakilWiring.build` takes its journal directory: a
    /// test must be able to point this somewhere scratch without setting a
    /// process-wide variable.
    public static func defaultDirectory(home: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(".wakil", isDirectory: true)
            .appendingPathComponent("layouts", isDirectory: true)
    }

    /// Writes the arrangement, and — for a conversation — refreshes the
    /// project's seed with it.
    ///
    /// **Two files for a conversation, on purpose.** The project's
    /// arrangement is what a brand-new conversation in a worked-in project
    /// opens on, and it would go stale the moment conversations started
    /// carrying their own: the operator would come back to a project after
    /// a month of work and find the panes they had before any of it. So
    /// the seed keeps being written as work proceeds — **except from an
    /// empty arrangement** (#161), which would answer "what should the
    /// next conversation here start from" with nothing, and overwrite the
    /// real answer to do it. The conversation's
    /// file is written first, because it is the one a failure must not
    /// cost — a stale seed is a worse starting point, a lost conversation
    /// is a lost workspace.
    ///
    /// **The seed written is the ACTIVE project's**, which matters only
    /// when a conversation is carried across a project change: the panes
    /// go into the project the operator is in, not the one the
    /// conversation began in. That keeps the project file meaning what it
    /// has always meant — the last arrangement worked on in this project —
    /// and it is the same file the same work would have overwritten before
    /// conversations had arrangements of their own. `WindowModel`
    /// refreshes the scope it holds on every project change precisely so
    /// this stays true.
    public func save(_ snapshot: LayoutSnapshot, for scope: LayoutScope) throws {
        // **The settings pane is excluded from the layout file entirely**
        // (Decision 30, 2e). Stripped here rather than filtered at each of
        // the two writes below, and stripped again on read — see
        // `layoutWithoutOverlayPanes` for why both sides.
        //
        // The strip happens BEFORE the emptiness guard below, deliberately.
        // A canvas holding nothing but a settings pane is an empty canvas
        // as far as this file is concerned, and writing it as a
        // one-pane-strong seed would make the next new conversation here
        // open on a pane that cannot be restored.
        let snapshot = layoutWithoutOverlayPanes(snapshot)
        try write(snapshot, to: fileURL(for: scope))
        guard scope.lineageRoot != nil else { return }
        // **Nothing is never a starting point** (#161). A conversation is
        // entitled to have no panes open — #142 names it as a state a
        // conversation can be in, and the line above records it, so it
        // survives a relaunch. What it may not do is push that state onto
        // the project: the seed exists to be what the NEXT new
        // conversation here opens on, and an empty one answers that
        // question with nothing while destroying the real answer.
        //
        // Observed rather than reasoned about: carrying a conversation
        // into a project it had never been arranged in wrote that
        // project's seed as `{"panes": []}`. It cost nothing there because
        // the project had no seed yet.
        //
        // **The asymmetry stops here, at the seed a CONVERSATION
        // refreshes.** A project-scoped save still writes whatever it is
        // handed, empty or not: an operator who closed every pane in a
        // project meant to close them, which is the same judgement
        // `activateLayout` makes when it refuses to resurrect an emptied
        // canvas on the way back in.
        guard !snapshot.panes.isEmpty else { return }
        try write(snapshot, to: fileURL(for: scope.projectSeed))
    }

    /// Writes `snapshot` to `scope`'s file **without** the overlay strip
    /// `save` applies.
    ///
    /// `internal`, and a test seam rather than an API: it produces the one
    /// file `save` cannot — the one a hand-editing operator, or a build
    /// from before Decision 30 landed, leaves behind. The read side has to
    /// strip too, and the only honest way to pin that is to hand it such a
    /// file.
    func writeUnstripped(_ snapshot: LayoutSnapshot, for scope: LayoutScope) throws {
        try write(snapshot, to: fileURL(for: scope))
    }

    private func write(_ snapshot: LayoutSnapshot, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Sorted keys so an unchanged arrangement encodes to identical
        // bytes run after run; `SnapGraph` sorts its own links for the
        // same reason. A file that churns on every launch is a file whose
        // modification time means nothing.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(snapshot).write(to: file, options: .atomic)
    }

    /// The saved arrangement, or `nil` with a note explaining why not.
    ///
    /// A file that was never written is `(nil, nil)` — absence is not
    /// degradation, and a note on every first run would train the operator
    /// to ignore the notes list.
    ///
    /// **The `note` channel exists for more than a corrupt file.** Spec
    /// §4.3 also wants a stale one caught: a saved layout naming a pane
    /// kind that no longer exists should be dropped, pane by pane, with a
    /// note, rather than restored wholesale or rejected wholesale. **That
    /// check now happens**, in `layoutDroppingUnknownPaneKinds`, through
    /// the `note` channel this signature was shaped for. It waited on the
    /// validity set it needed: this method declined to hardcode `["db"]`
    /// as a stand-in for a set "that belongs to whatever registers pane
    /// kinds", and `Pane.kinds` is now that set — added in 2c-i, after an
    /// agent opened three panes of a kind (`"database"`) nothing drew and
    /// nothing routed to.
    ///
    /// **A conversation with no file of its own opens on the project's.**
    /// Every file written before #147 is project-keyed and cannot be
    /// mapped to a lineage — the information is not in it — so those files
    /// become the seed rather than being migrated or discarded. Nothing is
    /// renamed and nothing is deleted.
    ///
    /// Since #160 "of its own" means *in this project*: a conversation
    /// carried into a project it has never been arranged in opens on that
    /// project's seed, which is what the operator expects a project switch
    /// to do and what it already does on the Landing.
    ///
    /// The fallback is on ABSENCE only — which, per the paragraph above,
    /// is not degradation. A conversation's file that exists and cannot be
    /// read is, so it returns the note and not the seed: falling through
    /// would hand the operator a plausible arrangement that is not theirs,
    /// with nothing to say the one they made is still on disk and broken.
    ///
    /// **A file written before the environment joined the scope seeds every
    /// environment** (Plan 3, ruling R3). Each level — the conversation's,
    /// then the project's — reads its own `<key>@<env>.json` first; when
    /// that is absent, the file the same level had before, filed under the
    /// project's display name (`legacyName`, which is what the window used
    /// until then) and then under the key. **Read-only:** `save` writes
    /// only the per-environment path, so the legacy file stays as it was
    /// and seeds every environment that has no file of its own yet.
    /// Rollback is reverting the branch, which finds it untouched.
    public func load(
        for scope: LayoutScope, legacyName: String? = nil
    ) -> (snapshot: LayoutSnapshot?, note: String?) {
        let own = readFallingBack(scope, legacyName: legacyName)
        guard scope.lineageRoot != nil, own.snapshot == nil, own.note == nil else { return own }
        // Absent, and this conversation has never been arranged: the
        // project's arrangement is the starting point. Reported as the
        // SEED's own note rather than the conversation's, because that is
        // whose file was read.
        return readFallingBack(scope.projectSeed, legacyName: legacyName)
    }

    /// `scope`'s own file, else its level's legacy files (R3), stopping at
    /// the first that exists — a legacy file that cannot be read is a note,
    /// like any other.
    private func readFallingBack(
        _ scope: LayoutScope, legacyName: String?
    ) -> (snapshot: LayoutSnapshot?, note: String?) {
        let own = read(fileURL(for: scope), describedAs: scope)
        guard own.snapshot == nil, own.note == nil else { return own }
        var names = [scope.project]
        if let legacyName, !legacyName.isEmpty, legacyName != scope.project { names.insert(legacyName, at: 0) }
        for name in names {
            let legacy = read(legacyFileURL(for: scope, project: name), describedAs: scope)
            if legacy.snapshot != nil || legacy.note != nil { return legacy }
        }
        return (nil, nil)
    }

    private func read(
        _ file: URL, describedAs scope: LayoutScope
    ) -> (snapshot: LayoutSnapshot?, note: String?) {
        guard let data = try? Data(contentsOf: file) else { return (nil, nil) }
        do {
            let decoded = try JSONDecoder().decode(LayoutSnapshot.self, from: data)
            // Stripped on the way in as well as on the way out, because
            // this build is not the only thing that writes these files: an
            // operator hand-editing configuration is the product, and a
            // file written before this ruling landed is already on disk.
            // Silently, with no note: a settings pane in a file is not a
            // stale pane kind the operator needs telling about — this
            // build draws that kind perfectly well, it just never restores
            // one. A Git pane is migrated, not dropped (3b-iii).
            let checked = layoutDroppingUnknownPaneKinds(layoutMigratingGitPanes(layoutWithoutOverlayPanes(decoded)))
            return (checked.snapshot, checked.note.map { "layout for \(scope): \($0)" })
        } catch {
            return (nil, "layout for \(scope) could not be read (\(error)); starting from an empty canvas")
        }
    }

    /// One file per project and environment at `<org>/<project>@<env>.json`,
    /// and one per conversation **per project and environment** at
    /// `<org>/conversations/<root>/<project>@<env>.json`.
    ///
    /// **Every file already on disk is still found** under the name it
    /// already has, through `load`'s legacy read (R3) — nothing is migrated
    /// and nothing is discarded.
    ///
    /// **A conversation's path carries the project (#160), and it must
    /// carry exactly what `LayoutScope`'s identity carries.** It did not
    /// until 2026-09-20: #147 dropped the project here and hand-wrote the
    /// scope's `Hashable` to drop it too, so that memory and disk agreed —
    /// which they did, on a rule the operator then walked into. Switching
    /// to a project with no sessions at all left the previous project's
    /// panes on screen, because one conversation was one arrangement
    /// however many projects it was visited from. The two halves moved
    /// back together for the same reason they moved away together: keyed
    /// differently, memory and disk disagree about what an arrangement
    /// belongs to, which is the failure `LayoutScope` exists to make
    /// unrepresentable.
    ///
    /// **A file written under the old path is simply not found**, and the
    /// conversation opens on the project's seed — #147's own rule for an
    /// arrangement that cannot be mapped. Nothing is renamed and nothing
    /// is deleted; `<org>/conversations/<root>.json` is left where it
    /// lies, which #142's "reclamation is by absence, not by deletion"
    /// already covers.
    ///
    /// **Nothing can collide.** A project writes `<name>@<env>.json` directly
    /// under the org; a conversation writes inside a `conversations`
    /// directory, under a subdirectory named for its root. A project
    /// actually called `conversations` writes `conversations@<env>.json`, a
    /// different name from the `conversations/` directory beside it. And a
    /// root's subdirectory cannot be confused with the flat file #147
    /// wrote: one is `<root>/`, the other `<root>.json`.
    ///
    /// Org, project and root names are flattened before use: the first two
    /// come from a user-authored registry, and one containing `/` or `..`
    /// would otherwise write outside `directory`. Replacing rather than
    /// rejecting keeps a legal-but-awkward project name working; the
    /// mapping need not be reversible, because nothing ever reads these
    /// names back off the filesystem. A lineage root is a UUID Wakil
    /// minted, so flattening it is belt and braces — it is applied anyway,
    /// because the value arrives over the wire from a store an operator
    /// can hand-edit.
    ///
    /// **The environment is in the file name (Plan 3)**:
    /// `<project>@<environment>.json`, where `<project>` is the registry
    /// key. `@` is flattened out of both halves, so no key and environment
    /// can spell another pair's file, and an empty environment flattens to
    /// `_` — never the bare `<project>.json` every release before this
    /// wrote, which `save` must not overwrite (R3).
    private func fileURL(for scope: LayoutScope) -> URL {
        let name = "\(flattenPart(scope.project))@\(flattenPart(scope.environment)).json"
        return levelDirectory(for: scope).appendingPathComponent(name)
    }

    /// 2e-ii. Moves every `<from>@<environment>.json` of an organisation to `<to>@…`, so a renamed
    /// project comes back with its panes — the project's own files and each conversation's under
    /// `conversations/<root>/`, which carry the project too (final review Important 1: a place shown
    /// in a conversation otherwise came back on the project's seed). A project with nothing saved
    /// is a no-op, and a file already under the new name is replaced — the rename is the later word.
    public func renameProject(organization: String, from: String, to: String) throws {
        let prefix = "\(flattenPart(from))@"
        for level in levels(of: organization) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: level.path)) ?? []
            for file in files where file.hasPrefix(prefix) && file.hasSuffix(".json") {
                try move(level.appendingPathComponent(file),
                         to: level.appendingPathComponent("\(flattenPart(to))@" + file.dropFirst(prefix.count)))
            }
        }
    }

    /// 2e-ii. Moves one environment's files, `<project>@<from>.json` to `<project>@<to>.json`, at
    /// the org level and in every conversation. Same rules as `renameProject`.
    public func renameEnvironment(organization: String, project: String, from: String, to: String) throws {
        for level in levels(of: organization) {
            try move(level.appendingPathComponent("\(flattenPart(project))@\(flattenPart(from)).json"),
                     to: level.appendingPathComponent("\(flattenPart(project))@\(flattenPart(to)).json"))
        }
    }

    /// Every directory an organisation files arrangements in: its own, then each conversation's.
    private func levels(of organization: String) -> [URL] {
        let org = directory.appendingPathComponent(flatten(organization), isDirectory: true)
        let conversations = org.appendingPathComponent("conversations", isDirectory: true)
        let roots = (try? FileManager.default.contentsOfDirectory(atPath: conversations.path)) ?? []
        return [org] + roots.sorted().map { conversations.appendingPathComponent($0, isDirectory: true) }
    }

    private func move(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path), source != destination else { return }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: source, to: destination)
    }

    /// Where `scope`'s level kept its file before the environment joined
    /// the path: `<project>.json` in the same directory, `project` being
    /// the display name or the key. Read, never written (R3).
    private func legacyFileURL(for scope: LayoutScope, project: String) -> URL {
        levelDirectory(for: scope).appendingPathComponent("\(flatten(project)).json")
    }

    /// The org's directory for a project's arrangement; a conversation's
    /// root's directory inside `conversations` for a conversation's.
    private func levelDirectory(for scope: LayoutScope) -> URL {
        let org = directory.appendingPathComponent(flatten(scope.organization), isDirectory: true)
        guard let lineageRoot = scope.lineageRoot else { return org }
        return org
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent(flatten(lineageRoot), isDirectory: true)
    }

    /// `flatten`, and `@` too, which separates the key from the environment.
    private func flattenPart(_ name: String) -> String {
        flatten(name).replacingOccurrences(of: "@", with: "_")
    }

    private func flatten(_ name: String) -> String {
        let cleaned = name.map { character -> Character in
            character == "/" || character == ":" || character == "\\" ? "_" : character
        }
        let result = String(cleaned).replacingOccurrences(of: "..", with: "__")
        return result.isEmpty ? "_" : result
    }
}
