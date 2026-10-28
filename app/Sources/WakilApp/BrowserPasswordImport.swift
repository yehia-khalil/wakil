import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WakilKit

/// 3d-iv: the one-time import from the Passwords app's CSV (ruling 17).
///
/// **The file is read once, into memory, and parsed. Its rows, with their values, live only in this
/// sheet's state and go when it closes.** Nothing is written but Keychain items, each through one
/// `browser_password_save` (ruling 10) — which is also where Cancel stops (Rule 4: after the current
/// row) and why one refused row stops no other (Rule 8: its refusal shows whole on it). After the run
/// the sheet asks, in place, whether to move the file to the Trash (`FileManager.trashItem`; never a
/// permanent delete).
struct BrowserPasswordImport: View {
    /// The organisation Settings is showing: every row's picker starts on it.
    let org: String
    let access: BrowserPasswordsAccess
    let close: () -> Void

    enum Outcome: Equatable { case imported, refused(String) }

    @State private var file: URL?
    @State private var rows: [BrowserImportRow] = []
    @State private var readError: String?
    @State private var organisations: [WindowModel.OrgListing] = []
    /// Row id → the organisation it goes to, when not `org`.
    @State private var chosen: [Int: String] = [:]
    /// Organisation → site → the usernames already saved there: what "replaces" is decided from.
    @State private var saved: [String: [String: Set<String>]] = [:]
    @State private var running = false
    @State private var cancelling = false
    @State private var finished = false
    @State private var current = 0
    @State private var total = 0
    @State private var outcomes: [Int: Outcome] = [:]
    @State private var asksTrash = false
    @State private var trashNote: String?

    private var coolWhite: Color { SettingsPalette.coolWhite }
    private var caution: Color { SettingsPalette.caution }

    var body: some View {
        SettingsSheet(title: BrowserPasswordImportPlan.title, subtitle: BrowserPasswordImportPlan.hint) {
            VStack(alignment: .leading, spacing: 12) {
                fileLine
                if let readError {
                    SheetMessage(text: readError, identifier: "settings.browser.passwords.import.error")
                }
                if !rows.isEmpty { rowList }
                if running {
                    Text(BrowserPasswordImportPlan.progress(current, of: total))
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(coolWhite.opacity(0.72))
                        .accessibilityIdentifier("settings.browser.passwords.import.progress")
                }
                if finished { receipt }
            }
        } footer: {
            Spacer()
            FormButton(title: finished ? "Done" : BrowserPasswordImportPlan.cancelLabel, tone: coolWhite,
                       identifier: "settings.browser.passwords.import.cancel") {
                if running { cancelling = true } else { close() }
            }
            .disabled(cancelling)
            .keyboardShortcut(.cancelAction)
            SheetPrimaryButton(title: BrowserPasswordImportPlan.importLabel,
                               enabled: !finished && !BrowserPasswordImportPlan.runnable(rows).isEmpty,
                               working: running, identifier: "settings.browser.passwords.import.run") {
                run()
            }
        }
        .interactiveDismissDisabled(running)
        .task { await loadOrganisations() }
        // Dropped with the sheet, and said so: no value outlives it.
        .onDisappear {
            cancelling = true
            rows = []
            outcomes = [:]
            file = nil
        }
    }

    // MARK: The file

