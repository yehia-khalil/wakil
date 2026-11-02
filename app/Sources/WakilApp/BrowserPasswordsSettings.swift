import AppKit
import LocalAuthentication
import SwiftUI
import WakilKit

/// 3d-iv: what Settings → Browser → Passwords reaches, handed down by the window
/// (`WakilWindow.loaded`). **Reads are direct calls; writes are actions** (ruling 10): `store` lists
/// and reads, `dispatch` runs `browser_password_save`, `_delete` and `_never` as the operator's own
/// surface calls, and `organisations` is `ctx_list_orgs` for the import's picker.
struct BrowserPasswordsAccess {
    let store: BrowserPasswordStore
    /// The HOME whose `.wakil/orgs/<org>/browser` holds `passwords-never.json`.
    let home: URL?
    let dispatch: @MainActor (String, [String: JSONValue]) async throws -> Void
    let organisations: @MainActor () async -> [WindowModel.OrgListing]

    @MainActor init(session: WindowSession) {
        let model = session.model
        store = session.wiring.browserPasswords
        home = model.browserHome
        dispatch = { name, params in _ = try await model.dispatchFromSurfaceThrowing(name, .object(params)) }
        organisations = { await model.listOrgs() }
    }
}

private struct BrowserPasswordsKey: EnvironmentKey {
    static let defaultValue: BrowserPasswordsAccess? = nil
}

extension EnvironmentValues {
    var browserPasswords: BrowserPasswordsAccess? {
        get { self[BrowserPasswordsKey.self] }
        set { self[BrowserPasswordsKey.self] = newValue }
    }
}

/// One `.deviceOwnerAuthentication` (ruling 16). Cancelled by the operator, it is no error; cancelled
/// by anything else, it is.
enum BrowserPasswordAuthentication: Sendable, Equatable {
    case open, cancelled
    case failed(String)

    static func ask(reason: String) async -> BrowserPasswordAuthentication {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            // The reply holds the context, so it lives until the evaluation answers; a context freed
            // mid-evaluation would cancel it with no word to the operator.
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
                withExtendedLifetime(context) {}
                if ok { continuation.resume(returning: .open); return }
                // Only the operator's own Cancel is silent; a system or app cancel shows whole (Rule 8).
                if let error = error as? LAError, error.code == .userCancel {
                    continuation.resume(returning: .cancelled)
                    return
                }
                continuation.resume(returning: .failed(error?.localizedDescription ?? "Authentication failed."))
            }
        }
    }
}

/// The organisation's saved logins, by site, each with Reveal, Copy, Edit and Delete; the sites it
/// never offers to save on, each with ×; and Import….
///
/// **No password outlives the section.** A revealed value, and a new password being typed, are this
/// view's state only: locked away when the authentication lapses (five minutes), when the
/// organisation changes and when the section closes. Nothing is logged and no error is built from one.
struct BrowserPasswordsSettings: View {
    let org: String
    /// What the empty sentence names: the organisation's display name.
    let name: String

    @Environment(\.browserPasswords) private var access

    @State private var logins: [BrowserLogin] = []
    /// The organisation the section shows now: a read or reveal started for another is dropped.
    @State private var shownOrg: String?
    @State private var loadError: String?
    @State private var never: [String] = []
    @State private var neverError: String?
    @State private var unlock = BrowserPasswordUnlock()
    @State private var lockTimer: Task<Void, Never>?
    /// Row key (`BrowserPasswords.account`) → its revealed value, while unlocked.
    @State private var revealed: [String: String] = [:]
    @State private var copied: String?
    /// The rows whose work runs (Rule 5): every button on such a row is inert until it ends.
    @State private var busy: Set<String> = []
    /// Each row's refusal, whole, on that row (Rule 8).
    @State private var refusals: [String: String] = [:]
    @State private var confirmingDelete: String?
    @State private var editing: BrowserLogin?
    @State private var editUsername = ""
    @State private var editPassword = ""
    @FocusState private var editFocus: EditField?
    @State private var neverBusy: String?
    @State private var importing = false

    enum EditField: Hashable { case username, password }

