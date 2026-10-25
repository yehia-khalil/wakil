import AppKit
import SwiftUI
import WakilKit
import WebKit

/// A page's own request for an answer (3c-i): a JavaScript alert, confirm or prompt, an HTTP sign-in,
/// or a camera / microphone request. **Not store state** — the page asked, not the operator or the
/// agent (spec call 5's page exception) — so the host holds it, per tab and place
/// (`BrowserTabHost.prompts`), with the WebKit completion handler it answers.
///
/// **Answered exactly once.** WebKit asserts when a handler is never called, so a prompt whose web
/// view goes (its tab closed, evicted, its store cleared, its page crashed) is dismissed: denied or
/// cancelled, as Cancel would.
@MainActor
final class BrowserPrompt: Identifiable {
    enum Kind: Equatable {
        case alert(String)
        case confirm(String)
        case text(String, defaultText: String)
        /// HTTP basic or digest sign-in: the server's host and its realm.
        case signIn(host: String, realm: String)
        /// A camera / microphone request, its question already worded (global constraints' copy).
        case media(String)
    }

    enum Answer {
        /// OK, or Allow.
        case accept
        /// Cancel, or Don't Allow.
        case dismiss
        /// Its page went before the operator answered (tab closed, evicted, crashed, store
        /// cleared): answered as Cancel, and never kept as the operator's answer.
        case withdrawn
        case text(String)
        case credential(user: String, password: String)
    }

    let id = UUID()
    let kind: Kind
    /// The host of the page that asked, shown over the question so a page cannot pass as Wakil.
    let origin: String
    private var reply: (@MainActor @Sendable (Answer) -> Void)?

    init(kind: Kind, origin: String, reply: @escaping @MainActor @Sendable (Answer) -> Void) {
        self.kind = kind
        self.origin = origin
        self.reply = reply
    }

    /// Answers WebKit; a second answer is ignored.
    func answer(_ answer: Answer) {
        guard let reply else { return }
        self.reply = nil
        reply(answer)
    }

    var isAnswered: Bool { reply == nil }

    /// The backstop: a prompt let go unanswered (its holder went without answering it) still
    /// answers WebKit, as Cancel — WebKit asserts on a handler never called.
    deinit {
        guard let reply else { return }
        Task { @MainActor in reply(.withdrawn) }
    }
}

/// The camera / microphone question (global constraints): `<host> wants to use your camera`.
func browserMediaQuestion(host: String, type: WKMediaCaptureType) -> String {
    let what: String
    switch type {
    case .camera: what = "camera"
    case .microphone: what = "microphone"
    case .cameraAndMicrophone: what = "camera and microphone"
    @unknown default: what = "camera and microphone"
    }
    return "\(host) wants to use your \(what)"
}

/// A prompt drawn over its own tab's page only: the page under it waits, the rest of the canvas —
/// the pane's header and tab list, every other pane — stays usable (Rule 8; never a window-modal
/// sheet). Its first field arrives focused (Rule 3).
struct BrowserPromptCard: View {
    let prompt: BrowserPrompt
    let answer: (BrowserPrompt.Answer) -> Void

    @State private var text = ""
    @State private var user = ""
    @State private var password = ""
    @FocusState private var focused: Field?

    /// `card`: a question with no field (alert, confirm, camera / microphone) holds the keyboard
    /// itself — Return is its default button, Esc its Cancel / Don't Allow (Rule 3).
    private enum Field { case text, user, password, card }

    var body: some View {
        ZStack {
            // Takes the page's clicks while the page waits for its answer.
            Color.black.opacity(0.28).contentShape(Rectangle()).onTapGesture {}
            VStack(alignment: .leading, spacing: 10) {
                Text(prompt.origin)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.5))
                    .accessibilityIdentifier("browser.prompt.origin")
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("browser.prompt.text")
                fields
                buttons
            }
            .padding(16)
            .focusable(hasField ? false : true)
            .focused($focused, equals: .card)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard focused == .card else { return .ignored }
                answer(.accept)
                return .handled
            }
            .onKeyPress(.escape) {
                guard focused == .card else { return .ignored }
                // An alert's one button is OK; elsewhere Esc is Cancel / Don't Allow.
                if case .alert = prompt.kind { answer(.accept) } else { answer(.dismiss) }
                return .handled
            }
            .frame(maxWidth: 360, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(EditorPaneStyle.slab))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .padding(16)
        }
        .onAppear {
            if case .text(_, let initial) = prompt.kind {
                text = initial
                focused = .text
            } else if case .signIn = prompt.kind {
                focused = .user
            } else {
                focused = .card
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.prompt")
    }

    private var hasField: Bool {
        switch prompt.kind {
        case .text, .signIn: true
        default: false
        }
    }

    private var message: String {
        switch prompt.kind {
        case .alert(let m), .confirm(let m), .media(let m): m
        case .text(let m, _): m
        case .signIn(let host, let realm): realm.isEmpty ? "Sign in to \(host)" : "Sign in to \(host) — \(realm)"
        }
    }

    @ViewBuilder private var fields: some View {
        switch prompt.kind {
        case .text:
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .text)
                .onSubmit { answer(.text(text)) }
                .onExitCommand { answer(.dismiss) }
                .accessibilityIdentifier("browser.prompt.field")
        case .signIn:
            TextField("User name", text: $user)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .user)
                .onSubmit { focused = .password }
                .onExitCommand { answer(.dismiss) }
                .accessibilityIdentifier("browser.prompt.user")
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .password)
                .onSubmit { answer(.credential(user: user, password: password)) }
                .onExitCommand { answer(.dismiss) }
                .accessibilityIdentifier("browser.prompt.password")
        default:
            EmptyView()
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            switch prompt.kind {
            case .alert:
                button("OK", "browser.prompt.ok") { answer(.accept) }
            case .confirm:
                button("Cancel", "browser.prompt.cancel") { answer(.dismiss) }
                button("OK", "browser.prompt.ok") { answer(.accept) }
            case .text:
                button("Cancel", "browser.prompt.cancel") { answer(.dismiss) }
                button("OK", "browser.prompt.ok") { answer(.text(text)) }
            case .signIn:
                button("Cancel", "browser.prompt.cancel") { answer(.dismiss) }
                button("Sign In", "browser.prompt.ok") { answer(.credential(user: user, password: password)) }
            case .media:
                button("Don't Allow", "browser.prompt.cancel") { answer(.dismiss) }
                button("Allow", "browser.prompt.ok") { answer(.accept) }
            }
        }
    }

    private func button(_ title: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).accessibilityIdentifier(id)
    }
}

