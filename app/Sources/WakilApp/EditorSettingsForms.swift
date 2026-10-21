import WakilKit
import SwiftUI

/// A whole number edited in a field (3b-v): ± steps write at once; typed text writes when focus
/// leaves or on Return (Rule 2). An invalid value keeps the text, shows why, and writes nothing
/// (Rule 8) — the range check is Go's, so the sentence is Go's.
struct NumberSettingRow: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let identifier: String
    let save: (Int) async -> String?

    @State private var draft: String?
    @State private var refusal: String?
    @State private var inFlight = false
    @FocusState private var focused: Bool

    private var coolWhite: Color { SettingsPalette.coolWhite }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(label) {
                HStack(spacing: 8) {
                    TextField("", text: Binding(get: { draft ?? "\(value)" }, set: { draft = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsScale.body, design: .monospaced))
                        .foregroundStyle(coolWhite.opacity(0.88))
                        .frame(width: 44)
                        .inPlaceField(focused: focused)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, now in if !now { commit() } }
                        .accessibilityIdentifier(identifier)
                    Stepper("", value: Binding(get: { value }, set: { n in draft = nil; write(n) }), in: range)
                        .labelsHidden()
                        .accessibilityIdentifier("\(identifier).stepper")
                    Text("\(range.lowerBound)–\(range.upperBound)")
                        .font(.system(size: SettingsScale.meta))
                        .foregroundStyle(coolWhite.opacity(0.30))
                }
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .underRowValue()
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("\(identifier).refusal")
            }
        }
    }

    private func commit() {
        guard !inFlight else { return }
        guard let text = draft?.trimmingCharacters(in: .whitespaces), text != "\(value)" else {
            draft = nil
            refusal = nil
            return
        }
        guard let n = Int(text) else {
            refusal = "\(label) must be a whole number from \(range.lowerBound) to \(range.upperBound)"
            return
        }
        write(n)
    }

    private func write(_ n: Int) {
        // Whatever was typed is taken now, so Return then focus-loss (or a ± click that moves
        // focus) writes once. The field keeps showing the value being written until the save
        // lands, so a focus-leave never sees the old value as an edit; a refusal puts the typed
        // text back.
        let typed = draft
        draft = "\(n)"
        inFlight = true
        Task {
            let answer = await save(n)
            refusal = answer
            draft = answer != nil ? typed : nil
            inFlight = false
        }
    }
}

/// A two-state setting drawn as `SegmentedChoice`, written on click.
struct ChoiceSettingRow: View {
    let label: String
    let options: [String]
    let selected: String
    let identifier: (String) -> String
    let refusalIdentifier: String
    /// What the setting does, under the choice; nil draws none.
    var hint: String? = nil
    let save: (String) async -> String?

    @State private var refusal: String?
    private var coolWhite: Color { SettingsPalette.coolWhite }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(label) {
                    SegmentedChoice(
                        options: options,
                        selection: Binding(get: { selected }, set: { option in
                            guard option != selected else { return }
                            Task { refusal = await save(option) }
                        }),
                        identifier: identifier)
            }
            if let hint {
                FormHint(hint).underRowValue().padding(.vertical, 6)
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .underRowValue()
                    .padding(.vertical, 4)
                    .accessibilityIdentifier(refusalIdentifier)
            }
        }
    }
}

/// The top-level Editor node: the operator's app-wide editor settings (3b-v).
struct EditorAppSettingsForm: View {
    let editor: SettingsEditor
    let error: String?
    let save: ([String: JSONValue]) async -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Text(error + " — the defaults are in force; fix or remove the file to change them here.")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.editor.error")
            }
            // Two groups (2026-10-21): how text is edited, and which files are listed.
            SettingsSection("Editing") {
                NumberSettingRow(
                    label: "Font size", value: editor.fontSize, range: 9...24,
                    identifier: "settings.editor.fontSize",
                    save: { n in await save(["fontSize": .integer(Int64(n))]) })
                ChoiceSettingRow(
                    label: "Word wrap", options: ["Off", "On"], selected: editor.wordWrap ? "On" : "Off",
                    identifier: { option in
                        let key = option.lowercased()
                        return "settings.editor.wordWrap.\(key)"
                    },
                    refusalIdentifier: "settings.editor.wordWrap.refusal",
                    save: { option in await save(["wordWrap": .bool(option == "On")]) })
                ChoiceSettingRow(
                    label: "Autosave", options: EditorAutosaveMode.allCases.map(\.label),
                    selected: editor.autosave.label,
                    identifier: { label in
                        let mode = EditorAutosaveMode.allCases.first { $0.label == label }?.rawValue ?? label
                        return "settings.editor.autosave.\(mode)"
                    },
                    refusalIdentifier: "settings.editor.autosave.refusal",
                    save: { label in
                        let mode = EditorAutosaveMode.allCases.first { $0.label == label } ?? .off
                        return await save(["autosave": .string(mode.rawValue)])
                    })
            }
            SettingsSection("Files") {
                ChoiceSettingRow(
                    label: "Show ignored files", options: ["Off", "On"], selected: editor.showIgnored ? "On" : "Off",
                    identifier: { option in
                        let key = option.lowercased()
                        return "settings.editor.showIgnored.\(key)"
                    },
                    refusalIdentifier: "settings.editor.showIgnored.refusal",
                    hint: "Files your .gitignore excludes, like .env or build output. On, they show dimmed "
                        + "in the Files tree and ⌘P; project search never looks inside them.",
                    save: { option in await save(["showIgnored": .bool(option == "On")]) })
            }
            Text("Yours across every organisation and project — stored in ~/.wakil/settings.json.")
                .font(.system(size: SettingsScale.meta))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.40))
        }
    }
}

