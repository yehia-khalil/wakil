import SwiftUI
import WakilKit

/// The top-level Browser node (3c-i): the operator's search engine and start page, and the
/// organisation's browsing data. The first two are app-wide (~/.wakil/settings.json); the data is
/// this organisation's (Invariant 4).
struct BrowserSettingsForm: View {
    let browser: SettingsBrowser
    /// What the confirmation names: the organisation's display name.
    let organisation: String
    let save: ([String: JSONValue]) async -> String?
    /// Deletes the organisation's browsing data; answers the refusal's sentence, or nil.
    let clearData: () async -> String?

    static let engines: [(label: String, key: String)] = [
        ("Google", "google"), ("DuckDuckGo", "duckduckgo"), ("Bing", "bing"), ("Kagi", "kagi"),
    ]

    @State private var draft: String?
    @State private var startRefusal: String?
    @State private var inFlight = false
    @State private var confirming = false
    @State private var clearing = false
    @State private var clearRefusal: String?
    @State private var cleared = false
    @FocusState private var focused: Bool

    private var coolWhite: Color { SettingsPalette.coolWhite }
    private var caution: Color { SettingsPalette.caution }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSection("Search") {
                ChoiceSettingRow(
                    label: "Search engine", options: Self.engines.map(\.label),
                    selected: Self.engines.first { $0.key == browser.searchEngine }?.label ?? browser.searchEngine,
                    identifier: { label in
                        "settings.browser.searchEngine.\(Self.engines.first { $0.label == label }?.key ?? label)"
                    },
                    refusalIdentifier: "settings.browser.searchEngine.refusal",
                    hint: "Used when what you type in the address bar is not an address.",
                    save: { label in
                        let key = Self.engines.first { $0.label == label }?.key ?? label.lowercased()
                        return await save(["searchEngine": .string(key)])
                    })
                startPageRow
            }
            SettingsSection("Browsing data") {
                clearSection
            }
            Text("Search and start page are yours across every organisation — stored in ~/.wakil/settings.json. "
                 + "Browsing data is this organisation's.")
                .font(.system(size: SettingsScale.meta))
                .foregroundStyle(coolWhite.opacity(0.40))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startPageRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow("Start page") {
                TextField("Blank", text: Binding(get: { draft ?? browser.startPage }, set: { draft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsScale.body, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.88))
                    .inPlaceField(focused: focused)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, now in if !now { commit() } }
                    .accessibilityIdentifier("settings.browser.startPage")
            }
            if let startRefusal {
                Text(startRefusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .underRowValue()
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("settings.browser.startPage.refusal")
            }
        }
    }

    /// Rule 2: saved on focus loss and Return. A refused value keeps its text under Go's sentence.
    private func commit() {
        guard !inFlight else { return }
        guard let text = draft?.trimmingCharacters(in: .whitespaces), text != browser.startPage else {
            draft = nil
            startRefusal = nil
            return
        }
        draft = text
        inFlight = true
        Task {
            let answer = await save(["startPage": .string(text)])
            startRefusal = answer
            if answer == nil { draft = nil }
            inFlight = false
        }
    }

    private var clearSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    clearRefusal = nil
                    cleared = false
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
                    Text(BrowserClearDataQuestion.text(org: organisation))
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.browser.clear.question")
                    HStack(spacing: 10) {
                        FormButton(title: BrowserClearDataQuestion.deleteLabel, tone: caution, filled: true,
                                   identifier: "settings.browser.clear.confirm") {
                            confirming = false
                            clearing = true
                            Task {
                                clearRefusal = await clearData()
                                cleared = clearRefusal == nil
                                clearing = false
                            }
                        }
                        FormButton(title: BrowserClearDataQuestion.keepLabel, tone: coolWhite.opacity(0.62),
                                   identifier: "settings.browser.clear.keep") {
                            confirming = false
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 4)
            }
            if cleared {
                Text("Deleted \(organisation)'s browsing data.")
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
