import AppKit
import WakilKit
import SwiftUI

/// The row detail strip: the anchor row, one block per column, every value whole. Read-only.
/// It scrolls as a whole; a value taller than the strip scrolls inside its own region, capped
/// at the strip's visible height, so a 5,000-line JSON never pushes the other columns out of
/// reach. Values render through a non-editable TextKit 2 `NSTextView`, which lays out lazily,
/// so a 1 MB cell does not freeze the pane. Nothing scrolls sideways: long lines wrap at any
/// character.
struct RowDetailStrip: View {
    let table: PaneTable
    let pane: Pane
    /// Closes the strip — the × in its corner, beside Space, Esc and the row's ⓘ.
    let close: () -> Void

    private static let padding: CGFloat = 10
    private static let labelHeight: CGFloat = 12
    private static let labelSpacing: CGFloat = 2

    private static let ink = Color(red: 0.910, green: 0.925, blue: 0.965)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
            values()
        }
        .background(Self.ink.opacity(0.03))
        .overlay(alignment: .leading) {
            Rectangle().fill(Self.ink.opacity(0.10)).frame(width: 1)
        }
        // A container, so its own identifier does not overwrite the × and the values inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("db.\(pane.id).detail")
    }

    /// The strip's own row above its scroll area: which row it shows, and the × that closes it.
    /// In the layout, not over it, so the × never sits on the scroller or on a value.
    private func header() -> some View {
        HStack(spacing: 6) {
            Text(table.selection.anchorRow.map { "ROW \($0 + 1)" } ?? "")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.7)
                .foregroundStyle(Self.ink.opacity(0.45))
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Self.ink.opacity(0.55))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close details")
            .accessibilityLabel("Close details")
            .accessibilityIdentifier("db.\(pane.id).detail.close")
        }
        .padding(.leading, Self.padding)
        .padding(.trailing, 4)
        .padding(.top, 4)
    }

    private func values() -> some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if let anchor = table.selection.anchorRow, anchor < table.rows.count {
                        ForEach(rowDetailFields(columns: table.columns, row: table.rows[anchor])) { field in
                            VStack(alignment: .leading, spacing: Self.labelSpacing) {
                                Text(field.name)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Self.ink.opacity(0.45))
                                if field.isNull {
                                    Text("NULL")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Self.ink.opacity(0.30))
                                } else {
                                    RowDetailValue(
                                        text: field.display,
                                        maxHeight: geometry.size.height - 2 * Self.padding
                                            - Self.labelHeight - Self.labelSpacing)
                                        .accessibilityIdentifier("db.\(pane.id).detail.\(field.index)")
                                }
                            }
                        }
                    } else {
                        Text("no row selected")
                            .font(.system(size: 10))
                            .foregroundStyle(Self.ink.opacity(0.35))
                    }
                }
                .padding(Self.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One value: a read-only, selectable, wrapping text view whose height is its content's,
/// capped at `maxHeight`, past which it scrolls inside itself.
private struct RowDetailValue: NSViewRepresentable {
    let text: String
    let maxHeight: CGFloat

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// What the last `updateNSView` set and the last `sizeThatFits` measured, so neither
    /// re-reads or re-lays-out a 1 MB string on a hover.
    final class Coordinator {
        var text: String?
        var measuredWidth: CGFloat?
        var measuredText: String?
        var measuredHeight: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 0.85)
        textView.textContainerInset = .zero
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // No inner padding, so a value starts where its label and a NULL do.
        textView.textContainer?.lineFragmentPadding = 0
        // Wrap at any character: base64 and minified JSON have no break points.
        textView.textContainer?.lineBreakMode = .byCharWrapping

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Nothing scrolls sideways. An overlay scroller takes no width, so the clip view is as
        // wide as the value and the text view never measures wider than what shows; no
        // horizontal elasticity, so a trackpad swipe cannot drag the value sideways either.
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        scroll.scrollerStyle = .overlay
        if context.coordinator.text != text {
            context.coordinator.text = text
            textView.string = text
            textView.scroll(.zero)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let textView = scroll.documentView as? NSTextView,
              let manager = textView.textLayoutManager
        else { return nil }
        let cache = context.coordinator
        if cache.measuredWidth != width || cache.measuredText != text {
            textView.frame.size.width = width
            manager.ensureLayout(for: manager.documentRange)
            cache.measuredHeight = manager.usageBoundsForTextContainer.height
            cache.measuredWidth = width
            cache.measuredText = text
        }
        let content = cache.measuredHeight
        return CGSize(width: width, height: min(max(content, Self.font.pointSize + 4), max(maxHeight, 60)))
    }
}