/// A project's Editor node: the settings that belong to its code, in its project.json (3b-v).
struct EditorProjectSettingsForm: View {
    let editor: SettingsProjectEditor
    let save: ([String: JSONValue]) async -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Two groups (2026-10-21): indentation, and the heavy folders.
            SettingsSection("Indentation") {
                NumberSettingRow(
                    label: "Tab size", value: editor.tabSize, range: 1...16,
                    identifier: "settings.projectEditor.tabSize",
                    save: { n in await save(["tabSize": .integer(Int64(n))]) })
                ChoiceSettingRow(
                    label: "Indent with", options: ["Spaces", "Tabs"], selected: editor.insertSpaces ? "Spaces" : "Tabs",
                    identifier: { option in
                        let key = option.lowercased()
                        return "settings.projectEditor.indent.\(key)"
                    },
                    refusalIdentifier: "settings.projectEditor.indent.refusal",
                    save: { option in await save(["insertSpaces": .bool(option == "Spaces")]) })
            }
            SettingsSection("Heavy folders") {
                HeavyFoldersSettingRow(
                    folders: editor.heavyFolders,
                    save: { names in await save(["heavyFolders": .array(names.map { .string($0) })]) })
            }
            Text("A file's own indentation wins: tab size and indent apply to new files and files with none. "
                 + "Stored in this project's project.json, so they travel with the code.")
                .font(.system(size: SettingsScale.meta))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.40))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A project's heavy folders (3b-v part 2): `.git` first, fixed, then one name per row. A row
/// writes when focus leaves it or on Return (Rule 2); *Add folder* adds an empty row, focused
/// (Rule 3); × writes the list without that row at once — adding it back undoes it (Rule 1). A row
/// left empty writes nothing and goes away; a refused name keeps its text and shows Go's sentence
/// under the list (Rule 8). Every write sends the whole list.
struct HeavyFoldersSettingRow: View {
    let folders: [String]
    let save: ([String]) async -> String?

    @State private var drafts: [Int: String] = [:]
    /// The added row's text; nil when there is no added row.
    @State private var adding: String?
    @State private var refusal: String?
    /// The row the sentence refuses (`addedKey` for the added row); a write on another row leaves it.
    @State private var refusalRow: Int?
    @State private var inFlight = false
    /// Rows whose focus left while a write was in flight (`addedKey` for the added row).
    @State private var queued: [Int] = []
    /// A row's index; `folders.count` is the added row.
    @FocusState private var focused: Int?

    private var coolWhite: Color { SettingsPalette.coolWhite }