    private var fileLine: some View {
        HStack(spacing: 10) {
            FormButton(title: file == nil ? "Choose File…" : "Choose Another File…", tone: SettingsPalette.accent,
                       identifier: "settings.browser.passwords.import.choose") {
                choose()
            }
            .disabled(running || finished)
            if let file {
                Text(file.lastPathComponent)
                    .font(.system(size: SettingsScale.identifier, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Read once into memory and parsed; the bytes go when this returns.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.prompt = "Choose"
        panel.message = "Choose the file Passwords exported"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readError = nil
        outcomes = [:]
        chosen = [:]
        do {
            let parsed = try BrowserPasswordCSV.parse(try Data(contentsOf: url))
            rows = BrowserPasswordImportPlan.ordered(parsed)
            file = url
        } catch BrowserPasswordCSVError.noHeader {
            rows = []
            file = url
            readError = "\(url.lastPathComponent) has no url and password columns, so it is not a Passwords export."
        } catch {
            rows = []
            file = url
            readError = "\(url.lastPathComponent) can't be read: \(error.localizedDescription)"
        }
        Task { await loadSaved(for: org) }
    }

    // MARK: The rows

    private var rowList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { n, row in
                    rowView(row, n: n)
                }
            }
        }
        .frame(maxHeight: 320)
    }

    private func rowView(_ row: BrowserImportRow, n: Int) -> some View {
        let target = chosen[row.id] ?? org
        let note = row.site.flatMap { saved[target]?[$0] }
            .map { BrowserPasswordImportPlan.note(row, saved: $0) } ?? row.skipped
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.site ?? (row.url.isEmpty ? row.title : row.url))
                        .font(.system(size: SettingsScale.identifier, design: .monospaced))
                        .foregroundStyle(coolWhite.opacity(row.skipped == nil ? 0.86 : 0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(BrowserPasswordSettings.shown(row.username))
                        .font(.system(size: SettingsScale.meta + 1))
                        .foregroundStyle(coolWhite.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if row.skipped == nil {
                    if outcomes[row.id] == .imported {
                        Image(systemName: "checkmark")
                            .font(.system(size: SettingsScale.meta, weight: .semibold))
                            .foregroundStyle(coolWhite.opacity(0.72))
                            .accessibilityLabel("Imported")
                    }
                    Picker("", selection: Binding(get: { chosen[row.id] ?? org }, set: { pick($0, for: row) })) {
                        ForEach(organisationChoices, id: \.id) { choice in
                            Text(choice.label).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(running || finished)
                    .accessibilityIdentifier("settings.browser.passwords.import.row.\(n).org")
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: SettingsScale.meta + 1))
                    .foregroundStyle(coolWhite.opacity(0.50))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .refused(let why)? = outcomes[row.id] {
                Text(why)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.browser.passwords.import.row.\(n).refusal")
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(coolWhite.opacity(0.06)).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.browser.passwords.import.row.\(n)")
    }

    /// Every organisation on this Mac, the shown one always among them.
    private var organisationChoices: [(id: String, label: String)] {
        var all = organisations.map { (id: $0.name, label: $0.displayName ?? $0.name) }
        if !all.contains(where: { $0.id == org }) { all.insert((org, org), at: 0) }
        return all
    }

    private func pick(_ target: String, for row: BrowserImportRow) {
        chosen[row.id] = target == org ? nil : target
        Task { await loadSaved(for: target) }
    }

    private func loadOrganisations() async {
        organisations = await access.organisations()
    }

    /// The organisation's saved logins, attributes only (no prompt), for the rows' "replaces" note.
    private func loadSaved(for target: String) async {
        guard saved[target] == nil else { return }
        let store = access.store
        let found = await Task.detached { try? store.logins(org: target, site: nil) }.value
        var bySite: [String: Set<String>] = [:]
        for login in found ?? [] { bySite[login.site, default: []].insert(login.username) }
        saved[target] = bySite
    }

    // MARK: The run (Rules 4, 5 and 8)

    private func run() {
        guard !running, !finished else { return }
        let plan = BrowserPasswordImportPlan.runnable(rows)
        guard !plan.isEmpty else { return }
        running = true
        cancelling = false
        total = plan.count
        current = 0
        let targets = chosen, org = org, access = access
        Task {
            for row in plan {
                if cancelling { break }
                current += 1
                guard let params = BrowserPasswordImportPlan.save(row, org: targets[row.id] ?? org) else { continue }
                do {
                    try await access.dispatch("browser_password_save", params)
                    outcomes[row.id] = .imported
                } catch {
                    outcomes[row.id] = .refused(String(describing: error))
                }
            }
            running = false
            cancelling = false
            finished = true
            asksTrash = file != nil
        }
    }

    private var imported: Int { outcomes.values.filter { $0 == .imported }.count }

    private var receipt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BrowserPasswordImportPlan.receipt(imported: imported, rows: rows.count))
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(coolWhite.opacity(0.80))
                .accessibilityIdentifier("settings.browser.passwords.import.done")
            if asksTrash, let file {
                Text(BrowserPasswordImportPlan.trashQuestion(file: file.lastPathComponent))
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.browser.passwords.import.trash.question")
                HStack(spacing: 10) {
                    FormButton(title: BrowserPasswordImportPlan.trashLabel, tone: caution, filled: true,
                               identifier: "settings.browser.passwords.import.trash.confirm") {
                        trash(file)
                    }
                    FormButton(title: BrowserPasswordImportPlan.keepLabel, tone: coolWhite.opacity(0.62),
                               identifier: "settings.browser.passwords.import.trash.keep") {
                        asksTrash = false
                    }
                }
            }
            if let trashNote {
                SheetMessage(text: trashNote, identifier: "settings.browser.passwords.import.trash.note")
            }
        }
    }

    /// To the Trash, where the operator can still take it back — never a permanent delete.
    private func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            asksTrash = false
            trashNote = "✓ \(url.lastPathComponent) is in the Trash."
        } catch {
            trashNote = "\(url.lastPathComponent) was not moved to the Trash: \(error.localizedDescription)"
        }
    }
}
