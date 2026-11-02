import SwiftUI

// MARK: - The settings form vocabulary (#327)
//
// **One vocabulary for every settings form.** The database form was the
// first surface in Wakil where an operator fills in several fields, and it
// was drawn with one-off helpers private to it. The API settings form, and
// every form after it, would have grown a second dialect, so the pieces live
// here and each is taken from something the app or the artboard already
// draws, never invented:
//
// | Piece            | Taken from                                                         |
// |------------------|--------------------------------------------------------------------|
// | `FormCard`       | `.slab` (`Settings.dc.html`), a half-pixel luminous edge, no outline |
// | `LabelledField`  | the register form's boxed `.field`, under a `.micro` label        |
// | `SegmentedChoice`| luminance violet for what is chosen (§5), as `ContextLine` and the rail's anchor draw it |
// | `Chip`           | `.chip`: uppercase, tracked, on a tint, with no border            |
// | `FormButton`     | the confirmation's filled button (**Store it**)                   |
// | `FormHint`       | the artboard's `.note`: one plain sentence under a setting saying what it does |
// | `SettingsSection`| the QUICK TASKS header: a hairline above, the micro label, 12pt rhythm (2026-10-21) |
// | `SettingsRow`    | the QUICK TASKS rows: label left at a fixed width, the value right, one line |
//
// design-language.md §2: *"Panels are slabs … defined by drop shadow and a
// half-pixel luminous edge rather than a border. No panel has a visible
// outline."* That is why `FormCard` strokes a top-to-bottom gradient, the same
// edge `OrgPlane`'s plane draws, rather than a flat line.

/// The settings pane's type scale, shared by its forms. See `SettingsPane`
/// for why each number is what it is.
enum SettingsScale {
    /// Uppercase labels and row verbs. §6: 8–9.5px, tracking .16–.22em.
    static let micro: CGFloat = 9
    static let microTracking: CGFloat = 1.6
    /// Identifiers — monospace, always (§6).
    static let identifier: CGFloat = 12.5
    /// Sentences, cell values, and the artboard's `.note`.
    static let body: CGFloat = 12
    /// The second line of a cell: paths, refs, dates, emails.
    static let meta: CGFloat = 10
    /// A row that is a gesture — the artboard's `.add`.
    static let door: CGFloat = 13
    /// `.row { height: 44px }`, and the padding it sits in.
    static let rowHeight: CGFloat = 44
    static let gutter: CGFloat = 22
    static let columnGap: CGFloat = 20
    /// A page row's label column (`SettingsRow`), as the QUICK TASKS rows first drew it.
    static let labelWidth: CGFloat = 120
    /// The rhythm between a page's sections, and from a section's hairline to its header.
    static let sectionGap: CGFloat = 12
    /// What opens under a row — a confirmation, **Replace token**'s field, a refusal — sits this
    /// far from the next row (2e-iii).
    static let openGap: CGFloat = 8
    /// Between a card's fields, across and down: `FormCard`'s own spacing.
    static let fieldGap: CGFloat = 12
}

/// §5's colours, as the settings pane uses them. Text is cool white stepped
/// down by opacity, never by hue; violet is luminance and marks what is
/// active or chosen; amber is caution and nothing else.
enum SettingsPalette {
    static let coolWhite = Color(red: 0.910, green: 0.925, blue: 0.965)   // #e8ecf6
    static let caution = Color(red: 0.910, green: 0.706, blue: 0.353)     // #e8b45a
    static let accent = Color(red: 0.486, green: 0.361, blue: 1.0)        // #7c5cff
}

/// A form's own surface inside a pane: a slightly raised slab with a
/// half-pixel luminous edge, brighter on top, and no outline.
///
/// `accessory` sits on the title's line at the trailing edge — a quiet verb about the card itself,
/// such as edit mode's **Cancel** (2e-iv) — so the card gains no row for it.
struct FormCard<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsScale.fieldGap) {
                Text(title)
                    .font(.system(size: SettingsScale.micro, weight: .medium))
                    .tracking(SettingsScale.microTracking)
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.coolWhite.opacity(0.025)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5))
    }
}

extension FormCard where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// A card's row of fields: side by side when the card is wide enough, one under another when it
/// is not — so a card never draws wider than its pane (§14). The fields keep their widths; it is
/// the row that gives way, as the account table's verbs do.
struct FormRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: SettingsScale.fieldGap) { content }
            VStack(alignment: .leading, spacing: SettingsScale.fieldGap) { content }
        }
    }
}

