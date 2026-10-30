import WakilKit
import SwiftUI

/// The home composer's *Start in* picker (workspaces, piece 3; decision 19): where a send goes,
/// pre-set to the current place (Rule 9). Choosing one sets where the next send goes and nothing
/// else — the screen stays on the home (piece 3 walk; `WindowModel.chooseStartIn`); the draft stays. With one project and one environment there is nothing to
/// choose, and nothing is drawn.
struct ComposerStartIn: View {
    let model: WindowModel
    @State private var choices: [HomeStartChoice] = []

    /// The row shown: *Start in*'s choice, else the window's place.
    private var selected: HomeStartChoice? { homeStartSelected(choices, chosen: model.homeStartIn) }

    private var coolWhite: Color { Color(red: 0.910, green: 0.925, blue: 0.965) }

    var body: some View {
        Group {
            if choices.count > 1 {
                Menu {
                    Section("Start in") {
                        ForEach(choices) { choice in
                            Button {
                                model.chooseStartIn(choice)
                            } label: {
                                Text((choice.id == selected?.id ? "✓ " : "") + choice.label + (choice.isProduction ? " — production" : ""))
                            }
                            .accessibilityIdentifier("window.composer.startIn.\(choice.id)")
                        }
                    }
                } label: {
                    Text("in \(selected?.label ?? model.project) ▾")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(selected?.isProduction == true
                                         ? Color(EnvironmentBadge.productionColour) : coolWhite.opacity(0.6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Where a send starts: Main of this project and environment")
                .accessibilityIdentifier("window.composer.startIn")
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
