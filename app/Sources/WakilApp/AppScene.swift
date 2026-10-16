import AppKit
import Foundation
import WakilKit
import SwiftUI

// MARK: - Scene

/// Runs `WindowSession.shutdown()` before the process exits.
///
/// `applicationShouldTerminate` returning `.terminateLater` is the AppKit
/// hook that lets asynchronous teardown finish. The obvious alternative does
/// not: `NSApplication.willTerminateNotification` is delivered as the
/// process is already going away, so a `Task` started from it is not waited
/// on and may never run at all. `NSApp.reply(toApplicationShouldTerminate:)`
/// is what resumes the quit once `shutdown()` has returned.
///
/// **It holds the startup `Task`, not the started session**, and that is the
/// whole of the fix for a quit that lands *during* launch. `WindowSession
/// .start()` spawns the three Go children and binds the unix socket before it
/// returns, so a delegate that learned about the session only from the
/// returned value had a window — as long as `start()` takes: two child
/// spawns, two MCP handshakes, a socket bind — in which ⌘Q found `nil` here,
/// replied `.terminateNow`, and left two live children and a socket file
/// behind with no teardown run at all. The task can be handed
/// over before any of those resources exist, which closes that window
/// exactly: there is no instant at which something has been created and this
/// object does not know how to reach it.
///
/// The cost is that quitting mid-launch now *waits* for launch to finish
/// before tearing it down, rather than returning instantly. That wait is
/// bounded by what `start()` itself is bounded by: `MCPClient`'s 10-second
/// per-request timeout, over the two awaited requests its `start()` makes
/// (`initialize` and `tools/list`) for each of the two Go clients — so at
/// worst about forty seconds, and in practice the tens of milliseconds those
/// handshakes actually take. The alternative to waiting is cancelling a
/// half-built assembly, which would mean teaching every resource in it to
/// unwind from an arbitrary point; leaking a socket and two child processes
/// on every quit is the worse of the two failures.
@MainActor
final class WakilAppDelegate: NSObject, NSApplicationDelegate {
    /// The one window's startup, from the moment it begins rather than the
    /// moment it completes. `nil` only before the scene's `.task` has run at
    /// all, when nothing has been created and there is nothing to tear down.
    var startup: Task<WindowSession, Never>?