/// A `.micro` label above a control: the forms' one labelling idiom.
struct FormLabelled<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: SettingsScale.micro, weight: .medium))
                .tracking(SettingsScale.microTracking)
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.40))
            content
        }
    }
}

/// A labelled field in the boxed `.field` treatment: its own background and
/// a hairline, so it is never mistaken for a label. `secure` masks it, for
/// the one kind of value a person types that must not be on screen.
struct LabelledField: View {
    let label: String
    var prompt: String = ""
    @Binding var text: String
    let width: CGFloat
    let identifier: String
    var secure: Bool = false
    /// `width` is the most it takes rather than what it always takes: it narrows with the card,
    /// so a long field (a base URL, a token, a host) never runs past the pane (§14).
    var narrows: Bool = false
    /// A focus the caller moves into this field, as `focusKey` (Rule 3): **Edit** on a database
    /// puts the keyboard in the first connection field.
    var focus: FocusState<String?>.Binding? = nil
    var focusKey: String = ""

    var body: some View {
        FormLabelled(label: label) {
            Group {
                if secure {
                    SecureField(prompt, text: $text)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label.lowercased())
            .textFieldStyle(.plain)
            .font(.system(size: SettingsScale.identifier, design: .monospaced))
            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.90))
            .modifier(FieldBoxWidth(width: width, narrows: narrows))
            .modifier(MovableFocus(focus: focus, key: focusKey))
        }
    }
}

private struct MovableFocus: ViewModifier {
    let focus: FocusState<String?>.Binding?
    let key: String

    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus, equals: key)
        } else {
            content
        }
    }
}

private struct FieldBoxWidth: ViewModifier {
    let width: CGFloat
    let narrows: Bool

    func body(content: Content) -> some View {
        if narrows {
            content.fieldBox(maxWidth: width)
        } else {
            content.fieldBox(width: width)
        }
    }
}

extension View {
    /// The boxed `.field`: its own background and a hairline, so a value a person types is never
    /// mistaken for a label. `LabelledField` draws it; so does any field that sits in a list.
    func fieldBox(width: CGFloat) -> some View {
        fieldPadding().frame(width: width, alignment: .leading).fieldSurface()
    }

    /// The same `.field` at most `maxWidth` wide, narrowing with its column, so a form never draws
    /// wider than its pane (§14): a card's long fields, and **Replace token**'s field.
    func fieldBox(maxWidth: CGFloat) -> some View {
        fieldPadding().frame(maxWidth: maxWidth, alignment: .leading).fieldSurface()
    }

    private func fieldPadding() -> some View {
        padding(.horizontal, 9).padding(.vertical, 6)
    }

    private func fieldSurface() -> some View {
        background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(SettingsPalette.coolWhite.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(SettingsPalette.coolWhite.opacity(0.14), lineWidth: 0.5)))
    }
}

/// What a setting does, in one or two plain sentences under its label: the artboard's `.note`.
/// It sits beside the one setting it explains, never pooled in a footnote, and reads at a
/// legible step of cool white — it is meant to be read, not to recede.
struct FormHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: SettingsScale.body - 1))
            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.52))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)
    }
}

/// One choice among a few, as joined buttons. The chosen one is luminance
/// violet on a faint violet tint (§5: light marks what is active).
///
/// **Buttons, not a menu**: a menu's items are not in the accessibility tree
/// until it is open, so no check could press one. `identifier` names each
/// option's button. It is a closure over the option, and the call site writes
/// the whole pattern (`"settings.db.driver.\($0)"`), because the control
/// harvester (`make controls`) reads identifiers off the source and has to see
/// the family there.
struct SegmentedChoice: View {
    let options: [String]
    @Binding var selection: String
    let identifier: (String) -> String
    /// A value the selection holds that is none of `options` — drawn after them as one more
    /// chosen segment, **with no button**, so a value written from elsewhere (an agent may set
    /// any HTTP method) is shown rather than silently dropped. `nil`, the default, draws none.
    var held: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let chosen = selection == option
                Button { selection = option } label: {
                    segment(option, chosen: chosen)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier(option))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
            if let held {
                // Read, not pressed: no identifier, on the rule every control here follows.
                segment(held, chosen: true)
            }
        }
        .background(SettingsPalette.coolWhite.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(SettingsPalette.coolWhite.opacity(0.12), lineWidth: 0.5))
    }

    private func segment(_ option: String, chosen: Bool) -> some View {
        Text(option)
            .font(.system(size: SettingsScale.meta, weight: .medium))
            .foregroundStyle(chosen
                ? SettingsPalette.accent
                : SettingsPalette.coolWhite.opacity(0.50))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(chosen ? SettingsPalette.accent.opacity(0.14) : .clear)
            .contentShape(Rectangle())
    }
}