    var body: some View {
        // Headed by the page's HEAVY FOLDERS section (`SettingsSection`), not by itself.
        VStack(alignment: .leading, spacing: 4) {
            FormHint("Big folders git ignores, like vendor or node_modules, matched by name at any depth. "
                     + "Each shows as one row and loads only when you open it, so the tree and ⌘P stay "
                     + "fast; project search skips them. Remove a name to list its files like any "
                     + "ignored file.")
                .padding(.bottom, 4)
            HStack(spacing: 8) {
                Text(".git")
                    .font(.system(size: SettingsScale.body, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.45))
                    .fieldBox(width: 180)
                Text("always heavy")
                    .font(.system(size: SettingsScale.meta))
                    .foregroundStyle(coolWhite.opacity(0.40))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.projectEditor.heavy.git")
            ForEach(Array(folders.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 8) {
                    field(text: Binding(get: { drafts[i] ?? name }, set: { drafts[i] = $0 }), row: i)
                        .accessibilityIdentifier("settings.projectEditor.heavy.\(i)")
                    Button {
                        var next = folders
                        next.remove(at: i)
                        write(next, wrote: .removed(i))
                    } label: {
                        Image(systemName: "xmark").font(.system(size: SettingsScale.meta))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(coolWhite.opacity(0.40))
                    .disabled(inFlight)
                    .accessibilityLabel("Remove \(name)")
                    .accessibilityIdentifier("settings.projectEditor.heavy.\(i).remove")
                }
            }
            if adding != nil {
                field(text: Binding(get: { adding ?? "" }, set: { adding = $0 }), row: folders.count)
                    .accessibilityIdentifier("settings.projectEditor.heavy.new")
                    // Rule 3, one turn late: set in the update that inserts the row, the field has no
                    // AppKit view yet, and SwiftUI hands the keyboard to the pane's first field
                    // (Tab size) instead. Asked after that update, the field exists to take it.
                    .onAppear {
                        let row = folders.count
                        DispatchQueue.main.async { focused = row }
                    }
            } else {
                FormButton(title: "+ Add folder", tone: coolWhite.opacity(0.75),
                           identifier: "settings.projectEditor.heavy.add") {
                    clearRefusal(ifRow: Self.addedKey)
                    adding = ""
                }
                .disabled(inFlight)
                .padding(.top, 2)
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.projectEditor.heavy.refusal")
            }
        }
        .padding(.bottom, 4)
        .onChange(of: inFlight) { _, now in if !now { drainQueued() } }
    }

    private func field(text: Binding<String>, row: Int) -> some View {
        TextField("folder name", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: SettingsScale.body, design: .monospaced))
            .foregroundStyle(coolWhite.opacity(0.88))
            .fieldBox(width: 180)
            .focused($focused, equals: row)
            .onSubmit { commit(row) }
            .onChange(of: focused) { was, now in if was == row, now != row { commit(row) } }
    }

    private func commit(_ row: Int) {
        if inFlight {
            // Nothing is dropped: the edit runs once the write in flight has landed.
            let key = row == folders.count ? Self.addedKey : row
            if !queued.contains(key) { queued.append(key) }
            return
        }
        if row == folders.count {
            let name = (adding ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                adding = nil
                clearRefusal(ifRow: Self.addedKey)
                return
            }
            write(folders + [name], wrote: .added(name))
            return
        }
        guard row < folders.count, let text = drafts[row]?.trimmingCharacters(in: .whitespaces),
              text != folders[row] else {
            drafts[row] = nil
            return
        }
        var next = folders
        if text.isEmpty {
            next.remove(at: row)
            write(next, wrote: .removed(row))
        } else {
            next[row] = text
            write(next, wrote: .row(row, text))
        }
    }

    private static let addedKey = -1

    /// What a write commits; on success only that entry's input is cleared.
    private enum Wrote { case row(Int, String), added(String), removed(Int) }

    /// The typed text stays until the save lands: a success clears only what it wrote (other rows'
    /// drafts and the added row survive), a refusal keeps it beside its sentence. `inFlight`
    /// makes Return then focus-leave write once; a commit that arrives meanwhile is queued.
    private func write(_ next: [String], wrote: Wrote) {
        inFlight = true
        Task {
            let answer = await save(next)
            let key: Int
            switch wrote {
            case .row(let i, _), .removed(let i): key = i
            case .added: key = Self.addedKey
            }
            if let answer {
                refusal = answer
                refusalRow = key
            } else {
                clearRefusal(ifRow: key)
                switch wrote {
                // Text typed after the commit stays: clear only what was written.
                case .row(let i, let text):
                    if drafts[i]?.trimmingCharacters(in: .whitespaces) == text { drafts[i] = nil }
                case .added(let name):
                    if adding?.trimmingCharacters(in: .whitespaces) == name { adding = nil }
                case .removed(let i): rowRemoved(i)
                }
            }
            inFlight = false
        }
    }

    private func clearRefusal(ifRow key: Int) {
        if refusalRow == key {
            refusal = nil
            refusalRow = nil
        }
    }

    /// Row `i` is gone: drafts, focus and queued edits above it move down one so they stay on the
    /// folder they were typed on (Rule 6).
    private func rowRemoved(_ i: Int) {
        var shifted: [Int: String] = [:]
        for (k, v) in drafts where k != i { shifted[k > i ? k - 1 : k] = v }
        drafts = shifted
        if let f = focused { focused = f == i ? nil : (f > i ? f - 1 : f) }
        queued = queued.compactMap { $0 == i ? nil : ($0 > i ? $0 - 1 : $0) }
        if let r = refusalRow, r != Self.addedKey, r > i { refusalRow = r - 1 }
    }

    private func drainQueued() {
        guard !inFlight, !queued.isEmpty else { return }
        let key = queued.removeFirst()
        commit(key == Self.addedKey ? folders.count : key)
        drainQueued()
    }
}
