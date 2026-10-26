import AppKit
import WakilKit
import SwiftUI

/// The typed-confirmation surface Invariant 7 has required since the
/// charter and that nothing could render until Phase 2b-iii gave the gate a
/// subject.
///
/// A plane above the canvas (design-language §3's depth model), edged in
/// §5's reserved destructive red — deliberately NOT an `NSAlert`. A system
/// modal is off-language, and it spins its own run loop, which the void's
/// `CAMetalLayer` and 2b-iv's motion are not written to survive.
///
/// The statement is shown VERBATIM AND UNELIDED. An operator confirming a
/// statement they cannot entirely see is not confirming it, so this scrolls
/// rather than truncating.
///
/// **3c-ii adds the site question** (`PendingAsk.site`, plan ruling 13 as the operator ruled it on
/// 2026-10-26): a neutral-edged plane, `Let the agent use <site>?`, with **Don't Allow** (Esc) and
/// **Allow for this conversation**. For a typed request there is no field: Allow is enabled at once
/// and takes the keyboard — Return answers it, the one Enter-to-commit here, which ruling 13 allows
/// because the site question is a gate price (Rule 1) and clicking it is the operator's choice. For
/// a spoken request the `type confirm` field stays and Allow waits for the word (Invariant 7). A
/// production act (`PendingAsk.productionSite`) keeps this red plane with `PRODUCTION` in its
/// corner, whatever the place's environment (ruling C11b).
///
/// **After an answer the keyboard goes back to what held it before the plane** (Rule 6): the
/// composer the request was typed in, or the pane the operator was in.
struct ConfirmationPlane: View {
    let pending: PendingMutation
    let environment: String
    /// Whether a site question waits for the typed word (`WindowModel.siteQuestionWantsTyping`).
    let siteWantsTyping: Bool
    @Binding var typed: String
    let confirm: () -> Void
    /// A typed request's Allow: a click, no word (`WindowModel.allowPendingSite`).
    let allow: () -> Void
    let cancel: () -> Void
    /// Whether this plane is the front-most thing Escape should reach.
    ///
    /// **A window may hold exactly one live `.cancelAction` at a time.**
    /// AppKit resolves a key equivalent by searching the view tree and
    /// taking the first match, which is an arbitrary winner rather than the
    /// front-most one: two planes both claiming Escape is a bug whichever
    /// way it lands. `OrgPlane` claims it too (spec §8.5), and `OrgPlane`
    /// draws *above* this one — so when both are on screen, Escape belongs
    /// to the org plane and this must stand down.
    ///
    /// Found on the 2b-viii acceptance walk: with a mutation parked and the
    /// org plane opened over it, Escape cancelled the mutation behind the
    /// plane the operator was actually looking at. Cancelling an unrelated,
    /// invisible confirmation is the worst available outcome for a key
    /// pressed to dismiss something else.
    let ownsEscape: Bool

    /// Whether the typed-confirmation field holds first responder. There
    /// is no other `@FocusState` anywhere in `WakilApp`, and this plane's
    /// one job is a typed word — without this, first responder is
    /// whatever the window had focused before the plane appeared (the
    /// agent composer, most likely), so an operator who sees the plane
    /// and types "confirm" would type it somewhere else entirely.
    @FocusState private var confirmationFieldFocused: Bool

    /// §5's reserved destructive red. Not `Color(hex:)` — there is no such
    /// helper in this target — but the idiom every other `#e85c5c` site in
    /// `WakilApp` already uses (`ThoughtThread.swift`, `WakilWindow.swift`).
    private var destructive: Color { Color(red: 0.910, green: 0.361, blue: 0.361) }   // #e85c5c

    /// The keyboard as it was when the plane rose, given back when it goes.
    @State private var keyboardReturn = PlaneKeyboardReturn()

    /// The site a site question asks about; nil for a production act and every other change.
    private var site: String? {
        if case .site(let site) = pending.ask { return site }
        return nil
    }

    /// A change and a production act always type the word; a site question only when spoken.
    private var showsField: Bool { site == nil || siteWantsTyping }

    /// `PRODUCTION` for a production act whatever the place's environment, else the place's.
    private var corner: String {
        if case .productionSite = pending.ask { return "PRODUCTION" }
        return environment.uppercased()
    }