    /// **Unsaved editor tabs ask first** (3b-i Task 9). `requestQuit()` answers true when nothing
    /// is unsaved and the quit goes on; otherwise the window draws Save / Don't Save / Cancel and
    /// the quit waits, still `.terminateLater`, until `finishQuit` hears how it resolved.
    ///
    /// **Never left waiting**: with no window to draw the prompt in, the quit is answered no at
    /// once and the prompt withdrawn — the unsaved work is kept, and the app stays reachable from
    /// the Dock. A quit the window's close already approved (`quitApprovedByClose`) asks nothing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let startup else { return .terminateNow }
        Task {
            let session = await startup.value
            let nothingToAsk = quitApprovedByClose ? true : await session.model.requestQuit()
            if nothingToAsk {
                await finishQuitting(session)
            } else if let window = wakilWindow {
                bringForward(window)
                quitWaiting = .terminate(session)
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
                await session.model.resolveUnsaved(.cancel)
            }
        }
        return .terminateLater
    }

    /// A quit waiting on the unsaved prompt: AppKit's terminate (answer it), or the window's close
    /// button (start the terminate once approved).
    private enum QuitWait {
        case terminate(WindowSession)
        case windowClose
    }

    private var quitWaiting: QuitWait?
    /// The window's close went through the unsaved prompt (or found nothing unsaved): the
    /// terminate it starts must not ask again.
    private var quitApprovedByClose = false

    /// The window to ask in: Wakil's, if it still exists — on screen, minimised, or with the app
    /// hidden (neither of which counts as visible). Nil only once it has been closed.
    private var wakilWindow: NSWindow? {
        NSApp.windows.first { isExpectedWindow($0) && ($0.isVisible || $0.isMiniaturized || NSApp.isHidden) }
    }

    /// Shows the window the prompt is drawn in: unhidden, restored from the Dock, in front.
    private func bringForward(_ window: NSWindow) {
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The unsaved prompt resolved: quit (after Save or Don't Save) or stay (Cancel, or a Save that
    /// could not finish). Nothing when no quit is waiting.
    func finishQuit(approved: Bool) {
        guard let waiting = quitWaiting else { return }
        quitWaiting = nil
        switch waiting {
        case .terminate(let session):
            guard approved else {
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            Task { await finishQuitting(session) }
        case .windowClose:
            guard approved else { return }   // the window stays open, as it already is
            quitApprovedByClose = true
            NSApp.terminate(nil)
        }
    }

    private func finishQuitting(_ session: WindowSession) async {
        await session.shutdown()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// The window's close button (3b-i Task 9). Closing the one window quits Wakil (below), but
    /// AppKit only says so after the window is gone — too late to ask anything. So the close is
    /// refused here and turned into a quit: nothing unsaved quits at once, and dirty tabs raise the
    /// quit prompt in the still-open window, whose approval terminates as usual.
    fileprivate func windowShouldClose(_ window: NSWindow) -> Bool {
        guard let startup, !quitApprovedByClose else { return true }
        guard quitWaiting == nil else { return false }   // a quit is already asking
        Task {
            let session = await startup.value
            if await session.model.requestQuit() {
                quitApprovedByClose = true
                NSApp.terminate(nil)
            } else {
                quitWaiting = .windowClose
            }
        }
        return false
    }

    /// Retained here: `NSWindow.delegate` is weak.
    private var closeGuard: WindowCloseGuard?

    /// Resigning active is a point where the operator has left the editor: autosave "when focus
    /// leaves" saves the dirty tabs (3b-v). Reached through the startup task like every other
    /// delegate entry, so a resign during launch waits for the session rather than being dropped.
    func applicationWillResignActive(_ notification: Notification) {
        guard let startup else { return }
        Task { @MainActor in
            let session = await startup.value
            await session.model.editorAppDidResignActive()
        }
    }

    /// **Closing the window quits Wakil, because there is only ever one.**
    ///
    /// Without this, closing the window without quitting left the app
    /// running and holding, invisibly: three Go children (`wakil-ctx`,
    /// `wakil-db`, `wakil-http`), a `claude` child if a session was live, and a bound
    /// unix socket at `$TMPDIR/wakil-<sessionId>.sock` — with no surface
    /// to see or kill any of them. The only teardown path was app
    /// *termination*, so an operator who reached for ⌘W-on-the-window
    /// rather than ⌘Q leaked the lot.
    ///
    /// **This routes window close into the teardown that already exists**
    /// rather than adding a second one: AppKit calls
    /// `applicationShouldTerminate` above, which awaits
    /// `WindowSession.shutdown()` and its stated ordering — the `claude`
    /// child dies before the socket its shim connects to is closed and
    /// unlinked. A `windowWillClose` hook would have had to restate that
    /// ordering in a second place.
    ///
    /// **The alternative was tearing the window down and leaving the app
    /// alive**, which is what a multi-window app would owe. It was
    /// rejected because Wakil is single-window on purpose (⌘N is removed
    /// below, and no charter document contemplates a second window), and
    /// because it would require `startup` to become re-runnable — it is a
    /// one-shot `Task` today, deliberately, and `WakilWindow`'s `.task`
    /// reuses it precisely so a second `WindowSession` is never built.
    ///
    /// Unverifiable by unit test: `WakilApp` has no test target. The
    /// operator walks it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// **Wakil is a dark-appearance app, and now says so to AppKit.**
    ///
    /// Every background in this app is hardcoded near-black — the void
    /// (`#030408`), the slab (`#0E1019`), the confirmation plane (black at
    /// 0.86) — but nothing ever declared the appearance, and a long list of
    /// `Text` views carry no explicit colour and therefore resolve to the
    /// *system* label colour. On a Mac set to Light Mode that colour is
    /// black, so the app drew black text on its own near-black backgrounds:
    /// the launch state, every error message in the status line, the rail,
    /// the palette, and — the one that matters — the SQL statement in the
    /// confirmation plane. An operator was being asked to type `confirm`
    /// for a database mutation they could not read.
    ///
    /// Two halves, and both are needed. `.preferredColorScheme(.dark)` on
    /// the scene's content covers SwiftUI's own resolution; this line covers
    /// the AppKit surfaces SwiftUI does not reach — the titlebar behind the
    /// traffic lights, any panel or sheet, and the standard menus.
    ///
    /// **Not `NSRequiresAquaSystemAppearance` in the Info.plist**, which is
    /// the opposite key: it opts an app *out* of Dark Mode and pins it to
    /// light, which here would guarantee the bug rather than fix it. There
    /// is no plist key that forces dark; the appearance has to be set.
    ///
    /// This forecloses `design-language.md` §15's "light-environment
    /// variant, if ever needed" until it is removed, and removing it means
    /// giving the unstyled `Text` views explicit colour tokens first —
    /// which is the honest order, since the variant cannot exist while a
    /// dozen labels take their colour from the system.
    ///
    /// Set in `applicationDidFinishLaunching` below, alongside the window
    /// chrome, rather than in a hook of its own.
    ///
    /// §1's first principle is futurism through absence: no window chrome.
    /// `.windowStyle(.hiddenTitleBar)` (on the `WindowGroup` below) hides
    /// the title bar but leaves its height reserved and the system
    /// background showing behind the rounded corners; this is what actually
    /// lets the void reach all four edges.
    ///
    /// **Why this isn't done inline against `NSApp.windows.first` and
    /// nothing else.** Measured on this machine: at the point
    /// `applicationDidFinishLaunching` fires, `NSApp.windows.first` is
    /// already non-nil — AppKit's launch sequence has SwiftUI materialise
    /// the `WindowGroup`'s window before posting this notification, at
    /// least for this one-window scene. But that is an observed fact about
    /// this launch path, not a documented guarantee, and a `guard let
    /// window = NSApp.windows.first else { return }` that silently drops
    /// the customisation the one time it *is* still nil would ship a title
    /// bar that only sometimes disappears. So this falls back to
    /// `NSWindow.didBecomeKeyNotification`, which fires exactly when a
    /// window we can configure exists, whether or not it was ready at
    /// `didFinishLaunching` time.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The AppKit half of the dark-appearance fix — see the comment above
        // the doc block for this method. Set before the window is touched so
        // no surface is ever configured under the system's appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if let window = NSApp.windows.first {
            configureWindow(window)
            return
        }
        // A `@objc` selector, not a closure: `NotificationCenter`'s
        // closure-taking overload types its handler `@Sendable`, and a
        // `Notification` posted from an arbitrary AppKit callsite is not
        // provably `Sendable` to the compiler even though `queue: .main`
        // guarantees the handler runs on the main thread at runtime. The
        // selector form has no such typing and is the ordinary AppKit way
        // to observe a one-shot notification.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    /// **Filters rather than trusting the first key window** (final review
    /// Finding 7b, 2026-09-09). The observer above registers with
    /// `object: nil`, because at the point it is added there is no window
    /// yet to scope it to — so without this filter, if the one `WindowGroup`
    /// window is not first to exist, the first sheet or utility panel to
    /// become key would be mistaken for it, `configureWindow` would apply
    /// the chrome to the wrong object, and the observer would un-register
    /// itself and never get a second chance. Instead this keeps listening —
    /// the observer is only removed once `isExpectedWindow` accepts one —
    /// so an early sheet or panel is ignored rather than consumed.
    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, isExpectedWindow(window) else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: nil)
        configureWindow(window)
    }

    /// Whether `window` can be the one `WakilApplication`'s `WindowGroup`
    /// creates, as opposed to a sheet or a utility panel that happened to
    /// become key first. `WakilApplication` never opens an `NSPanel` and
    /// never shows a sheet (2a's scope bound: one window, §1), so anything
    /// that is a panel or sits outside the normal window level is, by
    /// construction, not it.
    private func isExpectedWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.level == .normal
    }

    /// Makes the title bar transparent and the content full-size —
    /// `.hiddenTitleBar` alone leaves the bar's height reserved.
    private func configureWindow(_ window: NSWindow) {
        // 3b-i Task 9: the close button asks about unsaved tabs first (`windowShouldClose`). A
        // forwarding wrapper over SwiftUI's own window delegate, which keeps every other call.
        let guardian = WindowCloseGuard(wrapping: window.delegate) { [weak self] window in
            self?.windowShouldClose(window) ?? true
        }
        closeGuard = guardian
        window.delegate = guardian
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // The void is the background. Without this the system window
        // background shows for one frame on launch and behind the rounded
        // corners forever.
        window.backgroundColor = NSColor(red: 0.012, green: 0.016, blue: 0.031, alpha: 1)
        // **Deliberately NOT `isMovableByWindowBackground`.** 2b-ii set it,
        // on the reasoning that a pane's own `DragGesture` would consume the
        // mouse-down before AppKit's window-background drag saw it. That is
        // not how the flag works: AppKit asks the hit view
        // `mouseDownCanMoveWindow` on mouse-down, *before* any gesture
        // recogniser runs, and SwiftUI's hosted views answer yes — so the
        // window moved and the pane's gesture never received the sequence.
        // Dragging a pane became impossible, which is 2b-i's whole
        // deliverable. Observed on the first hands-on run, 2026-09-09.
        //
        // The window is still movable: `.hiddenTitleBar` keeps the titlebar
        // and only makes it transparent, so the strip behind the traffic
        // lights drags as it always did.
    }
}

