import SwiftUI

/// A Settings sheet: a title and one line saying what it is for, the content, and a footer bar —
/// Back on the left, Cancel then the main action on the right, as macOS sheets place them.
struct SettingsSheet<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.95))
                Text(subtitle)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)
            content
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            Rectangle().fill(SettingsPalette.coolWhite.opacity(0.08)).frame(height: 0.5)
            HStack(spacing: 8) { footer }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 560)
    }
}

/// The footer's main action: filled, the default key (Return), dimmed and inert while it cannot run
/// or while its work is in flight (Rule 5), with a spinner then.
struct SheetPrimaryButton: View {
    let title: String
    var enabled = true
    var working = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if working { ProgressView().controlSize(.small) }
            FormButton(title: title, tone: SettingsPalette.accent, filled: true, identifier: identifier, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled || working)
                .opacity(enabled && !working ? 1 : 0.45)
        }
    }
}

/// A choice in a sheet: a name, one line saying what it means, and an optional note on the right
/// (a repository count, "Connected as …"). Selected, it takes the accent; disabled, it dims.
struct SheetChoice: View {
    let title: String
    let detail: String
    var note: String? = nil
    var selected = false
    var enabled = true
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: SettingsScale.identifier, weight: .semibold))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.92))
                    Text(detail)
                        .font(.system(size: SettingsScale.meta + 1))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if let note {
                    Text(note)
                        .font(.system(size: SettingsScale.meta))
                        .foregroundStyle(selected ? SettingsPalette.accent : SettingsPalette.coolWhite.opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? SettingsPalette.accent.opacity(0.12) : SettingsPalette.coolWhite.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected ? SettingsPalette.accent.opacity(0.7) : SettingsPalette.coolWhite.opacity(0.09),
                                    lineWidth: selected ? 1 : 0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityIdentifier(identifier)
    }
}

/// A sheet's message line: a ✓ success in the quiet ink, anything else in amber, whole (Rule 8).
struct SheetMessage: View {
    let text: String
    let identifier: String

    var body: some View {
        Text(text)
            .font(.system(size: SettingsScale.body))
            .foregroundStyle(text.hasPrefix("✓") ? SettingsPalette.coolWhite.opacity(0.75) : SettingsPalette.caution)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier(identifier)
    }
}
