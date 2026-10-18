import Foundation

/// One retained `Bash` `HarnessEvent`, paired with the wall-clock moment
/// `WindowModel.append(_:)` observed it.
///
/// **Fix round 1 (Critical).** The first cut of `mirroredBlocks` gave
/// every mirrored block an index-derived `startedAt`
/// (`Date(timeIntervalSince1970: Double(order.count))` — epoch 1970 plus a
/// few seconds), because the pure decode has no timestamp of its own to
/// read off `HarnessEvent`. `PaneStore.recordTerminal` inserts by
/// `startedAt`, so that synthetic value sorted every mirrored block ahead
/// of every real operator block, unconditionally — not occasional
/// bunching, a deterministic inversion, because an epoch-1970 value is
/// always less than a real `Date()`.
///
/// **The fix is to source `startedAt` honestly rather than synthesise a
/// second one.** `HarnessEvent` itself carries no timestamp, but
/// `WindowModel` does know when it learned of each event — the instant it
/// arrives — and arrival time IS when that command started, as closely as
/// Wakil can ever know it: `.toolUse` arrives the moment the agent issues
/// the call, before the command runs. So the `Date()` is captured once,
/// in `WindowModel.append(_:)`, where the event actually arrives, and
/// carried alongside the event from there on — `mirroredBlocks` stays
/// pure, reading `at` rather than calling `Date()` itself, which is what
/// keeps it callable from a test with fabricated timestamps at all.
public struct MirrorEvent: Sendable, Equatable {
    public let event: HarnessEvent
    public let at: Date

    public init(_ event: HarnessEvent, at: Date) {
        self.event = event
        self.at = at
    }
}

