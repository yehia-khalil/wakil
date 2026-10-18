import Foundation

/// What one `runDebugScript` run produced: its output lines, and how many
/// of them were error lines.
///
/// `failureCount` exists so a caller can report failure without inspecting
/// the JSON it just printed. `--dispatch` turns it into a non-zero exit
/// code, and deciding that by searching the output text for `"error"`
/// would misread a *successful* result that happens to contain that word
/// (a database row, say) as a failed line.
public struct DebugScriptResult: Sendable {
    public let lines: [String]
    public let failureCount: Int

    public init(lines: [String], failureCount: Int) {
        self.lines = lines
        self.failureCount = failureCount
    }
}

/// Runs a debug script — one JSON object per element of `lines`, each shaped
/// `{"action": "...", "params": {...}, "confirmation": "..."}` with
/// `confirmation` optional — against `registry`, dispatching every line with
/// `origin: .debug`.
///
/// This is the second of the registry's real (non-test) consumers, the
/// first being the MCP `tools/call` bridge (`origin: .agent`, see
/// `MCPServer.handleToolsCall`). Spec §4 names three; the third is the
/// window's controls, which dispatch with `origin: .ui` (see
/// `WindowModel.dispatch` in App/WindowModel.swift), added in Task 11 after
/// this file. Getting this consumer in before the window is
/// deliberate: it is what lets an operator drive `ActionRegistry.dispatch`
/// — the one chokepoint every state change passes through — from a file
/// instead of by clicking, so the chokepoint is exercised by something
/// other than the UI from the start rather than having a second entry
/// point retrofitted around a UI-shaped one.
///
/// Returns exactly one output line per input line, in the same order, so
/// output line N always describes input line N. (`--dispatch` filters
/// blank lines out of a file before calling this, so its correspondence is
/// to the file's non-empty lines; this function itself makes no such
/// exception — an empty string in `lines` is a line that fails to parse.)
/// A line that fails for any reason — malformed JSON, a missing `"action"`
/// field, an unknown action name, a write-gate refusal, or a handler
/// throwing — produces a JSON object with an `"error"` key and does **not**
/// stop the remaining lines from running. An operator uses one script to
/// check several behaviours in one pass (per
/// docs/superpowers/specs/2026-09-07-phase-2a-spine-design.md §8's operator
/// checklist); aborting on the first failure would hide every result after
/// it.
///
/// This function never pre-checks whether `name` is registered before
/// calling `dispatch`. `dispatch` already journals every outcome it can
/// produce, including an unrecognized name (outcome `"unknown"`) — a
/// pre-check here would either duplicate that decision or, if it disagreed,
/// dispatch a name that skips the very journal entry `dispatch` exists to
/// write for it.
public func runDebugScript(
    _ lines: [String],
    registry: ActionRegistry,
    environment: String
) async -> [String] {
    await runDebugScriptReportingFailures(lines, registry: registry, environment: environment).lines
}

/// `runDebugScript`, additionally reporting how many lines produced an
/// error line. Identical in every other respect — see that function's doc
/// comment, which is the contract both share.
public func runDebugScriptReportingFailures(
    _ lines: [String],
    registry: ActionRegistry,
    environment: String
) async -> DebugScriptResult {
    var output: [String] = []
    output.reserveCapacity(lines.count)
    var failureCount = 0
    for line in lines {
        let outcome = await dispatchOneDebugLine(line, registry: registry, environment: environment)
        output.append(outcome.line)
        if outcome.isFailure { failureCount += 1 }
    }
    return DebugScriptResult(lines: output, failureCount: failureCount)
}

/// Parses and dispatches one line of a debug script, returning the output
/// line and whether it is an error line. Never throws: every failure mode
/// becomes an `{"error": "..."}` line instead, since a thrown error here
/// would abort `runDebugScript`'s loop and defeat the entire point of that
/// function (see its doc comment). `isFailure` is decided here, where the
/// failure is known, rather than inferred later from the text.
private func dispatchOneDebugLine(
    _ line: String,
    registry: ActionRegistry,
    environment: String
) async -> (line: String, isFailure: Bool) {
    let parsed: JSONValue
    do {
        parsed = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    } catch {
        return (encodeDebugErrorLine("invalid JSON: \(error)"), true)
    }

    guard case .object(let obj) = parsed, case .string(let name)? = obj["action"] else {
        return (encodeDebugErrorLine(#"each line must be a JSON object with a string "action" field"#), true)
    }
    let params = obj["params"] ?? .object([:])
    // `--dispatch` names an environment and nothing else; the organisation
    // and project are empty, which the journal records as absent.
    let caller = DispatchCaller(
        place: Place(organization: "", project: "", environment: environment), session: nil)
    var confirmation: String?
    if case .string(let c)? = obj["confirmation"] {
        confirmation = c
    }

    do {
        let result = try await registry.dispatch(
            name: name,
            params: params,
            origin: .debug,
            caller: caller,
            confirmation: confirmation
        )
        return (encodeDebugLine(result), false)
    } catch {
        // A mutation whose reply budget ran out is journalled `"uncertain"`
        // beside `dispatch`'s own `"error"` line, so the audit trail of a
        // `--dispatch` run — which is how `phase-2b-iii-acceptance.md`
        // check 1 confirms a mutation — cannot read as "nothing happened"
        // when the truth is "nobody knows". No-op for every other failure.
        // See `recordUncertainMutation`.
        await recordUncertainMutation(
            error, registry: registry, action: name, params: params, origin: .debug,
            caller: caller)
        return (encodeDebugErrorLine("\(error)"), true)
    }
}

private func encodeDebugLine(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let text = String(data: data, encoding: .utf8) else {
        // Not reachable from any value that gets here — but the reason is
        // about these values, not about the type. `JSONValue.number` wraps
        // a `Double`, and `JSONEncoder` throws `EncodingError.invalidValue`
        // on a non-finite one: measured 2026-09-08 on Swift 6.3.2 against
        // this exact enum, `.number(.infinity)`, `.number(-.infinity)` and
        // `.number(.nan)` each throw ("Unable to encode Double.inf directly
        // in JSON"). What rules them out here is provenance. Every value
        // reaching this function is either a dispatch result — decoded by
        // `JSONValue.init(from:)` out of an MCP server's stdout, and JSON
        // has no literal for infinity or NaN, so no decoded `.number` can
        // be one — or an `encodeDebugErrorLine` object holding a single
        // `.string`. Kept as a non-fatal fallback rather than a forced
        // unwrap so a future caller handing this function a locally
        // constructed value cannot turn an encoding failure into a crash of
        // the whole script run.
        return #"{"error":"failed to encode result"}"#
    }
    return text
}

private func encodeDebugErrorLine(_ message: String) -> String {
    encodeDebugLine(.object(["error": .string(message)]))
}