    /// The site question's neutral edge: the prompt card's hairline (`UnsavedPromptBar`'s).
    private var neutral: Color { BrowserPaneStyle.text.opacity(BrowserPaneStyle.promptEdge) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(site.map { "Let the agent use \($0)?" }
                     ?? (pending.origin == .agent ? "The agent proposes a change" : "Confirm this change"))
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Text(corner)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(site == nil ? destructive : BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
            }

            if site != nil {
                Text("It can click, type and submit there until this conversation ends.")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let database = pending.database {
                Text(database).font(.system(size: 12, design: .monospaced)).opacity(0.7)
            }

            ScrollView {
                Text(pending.statement)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)

            if pending.affectsEveryRow {
                Text("No WHERE clause — this affects every row.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(destructive)
            }

            HStack(spacing: 12) {
                if showsField {
                    TextField("type confirm", text: $typed)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($confirmationFieldFocused)
                        .onSubmit(confirm)
                        .accessibilityIdentifier("confirmation.field")
                } else {
                    Spacer(minLength: 0)
                }
                if site != nil {
                    Button("Don't Allow", action: cancel)
                        .keyboardShortcut(ownsEscape ? KeyboardShortcut.cancelAction : nil)
                        .accessibilityIdentifier("confirmation.deny")
                    Button("Allow for this conversation", action: showsField ? confirm : allow)
                        .disabled(showsField && typed != "confirm")
                        // A typed request's Allow takes the keyboard: Return answers it (ruling 13).
                        .keyboardShortcut(!showsField && ownsEscape ? KeyboardShortcut.defaultAction : nil)
                        .accessibilityIdentifier("confirmation.allow")
                } else {
                    // The button itself never goes away — Cancel stays
                    // clickable under the org plane's dimmer for an operator
                    // who dismisses that plane first. Only the *key
                    // equivalent* is surrendered. See `ownsEscape`.
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(ownsEscape ? KeyboardShortcut.cancelAction : nil)
                        .accessibilityIdentifier("confirmation.cancel")
                    Button("Run", action: confirm).disabled(typed != "confirm")
                        .accessibilityIdentifier("confirmation.run")
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(.black.opacity(0.86))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(site == nil ? destructive : neutral, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 30)
        // Fires when this view is inserted into the hierarchy — i.e. when
        // the plane appears, since `Canvas.swift` only ever includes it
        // conditionally (`if let pending = model.pending`).
        // The plane's own window, not the key one: an agent may ask while Wakil is in the background,
        // and the keyboard to keep and to take is this window's. What held it is read before the
        // plane takes it.
        .background(PlaneWindowReader { window in
            keyboardReturn.capture(in: window)
            // A turn later: this can run inside SwiftUI's update, where a focus change is dropped.
            DispatchQueue.main.async { takeKeyboard() }
        })
        // One proposal straight after another keeps this view: the next one takes the keyboard too.
        .onChange(of: pending.id) { _, _ in takeKeyboard() }
        .onDisappear { keyboardReturn.restore() }
    }

    private func takeKeyboard() {
        if showsField {
            confirmationFieldFocused = true
        } else {
            // No field: nothing the operator types goes on into the composer they asked in,
            // where a Return would send it — Return and Esc are the plane's.
            confirmationFieldFocused = false
            DispatchQueue.main.async { keyboardReturn.window?.makeFirstResponder(nil) }
        }
    }
}

/// What held the keyboard as a plane rose (a text field's own view rather than its field editor),
/// and the window it was in. Given back once the plane has gone — only when nothing else took the
/// keyboard meanwhile, and only to a view still in that window (Rule 6).
@MainActor
final class PlaneKeyboardReturn {
    private(set) weak var window: NSWindow?
    private weak var responder: NSResponder?

    func capture(in window: NSWindow) {
        self.window = window
        var held = window.firstResponder
        if let editor = held as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { held = field }
        responder = held === window ? nil : held
    }

    func restore() {
        // A turn later: the plane's own field leaves first responder as the plane is taken down.
        DispatchQueue.main.async { [self] in
            guard let window, let view = responder as? NSView, view.window === window else { return }
            let now = window.firstResponder
            let free = now == nil || now === window
                || ((now as? NSTextView)?.isFieldEditor == true && ((now as? NSTextView)?.delegate as? NSView)?.window == nil)
            guard free else { return }
            window.makeFirstResponder(view)
        }
    }
}

/// Tells `found` the window the plane is drawn in, once, as soon as it has one.
private struct PlaneWindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var found: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let found else { return }
            self.found = nil
            found(window)
        }
    }
}