/// A page whose certificate is not trusted (global constraints' copy):
/// `<host>'s certificate isn't trusted — <reason>`, drawn whole over the page area (Rule 8).
/// **Visit Anyway is the operator's alone** — a button here, never an action the agent can reach —
/// and it holds for that organisation and host until the window closes.
struct BrowserCertificatePage: View {
    let text: String
    let visitAnyway: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.lock")
                .font(.system(size: 22))
                .foregroundStyle(EditorPaneStyle.amber)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .accessibilityIdentifier("browser.certificate")
            Button("Visit Anyway", action: visitAnyway)
                .accessibilityIdentifier("browser.visitAnyway")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EditorPaneStyle.slab)
    }
}

/// A page whose web content process ended (global constraints' copy): `This page stopped.` with
/// Reload, which is the tab's `browser_reload`.
struct BrowserCrashPage: View {
    let reload: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("This page stopped.")
                .font(.system(size: 12))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                .accessibilityIdentifier("browser.crashed")
            Button("Reload", action: reload)
                .accessibilityIdentifier("browser.crashReload")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EditorPaneStyle.slab)
    }
}

// MARK: - Downloads

/// The pane's foot while a download is live or ended this session: each one's name, its size line,
/// Cancel while it runs (Rule 4), Show in Finder once it finished; × clears the ended ones. Every
/// control is a `browser_*` action, but Show in Finder, which is the Mac's.
struct BrowserDownloadStrip: View {
    let downloads: [BrowserDownload]
    let dispatch: (String, [String: JSONValue]) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(downloads, id: \.id) { row($0) }
                }
                .padding(.horizontal, 8)
            }
            if downloads.contains(where: { $0.state != .running }) {
                Button { dispatch("browser_downloads_clear", [:]) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(EditorPaneStyle.text.opacity(0.7))
                .help("Clear finished downloads")
                .accessibilityLabel("Clear finished downloads")
                .accessibilityIdentifier("browser.downloads.clear")
                .padding(.trailing, 8)
            }
        }
        .frame(height: 30)
        .background(EditorPaneStyle.slab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.downloads")
    }

    private func row(_ d: BrowserDownload) -> some View {
        HStack(spacing: 6) {
            Image(systemName: d.state == .finished ? "checkmark.circle" : d.state == .running ? "arrow.down.circle" : "xmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(d.state == .failed ? EditorPaneStyle.amber : EditorPaneStyle.text.opacity(0.6))
            Text(d.filename)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(EditorPaneStyle.text.opacity(0.9))
                .accessibilityIdentifier("browser.download.\(d.id).name")
            Text(status(d))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(d.state == .failed ? EditorPaneStyle.amber : EditorPaneStyle.text.opacity(0.55))
                .lineLimit(1)
                .accessibilityIdentifier("browser.download.\(d.id).status")
            switch d.state {
            case .running:
                // Rule 5: asked once, it cannot be asked again while the page stops it.
                Button("Cancel") { dispatch("browser_download_cancel", ["download": .string(d.id)]) }
                    .controlSize(.small)
                    .disabled(d.cancelRequested)
                    .accessibilityIdentifier("browser.download.\(d.id).cancel")
            case .finished:
                if let path = d.path {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("browser.download.\(d.id).show")
                }
            case .failed, .cancelled:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.download.\(d.id)")
    }

    private func status(_ d: BrowserDownload) -> String {
        switch d.state {
        case .running, .finished: browserDownloadSize(received: d.received, expected: d.expected, state: d.state)
        case .cancelled: "Cancelled"
        case .failed: d.failure ?? "Failed"
        }
    }
}
