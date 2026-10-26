import Foundation
import WakilKit
import WebKit

/// The window's `BrowserPageDriver` (3c-ii): the agent reads and acts in a tab's page through
/// Wakil's script in its `wakil.agent` world (`BrowserAgentScript`), on the tab's own live web view.
///
/// **Made before the wiring, its host set after** (`WindowSession`), as the browser-data remover's
/// `BrowserTabsBox` is: the actions are registered by `WakilWiring.build`, and the web views are the
/// window's `BrowserTabHost`, which needs the model the wiring makes. Until the host is set, and for a
/// tab with no live web view (never shown this launch, or released), every call answers `notLoaded`
/// — the refusal that says to select the tab first.
///
/// **It never takes the keyboard and never selects a tab** (Rule 6): it calls no `makeFirstResponder`
/// and dispatches nothing. A focus the script gives an element is the page's own, inside its web view.
/// It hops to the main actor for every web view call.
final class BrowserPageAgent: BrowserPageDriver, @unchecked Sendable {
    @MainActor weak var host: BrowserTabHost?

    /// The 1 s idle rule's ceiling: after this long of continuous operator input, the act is refused.
    static let busyCeiling: TimeInterval = 10
    /// How long an act waits for a navigation it started to begin, then to finish.
    static let settleStart: TimeInterval = 0.3
    static let settleFinish: TimeInterval = 10
    private static let pollInterval: Duration = .milliseconds(50)

    func read(scope: LayoutScope?, pane: String, tab: String, firstRef: Int) async throws -> BrowserPageRead {
        let text = try await call(scope: scope, pane: pane, tab: tab, "globalThis.wakil.read(firstRef)",
                                  ["firstRef": firstRef])
        let answer = try decode(ReadAnswer.self, text)
        guard answer.stale != true, let url = answer.url, let elements = answer.elements else {
            throw BrowserPageDriverError.stale
        }
        return BrowserPageRead(url: url, title: answer.title ?? "", text: answer.text ?? "", elements: elements,
                               framesSkipped: answer.framesSkipped ?? 0)
    }

    func describe(scope: LayoutScope?, pane: String, tab: String, ref: String) async throws -> BrowserElement {
        let text = try await call(scope: scope, pane: pane, tab: tab, "globalThis.wakil.describe(ref)", ["ref": ref])
        let answer = try decode(DescribeAnswer.self, text)
        guard answer.stale != true, let element = answer.element else { throw BrowserPageDriverError.stale }
        return element
    }

    func act(scope: LayoutScope?, pane: String, tab: String, _ act: BrowserPageAct) async throws -> BrowserActResult {
        try await MainActor.run { _ = try self.liveView(scope: scope, pane: pane, tab: tab) }
        try await waitForQuiet(scope: scope, pane: pane, tab: tab)
        let before = try await MainActor.run { () throws -> (url: String?, loading: Bool) in
            let view = try self.liveView(scope: scope, pane: pane, tab: tab)
            return (view.url?.absoluteString, view.isLoading)
        }
        let text = try await call(scope: scope, pane: pane, tab: tab, "globalThis.wakil.act(spec)",
                                  ["spec": Self.spec(act)])
        let answer = try decode(ActAnswer.self, text)
        if answer.stale == true { throw BrowserPageDriverError.stale }
        if let reason = answer.failed {
            // The script's words are Wakil's fixed sentences; anything else is not passed on.
            throw BrowserPageDriverError.failed(
                reason == BrowserAgentScript.yoursNowReason ? reason : Self.scriptStoppedReason)
        }
        return try await settle(scope: scope, pane: pane, tab: tab, before: before)
    }

    // MARK: The web view

    /// The tab's live web view, never one made for the call (that would load the page unasked).
    @MainActor
    private func liveView(scope: LayoutScope?, pane: String, tab: String) throws -> BrowserWebView {
        guard let host, let scope = scope ?? host.model?.browserScope,
              let view = host.liveView(scope: scope, pane: pane, tab: tab)
        else { throw BrowserPageDriverError.notLoaded }
        return view
    }

    /// Waits out the operator's quiet second in this tab's page (`browserIdleWait`); after the busy
    /// ceiling of continuous input, the act is refused rather than typed under their hands.
    private func waitForQuiet(scope: LayoutScope?, pane: String, tab: String) async throws {
        let start = Date()
        while true {
            let wait = try await MainActor.run {
                browserIdleWait(lastInput: try self.liveView(scope: scope, pane: pane, tab: tab).lastOperatorInput,
                                now: Date())
            }
            if wait <= 0 { return }
            if Date().timeIntervalSince(start) + wait > Self.busyCeiling { throw BrowserPageDriverError.operatorBusy }
            try await Task.sleep(for: .milliseconds(Int((wait * 1000).rounded(.up))))
        }
    }