/// Turns the agent's own `Bash` calls — as they already arrive on the
/// harness stream, `HarnessEvent.toolUse`/`.toolResult` — into
/// `TerminalBlock`s of `origin: .agent`, so an open terminal pane can show
/// *"when a terminal is open, I want to see the commands the agent is
/// running"* with no new plumbing. Task 15.
///
/// **This is a rendering, not an action.** Nothing here dispatches through
/// `ActionRegistry` and nothing is journalled — the write gate and
/// Invariant 2 are not engaged, because nothing here changes what the
/// agent can do or read; it only decides what a pane draws. `WindowModel`
/// already receives every one of these events for the thought thread; this
/// file is the second, narrower projection of the same stream.
///
/// **`Bash` only — ruling 1.** A terminal is a shell surface. `Read`,
/// edits, and every MCP tool call belong to the thought thread now and an
/// editor pane later; mirroring every tool call would turn the terminal
/// into a second, worse thought thread, one command call among a hundred
/// file reads. `onlyBashIsMirrored` (`TerminalMirrorTests.swift`) pins
/// this: a `Read` and an `mcp__wakil__read_pane` call in the same batch as
/// a `Bash` call produce exactly one block.
///
/// **A mirrored block must say where it ran — ruling 2, for the drawing
/// task that follows this one.** `TerminalBlockOrigin.agent`'s own doc
/// comment already carries the fact this function relies on: the command
/// ran in Wakil's OWN shell, in a bare environment built from nothing but
/// four variables, and it never touched this pane's PTY — which carries
/// the active organisation, project and environment. Drawing a mirrored
/// block like one the operator ran would read as though it ran inside the
/// credential boundary that context establishes, which is false. Nothing here adds a field for
/// this: `origin == .agent` already says it, and a second field carrying
/// the same fact in different words is exactly the kind of thing ruling 3
/// forbids (below).
///
/// **Never luminous — ruling 3.** Light in a terminal pane tracks exactly
/// one thing: whether a block is asking for the operator's own `⏎`. A
/// mirrored block is a report of something that already happened
/// elsewhere, in a shell the operator's hand never touched, so it is drawn
/// recessed — never the third state between "quiet" and "waiting for
/// you". That is the drawing task's job, not this file's, but it is why
/// this file does not invent a field to carry: an `isLive` flag or a
/// `justFinished` timestamp would be exactly the kind of thing a later
/// author reaches for to make a block glow, and the constraint is stated
/// here so nobody has to rediscover it by drawing the wrong thing first.
///
/// **A running block: a running state and an elapsed counter, never a
/// progress bar — ruling 4.** `HarnessEvent.toolUse` arrives the instant
/// the agent issues the call, BEFORE the command runs; `.toolResult`
/// arrives whole, only once the command has finished. So a mirrored
/// block's characters never scroll as they are produced, and cannot —
/// those bytes never reach Wakil while the command is running, only the
/// call and, later, the whole result. Realtime is true of WHAT the agent
/// is running, not of watching it run. A still-running block therefore
/// carries `exitCode: nil` and `durationMs: nil`
/// (`aToolCallWhoseResultHasNotArrivedIsARunningBlockWithNoExitCode`); the
/// drawing task computes an elapsed counter from `startedAt` the same way
/// it would for the operator's own running block, and draws no progress
/// bar, because Wakil genuinely has no idea how far along the command is.
///
/// **`Rerun` becomes `Propose rerun`.** A later task's action bar offers
/// "Rerun" on the operator's own finished blocks — dispatching `term_run`
/// straight into this pane's own credentialed shell. Offered on a mirrored
/// block unchanged, "Rerun" would run the SAME command a second time, but
/// now with this pane's organisation credentials and active environment
/// instead of the bare, four-variable one it actually ran under — a
/// materially different act wearing the same button. A mirrored block's
/// version of that action must read "Propose rerun" and go through
/// `term_propose`, the same two-keystroke path an agent's own proposal
/// already takes, so the operator's own `⏎` is what actually authorises
/// running it here.
///
/// **A tool result's `content` is never assumed to be an object.** Per
/// `HarnessEvent.toolResult`'s own doc comment, the probe saw it arrive as
/// a JSON *string* from an MCP server and as an array of objects from
/// `ToolSearch`. `Bash`'s own result is ordinarily a plain string, but
/// `outputLines(from:)` below still switches on every `JSONValue` case
/// rather than reaching for `.string` unconditionally, so a shape this
/// build has not seen yet degrades to a best-effort rendering instead of
/// silently dropping the block's output.
public func mirroredBlocks(from events: [MirrorEvent], cap: Int) -> [TerminalBlock] {
    var order: [String] = []
    var byId: [String: TerminalBlock] = [:]

    for wrapped in events {
        switch wrapped.event {
        case .toolUse(let id, let name, let input):
            guard name == "Bash", byId[id] == nil else { continue }
            byId[id] = TerminalBlock.capped(
                id: id, command: bashCommand(from: input), origin: .agent,
                exitCode: nil, durationMs: nil, output: [], heldTheGrid: false,
                // The caller's arrival time, not a value computed here —
                // see `MirrorEvent`'s own doc comment for why a value
                // synthesised inside this pure decode was the bug.
                startedAt: wrapped.at)
            order.append(id)
        case .toolResult(let id, let content, let isError):
            // A result for an id this function never saw a `Bash`
            // `toolUse` for — another tool's result, or one whose
            // matching call fell out of a capped retention window — is
            // silently not a mirrored block. There is no command text to
            // show for it and nothing to complete.
            guard let running = byId[id] else { continue }
            byId[id] = TerminalBlock.capped(
                id: running.id, command: running.command, origin: running.origin,
                exitCode: isError ? 1 : 0, durationMs: running.durationMs,
                output: outputLines(from: content), heldTheGrid: false,
                // Unchanged from the running block: the command STARTED
                // when its `toolUse` arrived, not when its `toolResult`
                // did, so the result filling a block in must not move it.
                startedAt: running.startedAt)
        default:
            continue
        }
    }

    let blocks = order.compactMap { byId[$0] }
    return Array(blocks.suffix(cap))
}

/// `input["command"]`, or `""` for a `Bash` call whose input this build
/// cannot make sense of — never thrown, because a decode failure here must
/// degrade the one block it affects, not the whole batch `mirroredBlocks`
/// is decoding.
private func bashCommand(from input: JSONValue) -> String {
    guard case .object(let fields) = input, case .string(let command)? = fields["command"] else {
        return ""
    }
    return command
}

