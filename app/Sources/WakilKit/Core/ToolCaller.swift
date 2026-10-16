import Foundation

/// The one operation the action layer performs against a capability
/// process: call a tool by name and read its raw `result`.
///
/// **Why this exists as a protocol and `MCPClient` alone did not suffice.**
/// The handlers `registerStandardActions` builds were registered against
/// the concrete actor, which owns a subprocess. That left a test exactly
/// one seam — spawn a fake MCP server in `/bin/sh`, handshake with it, and
/// grep a request log — and the cost is recorded in the code it produced:
/// a suite of sixty-odd tests that had to be `.serialized` to stop its
/// shells competing for the machine (`DBActionTests`, 65 tests when the
/// `.serialized` came off), three functions extracted only so something
/// could be tested without a client, and 18 of 26 registered actions with
/// no reachable missing-client path.
///
/// The three functions, so the count can be checked rather than taken:
/// `mutationCallFailure` and `dbPaneContents` in `StandardActions.swift`,
/// and `ContextStore.parseActiveContext`. Each says so in its own doc
/// comment, and each now stands on a second reason as well — the port
/// made the callers around them testable too.
///
/// **What is deliberately NOT here.** Lifecycle — `start`, `stop`, the
/// restart-in-place `AppWiring` performs on an org switch — and the reply
/// budgets (`MCPClient.readReplyTimeout`, `MCPClient.mutationReplyTimeout`)
/// stay on the concrete type. A caller that needs those needs the client,
/// not the port, and `AppWiring` is that caller. Adding a second
/// requirement here is a design change, not a convenience.
///
/// **Two adapters, so the seam is real rather than hypothetical:**
/// `MCPClient` over a subprocess in production, and `RecordingToolCaller`
/// in the test target.
///
/// Invariant 10 is unweakened by this: the port is a caller's view of a
/// capability process from the action side, and the capability layer stays
/// a separate headless process (Decision 3).
public protocol ToolCaller: Sendable {
    /// Calls `name` with `arguments` and returns the raw `result` value.
    ///
    /// A server-side tool failure — the `wakil-ctx` pattern of returning a
    /// `CallToolResult` carrying `isError: true` — is a *successful* call
    /// and comes back as a normal result object. Only a transport- or
    /// protocol-level failure throws. `callChecked` in `StandardActions`
    /// is what reads the tool-specific `isError` out of the result, and
    /// every handler goes through it.
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue
}
