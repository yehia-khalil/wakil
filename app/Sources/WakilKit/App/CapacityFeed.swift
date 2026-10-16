import Foundation
import Observation

/// The window's capacity readings: records what the stream reports, and
/// holds the latest `ctx_capacity` answer for the three surfaces. Extracted
/// from `WindowModel` the way `GitRootWatcher` and `TerminalMirrorFeed` were;
/// the model only owns it and forwards events.
@MainActor @Observable
public final class CapacityFeed {
    public private(set) var readings: [CapacityReading] = []
    public private(set) var failure: String?

    @ObservationIgnored private var dispatch: (@MainActor (String, JSONValue) async throws -> JSONValue)?
    /// Bumped by `reset()`; a reply that started under an older value is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The registry route. Attached by `WindowModel` at the end of its
    /// `init`, because the closure needs `self`; until then nothing is sent.
    func attach(dispatch: @escaping @MainActor (String, JSONValue) async throws -> JSONValue) {
        self.dispatch = dispatch
    }

    /// Forgets the readings and the failure, keeping the route: an org
    /// switch must not show the outgoing org's numbers.
    func reset() {
        generation += 1
        readings = []
        failure = nil
    }

    public func reading(for account: String) -> CapacityReading? {
        readings.first { $0.account == account }
    }

    /// One stream reading for `provider`, the account the producing session
    /// ran under. An empty provider (none chosen yet) records nothing.
    func receive(_ windows: CapacityWindows, provider: String) async {
        guard !provider.isEmpty, let dispatch else { return }
        _ = try? await dispatch("capacity_record",
                                capacityRecordParams(provider: provider, windows: windows, asOf: now()))
        await refresh()
    }

    /// Re-reads every provider. A failed read keeps the last readings on
    /// screen with their own "as of", and says why (Rule 8). `probe` asks Go
    /// to probe stale Claude accounts first (a 1-token request each, at most
    /// once a minute per account); only launch, a switch and a turn's end pass it.
    public func refresh(probe: Bool = false) async {
        guard let dispatch else { return }
        let started = generation
        do {
            let params: JSONValue = probe ? .object(["refresh": .bool(true)]) : .object([:])
            let result = try await dispatch("ctx_capacity", params)
            // An org switch reset the feed while this was in flight: the reply is the old org's.
            guard started == generation else { return }
            guard let listing = decodeCapacityListing(fromResult: result) else {
                failure = "capacity could not be read: the reply was not a capacity listing"
                return
            }
            readings = listing.readings
            failure = nil
        } catch {
            guard started == generation else { return }
            failure = "capacity could not be read: \(error)"
        }
    }
}
