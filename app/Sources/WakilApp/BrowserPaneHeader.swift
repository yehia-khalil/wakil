import AppKit
import SwiftUI
import WakilKit

/// How much of the tab list a browser pane's width leaves room for (3c-i): the whole list from
/// 640 pt, its favicons alone from 420 pt, and below that none — the header's tab count becomes
/// the list, as a menu.
enum BrowserTabListMode: Equatable {
    case full, folded, hidden

    init(paneWidth: Double) {
        self = paneWidth < 420 ? .hidden : paneWidth < 640 ? .folded : .full
    }

    var width: CGFloat {
        switch self {
        case .full: 176
        case .folded: 34
        case .hidden: 0
        }
    }
}

/// What a tab is called in the list and the count menu: its title, else its host, else New Tab.
func browserTabLabel(_ tab: BrowserTab) -> String {
    if !tab.title.isEmpty { return tab.title }
    if let url = URL(string: tab.url), !tab.url.isEmpty { return BrowserAddress.displayHost(url) }
    return "New Tab"
}

/// The header row: ‹ › ↻ (× while loading), the address field, and the tab count.
struct BrowserHeader<Address: View>: View {
    let tab: BrowserTab?
    let tabs: [BrowserTab]
    let listMode: BrowserTabListMode
    let dispatch: (String, [String: JSONValue]) -> Void
    @ViewBuilder let address: () -> Address

    var body: some View {
        HStack(spacing: 4) {
            control("chevron.left", "browser.back", "Back", enabled: tab?.canGoBack == true) {
                dispatch("browser_back", [:])
            }
            control("chevron.right", "browser.forward", "Forward", enabled: tab?.canGoForward == true) {
                dispatch("browser_forward", [:])
            }
            if tab?.isLoading == true {
                control("xmark", "browser.stop", "Stop", enabled: true) { dispatch("browser_stop", [:]) }
            } else {
                control("arrow.clockwise", "browser.reload", "Reload", enabled: tab != nil) {
                    dispatch("browser_reload", [:])
                }
            }
            address()
            count
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }

    private func control(_ symbol: String, _ id: String, _ label: String, enabled: Bool,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(EditorPaneStyle.text.opacity(enabled ? 0.85 : 0.25))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// The number of tabs; with the list hidden, the list itself, as a menu.
    @ViewBuilder private var count: some View {
        let text = Text("\(tabs.count)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(EditorPaneStyle.text.opacity(0.6))
            .frame(minWidth: 18, minHeight: 18)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(EditorPaneStyle.text.opacity(0.25), lineWidth: 1))
        if listMode == .hidden {
            Menu {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { _, t in
                    Button(browserTabLabel(t)) { dispatch("browser_select_tab", ["tab": .string(t.id)]) }
                }
            } label: { text }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("browser.tabMenu")
        } else {
            text
                .accessibilityLabel("\(tabs.count) tabs")
                .accessibilityIdentifier("browser.tabCount")
        }
    }
}

/// The vertical tab list: favicon, title, × on hover; the active tab carries the rail's tick.
struct BrowserTabList: View {
    let snapshot: BrowserSnapshot
    let mode: BrowserTabListMode
    let favicon: (String) -> URL?
    let dispatch: (String, [String: JSONValue]) -> Void
    @State private var hovered: String?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(snapshot.tabs, id: \.id) { tab in row(tab) }
            }
            .padding(.vertical, 4)
        }
        .frame(width: mode.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.tabs")
    }

    private func row(_ tab: BrowserTab) -> some View {
        let active = tab.id == snapshot.active
        return HStack(spacing: 6) {
            BrowserFavicon(url: favicon(tab.id))
            if mode == .full {
                Text(browserTabLabel(tab))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(EditorPaneStyle.text.opacity(active ? 0.95 : 0.6))
                Spacer(minLength: 0)
                if hovered == tab.id {
                    Button { dispatch("browser_close_tab", ["tab": .string(tab.id)]) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.7))
                    .accessibilityLabel("Close \(browserTabLabel(tab))")
                    .accessibilityIdentifier("browser.tab.\(tab.id).close")
                }
            }
        }
        .padding(.leading, mode == .full ? 10 : 0)
        .padding(.trailing, mode == .full ? 6 : 0)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: mode == .full ? .leading : .center)
        .background(active ? EditorPaneStyle.lifted : Color.clear)
        .overlay(alignment: .leading) {
            if active {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(RailTreatment.activeTickColour))
                    .frame(width: 2)
                    .padding(.vertical, 5)
                    .shadow(color: Color(RailTreatment.activeTickColour).opacity(0.7), radius: 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { dispatch("browser_select_tab", ["tab": .string(tab.id)]) }
        .onHover { inside in hovered = inside ? tab.id : (hovered == tab.id ? nil : hovered) }
        .help(browserTabLabel(tab))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(browserTabLabel(tab))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { dispatch("browser_select_tab", ["tab": .string(tab.id)]) }
        .accessibilityIdentifier("browser.tab.\(tab.id)")
    }
}

/// The page's own icon when it names one, else a globe. Nothing is fetched to find one.
struct BrowserFavicon: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } placeholder: { globe }
            } else {
                globe
            }
        }
        .frame(width: 14, height: 14)
    }

    private var globe: some View {
        Image(systemName: "globe")
            .font(.system(size: 11))
            .foregroundStyle(EditorPaneStyle.text.opacity(0.55))
    }
}
