import SwiftUI
import WakilKit

/// The rows under the address field while it is edited (3c-iii, rulings 7–9): drawn inside the pane
/// over the page, the field's width — never a window or a popover, so the field keeps the keyboard
/// (Rule 3) while ↓ ↑ move the highlight. Each row is its kind's glyph, the title, and the bare URL
/// in mono; the highlighted row (and the one under the pointer) takes the rail's row lift. A press
/// on a row chooses it, on the mouse-down, before the field can let the keyboard go.
struct BrowserSuggestionList: View {
    let rows: [BrowserSuggestion]
    let highlight: Int?
    let choose: (BrowserSuggestion) -> Void

    @State private var hovered: String?

    static let rowHeight: CGFloat = 26
    static let maxRows = 12

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.prefix(Self.maxRows).enumerated()), id: \.element.id) { index, row in
                rowView(row, index: index)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: BrowserPaneStyle.promptRadius, style: .continuous)
                .fill(BrowserPaneStyle.slab))
        .overlay(
            RoundedRectangle(cornerRadius: BrowserPaneStyle.promptRadius, style: .continuous)
                .strokeBorder(BrowserPaneStyle.text.opacity(BrowserPaneStyle.promptEdge), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.suggestions")
    }

    private func rowView(_ row: BrowserSuggestion, index: Int) -> some View {
        let bare = row.kind == .search ? "" : BrowserSuggestions.bareURL(row.url)
        let title = row.title.isEmpty ? bare : row.title
        let lifted = highlight == index || hovered == row.id
        return HStack(spacing: BrowserPaneStyle.gap) {
            Image(systemName: Self.glyph(row.kind))
                .font(.system(size: BrowserPaneStyle.metaSize))
                .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
                .frame(width: 14)
            Text(title)
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(BrowserPaneStyle.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if !row.title.isEmpty, !bare.isEmpty {
                Text(bare)
                    .font(.system(size: BrowserPaneStyle.metaSize, design: .monospaced))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(BrowserPaneStyle.text.opacity(lifted ? RailTreatment.rowHoverTint : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in choose(row) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint([bare, row.kind.rawValue].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(highlight == index ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose(row) }
        .accessibilityIdentifier("browser.suggestion.\(index)")
    }

    /// The row's kind: an open tab, a bookmark, a page from history, the engine's words.
    static func glyph(_ kind: BrowserSuggestion.Kind) -> String {
        switch kind {
        case .tab: "square.on.square"
        case .bookmark: "star"
        case .history: "clock"
        case .search: "magnifyingglass"
        }
    }
}

/// Where the address field is drawn, so the pane can lay the rows under it.
struct BrowserAddressAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
