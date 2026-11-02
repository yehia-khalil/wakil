import AppKit
import SwiftUI
import WakilKit

// The Running page's pieces (the comp, 2026-11-02): its colours, the spine's node, a field's row,
// the chip that adds one, and the layouts that wrap them whole at the window's minimum width.

/// The comp's tokens over §5: read text never under .58 cool white on the slab (5.4:1 and up);
/// violet read as text is `act` (#9e82ff), not the luminance violet, which reads under 4.5:1.
enum RunInk {
    static func text(_ opacity: Double) -> Color { SettingsPalette.coolWhite.opacity(opacity) }
    static let violet = SettingsPalette.accent                                      // #7c5cff
    static let act = Color(red: 0.620, green: 0.510, blue: 1.0)                     // #9e82ff
    static let green = Color(red: 0.545, green: 0.878, blue: 0.784)                 // #8be0c8
    static let red = Color(red: 0.910, green: 0.361, blue: 0.361)                   // #e85c5c
    static let redText = Color(red: 0.949, green: 0.725, blue: 0.725)               // #f2b9b9
    static let slab = Color(red: 0.055, green: 0.063, blue: 0.098)                  // #0e1019
    static let slab2 = Color(red: 0.071, green: 0.082, blue: 0.133)                 // #121522
    static let primaryText = Color(red: 0.851, green: 0.816, blue: 1.0)             // #d9d0ff
    static let hair = text(0.08)
    static let edge = text(0.14)
}

/// The head's actions: quiet (Detect), plain (✨ Draft), primary (▶ Try) — one primary a page.
struct RunButton: View {
    enum Kind { case quiet, plain, primary }
    let title: String
    let kind: Kind
    let identifier: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(kind == .primary ? RunInk.primaryText : kind == .quiet ? RunInk.text(0.72) : RunInk.text(0.86))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(kind == .primary ? RunInk.violet.opacity(0.22) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(kind == .primary ? RunInk.act.opacity(0.5) : kind == .quiet ? .clear : RunInk.edge,
                                    lineWidth: 0.5)))
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
            .fixedSize()
            .accessibilityIdentifier(identifier)
    }
}

