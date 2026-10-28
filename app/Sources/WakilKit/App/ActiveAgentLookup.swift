import Foundation

/// Which agent is running in a project or an environment of it, asked live (2e-ii).
///
/// `registerStandardActions` runs before the window exists, so the pin check on renaming and
/// removing a project or environment (Invariant 5) cannot capture `WindowModel.agents`. It
/// captures this box instead; `WakilWiring.useActiveContext(of:)` points it at the window, as
/// it does `ActiveShellContext`. Unwired — `--dispatch` has no window and so no agent — it
/// answers nil.
public final class ActiveAgentLookup: @unchecked Sendable {
    public typealias Source = @Sendable (_ project: String, _ environment: String?) async -> String?

    private let lock = NSLock()
    private var source: Source?

    public init() {}

    public func use(_ source: @escaping Source) {
        lock.lock()
        self.source = source
        lock.unlock()
    }

    /// The running agent's name, or nil. A synchronous helper takes the lock: Swift 6 forbids
    /// holding an `NSLock` across a suspension (see `ActiveShellContext.current`).
    public func agent(in project: String, environment: String?) async -> String? {
        guard let source = installedSource() else { return nil }
        return await source(project, environment)
    }

    private func installedSource() -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return source
    }
}

/// The window's live conversations, asked live (conversations 2 of 3): what `session_list`
/// lists beside the past sessions Go finds. Captured by `registerStandardActions` for
/// `ActiveAgentLookup`'s reason — no window exists yet — and pointed at the window by
/// `WakilWiring.useActiveContext(of:)`. Unwired, it answers none.
public final class LiveConversationLookup: @unchecked Sendable {
    public typealias Source = @Sendable (_ place: Place?) async -> [LiveConversation]
    public typealias Organization = @Sendable () async -> String?

    private let lock = NSLock()
    private var source: Source?
    private var organizationSource: Organization?

    public init() {}

    /// `organization` is the organisation on screen: whose live conversations an unpinned
    /// caller — the operator, `--dispatch` — is answered with (`session_list`).
    public func use(_ source: @escaping Source, organization: @escaping Organization) {
        lock.lock()
        self.source = source
        organizationSource = organization
        lock.unlock()
    }

    /// Every live conversation, or `place`'s, newest activity first.
    public func live(in place: Place?) async -> [LiveConversation] {
        guard let source = installed().source else { return [] }
        return await source(place)
    }

    /// The organisation on screen, or nil — unwired, or none chosen yet.
    public func organization() async -> String? {
        guard let organizationSource = installed().organization else { return nil }
        return await organizationSource()
    }

    private func installed() -> (source: Source?, organization: Organization?) {
        lock.lock()
        defer { lock.unlock() }
        return (source, organizationSource)
    }
}

/// Ticket noticing, Task 9: the window's hand-off Start and Cancel (`WindowModel.startHandOff`,
/// `cancelHandOff`), for the operator-only `ticket_hand_off` actions registered before any window
/// exists; pointed at the window by `WakilWiring.useActiveContext(of:)`, as
/// `LiveConversationLookup` is. With no window, a Start says so and a Cancel does nothing.
public final class TicketHandOffLookup: @unchecked Sendable {
    public typealias Start = @Sendable (TicketHandOffRequest, (@Sendable (String) -> Void)?) async throws -> String
    public typealias Cancel = @Sendable (String) async -> Void

    private let lock = NSLock()
    private var startSource: Start?
    private var cancelSource: Cancel?

    public init() {}

    public func use(start: @escaping Start, cancel: @escaping Cancel) {
        lock.lock()
        startSource = start
        cancelSource = cancel
        lock.unlock()
    }

    /// Starts the hand-off and returns its conversation's id; `reserved` hears the id before its
    /// first message goes, so a Cancel can name it.
    public func start(_ r: TicketHandOffRequest, reserved: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let start = installed().start else { throw TicketHandOffError(description: "no window to start the hand-off in") }
        return try await start(r, reserved)
    }

    /// Ends the conversation a Start reserved.
    public func cancel(_ conversation: String) async {
        await installed().cancel?(conversation)
    }

    private func installed() -> (start: Start?, cancel: Cancel?) {
        lock.lock()
        defer { lock.unlock() }
        return (startSource, cancelSource)
    }
}
