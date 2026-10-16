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
struct FormCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: SettingsScale.micro, weight: .medium))
                .tracking(SettingsScale.microTracking)
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.42))
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
            .fieldBox(width: width)
        }
    }
}

extension View {
    /// The boxed `.field`: its own background and a hairline, so a value a person types is never
    /// mistaken for a label. `LabelledField` draws it; so does any field that sits in a list.
    func fieldBox(width: CGFloat) -> some View {
        padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .background(
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
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
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
