import SwiftUI
import WakilKit

/// The organisation's Browsing data node (settings revamp, moved from Browser): clearing this
/// organisation's cookies, logins and site storage, and its saved passwords. Both are this
/// organisation's (Invariant 4), so they sit under its heading, not Wakil's.
struct BrowsingDataSettingsForm: View {
    /// What the confirmation names: the organisation's display name.
    let organisation: String
    /// The organisation's id: what Delete passes, so the action refuses if another is active by then.
    let organisationId: String
    /// Deletes the named organisation's browsing data; answers the refusal's sentence, or nil.
    let clearData: (_ org: String) async -> String?

    @State private var confirming = false
    @State private var clearing = false
    @State private var clearRefusal: String?
    @State private var cleared = false
    /// The organisation the open question names, as (id, display name), fixed when it was asked.
    @State private var asked: (id: String, name: String)?

    private var coolWhite: Color { SettingsPalette.coolWhite }
    private var caution: Color { SettingsPalette.caution }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSection("Clear") {
                clearSection
            }
            SettingsSection("Passwords") { BrowserPasswordsSettings(org: organisationId, name: organisation) }
        }
    }

    private var clearSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    clearRefusal = nil
                    cleared = false
                    asked = (organisationId, organisation)
                    confirming = true
                } label: {
                    Text("Clear this organisation's browsing data…")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(caution.opacity(clearing ? 0.4 : 0.9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(clearing)
                .accessibilityIdentifier("settings.browser.clear")
                if clearing { ProgressView().controlSize(.small) }
            }
            FormHint("Cookies, logins and site storage for every project of this organisation.")
            if confirming {
                VStack(alignment: .leading, spacing: 4) {
                    Text(BrowserClearDataQuestion.text(org: asked?.name ?? organisation))
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.browser.clear.question")
                    HStack(spacing: 10) {
                        FormButton(title: BrowserClearDataQuestion.deleteLabel, tone: caution, filled: true,
                                   identifier: "settings.browser.clear.confirm") {
                            confirming = false
                            clearing = true
                            let org = asked?.id ?? organisationId
                            Task {
                                clearRefusal = await clearData(org)
                                cleared = clearRefusal == nil
                                clearing = false
                            }
                        }
                        FormButton(title: BrowserClearDataQuestion.keepLabel, tone: coolWhite.opacity(0.62),
                                   cancels: true, identifier: "settings.browser.clear.keep") {
                            confirming = false
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 4)
            }
            if cleared {
                Text(BrowserClearDataQuestion.receipt(asked: asked?.name, current: organisation))
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(coolWhite.opacity(0.62))
                    .accessibilityIdentifier("settings.browser.clear.done")
            }
            if let clearRefusal {
                Text(clearRefusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.browser.clear.refusal")
            }
        }
        .padding(.vertical, 10)
    }
}
