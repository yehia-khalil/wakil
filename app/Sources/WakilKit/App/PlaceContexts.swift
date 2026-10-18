import Foundation

/// What `get_context` says about an agent session's place: its roots, for the git and
/// editor actions and a terminal's start directory, and its production declarations, for the
/// gate. Read through the pool's `wakil-ctx` pinned to that place (`PlaceClients`), so the
/// answer is that place's own project and never the window's.
///
/// Once per place, with concurrent first reads sharing one call. Only a success is kept: a
/// failed read is forgotten, so the next call tries again. `WindowModel` calls `retain` beside
/// `PlaceClients.retain`, so a place no session holds any more is read afresh if it returns.
public actor PlaceContexts {
    private let clients: PlaceClients
    private var contexts: [Place: Task<ContextStore.ActiveContext, Error>] = [:]

    public init(clients: PlaceClients) { self.clients = clients }

    public func context(for place: Place) async throws -> ContextStore.ActiveContext {
        let task: Task<ContextStore.ActiveContext, Error>
        if let reading = contexts[place] {
            task = reading
        } else {
            let clients = clients
            task = Task { try await ContextStore(client: clients.client(.context, for: place)).current() }
            contexts[place] = task
        }
        do {
            return try await task.value
        } catch {
            // Only this read's own entry: a retain may have dropped it meanwhile.
            if contexts[place] == task { contexts[place] = nil }
            throw error
        }
    }

    /// Drops what is kept for `place`, so the next call reads it again. `WindowModel` calls it
    /// whenever it reads that place itself: the window's read is the newer one, and a
    /// production declaration changed since must price the agent's next mutation.
    public func forget(_ place: Place) {
        contexts[place] = nil
    }

    public func retain(_ places: Set<Place>) {
        contexts = contexts.filter { places.contains($0.key) }
    }
}