/// A tool result's `content`, rendered as the plain-text lines
/// `TerminalBlock.output` declares — matching `PaneCell`'s own reasoning
/// for `.array`/`.object` (encode and show it rather than show nothing),
/// but split into lines here because a block's output is a `[String]`,
/// never one attributed blob.
private func outputLines(from content: JSONValue) -> [String] {
    switch content {
    case .string(let text):
        guard !text.isEmpty else { return [] }
        // Trailing newline dropped, not kept as an empty final line: a
        // command's captured stdout ordinarily ends in one, and the
        // operator's own blocks (`TerminalSession.stripEscapeSequences`)
        // never carry a blank trailing row for it either.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    case .array(let items):
        // The array-of-objects shape the probe recorded for `ToolSearch`
        // — never actually reachable here today, since only `Bash` is
        // mirrored and its result is ordinarily a plain string, but the
        // decode must not assume otherwise. One rendered line per element.
        return items.map { PaneCell($0).text }
    case .null:
        return []
    default:
        let text = PaneCell(content).text
        return text.isEmpty ? [] : [text]
    }
}

/// The agent's `Bash` calls, mirrored into every terminal pane (Task 15;
/// extracted from `WindowModel` in PR 4 of the split).
@MainActor
final class TerminalMirrorFeed {
    private let panes: PaneStore
    private let layout: LayoutStore
    /// The agent's `Bash` tool uses and their results, as they arrived.
    private(set) var events: [MirrorEvent] = []

    init(panes: PaneStore, layout: LayoutStore) {
        self.panes = panes
        self.layout = layout
    }

    func retain(_ event: HarnessEvent, at arrivedAt: Date) {
        guard isRelevant(event) else { return }
        events.append(MirrorEvent(event, at: arrivedAt))
        let overflow = events.count - TerminalBlock.historyCap * 2
        if overflow > 0 { events.removeFirst(overflow) }
    }

    /// `event`'s block, into every terminal pane of `scope` — the canvas of the place whose agent
    /// ran it; `nil` is the one on screen. Each place's agent mirrors into its own place's panes
    /// (background agents, 3 of 4), not into whatever the operator is looking at.
    func pump(_ event: HarnessEvent, into scope: LayoutScope?) async {
        guard let id = Self.id(of: event),
              let block = mirroredBlocks(from: events, cap: TerminalBlock.historyCap)
                  .first(where: { $0.id == id })
        else { return }
        await ScopeRouting.$home.withValue(scope) {
            for pane in await layout.snapshot().panes where pane.kind == "terminal" {
                await panes.appendMirrored(paneId: pane.id, block: block)
            }
        }
    }

    /// Every retained block, into every terminal pane of `scope` (`pump`'s target).
    func backfill(into scope: LayoutScope?) async {
        await ScopeRouting.$home.withValue(scope) { await backfillHome() }
    }

    private func backfillHome() async {
        let blocks = mirroredBlocks(from: events, cap: TerminalBlock.historyCap)
        guard !blocks.isEmpty else { return }
        // Captured once, before the loop, rather than per pane: every block in
        // `blocks` already happened, and nothing suspends between here and the
        // last `appendMirrored` below, so one timestamp at or after all of them —
        // and strictly before whatever `pump` appends next — separates "replayed
        // from history" from "streamed live" for every pane this call touches.
        let backfilledAt = Date()
        for pane in await layout.snapshot().panes where pane.kind == "terminal" {
            for block in blocks { await panes.appendMirrored(paneId: pane.id, block: block) }
            await panes.setTerminalBackfilledAt(paneId: pane.id, backfilledAt)
        }
    }

    private static func id(of event: HarnessEvent) -> String? {
        switch event {
        case .toolUse(let id, _, _): return id
        case .toolResult(let id, _, _): return id
        default: return nil
        }
    }

    private func isRelevant(_ event: HarnessEvent) -> Bool {
        switch event {
        case .toolUse(_, let name, _):
            return name == "Bash"
        case .toolResult(let id, _, _):
            return events.contains {
                if case .toolUse(let seenId, let seenName, _) = $0.event {
                    return seenId == id && seenName == "Bash"
                }
                return false
            }
        default:
            return false
        }
    }
}
