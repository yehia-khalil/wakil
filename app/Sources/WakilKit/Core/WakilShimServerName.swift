import Foundation

/// The `--mcp-config` key Wakil's own shim is registered under, and so the
/// `<server>` segment of every `mcp__<server>__<tool>` name the CLI gives
/// Wakil's tools (probe §4). One constant rather than a literal in each
/// place because `agentAllowedTools` (`App/AgentMCPConfig.swift`) has to name the same server
/// `agentMCPConfigJSON` defines: an allow entry naming a server that does
/// not exist grants nothing, and would look like a working allow list right
/// up until a live turn was denied.
public let wakilShimServerName = "wakil"
