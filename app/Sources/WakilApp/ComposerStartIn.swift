import WakilKit
import SwiftUI

/// The home composer's *Start in* (workspaces, piece 3; decision 19): where a send goes, pre-set to
/// the current place (Rule 9). Choosing a row sets where the next send goes and nothing else — the
/// screen stays on the home (piece 3 walk; `WindowModel.chooseStartIn`), the draft stays, and the
/// composer takes the keyboard back. With one project and one environment there is nothing to
/// choose, and nothing is drawn.
///
/// **Wakil's own plane, not an NSMenu** (the comp of 2026-10-30): a native menu drops colour, and
/// Invariant 8 needs production in red — on the label and on its row, tagged *production*. ↑ and ↓
/// move, Return chooses, Escape closes.
struct ComposerStartIn: View {
    let model: WindowModel
    /// Gives the composer the keyboard back after a choice: the draft stays where it was typed.
    var refocus: () -> Void = {}

    @State private var choices: [HomeStartChoice] = []
    @State private var open = false

    /// The row shown: *Start in*'s choice, else the window's place.
    private var selected: HomeStartChoice? { homeStartSelected(choices, chosen: model.homeStartIn) }

    private let ink = Color(HomePalette.ink)

    var body: some View {
        Group {
            if choices.count > 1 {
                Button { open.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("in \(selected?.label ?? model.project)")
                            .font(.system(size: 11, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(selected?.isProduction == true ? Color(HomePalette.red) : ink.opacity(HomePalette.secondary))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(ink.opacity(open ? 0.08 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Where a send starts: Main of this project and environment")
                .accessibilityIdentifier("window.composer.startIn")
                .popover(isPresented: $open, arrowEdge: .top) {
                    StartInPlane(choices: choices, selected: selected?.id) { choice in
                        model.chooseStartIn(choice)
                        open = false
                        refocus()
                    }
                    .presentationBackground(Color(red: 0.067, green: 0.075, blue: 0.114))
                }
            } else {
                // Something must be drawn for `.task` to run: an empty Group never appears, so
                // the choices were never read and the picker never drawn (piece 3's e2e run).
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .task(id: "\(model.organization)/\(model.projectKey)/\(model.environment)") {
            let projects = await model.listProjects().map(\.name)
            let environments = await model.listEnvironments().map(\.name)
            let flags = model.environmentProduction
            let current = model.projectKey
            choices = homeStartChoices(
                projects: projects, current: model.place, environments: environments,
                isProduction: { p, e in p == current ? flags.isProduction(e) : EnvironmentProduction.undeclared.isProduction(e) })
        }
    }
}

/// Start in, opened: *START IN · MAIN OF*, the rows grouped by project with a hairline between, a
/// tick on the one chosen, *now* and *production* tags, and what choosing does.
private struct StartInPlane: View {
    let choices: [HomeStartChoice]
    let selected: String?
    let choose: (HomeStartChoice) -> Void

    @State private var highlight = 0
    @FocusState private var focused: Bool
    private let ink = Color(HomePalette.ink)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("START IN · MAIN OF")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.7)
                .foregroundStyle(ink.opacity(HomePalette.micro))
                .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 6)
            ForEach(Array(homeStartGroups(choices).enumerated()), id: \.offset) { g, group in
                if g > 0 { hairline }
                ForEach(group) { choice in row(choice, index: choices.firstIndex(of: choice) ?? 0) }
            }
            hairline
            Text("Sets where Return sends. The home stays.")
                .font(.system(size: 11))
                .foregroundStyle(ink.opacity(HomePalette.quiet))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 5)
        }
        .padding(6)
        .frame(width: 280, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            highlight = choices.firstIndex { $0.id == selected } ?? 0
            focused = true
        }
        .onKeyPress(.downArrow) { highlight = homeStartMove(highlight, by: 1, count: choices.count); return .handled }
        .onKeyPress(.upArrow) { highlight = homeStartMove(highlight, by: -1, count: choices.count); return .handled }
        .onKeyPress(.return) {
            guard choices.indices.contains(highlight) else { return .ignored }
            choose(choices[highlight])
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window.composer.startIn.plane")
    }

    private func row(_ choice: HomeStartChoice, index: Int) -> some View {
        let red = Color(HomePalette.red)
        return Button { choose(choice) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(choice.id == selected ? "✓" : "")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(HomePalette.action))
                    .frame(width: 14, alignment: .leading)
                Text(choice.label)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(choice.isProduction ? red : ink.opacity(HomePalette.strong))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let tag = choice.tag {
                    Text(tag)
                        .font(.system(size: 10.5))
                        .foregroundStyle(choice.isProduction ? red : ink.opacity(HomePalette.quiet))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(ink.opacity(highlight == index ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlight = index } }
        .accessibilityValue(choice.id == selected ? "selected" : "")
        .accessibilityIdentifier("window.composer.startIn.\(choice.id)")
    }

    private var hairline: some View {
        Rectangle().fill(ink.opacity(0.08)).frame(height: 0.5).padding(.vertical, 5).padding(.horizontal, 4)
            .accessibilityHidden(true)
    }
}