/// The artboard's `.chip`: uppercase and tracked on a tint of its own
/// colour, never outlined. The environment chip is one; so are a database's
/// driver and its write grant.
struct Chip: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tone.opacity(0.14)))
            .fixedSize()
    }
}

/// A form's action, drawn as a button: padded and rounded, filled for the
/// primary action and outlined for the quiet one. The confirmation's
/// **Store it** / **Cancel** pair is this.
struct FormButton: View {
    let title: String
    let tone: Color
    var filled: Bool = false
    /// Esc presses it: a destroy question's **Keep it** (settings revamp), so the safe answer is
    /// the one the escape key gives.
    var cancels: Bool = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(cancels ? KeyboardShortcut.cancelAction : nil)
            .buttonStyle(.plain)
            .font(.system(size: SettingsScale.body))
            .foregroundStyle(tone)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tone.opacity(filled ? 0.13 : 0.0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(tone.opacity(filled ? 0.38 : 0.20), lineWidth: 0.5)))
            .contentShape(Rectangle())
            .accessibilityIdentifier(identifier)
    }
}

// MARK: - The sectioned page (2026-10-21)

/// One headed group on a settings page: a hairline above it, its micro header, and its rows.
///
/// **A page with more than one group is drawn as these, one after another** — the operator found
/// the pages bland with nothing separating one group from the next. The header is QUICK TASKS'
/// style, which every section now shares; `accessory` sits beside it (QUICK TASKS' ⓘ).
struct SettingsSection<Accessory: View, Content: View>: View {
    let title: String
    /// False for a section whose first row already says its name (an API entry's editable Name,
    /// 2e-iii): the hairline and its identifier stay, the heading is not drawn twice.
    var drawsTitle: Bool = true
    let accessory: Accessory
    let content: Content

    init(_ title: String, drawsTitle: Bool = true,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.drawsTitle = drawsTitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The hairline is the section's identifier: it spans the column, so a page drawn wider
            // than its pane shows on it, and an e2e check holds it inside `settings.pane`
            // (2e-settings-pane, 2e-settings-narrow-rows). A container's frame would not: macOS
            // reports one as the union of its children.
            Rectangle().fill(SettingsPalette.coolWhite.opacity(0.10)).frame(height: 0.5)
                .accessibilityElement()
                .accessibilityIdentifier("settings.section.\(fragment)")
                // Untitled, the rule is all that parts one section from the next, so it takes the
                // air a title would have had above it — and the row before it draws no hairline of
                // its own (`SettingsRow(rule: false)`), or the two read as one doubled line.
                .padding(.top, drawsTitle ? 0 : SettingsScale.sectionGap)
            if drawsTitle {
                HStack(alignment: .center, spacing: 6) {
                    Text(title.uppercased())
                        .font(.system(size: SettingsScale.micro, weight: .medium))
                        .tracking(SettingsScale.microTracking)
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.32))
                    accessory
                }
                .padding(.top, SettingsScale.sectionGap)
                .padding(.bottom, 4)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SettingsScale.sectionGap - 10)
    }

    /// The title as an identifier fragment: `Local models` → `localModels`.
    private var fragment: String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
        guard let first = words.first else { return "untitled" }
        return first + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// One setting on one line: its label left at `labelWidth`, its value right, a faint hairline
/// under it — the QUICK TASKS rows' shape, which every sectioned page uses.
///
/// `wraps` is for a value that cannot shrink — a `SegmentedChoice` of several long options: when
/// label and value do not fit the column on one line, the value goes under the label instead of
/// running past the pane's edge. The settings pane opens 640pt wide, and Autosave's three
/// options beside a 120pt label are wider than its subject column.
struct SettingsRow<Value: View>: View {
    let label: String
    var wraps: Bool = false
    /// False for the last row of an untitled section: the next section's rule is its separator.
    var rule: Bool = true
    let value: Value

