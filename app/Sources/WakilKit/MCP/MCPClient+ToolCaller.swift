import Foundation

/// `callTool` already has this exact signature, so the conformance is
/// empty: the port was extracted from the client, not imposed on it.
extension MCPClient: ToolCaller {}
