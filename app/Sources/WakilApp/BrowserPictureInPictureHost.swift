import AppKit
import Foundation
import WakilKit
import WebKit

/// The window's automatic picture in picture (3d-iii): tells `BrowserPictureInPicture` what is on
/// screen and what WebKit reported, and carries out the effects it returns through each tab's frames.
///
/// **What is on screen** comes from the panes (`show` at the end of each sync, `hide` when a pane
/// leaves or is covered) and from the window (`didMiniaturize` / `didDeminiaturize`). Nothing here
/// listens to focus (call 14).
///
/// **Which frame floats.** Each frame's script (`BrowserPictureInPictureScript`) posts its newest
/// qualifying video's `since`; the frames that post `playing: true` are kept per web view, by token.
/// On `.float` every kept frame of every candidate tab is tried, newest first, until one floats
/// (ruling 3). Nothing playing, or WebKit refusing, floats nothing and says nothing (ruling 9).
///
/// **Restore** docks a view with no window in the window's content view, below every sibling and
/// invisible, so WebKit can bring the video back inline before the pane exists (ruling 5).
@MainActor
final class BrowserPictureInPictureHost: NSObject, WKScriptMessageHandler {
    private weak var host: BrowserTabHost?
    private var machine = BrowserPictureInPicture()

    /// A frame that last said it plays: its `WKFrameInfo` (which addresses the frame, not the
    /// document — probe b) and its newest video's `playing` stamp.
    private struct Frame {
        let info: WKFrameInfo
        let since: Double
    }

    /// Per web view (by identity, so a pop-up's view keeps its frames when it moves to its tab's key),
    /// per frame token. Emptied when the view is dropped (`forget(view:)`) or its main frame commits.
    private var frames: [ObjectIdentifier: [String: Frame]] = [:]

    /// The frame whose `enter` floated each view's video, kept until the float ends: a video paused
    /// in the floating window posts `playing: false` and loses its token, but `inline` and `pause`
    /// must still reach it.
    private var floated: [ObjectIdentifier: WKFrameInfo] = [:]

    /// The view docked for Restore and the view it was docked in.
    private var docked: (view: WKWebView, parent: NSView)?

    private var observers: [NSObjectProtocol] = []

    /// The window is closing: every pane's `onDisappear` that follows is its close, not a leaving, so
    /// nothing floats as the window goes.
    private var windowClosing = false