    private var coolWhite: Color { SettingsPalette.coolWhite }
    private var caution: Color { SettingsPalette.caution }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormHint(BrowserPasswordSettings.hint)
                .padding(.top, 4)
            list
            neverSection
            FormButton(title: "Import…", tone: SettingsPalette.accent,
                       identifier: "settings.browser.passwords.import") {
                importing = true
            }
            .disabled(access == nil)
            .padding(.top, 6)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.browser.passwords")
        // A new organisation is a new list and a locked one (Invariant 4).
        .task(id: org) {
            shownOrg = org
            lockAway()
            confirmingDelete = nil
            editing = nil
            refusals = [:]
            neverError = nil
            await reload()
        }
        .onDisappear {
            shownOrg = nil
            lockAway()
        }
        .sheet(isPresented: $importing, onDismiss: { Task { await reload() } }) {
            if let access {
                BrowserPasswordImport(org: org, access: access) { importing = false }
            }
        }
    }

    // MARK: The list

    @ViewBuilder private var list: some View {
        if let loadError {
            Text(loadError)
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(caution)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings.browser.passwords.error")
        } else if BrowserPasswordSettings.visible(logins, org: org).isEmpty {
            Text(BrowserPasswordSettings.empty(org: name))
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(coolWhite.opacity(0.52))
                .accessibilityIdentifier("settings.browser.passwords.empty")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                let shown = BrowserPasswordSettings.visible(logins, org: org)
                ForEach(BrowserPasswordSettings.bySite(shown), id: \.site) { group in
                    Text(group.site)
                        .font(.system(size: SettingsScale.identifier, design: .monospaced))
                        .foregroundStyle(coolWhite.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 8)
                    ForEach(group.rows, id: \.index) { row in
                        loginRow(row.login, n: row.index)
                    }
                }
            }
        }
    }

    private func rowKey(_ login: BrowserLogin) -> String { BrowserPasswordSettings.rowKey(login) }

    private func loginRow(_ login: BrowserLogin, n: Int) -> some View {
        let key = rowKey(login)
        let working = busy.contains(key)
        let isEditing = editing.map(rowKey) == key
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if isEditing {
                    editFields(n: n)
                } else {
                    Text(BrowserPasswordSettings.shown(login.username))
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(coolWhite.opacity(login.username.isEmpty ? 0.45 : 0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: SettingsScale.labelWidth + 40, alignment: .leading)
                    Text(revealed[key] ?? "••••••••")
                        .font(.system(size: SettingsScale.identifier, design: .monospaced))
                        .foregroundStyle(coolWhite.opacity(revealed[key] == nil ? 0.40 : 0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Not selectable: ⌘C would copy it unmarked. Copy is the one way out.
                        .accessibilityIdentifier("settings.browser.passwords.row.\(n).value")
                }
                Spacer(minLength: 6)
                if working { ProgressView().controlSize(.small) }
                if copied == key {
                    Text("Copied")
                        .font(.system(size: SettingsScale.meta))
                        .foregroundStyle(coolWhite.opacity(0.52))
                }
                rowButton(revealed[key] == nil ? "Reveal" : "Hide", "settings.browser.passwords.row.\(n).reveal",
                          disabled: working || isEditing) { reveal(login) }
                rowButton("Copy", "settings.browser.passwords.row.\(n).copy", disabled: working || isEditing) {
                    copy(login)
                }
                rowButton(isEditing ? "Done" : "Edit", "settings.browser.passwords.row.\(n).edit", disabled: working) {
                    if isEditing { editFocus = nil; commitEdit() } else { startEdit(login) }
                }
                rowButton("Delete", "settings.browser.passwords.row.\(n).delete", tone: caution,
                          disabled: working || isEditing) {
                    refusals[key] = nil
                    confirmingDelete = key
                }
            }
            .frame(minHeight: SettingsScale.rowHeight)
            if confirmingDelete == key { deleteQuestion(login, n: n) }
            if let refusal = refusals[key] {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.browser.passwords.row.\(n).refusal")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(coolWhite.opacity(0.06)).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.browser.passwords.row.\(n)")
    }

    private func rowButton(_ title: String, _ identifier: String, tone: Color? = nil, disabled: Bool,
                           _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: SettingsScale.meta + 1))
            .foregroundStyle((tone ?? coolWhite).opacity(disabled ? 0.30 : 0.72))
            .disabled(disabled)
            .fixedSize()
            .accessibilityIdentifier(identifier)
    }

    // MARK: Reveal and copy (ruling 16)

    /// The section's one authentication, asked for only when it is not already open.
    private func unlocked(reason: String, key: String) async -> Bool {
        if unlock.isOpen(at: Date()) { return true }
        switch await BrowserPasswordAuthentication.ask(reason: reason) {
        case .open:
            unlock.opened(at: Date())
            scheduleLock()
            return true
        case .cancelled:
            return false
        case .failed(let why):
            refusals[key] = why
            return false
        }
    }

    /// At the window's end everything revealed is hidden again and the next Reveal asks again.
    private func scheduleLock() {
        lockTimer?.cancel()
        guard let expires = unlock.expires else { return }
        lockTimer = Task {
            let wait = max(0, expires.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            lockAway()
        }
    }

    private func lockAway() {
        lockTimer?.cancel()
        lockTimer = nil
        unlock.lock()
        revealed = [:]
        copied = nil
    }

    private func reveal(_ login: BrowserLogin) {
        let key = rowKey(login)
        if revealed[key] != nil { revealed[key] = nil; return }
        withValue(login, reason: BrowserPasswordSettings.revealReason(username: login.username, site: login.site)) {
            revealed[key] = $0
        }
    }

    /// Marked concealed (`org.nspasteboard.ConcealedType`), so clipboard managers that honour it keep no
    /// copy, and cleared after 90 s unless something was copied since (the pasteboard's `changeCount`
    /// is still the one this copy made). The clearing outlives the section: it is not this view's task.
    private func copy(_ login: BrowserLogin) {
        let key = rowKey(login)
        withValue(login, reason: BrowserPasswordSettings.copyReason(username: login.username, site: login.site)) {
            value in
            let item = NSPasteboardItem()
            item.setString(value, forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            let written = pasteboard.changeCount
            Task { @MainActor in
                try? await Task.sleep(for: BrowserPasswordSettings.copyClearsAfter)
                if NSPasteboard.general.changeCount == written { NSPasteboard.general.clearContents() }
            }
            copied = key
        }
    }

    /// Authenticates, then reads the value directly (ruling 10), off the main actor.
    private func withValue(_ login: BrowserLogin, reason: String, _ use: @escaping (String) -> Void) {
        let key = rowKey(login)
        guard let access, !busy.contains(key) else { return }
        refusals[key] = nil
        copied = nil
        busy.insert(key)
        let store = access.store, org = org
        Task {
            defer { busy.remove(key) }
            guard await unlocked(reason: reason, key: key) else { return }
            let result = await Task.detached { () -> Result<String, Error> in
                Result { try store.password(org: org, site: login.site, username: login.username) }
            }.value
            // The organisation changed or the window locked while it read: show nothing.
            guard BrowserPasswordSettings.stillShown(asked: org, shown: shownOrg), unlock.isOpen(at: Date())
            else { return }
            switch result {
            case .success(let value): use(value)
            case .failure(let error): refusals[key] = String(describing: error)
            }
        }
    }

    // MARK: Edit (Rules 2 and 3)

    private func editFields(n: Int) -> some View {
        HStack(spacing: 8) {
            TextField("Username", text: $editUsername)
                .textFieldStyle(.plain)
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(coolWhite.opacity(0.88))
                .fieldBox(width: SettingsScale.labelWidth + 30)
                .focused($editFocus, equals: .username)
                .onSubmit { editFocus = nil }
                .accessibilityIdentifier("settings.browser.passwords.row.\(n).edit.username")
            SecureField("New password", text: $editPassword)
                .textFieldStyle(.plain)
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(coolWhite.opacity(0.88))
                .fieldBox(width: 170)
                .focused($editFocus, equals: .password)
                .onSubmit { editFocus = nil }
                .accessibilityIdentifier("settings.browser.passwords.row.\(n).edit.password")
        }
        // Rule 3: the field arrives focused.
        .onAppear { Task { editFocus = .username } }
        // Rule 2: leaving both fields keeps what was typed. Escape puts it back as it was.
        .onChange(of: editFocus) { old, now in if old != nil, now == nil { commitEdit() } }
        .onExitCommand { endEdit() }
    }

    private func startEdit(_ login: BrowserLogin) {
        if editing != nil { commitEdit() }
        refusals[rowKey(login)] = nil
        confirmingDelete = nil
        editing = login
        editUsername = login.username
        editPassword = ""
    }

    private func endEdit() {
        editing = nil
        editUsername = ""
        editPassword = ""
    }

    /// A rename first (its password kept), then a new password under the name it has by then.
    /// A refusal keeps the fields and their text open under it.
    private func commitEdit() {
        guard let login = editing, let access else { return }
        let key = rowKey(login)
        guard !busy.contains(key) else { return }
        let saves = BrowserPasswordSettings.editSaves(org: org, site: login.site, was: login.username,
                                                      username: editUsername, password: editPassword)
        guard !saves.isEmpty else { endEdit(); return }
        busy.insert(key)
        refusals[key] = nil
        Task {
            defer { busy.remove(key) }
            do {
                for save in saves { try await access.dispatch("browser_password_save", save) }
                if editing.map(rowKey) == key { endEdit() }
                revealed[key] = nil
            } catch {
                refusals[key] = String(describing: error)
            }
            await reload()
        }
    }

    // MARK: Delete (Rule 1: it destroys, so it asks, in place)

    private func deleteQuestion(_ login: BrowserLogin, n: Int) -> some View {
        let key = rowKey(login)
        return VStack(alignment: .leading, spacing: 4) {
            Text(BrowserPasswordSettings.deleteQuestion(username: login.username, site: login.site))
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(caution)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                FormButton(title: BrowserPasswordSettings.deleteLabel, tone: caution, filled: true,
                           identifier: "settings.browser.passwords.row.\(n).delete.confirm") {
                    delete(login)
                }
                .disabled(busy.contains(key))
                FormButton(title: BrowserPasswordSettings.keepLabel, tone: coolWhite.opacity(0.62),
                           cancels: true, identifier: "settings.browser.passwords.row.\(n).delete.keep") {
                    confirmingDelete = nil
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func delete(_ login: BrowserLogin) {
        let key = rowKey(login)
        guard let access, !busy.contains(key) else { return }
        busy.insert(key)
        confirmingDelete = nil
        Task {
            defer { busy.remove(key) }
            do {
                try await access.dispatch("browser_password_delete", [
                    "org": .string(org), "site": .string(login.site), "username": .string(login.username)])
                revealed[key] = nil
            } catch {
                refusals[key] = String(describing: error)
            }
            await reload()
        }
    }

    // MARK: Never saved for (ruling 8: the × is the only way to undo Never for This Site)

    @ViewBuilder private var neverSection: some View {
        if !never.isEmpty || neverError != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text(BrowserPasswordSettings.neverTitle)
                    .font(.system(size: SettingsScale.body, weight: .medium))
                    .foregroundStyle(coolWhite.opacity(0.86))
                    .padding(.top, 10)
                ForEach(Array(never.enumerated()), id: \.element) { n, site in
                    HStack(spacing: 8) {
                        Text(site)
                            .font(.system(size: SettingsScale.identifier, design: .monospaced))
                            .foregroundStyle(coolWhite.opacity(0.72))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button { offerAgain(site) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: SettingsScale.meta, weight: .semibold))
                                .foregroundStyle(coolWhite.opacity(neverBusy == nil ? 0.55 : 0.25))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(neverBusy != nil)
                        .help("Offer to save passwords on \(site) again")
                        .accessibilityLabel("Offer to save passwords on \(site) again")
                        .accessibilityIdentifier("settings.browser.passwords.never.\(n)")
                        if neverBusy == site { ProgressView().controlSize(.mini) }
                    }
                }
                if let neverError {
                    Text(neverError)
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.browser.passwords.never.error")
                }
            }
        }
    }

    private func offerAgain(_ site: String) {
        guard let access, neverBusy == nil else { return }
        neverBusy = site
        neverError = nil
        Task {
            defer { neverBusy = nil }
            do {
                try await access.dispatch("browser_password_never",
                                          ["org": .string(org), "site": .string(site), "on": .bool(false)])
            } catch {
                neverError = String(describing: error)
            }
            await reload()
        }
    }

    // MARK: Reading

    /// Attributes only, so listing never asks for permission; off the main actor.
    private func reload() async {
        guard let access else {
            loadError = "No password store in this window."
            return
        }
        let store = access.store, home = access.home, org = org
        let found = await Task.detached { () -> Result<[BrowserLogin], Error> in
            Result { try store.logins(org: org, site: nil) }
        }.value
        let sites = await Task.detached { () -> Result<[String], Error>? in
            guard let home else { return nil }
            return Result { try BrowserOrgFiles(home: home, org: org).neverSave() }
        }.value
        guard BrowserPasswordSettings.stillShown(asked: org, shown: shownOrg) else { return }
        switch found {
        case .success(let all): logins = all; loadError = nil
        case .failure(let error): logins = []; loadError = String(describing: error)
        }
        switch sites {
        case .success(let all)?: never = all
        case .failure(let error)?:
            never = []
            neverError = (error as? BrowserNeverSaveUnreadable).map {
                "passwords-never.json can't be read (\($0.reason)) — fix or move it; Wakil won't write over it."
            } ?? String(describing: error)
        case nil: never = []
        }
    }
}
