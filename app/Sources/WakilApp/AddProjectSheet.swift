import AppKit
import SwiftUI
import WakilKit

/// + Add a project (2e-ii, extended by 3a-iii): Choose a folder… as before, or Clone from a link… —
/// the link field takes the keyboard (Rule 3), the destination is the last folder cloned into with
/// Change…, and Clone shows its spinner and Cancel (Rules 4, 5). The clone becomes a project as a
/// chosen folder does.
struct AddProjectSheet: View {
    let lastFolder: String
    let chooseFolder: () -> Void
    let clone: (String, String) async -> (name: String?, error: String?)
    let finished: (String) -> Void
    let close: () -> Void

    @State private var cloning = false
    @State private var link = ""
    @State private var folder = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a project").font(.system(size: 14, weight: .semibold))
            if !cloning {
                HStack(spacing: 8) {
                    FormButton(title: "Choose a folder…", tone: SettingsPalette.accent, filled: true,
                               identifier: "settings.projects.add.folder") { chooseFolder() }
                    FormButton(title: "Clone from a link…", tone: SettingsPalette.accent,
                               identifier: "settings.projects.add.clone") {
                        cloning = true
                        folder = lastFolder
                        linkFocused = true
                    }
                }
            } else {
                TextField("https://github.com/org/repo or git@github.com:org/repo.git", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .focused($linkFocused)
                    .onAppear { linkFocused = true }
                    .accessibilityIdentifier("settings.projects.clone.link")
                HStack(spacing: 8) {
                    Text(folder.isEmpty ? "Choose where to clone" : folder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.7))
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("settings.projects.clone.folder")
                    FormButton(title: "Change…", tone: SettingsPalette.coolWhite, identifier: "settings.projects.clone.change") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Clone here"
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                }
                HStack(spacing: 8) {
                    if task != nil {
                        ProgressView().controlSize(.small)
                        Text("Cloning…").font(.system(size: SettingsScale.meta))
                        FormButton(title: "Cancel", tone: SettingsPalette.caution, identifier: "settings.projects.clone.cancel") {
                            task?.cancel()
                            task = nil
                        }
                    } else {
                        FormButton(title: "Clone", tone: SettingsPalette.accent, filled: true, identifier: "settings.projects.clone.go") {
                            start()
                        }
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || folder.isEmpty)
                    }
                }
                if let error {
                    Text(error)
                        .font(.system(size: SettingsScale.meta))
                        .foregroundStyle(SettingsPalette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.projects.clone.error")
                }
            }
            HStack {
                Spacer()
                FormButton(title: "Close", tone: SettingsPalette.coolWhite, identifier: "settings.projects.add.close") { close() }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func start() {
        error = nil
        let (l, f) = (link.trimmingCharacters(in: .whitespaces), folder)
        task = Task {
            let r = await clone(l, f)
            task = nil
            if Task.isCancelled { return }
            if let e = r.error { error = e } else if let name = r.name { finished(name) }
        }
    }
}
