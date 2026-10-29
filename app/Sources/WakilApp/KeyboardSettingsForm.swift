import AppKit
import SwiftUI
import WakilKit

/// The top-level Keyboard node (keyboard Task 6): every shortcut, grouped as the menu bar groups
/// them, and a recorder on each rebindable one. App-wide (~/.wakil/settings.json `"keys"`).
///
/// **No dialogs** (rule 1): a chord taken from another command, and Restore All, leave an Undo
/// line instead. A recorded chord saves on the keystroke (rule 2).
struct KeyboardSettingsForm: View {
    let keymap: Keymap
    /// settings.json's error, whole, when it could not be read: shown above the list, and nothing
    /// here writes until it reads again (a write would replace the file Wakil couldn't read).
    let error: String?
    let setKey: (String, KeyChange) async -> KeySetOutcome
    /// Writes the whole override map (Undo, Restore All); answers the refusal's sentence, or nil.
    let setKeys: ([String: String]) async -> String?
    /// Tells the window a recorder holds the keyboard, so its F-key monitor leaves every key alone.
    let recordingKey: (Bool) -> Void

    /// What Undo writes back and where its line sits: under a command's row, or at the bottom
    /// (`row` nil) for Restore All. It stays until the next change.
    private struct UndoLine {
        let row: String?
        let text: String
        let before: [String: String]
    }

    @State private var query = ""
    /// The command whose chord box is recording.
    @State private var recording: String?
    /// A chord pressed and on its way to `ctx_set_key`: the box shows it dimmed and does not
    /// record again until the reply (rule 5).
    @State private var pending: (id: String, chord: KeyChord?)?
    /// A refused chord or a refused write, whole, under its row (rule 8), by command id.
    @State private var refusals: [String: String] = [:]
    @State private var undo: UndoLine?
    /// Undo or Restore All in flight.
    @State private var writing = false
    /// A refused Undo, under its line; a refused Restore All, under its button.
    @State private var lineRefusal: String?
    @State private var restoreAllRefusal: String?

    private var coolWhite: Color { SettingsPalette.coolWhite }
    private var caution: Color { SettingsPalette.caution }
    private var canWrite: Bool { error == nil && !writing && pending == nil }

