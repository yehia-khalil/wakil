import AppKit
import SwiftUI
import WakilKit

/// + Add a project (2e-ii, extended by 3a-iii): open a folder already on this Mac, or clone a
/// repository from a link. Cloning asks for the link — which takes the keyboard (Rule 3) — and
/// where to put it, the last folder cloned into by default; Clone shows its spinner, and Cancel stops
/// it (Rules 4, 5). The clone becomes a project as a chosen folder does.
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

    private var ready: Bool { !link.trimmingCharacters(in: .whitespaces).isEmpty && !folder.isEmpty }

    var body: some View {
        SettingsSheet(
            title: cloning ? "Clone a repository" : "Add a project",
            subtitle: cloning ? "It is cloned with this organisation's git account for the link's host, then added as a project."
                : "Open a folder on this Mac, or clone a repository from a link."
        ) {
            if cloning { cloneForm } else { choices }
        } footer: {
            if cloning {
                FormButton(title: "Back", tone: SettingsPalette.coolWhite, identifier: "settings.projects.clone.back") {
                    cloning = false
                    error = nil
                }
                .disabled(task != nil)
            }
            Spacer()
            FormButton(title: "Cancel", tone: SettingsPalette.coolWhite, identifier: "settings.projects.add.close") {
                if let task { task.cancel(); self.task = nil } else { close() }
            }
            .keyboardShortcut(.cancelAction)
            if cloning {
                SheetPrimaryButton(title: task == nil ? "Clone" : "Cloning…", enabled: ready, working: task != nil,
                                   identifier: "settings.projects.clone.go") { start() }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetChoice(title: "Open a folder", detail: "A project already on this Mac",
                        identifier: "settings.projects.add.folder") { chooseFolder() }
            SheetChoice(title: "Clone a repository", detail: "From GitHub, GitLab, Bitbucket or any git link",
                        identifier: "settings.projects.add.clone") {
                cloning = true
                folder = lastFolder
            }
        }
    }

    private var cloneForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                label("Link")
                TextField("git@github.com:org/repo.git or https://github.com/org/repo", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .focused($linkFocused)
                    // Rule 3. A beat after appearing: in a sheet, focus set as the field appears is dropped.
                    .task {
                        try? await Task.sleep(for: .milliseconds(150))
                        linkFocused = true
                    }
                    .onSubmit { if ready, task == nil { start() } }
                    .disabled(task != nil)
                    .accessibilityIdentifier("settings.projects.clone.link")
            }
            VStack(alignment: .leading, spacing: 6) {
                label("Into")
                HStack(spacing: 8) {
                    Text(folder.isEmpty ? "Choose a folder" : (folder as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: SettingsScale.body, design: .monospaced))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(folder.isEmpty ? 0.4 : 0.8))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(SettingsPalette.coolWhite.opacity(0.05)))
                        .accessibilityIdentifier("settings.projects.clone.folder")
                    FormButton(title: "Change…", tone: SettingsPalette.coolWhite, identifier: "settings.projects.clone.change") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Clone here"
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                    .disabled(task != nil)
                }
            }
            if let error { SheetMessage(text: error, identifier: "settings.projects.clone.error") }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: SettingsScale.meta, weight: .medium))
            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.55))
    }

    private func start() {
        guard task == nil else { return }
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
