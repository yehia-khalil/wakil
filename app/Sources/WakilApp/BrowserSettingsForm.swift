import SwiftUI
import WakilKit

/// The Wakil scope's Browser node (3c-i): search, tabs and picture in picture, all app-wide
/// (~/.wakil/settings.json). The organisation's browsing data and passwords are its own node,
/// `BrowsingDataSettingsForm`, under the organisation (settings revamp).
struct BrowserSettingsForm: View {
    let browser: SettingsBrowser
    /// The keymap in force, for the Tabs hint that names Toggle Tab Column's chord.
    @Environment(\.keymap) private var keymap
    /// 3d-i: why this organisation has no pull-request group, in one line under Tabs; nil, it has one.
    var pullRequestsAbsent: String?
    let save: ([String: JSONValue]) async -> String?
    /// Why picture in picture is off on this Mac (its WebKit lacks the private API), or nil when it is there.
    let pictureInPictureUnavailable: String?

    static let engines: [(label: String, key: String)] = [
        ("Google", "google"), ("DuckDuckGo", "duckduckgo"), ("Bing", "bing"), ("Kagi", "kagi"),
    ]

    @State private var draft: String?
    @State private var startRefusal: String?
    @State private var inFlight = false
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
                ChoiceSettingRow(
                    label: "Search suggestions", options: ["Off", "On"],
                    selected: browser.searchSuggestions ? "On" : "Off",
                    identifier: { option in let choice = option.lowercased(); return "settings.browser.searchSuggestions.\(choice)" },
                    refusalIdentifier: "settings.browser.searchSuggestions.refusal",
                    hint: "Sends what you type in the address bar to the search engine as you type. Off, nothing "
                        + "leaves the Mac until you press Return. Kagi gives none.",
                    save: { option in await save(["searchSuggestions": .bool(option == "On")]) })
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.browser.searchSuggestions")
            }
            SettingsSection("Tabs") {
                tabsSection
            }
            SettingsSection("Picture in picture") {
                ChoiceSettingRow(
                    label: "Picture in picture", options: ["On", "Off"],
                    selected: browser.pictureInPicture ? "On" : "Off",
                    identifier: { option in let choice = option.lowercased(); return "settings.browser.pictureInPicture.\(choice)" },
                    refusalIdentifier: "settings.browser.pictureInPicture.refusal",
                    hint: "A playing video floats in its own window when you leave its tab, its pane, the place or "
                        + "the organisation, or minimise the window. Off, Wakil floats nothing; a page's own "
                        + "picture-in-picture button still works.",
                    save: { option in await save(["pictureInPicture": .bool(option == "On")]) })
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.browser.pictureInPicture")
                if let pictureInPictureUnavailable {
                    Text(pictureInPictureUnavailable)
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .underRowValue()
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("settings.browser.pictureInPicture.unavailable")
                }
            }
            Text("Yours across every organisation — stored in ~/.wakil/settings.json. "
                 + "Browsing data and passwords are each organisation's, under its name.")
                .font(.system(size: SettingsScale.meta))
                .foregroundStyle(coolWhite.opacity(SettingsInk.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 3d-i: horizontal or vertical tabs for every browser pane, and whether a new group is named by
    /// the quick-tasks model. Both are app-wide; horizontal and naming on are the defaults (Rule 9).
    /// Under them, why this organisation has no pull-request group, when it has none.
    @ViewBuilder private var tabsSection: some View {
        ChoiceSettingRow(
            label: "Tabs", options: ["Horizontal", "Vertical"],
            selected: browser.tabs == "vertical" ? "Vertical" : "Horizontal",
            identifier: { option in let choice = option.lowercased(); return "settings.browser.tabs.\(choice)" },
            refusalIdentifier: "settings.browser.tabs.refusal",
            hint: "Vertical puts the tabs in a column at the pane's left"
                + (keymap.chord("browser.toggleTabColumn").map { "; \($0.text) hides and shows it." } ?? "."),
            save: { option in await save(["tabs": .string(option.lowercased())]) })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.browser.tabs")
        ChoiceSettingRow(
            label: "Name groups with AI", options: ["Off", "On"],
            selected: browser.nameGroups ? "On" : "Off",
            identifier: { option in let choice = option.lowercased(); return "settings.browser.nameGroups.\(choice)" },
            refusalIdentifier: "settings.browser.nameGroups.refusal",
            hint: "Sends the titles of a new group's first tabs — never addresses or page text — to this "
                + "organisation's quick-tasks model for a name of up to three words. Off, a group is named "
                + "after its site.",
            save: { option in await save(["nameGroups": .bool(option == "On")]) })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.browser.nameGroups")
        if let pullRequestsAbsent {
            Text(pullRequestsAbsent)
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(coolWhite.opacity(SettingsInk.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.vertical, 6)
                .accessibilityIdentifier("settings.browser.pullRequests.absent")
        }
    }

    private var startPageRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow("Start page") {
                TextField("Blank", text: Binding(get: { draft ?? browser.startPage }, set: { draft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsScale.body, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(SettingsInk.primary))
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

}