    var body: some View {
        let shown = KeyCommand.matching(query, keymap: keymap)
        let fixed = FixedKey.matching(query)
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Text(error)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.keyboard.error")
            }
            searchField
            ForEach(KeyGroup.allCases, id: \.self) { group in
                let rows = shown.filter { $0.group == group }
                if !rows.isEmpty {
                    SettingsSection(group.title) {
                        ForEach(rows, id: \.id) { command in commandRow(command) }
                    }
                }
            }
            if !fixed.isEmpty {
                SettingsSection("Fixed") {
                    ForEach(fixed, id: \.title) { key in fixedRow(key) }
                }
            }
            if shown.isEmpty && fixed.isEmpty {
                Text("No shortcut matches “\(query)”.")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(coolWhite.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.keyboard.noMatch")
            }
            restoreAllSection
            Text("Shortcuts are yours across every organisation — stored in ~/.wakil/settings.json.")
                .font(.system(size: SettingsScale.meta))
                .foregroundStyle(coolWhite.opacity(0.40))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: error) { _, now in if now != nil { stopRecording() } }
        .onDisappear { stopRecording() }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(coolWhite.opacity(0.40))
            TextField("Search by name or shortcut", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(coolWhite.opacity(0.88))
                .accessibilityIdentifier("settings.keyboard.search")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(coolWhite.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(coolWhite.opacity(0.10), lineWidth: 0.5)))
        .frame(maxWidth: 320, alignment: .leading)
    }

    // MARK: Rows

    private func commandRow(_ command: KeyCommand) -> some View {
        let id = command.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: SettingsScale.columnGap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.system(size: SettingsScale.body, weight: .medium))
                        .foregroundStyle(coolWhite.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(command.place.placeTitle)
                        .font(.system(size: SettingsScale.meta))
                        .foregroundStyle(coolWhite.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                Spacer(minLength: 0)
                if !keymap.isDefault(id) {
                    Button { restoreDefault(id) } label: {
                        Text("↺")
                            .font(.system(size: SettingsScale.body))
                            .foregroundStyle(coolWhite.opacity(canWrite ? 0.62 : 0.30))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canWrite)
                    .help("Restore \(command.defaultChord.text)")
                    .accessibilityLabel("Restore the default shortcut")
                    .accessibilityIdentifier("settings.keyboard.restore.\(id)")
                }
                chordBox(id)
            }
            .frame(minHeight: SettingsScale.rowHeight)
            rowNotes(id)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(coolWhite.opacity(0.06)).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.keyboard.row.\(id)")
    }

    /// The chord, *none*, or *Type a shortcut* while recording. A click records; the recorder
    /// takes the keyboard at once (rule 3).
    private func chordBox(_ id: String) -> some View {
        let isRecording = recording == id
        let inFlight = pending?.id == id
        let anySaving = pending != nil
        let label: String
        let opacity: Double
        if isRecording {
            (label, opacity) = ("Type a shortcut", 0.52)
        } else if let pending, inFlight {
            (label, opacity) = (pending.chord?.text ?? "none", 0.40)
        } else if let chord = keymap.chord(id) {
            (label, opacity) = (chord.text, 0.88)
        } else {
            (label, opacity) = ("none", 0.40)
        }
        return Button { startRecording(id) } label: {
            Text(label)
                .font(.system(size: SettingsScale.body, design: isRecording ? .default : .monospaced))
                .foregroundStyle(coolWhite.opacity(opacity))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .frame(minWidth: 112, minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(coolWhite.opacity(isRecording ? 0.07 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(isRecording ? SettingsPalette.accent.opacity(0.85) : coolWhite.opacity(0.10),
                                        lineWidth: isRecording ? 1 : 0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // While any save is in flight, no box records (rule 5).
        .disabled(error != nil || anySaving || writing)
        // On the button, not in its label: the recorder is a plain view in the window's hierarchy.
        .overlay {
            if isRecording {
                KeyRecorder(
                    key: { event in recorded(event, for: id) },
                    cancel: { stopRecording() })
            }
        }
        .accessibilityLabel(isRecording ? "Type a shortcut" : "Shortcut \(label)")
        .accessibilityIdentifier("settings.keyboard.chord.\(id)")
    }

    /// Under a row: a refused chord or write, a stored chord that was ignored, and the Undo line.
    @ViewBuilder private func rowNotes(_ id: String) -> some View {
        if let refusal = refusals[id] {
            note(refusal, tone: caution, identifier: "settings.keyboard.refusal.\(id)")
        } else if let problem = keymap.problem(id) {
            note(problem, tone: caution, identifier: "settings.keyboard.problem.\(id)")
        }
        if let undo, undo.row == id { undoLine(undo) }
    }

    private func fixedRow(_ key: FixedKey) -> some View {
        HStack(alignment: .center, spacing: SettingsScale.columnGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.title)
                    .font(.system(size: SettingsScale.body, weight: .medium))
                    .foregroundStyle(coolWhite.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                Text(key.place)
                    .font(.system(size: SettingsScale.meta))
                    .foregroundStyle(coolWhite.opacity(0.30))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            Spacer(minLength: 0)
            Text(key.chord)
                .font(.system(size: SettingsScale.body, design: .monospaced))
                .foregroundStyle(coolWhite.opacity(0.40))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .frame(minWidth: 112, minHeight: 22)
        }
        .frame(minHeight: SettingsScale.rowHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(coolWhite.opacity(0.06)).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.keyboard.fixed.\(key.title)")
    }

    private var restoreAllSection: some View {
        let allDefault = KeyCommand.all.allSatisfy { keymap.isDefault($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            Button(action: restoreAll) {
                Text("Restore All Defaults")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(coolWhite.opacity(canWrite && !allDefault ? 0.62 : 0.30))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canWrite || allDefault)
            .accessibilityIdentifier("settings.keyboard.restoreAll")
            if let restoreAllRefusal {
                note(restoreAllRefusal, tone: caution, identifier: "settings.keyboard.restoreAll.refusal")
            }
            if let undo, undo.row == nil { undoLine(undo) }
        }
        .padding(.top, SettingsScale.sectionGap)
    }

    /// `Took ⌘P from Open… · Undo`, or `Restored all defaults · Undo`.
    private func undoLine(_ line: UndoLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(line.text + " · ")
                    .foregroundStyle(coolWhite.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Undo") { undoLast(line) }
                    .buttonStyle(.plain)
                    .foregroundStyle(coolWhite.opacity(canWrite ? 0.86 : 0.30))
                    .fixedSize()
                    .disabled(!canWrite)
                    .accessibilityIdentifier("settings.keyboard.undo")
                Spacer(minLength: 0)
            }
            .font(.system(size: SettingsScale.body))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.keyboard.undoLine")
            if let lineRefusal {
                note(lineRefusal, tone: caution, identifier: "settings.keyboard.undo.refusal")
            }
        }
        .padding(.bottom, 8)
    }

    private func note(_ text: String, tone: Color, identifier: String) -> some View {
        Text(text)
            .font(.system(size: SettingsScale.body))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.bottom, 8)
            .accessibilityIdentifier(identifier)
    }

    // MARK: Recording

    private func startRecording(_ id: String) {
        guard error == nil, pending == nil, !writing else { return }
        refusals[id] = nil
        recording = id
        recordingKey(true)
    }

    /// Esc, a click outside, the window losing the keyboard or the page going: nothing changes (rule 4).
    private func stopRecording() {
        guard recording != nil else { return }
        recording = nil
        recordingKey(false)
    }

    /// A key-down while `id` records; the recorder swallows every one, so no menu or pane sees it.
    /// The chord is the key as the layout types it (`KeyChord(event:)`): AZERTY's ⌘A records ⌘A,
    /// the chord the menu bar will then match.
    private func recorded(_ event: NSEvent, for id: String) {
        guard !event.isARepeat, let chord = KeyChord(event: event) else { return }
        if chord.key == .escape {
            stopRecording()
            return
        }
        if chord.key == .delete, chord.modifiers.isEmpty {
            save(id, .clear, shown: nil)
            return
        }
        if chord.isRefused {
            // Recording goes on, so the next key can be one Decision 50 allows.
            refusals[id] = "\(chord.text) was refused. \(KeyChord.refusedReason)"
            return
        }
        save(id, .chord(chord), shown: chord)
    }

    /// Saves on the keystroke (rule 2), the box showing `shown` dimmed until the reply.
    private func save(_ id: String, _ change: KeyChange, shown: KeyChord?) {
        let before = keymap.overrides
        stopRecording()
        refusals[id] = nil
        undo = nil
        lineRefusal = nil
        restoreAllRefusal = nil
        pending = (id, shown)
        Task {
            let outcome = await setKey(id, change)
            pending = nil
            switch outcome {
            case .took(let from?):
                let title = KeyCommand.all.first { $0.id == from }?.title ?? from
                undo = UndoLine(row: id, text: "Took \(shown?.text ?? "") from \(title)", before: before)
            case .took(nil):
                break
            case .refused(let sentence):
                refusals[id] = sentence
            }
        }
    }

    // MARK: Restore and Undo

    /// The default back, through the same save as a recorded chord: a command that held the
    /// default loses it and the Took line says so (rule 7).
    private func restoreDefault(_ id: String) {
        guard canWrite, let command = KeyCommand.all.first(where: { $0.id == id }) else { return }
        save(id, .restoreDefault, shown: command.defaultChord)
    }

    /// Every command back to its default; ids this build doesn't know are kept.
    private func restoreAll() {
        guard canWrite else { return }
        stopRecording()
        let before = keymap.overrides
        refusals = [:]
        undo = nil
        lineRefusal = nil
        restoreAllRefusal = nil
        writing = true
        Task {
            if let refusal = await setKeys(keymap.restoringAll()) {
                restoreAllRefusal = refusal
            } else {
                undo = UndoLine(row: nil, text: "Restored all defaults", before: before)
            }
            writing = false
        }
    }

    /// The map from before the change, written back whole. The line goes once it has.
    private func undoLast(_ line: UndoLine) {
        guard canWrite else { return }
        stopRecording()
        lineRefusal = nil
        writing = true
        Task {
            if let refusal = await setKeys(line.before) {
                lineRefusal = refusal
            } else {
                undo = nil
            }
            writing = false
        }
    }
}

/// The recorder's ears, laid over the chord box while it records. It takes the window's keyboard
/// (rule 3) and adds a local key-down monitor that swallows every key: local monitors run inside
/// `sendEvent` before the menu bar's key equivalents, so ⌘W is recorded rather than closing the
/// pane. The app's own F-key monitor was added first and runs first; `isRecordingKey` makes it
/// pass. A click outside the box, or the window losing the keyboard, cancels.
private struct KeyRecorder: NSViewRepresentable {
    let key: (NSEvent) -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.key = key
        view.cancel = cancel
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.key = key
        view.cancel = cancel
    }

    static func dismantleNSView(_ view: RecorderView, coordinator: ()) {
        view.stop()
    }

    @MainActor
    final class RecorderView: NSView {
        var key: (NSEvent) -> Void = { _ in }
        var cancel: () -> Void = {}
        private var keyMonitor: Any?
        private var mouseMonitor: Any?
        private var resignObserver: Any?

        override var acceptsFirstResponder: Bool { true }

        /// Clicks go through to the box beneath, which ignores them while it records.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                stop()
                return
            }
            start(in: window)
        }

        private func start(in window: NSWindow) {
            guard keyMonitor == nil else { return }
            // A responder of its own, not the window's content view, so the composer's Esc (which
            // claims Esc when focus is "nowhere") leaves it to this monitor.
            window.makeFirstResponder(self)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let taken: Bool = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window, window.isKeyWindow
                    else { return false }
                    self.key(event)
                    return true
                }
                return taken ? nil : event
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    let inside = event.window === window
                        && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                    if !inside { self.cancel() }
                }
                return event
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        }

        func stop() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            keyMonitor = nil
            mouseMonitor = nil
            resignObserver = nil
            if let window, window.firstResponder === self { window.makeFirstResponder(nil) }
        }
    }
}