struct WakilApplication: App {
    @NSApplicationDelegateAdaptor(WakilAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Wakil") {
            WakilWindow(delegate: delegate)
                // The SwiftUI half of the dark-appearance fix; the AppKit
                // half is `applicationDidFinishLaunching` above, which
                // explains both. Without this, every `Text` with no explicit
                // `.foregroundStyle` — including the SQL statement on the
                // confirmation plane — resolves to black on a Light Mode Mac
                // and disappears into the void.
                .preferredColorScheme(.dark)
        }
        // §1's first principle is futurism through absence: no window
        // chrome. The title bar hides and the traffic lights stay, so the
        // void reaches all four edges — which is the claim §2 actually
        // makes — while close, minimise, zoom, Mission Control, tiling and
        // window restoration keep working.
        //
        // Fully borderless was the alternative and costs every one of those
        // for three small circles.
        .windowStyle(.hiddenTitleBar)
        // **2a ships exactly one window, and File ▸ New Window is removed so
        // that stays true.** This is a scope bound, not an oversight.
        //
        // `WindowGroup` supplies that menu item by default, and a second
        // window it opened would be a fresh `WakilWindow` with its own
        // `@State session`.
        //
        // **The leak this comment used to describe no longer happens, and
        // what replaced it is not better.** The original argument was that
        // a second window runs `WindowSession.start()` again — a second
        // set of Wakil-owned Go children, a second `MCPSocketServer` on its own
        // socket path, a second harness — of which ⌘Q would tear down only
        // the last. That stopped being true when `WakilWindow`'s `.task`
        // gained its reuse guard (`WakilWindow.swift`, "Reused rather than
        // re-created"): a second window now finds `delegate.startup`
        // already set and *shares* the first window's session and model.
        // Nothing leaks. Instead two windows draw the same `WindowModel`,
        // which no part of this app is designed for and §1 argues against
        // before anything technical does.
        //
        // So the command stays removed on the design ruling rather than on
        // the leak: **one window, permanently.** No charter document
        // contemplates a second one — `north-star.md` does not use the word
        // "window" at all — and `applicationShouldTerminateAfterLastWindowClosed`
        // above now depends on it, since closing the window quits the app.
        // It matches what the runbooks already assume: one window, opened
        // once, quit once.
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The two pane commands: ⌘⏎ toggles maximize on the focused
            // pane and ⌘W closes it.
            // **⌘N is still not here**, and the group above is still
            // what removes it — the reasoning is unchanged, and a "new
            // pane" command must not be spelled the same as the "new
            // window" one that was deliberately taken away.
            //
            // They live in the scene rather than as buttons in the view
            // because a menu command is the only place a shortcut can
            // fire while focus is inside a text field. They reach the
            // model the same way `applicationShouldTerminate` does:
            // through the delegate's startup task, which exists from
            // before the session does. A command pressed during launch
            // therefore waits for the session rather than being dropped.
            //
            // In the **Window** menu, not File. Measured, not assumed: with
            // `.newItem` removed and nothing else added, this app has no
            // File menu at all — so putting the pane commands there
            // materialises one, and SwiftUI fills it out with *Close* and
            // *Close All* (⇧⌘W), either of which shuts the only window and
            // leaves the app running with nothing on screen. Placed here
            // the File menu stays absent, ⌘W belongs to *Close Pane*
            // uniquely, and a pane command sits next to the other things
            // that act on what is on screen.
            CommandGroup(after: .windowArrangement) {
                Button("Maximize Pane") {
                    focusedPane { model, id in await model.toggleMaximize(id: id) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                // 3b-i: in a focused editor pane ⌘W closes the active tab first, the pane once
                // none is left; anywhere else it closes the pane, as before.
                Button("Close Pane") {
                    focusedPane { model, _ in await model.closeFocusedTabOrPane() }
                }
                .keyboardShortcut("w", modifiers: .command)
                // 3b-i. ⌘T needs no focused pane: with no editor focused it opens a scratch tab in
                // the first editor pane, or a new one.
                Button("New Scratch Tab") {
                    withModel { model in Task { await model.newScratch() } }
                }
                .keyboardShortcut("t", modifiers: .command)
                // 3b-ii. ⌘B shows or hides the focused editor's Files; ⌘⇧F its Search. With no editor
                // focused, the first editor pane, else a new one (editor_tree's own rule).
                Button("Show Files") {
                    withModel { model in Task { await model.toggleEditorColumn(.files) } }
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Search Files") {
                    withModel { model in Task { await model.toggleEditorColumn(.search) } }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                // 3b-i. ⌘S saves the focused editor's active tab; a scratch tab asks for a path.
                Button("Save") {
                    focusedPane { model, _ in await model.saveFocusedEditor() }
                }
                .keyboardShortcut("s", modifiers: .command)
                Button("Toggle Density") {
                    focusedPane { model, id in await model.toggleDensity(id: id) }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                // Task 14: ⌘⇧O opens the org plane. Verified free — the
                // window binds ⌘↩, ⌘W, ⌘T, ⌘B, ⌘⇧F, ⌘S, ⌘⇧D, ⌘P and ⌘K here — and, unlike the two pane commands
                // above, this needs no focused pane: it must work from an
                // org-less window with no canvas and nothing focused at
                // all, which is exactly the state ⌘⇧O also opens into on
                // its own (spec §8.5).
                Button("Organisation…") {
                    withModel { model in model.showOrgPlane = true }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                // The palette: ⌘P opens or switches to, ⌘K runs a command.
                // **Menu commands, not buttons in the window**, for the reason
                // the pane commands above are: a menu command is the one place
                // a shortcut fires whatever holds focus — the composer, a query
                // line, a terminal, the diff. They used to be the window's
                // `Open…` / `Actions…` buttons, which drew a control for a key;
                // those are gone with the 2b-i stopgap. Pressed while the
                // palette is open, either switches its mode (`modeKey`).
                Button("Open…") {
                    withModel { model in model.paletteKey(.open) }
                }
                .keyboardShortcut("p", modifiers: .command)
                Button("Run a Command…") {
                    withModel { model in model.paletteKey(.commands) }
                }
                .keyboardShortcut("k", modifiers: .command)
                // 2e (#198). ⌘, is the platform's settings key and is
                // free here: this app declares no `Settings` scene, which
                // is what would otherwise claim it — and deliberately
                // does not, because settings are a PANE on the canvas,
                // not a separate window (Decision 30).
                //
                // Like *Organisation…* and unlike the two pane commands
                // above, this needs no focused pane: it must work from a
                // window with no canvas at all.
                //
                // It reaches the canvas through `openSettings`, which
                // dispatches `settings_open` — Invariant 2 admits no
                // second path to a state change, and a menu item that
                // touched `LayoutStore` directly would be exactly that.
                // Pressing it twice focuses the one pane rather than
                // opening a second; that singleton lives in
                // `LayoutStore.openSettings`, so `--dispatch` gets it too.
                Button("Settings…") {
                    withModel { model in Task { await model.openSettings() } }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    /// Runs `body` against the window's model, once it exists — the same
    /// "reach the model through the delegate's startup task" plumbing
    /// `focusedPane` below uses, minus that method's focused-pane
    /// requirement, which this command has no use for.
    private func withModel(_ body: @escaping @MainActor (WindowModel) -> Void) {
        guard let startup = delegate.startup else { return }
        Task { @MainActor in
            let model = await startup.value.model
            body(model)
        }
    }

    /// Runs `body` against the focused pane, or does nothing when no pane
    /// is focused. Both pane commands are "do this to whatever is focused",
    /// and `layoutSnapshot.focusedId` is the single answer to that — read
    /// at the moment the command fires rather than captured when the menu
    /// was built, which would go stale the first time focus moved.
    private func focusedPane(_ body: @escaping @MainActor (WindowModel, String) async -> Void) {
        guard let startup = delegate.startup else { return }
        Task { @MainActor in
            let model = await startup.value.model
            guard let id = model.layoutSnapshot.focusedId else { return }
            await body(model, id)
        }
    }
}

/// The window's delegate for one question — may it close? — forwarding every other message to
/// the delegate SwiftUI installed, so the window behaves exactly as before otherwise (3b-i Task 9).
private final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var inner: NSWindowDelegate?
    private let shouldClose: @MainActor (NSWindow) -> Bool

    init(wrapping inner: NSWindowDelegate?, shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
        self.inner = inner
        self.shouldClose = shouldClose
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (inner?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (inner?.responds(to: aSelector) ?? false) ? inner : super.forwardingTarget(for: aSelector)
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose(sender) else { return false }
        return inner?.windowShouldClose?(sender) ?? true
    }
}