    /// The window the panes are drawn in; set by the page container when it joins it. Its minimise
    /// and deminiaturise are the machine's `setMinimized`; its close makes every `hide` a closing one.
    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            removeObservers()
            windowClosing = false
            guard let window else { return }
            let center = NotificationCenter.default
            for (name, on) in [(NSWindow.didMiniaturizeNotification, true), (NSWindow.didDeminiaturizeNotification, false)] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setMinimized(on) }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosing = true }
            })
        }
    }

    init(host: BrowserTabHost) {
        self.host = host
    }

    isolated deinit { removeObservers() }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// The tab whose video floats, if any.
    var floatingKey: BrowserTabHost.Key? { machine.floating.map(Self.key) }

    // MARK: What is on screen

    /// The pane is drawn, not covered, and shows `tab` (nil: none). Called on every sync.
    func show(scope: LayoutScope, pane: String, tab: String?) {
        // A pane still drawn under its place's old name a moment after `rehome` is not the place on
        // screen; the pane under the new name is (`BrowserTabHost.rehome`).
        guard let host, scope == host.model?.browserScope, !host.isOldName(scope) else { return }
        run { $0.show(scope: scope, pane: pane, tab: tab) }
    }

    /// The pane left the screen or was covered; `closing`: it was closed (ruling 2).
    func hide(scope: LayoutScope, pane: String, closing: Bool) {
        run { $0.hide(scope: scope, pane: pane, closing: closing || windowClosing) }
    }

    private func setMinimized(_ on: Bool) {
        run { $0.setMinimized(on) }
    }

    // MARK: What WebKit said

    /// WebKit said the tab's video entered (`on`) or left picture in picture.
    func didChange(_ key: BrowserTabHost.Key, _ on: Bool) {
        run { $0.didChange(Self.ref(key), floating: on) }
        // Ended: after its effects (a `.pause` still reaches the floated frame).
        if !on, let view = host?.existing(scope: key.scope, pane: key.pane, tab: key.tab) {
            floated[ObjectIdentifier(view)] = nil
        }
    }

    /// Restore was pressed on the floating window; `view` must be in a window before this returns.
    func restore(_ key: BrowserTabHost.Key, view: WKWebView) {
        let ref = Self.ref(key)
        refreshEnabled()
        for effect in machine.restore(ref) {
            if case .goTo = effect { goTo(ref, view: view) } else { apply(effect) }
        }
    }

    /// The tab was closed: its view is about to be dropped, which ends the float with no word from
    /// WebKit (ruling 11, probe a). Synchronous, and the drop does not wait for anything.
    func closed(_ key: BrowserTabHost.Key) {
        refreshEnabled()
        _ = machine.closed(Self.ref(key))
        if let view = host?.existing(scope: key.scope, pane: key.pane, tab: key.tab) {
            floated[ObjectIdentifier(view)] = nil
        }
    }

    /// A place took a new name: its panes and floating tab go with it.
    func rehome(from: LayoutScope, to: LayoutScope) {
        machine.rehome(from: from, to: to)
    }

    /// The tab's main frame committed a new page: its frames' tokens are gone.
    func forgetFrames(_ key: BrowserTabHost.Key) {
        guard let view = host?.existing(scope: key.scope, pane: key.pane, tab: key.tab) else { return }
        frames[ObjectIdentifier(view)] = nil
    }

    /// The view is leaving the host (closed, evicted, its store cleared): its frames are forgotten,
    /// so its identity can never answer for a later view's.
    func forget(view: WKWebView) {
        frames[ObjectIdentifier(view)] = nil
        floated[ObjectIdentifier(view)] = nil
    }

    /// A frame's `wakilPictureInPicture` message, through `BrowserPictureInPictureMessages`:
    /// `{frame: token, playing: Bool, since: Number}`. Idempotent: a frame posts the same state often.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // The tab is found at arrival: a pop-up's view moves from its predicted key to its tab's.
        guard let view = message.webView, host?.key(of: view) != nil,
              let body = message.body as? [String: Any], let token = body["frame"] as? String
        else { return }
        let id = ObjectIdentifier(view)
        let playing = (body["playing"] as? NSNumber)?.boolValue ?? false
        if playing {
            let since = (body["since"] as? NSNumber)?.doubleValue ?? 0
            frames[id, default: [:]][token] = Frame(info: message.frameInfo, since: since)
        } else {
            // `pagehide` says false too, so the frame's next document is not asked under this token.
            frames[id]?[token] = nil
            if frames[id]?.isEmpty == true { frames[id] = nil }
        }
    }

    // MARK: Effects

    private func refreshEnabled() {
        machine.enabled = (host?.model?.browserSettings.pictureInPicture ?? true)
            && BrowserPictureInPictureSupport.available
    }

    private func run(_ call: (inout BrowserPictureInPicture) -> [BrowserPictureInPicture.Effect]) {
        refreshEnabled()
        for effect in call(&machine) { apply(effect) }
    }

    private func apply(_ effect: BrowserPictureInPicture.Effect) {
        switch effect {
        case .float(let refs):
            // Every kept frame of every tab that left, newest `playing` first (ruling 3).
            var candidates: [(ref: BrowserTabRef, view: WKWebView, frame: Frame)] = []
            for ref in refs {
                guard let view = liveView(ref), let kept = frames[ObjectIdentifier(view)] else { continue }
                candidates += kept.values.map { (ref, view, $0) }
            }
            candidates.sort { $0.frame.since > $1.frame.since }
            guard !candidates.isEmpty else { return machine.floatSettled(refs) }
            Task { @MainActor in
                // Refused or gone: the next newest. None floats: the video plays on in the page (ruling 9).
                // A tab that is back on screen before its turn is skipped: it has not left any more.
                for candidate in candidates where !self.machine.isShown(candidate.ref) {
                    guard await Self.call(BrowserPictureInPictureScript.enter, in: candidate.view, frame: candidate.frame.info)
                    else { continue }
                    self.floated[ObjectIdentifier(candidate.view)] = candidate.frame.info
                    // The others were asked for and will not float.
                    self.machine.floatSettled(refs.filter { $0 != candidate.ref })
                    return
                }
                self.machine.floatSettled(refs)
            }
        case .inline(let ref):
            everyFrame(of: ref, BrowserPictureInPictureScript.inline)
        case .pause(let ref):
            // `pause` also forgets the hidden-time snapshot, so the tab cannot float until it plays again.
            everyFrame(of: ref, BrowserPictureInPictureScript.pause)
        case .goTo(let ref):
            guard let view = liveView(ref) else { return }
            goTo(ref, view: view)
        }
    }

    /// `body` in the main frame, every other kept frame of the tab's view, and the frame Wakil floated.
    /// `inline` and `pause` act on what the frame holds, so asking one twice does nothing more.
    private func everyFrame(of ref: BrowserTabRef, _ body: String) {
        guard let view = liveView(ref) else { return }
        var kept = frames[ObjectIdentifier(view)]?.values.map(\.info) ?? []
        if let floated = floated[ObjectIdentifier(view)] { kept.append(floated) }
        kept.removeAll { $0.isMainFrame }
        Task { @MainActor in
            _ = await Self.call(body, in: view, frame: nil)
            for info in kept { _ = await Self.call(body, in: view, frame: info) }
        }
    }

    /// Restore (ruling 5): a view with no window is docked at once, then the place is gone to; the
    /// pane's page host takes the view from the dock when it draws.
    private func goTo(_ ref: BrowserTabRef, view: WKWebView) {
        if view.window == nil { dock(view) }
        bringWindowForward()
        Task { @MainActor [weak self] in
            let reached = await self?.host?.model?.browserReturn(to: ref) ?? false
            guard let self else { return }
            self.run { $0.restoreEnded(ref, reached: reached) }
            if reached {
                // The pane draws a turn or more after the store moves, and WebKit's own end of the
                // float lands about half a second after Restore (probe f). The dock is emptied when a
                // pane takes the view; a slow organisation switch gets five seconds before it is
                // emptied anyway.
                let clock = ContinuousClock(), deadline = clock.now + .seconds(5)
                while self.isDocked(view), clock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            self.undock(view)
        }
    }

    /// Restore from a minimised window, or while another app is active: the window comes back and
    /// Wakil comes forward, so the video goes inline where the operator can see it.
    private func bringWindowForward() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Still in the dock: no pane has taken it.
    private func isDocked(_ view: WKWebView) -> Bool {
        guard let docked, docked.view === view else { return false }
        return view.superview === docked.parent
    }

    /// Below every sibling in the window's content view, at the view's last page frame, **and**
    /// invisible (`alphaValue = 0`). The probe proved "below" in plain AppKit; here the content view is
    /// SwiftUI's hosting view, which draws much of its content in its own layer tree rather than as
    /// sibling views, and a subview draws over its superview's own content, so "below" alone is not
    /// proven to hide it. WebKit needs only the window, not the alpha.
    private func dock(_ view: WKWebView) {
        guard let content = window?.contentView else { return }
        undockCurrent()
        let frame = (view as? BrowserWebView)?.lastPageFrame.map { content.convert($0, from: nil) } ?? view.frame
        view.removeFromSuperview()
        view.alphaValue = 0
        (view as? BrowserWebView)?.docked = true
        view.autoresizingMask = []
        view.frame = frame
        content.addSubview(view, positioned: .below, relativeTo: nil)
        docked = (view, content)
    }

    /// Takes `view` out of the dock if it is still there; a view a pane took is left where it is.
    private func undock(_ view: WKWebView) {
        guard let docked, docked.view === view else { return }
        undockCurrent()
    }

    private func undockCurrent() {
        guard let (view, parent) = docked else { return }
        docked = nil
        if view.superview === parent { view.removeFromSuperview() }
        view.alphaValue = 1
        (view as? BrowserWebView)?.docked = false
    }

    private func liveView(_ ref: BrowserTabRef) -> WKWebView? {
        host?.existing(scope: ref.scope, pane: ref.pane, tab: ref.tab)
    }

    /// Runs one of the script's bodies in `frame` (nil: the main frame) and the `wakil.pip` world.
    /// True when it answered `true` or a count above 0; a frame that has gone fails, which is false.
    private static func call(_ body: String, in view: WKWebView, frame: WKFrameInfo?) async -> Bool {
        await withCheckedContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: [:], in: frame, in: BrowserPictureInPictureScript.world) { result in
                let answer = (try? result.get()) as? NSNumber
                continuation.resume(returning: (answer?.doubleValue ?? 0) > 0)
            }
        }
    }

    private static func ref(_ key: BrowserTabHost.Key) -> BrowserTabRef {
        BrowserTabRef(scope: key.scope, pane: key.pane, tab: key.tab)
    }

    private static func key(_ ref: BrowserTabRef) -> BrowserTabHost.Key {
        BrowserTabHost.Key(scope: ref.scope, pane: ref.pane, tab: ref.tab)
    }
}