    init(_ label: String, wraps: Bool = false, rule: Bool = true, @ViewBuilder value: () -> Value) {
        self.label = label
        self.wraps = wraps
        self.rule = rule
        self.value = value()
    }

    var body: some View {
        Group {
            if wraps {
                WrappingRowLayout {
                    labelText
                    HStack(spacing: 0) { value }
                }
            } else {
                oneLine
            }
        }
        .frame(minHeight: SettingsScale.rowHeight, alignment: .leading)
        .overlay(alignment: .bottom) {
            if rule {
                Rectangle().fill(SettingsPalette.coolWhite.opacity(0.06)).frame(height: 0.5)
            }
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: SettingsScale.body, weight: .medium))
            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.86))
            // A label longer than the column takes a second line rather than an ellipsis
            // ("Name groups with AI" was cut, 3d-i walk).
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var oneLine: some View {
        HStack(alignment: .center, spacing: SettingsScale.columnGap) {
            labelText.frame(width: SettingsScale.labelWidth, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
    }
}

/// `SettingsRow`'s `wraps`: the label and value on one line when the value's ideal width fits
/// beside the label, else the value under the label.
///
/// **One layout, not `ViewThatFits`.** `ViewThatFits` builds each arrangement as its own view, so
/// the value existed twice with two sets of `@State`, and a value holding state — the git accounts'
/// sheet and Test result, an instruction box's focus — lost it whenever the row changed
/// arrangement (#57). Here the value is one view whichever arrangement is drawn.
private struct WrappingRowLayout: Layout {
    private static let stackedSpacing: CGFloat = 6
    private static let stackedPadding: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(bounds.width, subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ proposed: CGFloat?, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard subviews.count == 2 else { return (.zero, []) }
        let label = subviews[0], value = subviews[1]
        let lead = SettingsScale.labelWidth + SettingsScale.columnGap
        let ideal = value.sizeThatFits(.unspecified)
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? lead + ideal.width
        if lead + ideal.width <= width {
            let labelSize = label.sizeThatFits(ProposedViewSize(width: SettingsScale.labelWidth, height: nil))
            let valueSize = value.sizeThatFits(ProposedViewSize(width: width - lead, height: nil))
            let height = max(labelSize.height, valueSize.height)
            return (CGSize(width: width, height: height), [
                CGRect(x: 0, y: (height - labelSize.height) / 2,
                       width: SettingsScale.labelWidth, height: labelSize.height),
                CGRect(x: lead, y: (height - valueSize.height) / 2,
                       width: valueSize.width, height: valueSize.height),
            ])
        }
        let labelSize = label.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let valueSize = value.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let valueY = Self.stackedPadding + labelSize.height + Self.stackedSpacing
        return (CGSize(width: width, height: valueY + valueSize.height + Self.stackedPadding), [
            CGRect(x: 0, y: Self.stackedPadding, width: labelSize.width, height: labelSize.height),
            CGRect(x: 0, y: valueY, width: valueSize.width, height: valueSize.height),
        ])
    }
}

/// A read value in a row: monospace for identifiers (§6), `—` for an empty one.
struct SettingsValue: View {
    let text: String
    var monospaced: Bool = true

    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: monospaced ? SettingsScale.identifier : SettingsScale.body,
                          design: monospaced ? .monospaced : .default))
            .foregroundStyle(SettingsPalette.coolWhite.opacity(text.isEmpty ? 0.30 : 0.85))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

extension View {
    /// Under a row, in its value column: a refusal, a hint, a note about that one setting.
    func underRowValue() -> some View {
        padding(.leading, SettingsScale.labelWidth + SettingsScale.columnGap)
    }

    /// A field edited where it stands: plain text until hovered or focused, when the box shows —
    /// the local model URL's treatment, so a row of values does not read as a row of inputs.
    func inPlaceField(focused: Bool) -> some View {
        modifier(InPlaceField(focused: focused))
    }
}

private struct InPlaceField: ViewModifier {
    let focused: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SettingsPalette.coolWhite.opacity(focused || hovering ? 0.05 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(SettingsPalette.coolWhite.opacity(focused ? 0.18 : hovering ? 0.10 : 0),
                                    lineWidth: 0.5)))
            .padding(.horizontal, -6)
            .onHover { hovering = $0 }
    }
}