    /// After an act: up to 300 ms for a navigation it started to begin (a new address, or a load),
    /// then up to 10 s for it to finish; then what the tab shows. A web view gone meanwhile (its tab
    /// closed) answers stale.
    private func settle(scope: LayoutScope?, pane: String, tab: String,
                        before: (url: String?, loading: Bool)) async throws -> BrowserActResult {
        func now() async throws -> (url: String?, title: String, loading: Bool) {
            try await MainActor.run {
                guard let view = try? self.liveView(scope: scope, pane: pane, tab: tab) else {
                    throw BrowserPageDriverError.stale
                }
                return (view.url?.absoluteString, view.title ?? "", view.isLoading)
            }
        }
        var started = false
        let startBy = Date().addingTimeInterval(Self.settleStart)
        var state = try await now()
        while !started, Date() < startBy {
            started = state.url != before.url || (!before.loading && state.loading)
            if started { break }
            try await Task.sleep(for: Self.pollInterval)
            state = try await now()
        }
        if started {
            let finishBy = Date().addingTimeInterval(Self.settleFinish)
            while state.loading, Date() < finishBy {
                try await Task.sleep(for: Self.pollInterval)
                state = try await now()
            }
        }
        return BrowserActResult(url: state.url ?? "", title: state.title, loading: state.loading,
                                navigated: started || state.url != before.url)
    }

    // MARK: The script

    /// The failed reason for anything the script did not say in Wakil's words (a thrown error, a
    /// page gone mid-call): never the page's text.
    static let scriptStoppedReason = "Wakil's page script could not finish there — read the page again "
        + "(browser_read_page)."

    /// How long a call waits for the page to answer before it is refused.
    static let callTimeout: TimeInterval = 10
    static let noAnswerReason = "the page did not answer within 10 s — try again, or read the page again "
        + "(browser_read_page)."

    /// A continuation resumed by whichever answers first, the page or the timeout.
    @MainActor
    private final class AnswerOnce {
        private var continuation: CheckedContinuation<Result<String, BrowserPageDriverError>, Never>?
        init(_ continuation: CheckedContinuation<Result<String, BrowserPageDriverError>, Never>) {
            self.continuation = continuation
        }
        func answer(_ result: Result<String, BrowserPageDriverError>) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    /// Runs `expression` in the tab's page, in `wakil.agent`, with `arguments` as values (never source).
    private func call(scope: LayoutScope?, pane: String, tab: String, _ expression: String,
                      _ arguments: [String: any Sendable]) async throws -> String {
        try await MainActor.run { _ = try self.liveView(scope: scope, pane: pane, tab: tab) }
        let body = BrowserAgentScript.body(expression)
        let result: Result<String, BrowserPageDriverError> = await withCheckedContinuation { continuation in
            Task { @MainActor in
                // Answered once: by the page, or by the timeout when its web process does not answer.
                let once = AnswerOnce(continuation)
                guard let view = try? self.liveView(scope: scope, pane: pane, tab: tab) else {
                    return once.answer(.failure(.notLoaded))
                }
                view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: BrowserAgentScript.world) { result in
                    switch result {
                    case .success(let value as String): once.answer(.success(value))
                    case .success, .failure: once.answer(.failure(.failed(Self.scriptStoppedReason)))
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.callTimeout))
                    once.answer(.failure(.failed(Self.noAnswerReason)))
                }
            }
        }
        return try result.get()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: Data(text.utf8)) else {
            throw BrowserPageDriverError.failed(Self.scriptStoppedReason)
        }
        return value
    }

    /// The act as the script's `spec` argument: values only. Type and select carry the element as read
    /// (`expect`), so the script refuses a field whose type, autocomplete, name or id changed since.
    private static func spec(_ act: BrowserPageAct) -> [String: any Sendable] {
        func expect(_ e: BrowserElement) -> [String: String] {
            ["type": e.type, "autocomplete": e.autocomplete, "name": e.name, "id": e.id]
        }
        switch act {
        case .click(let ref): return ["kind": "click", "ref": ref]
        case .type(let ref, let text, let e): return ["kind": "type", "ref": ref, "text": text, "expect": expect(e)]
        case .select(let ref, let option, let e):
            return ["kind": "select", "ref": ref, "option": option, "expect": expect(e)]
        case .press(let ref, let key): return ["kind": "press", "ref": ref, "key": key.rawValue]
        case .scroll(let ref): return ["kind": "scroll", "ref": ref]
        }
    }

    private struct ReadAnswer: Decodable {
        var stale: Bool?
        var url, title, text: String?
        var elements: [BrowserElement]?
        var framesSkipped: Int?
    }

    private struct DescribeAnswer: Decodable {
        var stale: Bool?
        var element: BrowserElement?
    }

    private struct ActAnswer: Decodable {
        var stale: Bool?
        var ok: Bool?
        var failed: String?
    }
}
