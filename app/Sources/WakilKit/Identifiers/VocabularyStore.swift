import Foundation

/// Owns 2d-i's sources. Cached sources (schema, code) are rebuilt in the
/// background on a context change; live ones (Wakil, panes) are read on
/// every `current()`, which is cheap and always current. **A turn never
/// waits for a cached build**: `current()` answers with what is ready.
public actor VocabularyStore {
    private let live: [any IdentifierSource]
    private let cached: [any IdentifierSource]
    private let report: @Sendable (String, String) async -> Void
    private var context: ContextStore.ActiveContext?
    private var held: [Identifier] = []
    /// Bumped by every drop and every context change, so a build that
    /// finishes after either is discarded rather than merged (Invariant 4).
    private var generation = 0
    /// Running builds by generation; each removes itself when done.
    private var builds: [Int: Task<Void, Never>] = [:]

    public init(live: [any IdentifierSource], cached: [any IdentifierSource],
                report: @escaping @Sendable (String, String) async -> Void) {
        self.live = live
        self.cached = cached
        self.report = report
    }

    /// An org switch: nothing of the old org survives this call.
    public func dropAll() {
        generation += 1
        cancelBuilds()
        held = []
        context = nil
    }

    public func contextChanged(_ context: ContextStore.ActiveContext) {
        if self.context?.org != context.org { held = [] }
        generation += 1
        self.context = context
        cancelBuilds()
        let mine = generation
        let sources = cached
        builds[mine] = Task.detached {
            var names: [Identifier] = []
            for source in sources {
                if Task.isCancelled { break }
                do {
                    let gathered = try await source.gather(for: context)
                    names += gathered.names
                    for failure in gathered.failures {
                        await self.reportIfCurrent(source.name, failure, generation: mine)
                    }
                } catch {
                    await self.reportIfCurrent(source.name, error, generation: mine)
                }
            }
            await self.install(names, generation: mine)
            await self.buildEnded(mine)
        }
    }

    private func cancelBuilds() {
        for build in builds.values { build.cancel() }
    }

    private func buildEnded(_ mine: Int) { builds[mine] = nil }

    /// A build or read whose generation is stale reports nothing, and a
    /// cancellation is never a source failure.
    private func reportIfCurrent(_ name: String, _ error: Error, generation mine: Int) async {
        guard !(error is CancellationError) else { return }
        await reportIfCurrent(name, String(describing: error), generation: mine)
    }

    private func reportIfCurrent(_ name: String, _ message: String, generation mine: Int) async {
        guard mine == generation else { return }
        await report(name, message)
    }

    private func install(_ names: [Identifier], generation mine: Int) {
        guard mine == generation else { return }
        held = names
    }

    /// For tests: waits for the latest cached build to finish.
    func waitForRebuild() async { await builds[generation]?.value }

    /// For tests: waits for every build still running, stale ones included.
    func waitForAllBuilds() async {
        for build in Array(builds.values) { await build.value }
    }

    public func current() async -> Vocabulary {
        guard let context else { return .empty }
        let mine = generation
        var names = held
        for source in live {
            do {
                let gathered = try await source.gather(for: context)
                names += gathered.names
                for failure in gathered.failures { await reportIfCurrent(source.name, failure, generation: mine) }
            } catch { await reportIfCurrent(source.name, error, generation: mine) }
        }
        // A drop or context change ran while a live source was suspended:
        // what was gathered belongs to the old context (Invariant 4).
        guard mine == generation else { return .empty }
        return Vocabulary(names)
    }
}