/// "+ <Field>": a field nothing sets yet, at the end of its stop (Rule 9: optional stays
/// optional). Pressing it shows the field, focused (Rule 3).
struct RunChip: View {
    let word: String
    var hint: String? = nil
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            (Text("+ ") + Text(word).foregroundColor(RunInk.text(0.72)) + Text(hint.map { " — \($0)" } ?? ""))
                .font(.system(size: 11.5))
                .foregroundStyle(RunInk.text(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().stroke(RunInk.edge, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// A stop's node on the spine: hollow at rest; during a Try green when its steps passed, violet
/// and breathing while it runs (still violet, unmoving, under Reduce Motion), red where it failed.
struct RunNode: View {
    let status: RunStopStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Group {
            switch status {
            case .idle, .notReached:
                Circle().fill(RunInk.slab).overlay(Circle().strokeBorder(RunInk.text(0.38), lineWidth: 1.2))
            case .passed: Circle().fill(RunInk.green)
            case .failed: Circle().fill(RunInk.red)
            case .running:
                Circle().fill(RunInk.violet)
                    .opacity(dim && !reduceMotion ? 0.45 : 1)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) { dim = true }
                    }
                    .onDisappear { dim = false }
            }
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }
}

/// A field's row: the label (sans) left, the value (monospace) edited where it stands, and where
/// it comes from on the right — or under the value when the row is narrow. Multi-line: Return is
/// a new line, and the row saves a second after typing stops and when it is left (Rule 2).
struct RecipeFieldRow: View {
    let label: String
    let stored: String
    let placeholder: String
    let identifier: String
    let source: FieldSource
    let note: String?
    let first: Bool
    /// Use the recipe's: the repo's own value cleared. Nil when the value is not the repo's own.
    var inherit: (() -> Void)? = nil
    var inheritIdentifier: String = ""
    /// Opened from a chip: focused as it appears (Rule 3).
    var focusOnAppear = false
    let save: (String) async -> String?
    /// Focus came (true) or went (false), with the text the field holds then.
    var focusChanged: (Bool, String) -> Void = { _, _ in }

    @State private var field = LeaveSavedField()
    @State private var autosave = EditorDebounce(delay: .seconds(1))
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        RecipeRowLayout {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(RunInk.text(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
            value
            provenance
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(focused ? RunInk.violet.opacity(0.07) : hovering ? RunInk.text(0.035) : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(focused ? RunInk.act.opacity(0.35) : .clear, lineWidth: 0.5)))
        .overlay(alignment: .top) {
            if !first && !focused { Rectangle().fill(RunInk.hair).frame(height: 0.5).padding(.horizontal, 12) }
        }
        .padding(.horizontal, -12)
        .onHover { hovering = $0 }
        .onAppear {
            field.appeared()
            if focusOnAppear { Task { @MainActor in focused = true } }
        }
        .onDisappear {
            autosave.cancel()
            commit(field.disappeared(stored: stored))
        }
    }

    private var value: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("", text: Binding(get: { field.draft ?? stored }, set: { field.draft = $0 == stored ? nil : $0 }),
                      prompt: Text(placeholder).foregroundStyle(RunInk.text(0.40)),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...40)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(4)
                .foregroundStyle(RunInk.text(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($focused)
                .onChange(of: focused) { old, new in
                    if old, !new {
                        autosave.cancel()
                        let text = field.draft ?? stored
                        commit(field.leave(stored: stored))
                        focusChanged(false, text)
                    }
                    if new { focusChanged(true, field.draft ?? stored) }
                }
                .onKeyPress(.return) {
                    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                }
                .onChange(of: field.draft) { _, draft in
                    guard draft != nil else { return }
                    autosave.schedule { commit(field.leave(stored: stored)) }
                }
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
            if field.saving {
                Text("Saving…").font(.system(size: 11)).foregroundStyle(RunInk.text(0.58))
            }
            if let refusal = field.refusal {
                Text(refusal)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("\(identifier).error")
            }
        }
    }

    @ViewBuilder
    private var provenance: some View {
        VStack(alignment: .leading, spacing: 3) {
            if source != .none {
                Text(source.label).foregroundStyle(source == .repo ? RunInk.act : RunInk.text(0.58))
            }
            if let note { Text(note).foregroundStyle(RunInk.text(0.58)).fixedSize(horizontal: false, vertical: true) }
            if let inherit {
                // The project page's "Use the organisation's", matched: body size, .70.
                Button("Use the recipe's", action: inherit)
                    .buttonStyle(.plain)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.70))
                    .accessibilityIdentifier(inheritIdentifier)
            }
        }
        .font(.system(size: 10.5))
        .padding(.top, 2)
    }

    private func commit(_ value: String?) {
        guard let value else { return }
        let field = field
        Task {
            _ = field.landed(await save(value))
            if field.draft != nil, field.refusal == nil { autosave.schedule { commit(field.leave(stored: value)) } }
        }
    }
}

/// A field row's three parts — label, value, where it comes from — on one line when the value
/// keeps `minimumValue` beside them; else where it comes from goes under the value, and the label
/// narrows. One layout, so the value's focus survives the change (`WrappingRowLayout`'s reason).
struct RecipeRowLayout: Layout {
    /// The label column every settings page shares (`SettingsRow`), so a row's value starts where
    /// theirs do.
    var labelWidth: CGFloat = SettingsScale.labelWidth
    var narrowLabelWidth: CGFloat = 84
    var gap: CGFloat = SettingsScale.columnGap
    var minimumValue: CGFloat = 300
    var sourceWidth: CGFloat = 220

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(bounds.width, subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ proposed: CGFloat?, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard subviews.count == 3 else { return (.zero, []) }
        let label = subviews[0], value = subviews[1], source = subviews[2]
        let sourceIdeal = source.sizeThatFits(.unspecified)
        let src = min(sourceIdeal.width, sourceWidth)
        let srcLead = src > 0 ? gap + src : 0
        let width = proposed.flatMap { $0.isFinite ? $0 : nil }
            ?? labelWidth + gap + value.sizeThatFits(.unspecified).width + srcLead
        if width - labelWidth - gap - srcLead >= minimumValue {
            let valueWidth = width - labelWidth - gap - srcLead
            let l = label.sizeThatFits(ProposedViewSize(width: labelWidth, height: nil))
            let v = value.sizeThatFits(ProposedViewSize(width: valueWidth, height: nil))
            let s = source.sizeThatFits(ProposedViewSize(width: src, height: nil))
            return (CGSize(width: width, height: max(l.height, v.height, s.height)), [
                CGRect(x: 0, y: 0, width: labelWidth, height: l.height),
                CGRect(x: labelWidth + gap, y: 0, width: valueWidth, height: v.height),
                CGRect(x: width - src, y: 0, width: src, height: s.height),
            ])
        }
        let lead = narrowLabelWidth + gap
        let valueWidth = max(width - lead, 1)
        let l = label.sizeThatFits(ProposedViewSize(width: narrowLabelWidth, height: nil))
        let v = value.sizeThatFits(ProposedViewSize(width: valueWidth, height: nil))
        let s = source.sizeThatFits(ProposedViewSize(width: valueWidth, height: nil))
        let sy = v.height + (s.height > 0 ? 4 : 0)
        return (CGSize(width: width, height: max(l.height, sy + s.height)), [
            CGRect(x: 0, y: 0, width: narrowLabelWidth, height: l.height),
            CGRect(x: lead, y: 0, width: valueWidth, height: v.height),
            CGRect(x: lead, y: sy, width: valueWidth, height: s.height),
        ])
    }
}

/// Two columns side by side when each keeps `minimumColumn`, else one under the other — Ports
/// beside Environment. One layout, so the env fields keep their focus when it changes.
struct RunTwoColumns: Layout {
    var gap: CGFloat = 28
    var minimumColumn: CGFloat = 260

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(bounds.width, subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ proposed: CGFloat?, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard subviews.count == 2 else { return (.zero, []) }
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? 2 * minimumColumn + gap
        if width >= 2 * minimumColumn + gap {
            let column = (width - gap) / 2
            let a = subviews[0].sizeThatFits(ProposedViewSize(width: column, height: nil))
            let b = subviews[1].sizeThatFits(ProposedViewSize(width: column, height: nil))
            return (CGSize(width: width, height: max(a.height, b.height)), [
                CGRect(x: 0, y: 0, width: column, height: a.height),
                CGRect(x: column + gap, y: 0, width: column, height: b.height),
            ])
        }
        let a = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let b = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return (CGSize(width: width, height: a.height + 20 + b.height), [
            CGRect(x: 0, y: 0, width: width, height: a.height),
            CGRect(x: 0, y: a.height + 20, width: width, height: b.height),
        ])
    }
}
