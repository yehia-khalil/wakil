import WakilKit
import SwiftUI

/// The settings pane: this machine's configuration, drawn as the config
/// tree, with the selected subject on the right under a breadcrumb.
///
/// **The layout is the config tree** (`phase-2e-probe.md` §4, chosen from
/// five drawn variants), and two of its shapes are binding:
///
/// ```
/// Organisation          three strings
/// Providers             (organisation, provider id) — ORG-LEVEL, cannot nest
/// Projects
///   └ project           roots, scopes, environments
///       └ environment   ← holds the databases and the api
///           ├ Databases
///           └ API
/// ```
///
/// It is **four deep, not three** — an *environment*, not a project, holds
/// the databases and the API (`config.go`) — and **providers cannot nest
/// at all**, a binding being `(organisation, provider id)`, so they sit
/// beside the projects and every project in the organisation draws on
/// them. The credential spine cuts across the tree rather than along it.
///
/// **The breadcrumb is not decoration.** Reaching a DSN is four levels
/// down, and a form with no statement of where it sits is a form the
/// operator has to navigate back out of to identify.
///
/// **What is editable here, and what is not.** The Organisation node's
/// three strings are editable (#199) — the phase's thinnest complete edit,
/// built first because it proves the whole path before anything
/// credential-bearing travels it. The Providers node becomes the account
/// table in #200 and the Databases node grows the DSN form in #207. The
/// **API entry is read-only permanently** — not because an artboard ran
/// ahead of the code but because Decision 8's amendment did, and a form
/// built on today's API shape is one rebuilt on someone else's schedule.
///
/// **This view holds no CONFIGURATION that outlives a read.** `selection`
/// is where the operator is standing and `drafts` is what they are
/// part-way through typing — both properties of this window's gesture, not
/// of the configuration. Everything else drawn comes from `tree`, which
/// `WindowModel.refreshSettings` re-reads from disk on open and after
/// every dispatch.
struct SettingsPane: View {
    /// The configuration, or `nil` when it has not been read yet or the
    /// read failed — `failure` says which.
    let tree: SettingsTree?
    /// Why the last read did not produce a tree.
    ///
    /// **A failure and an empty organisation must not draw alike.** A
    /// freshly created organisation genuinely has no projects; a read that
    /// never answered has learned nothing about whether it does, and
    /// rendering the second as the first tells the operator something
    /// about their machine that may be false.
    let failure: String?
    /// Re-reads from disk. Bound to the pane's own Reload control, which
    /// exists because the pane caches nothing and therefore has something
    /// true to offer when pressed.
    let reload: () -> Void
    /// Saves ONE of the organisation's three strings and answers the
    /// refusal's own sentence, or `nil` on success (#199).
    ///
    /// **One field per call**, which is the read-modify-write rule made
    /// operational: sending all three would flush this pane's idea of the
    /// record over a hand edit made while it was open.
    /// The organisation is the one the page was drawn for, not the window's at the moment of saving:
    /// a field left as an org switch redraws the page saves into the organisation it was typed for.
    let saveOrganisationField: (WindowModel.OrganisationField, String, String) async -> String?
    /// Saves app-wide editor fields (3b-v) and answers the refusal's sentence, or nil.
    var saveEditorSettings: ([String: JSONValue]) async -> String? = { _ in nil }
    /// Saves one project's editor fields: the project file's path, then the fields.
    var saveProjectEditorSettings: (String, [String: JSONValue]) async -> String? = { _, _ in nil }
    /// 3a-iii-b: saves one of a project's agent boxes — the project file's path, then general, commits
    /// or pull requests, exactly one given. Answers the refusal or nil.
    var saveProjectAgentInstructions: (String, String?, String?, String?) async -> String? = { _, _, _, _ in nil }
    /// Saves a local model: id, label, URL (3b-viii). Answers the refusal or nil.
    var saveLocalProvider: (String, String, String) async -> String? = { _, _, _ in nil }
    /// Saves the org's ghost-text or fast-path switch (3b-ix). Answers the refusal or nil.
    var saveOrganisationSwitch: (WindowModel.OrganisationSwitch, Bool) async -> String? = { _, _ in nil }
    /// Removes a local model by id (3b-viii). Answers the refusal or nil.
    var removeLocalProvider: (String) async -> String? = { _ in nil }
    /// 3a-iii: the organisation's git accounts.
    var git = GitAccountActions()
    /// Each quick-task provider's last error whole and which have answered, by id; the provider
    /// code completion goes to; and why the configuration could not be read.
    var quickTaskStatus: () async -> QuickTaskStatus = { QuickTaskStatus() }
    /// Every account on this machine, or `nil` before the first read.
    ///
    /// Read in the same refresh as `tree`, so the two halves of the pane
    /// are one moment of disk rather than two.
    let accounts: AccountListing?
    /// Capacity readings for every account the window knows of.
    let capacity: [CapacityReading]
    /// Adopts a row homed in another organisation into this one, in place,
    /// and answers the refusal's own sentence or `nil` (#201). No browser
    /// opens: the credential is copied Keychain-to-Keychain in Go.
    let adopt: (Account) async -> String?
    /// What the in-flight band is showing (#202).
    let login: ProviderLoginState
    /// Puts the add flow in front of the operator with its cost stated,
    /// and runs nothing.
    /// The account id, and the `claude` path the operator left or typed on
    /// the form (#322). An empty path means "use what Wakil found".
    let offerLogin: (String, String) async -> Void
    /// What Wakil would sign in with by itself: this organisation's record,
    /// else the machine lookup. Prefills the form's `claude` field.
    let resolvedClaudePath: String
    /// Starts the first browser trip.
    let startLogin: () async -> Void
    /// Cancels the trip that is running.
    let cancelLogin: () async -> Void
    /// Takes the band off the pane.
    let dismissLogin: () async -> Void
    /// Re-authenticates a row in place — the add flow re-entered at one
    /// trip or two, never skipping the mint (#205).
    let reauthenticate: (Account) async -> Void
    /// Discards the sign-in the directory holds and starts over as
    /// somebody else. Asks for no confirmation: it escalates nothing and
    /// is undone by the gesture that did it.
    let signInAsSomeoneElse: () async -> Void
    /// Unlinks a binding, behind this pane's own confirmation (#206).
    let unlink: (Account) async -> UnlinkReport?
    /// Stops waiting for trip 2 (#240). Never described as a cancel.
    var stopWaitingForMint: () async -> Void = {}
    /// The account this window is running under, so a row can say so
    /// (#270). Empty when the organisation has none set.
    var runningAccountId: String = ""
    /// Makes an account the one this window runs under.
    ///
    /// It is `setProvider`, the same call ⌘P makes — guards, credential
    /// lookup, live swap and the `ctx_set_provider` write included. The
    /// pane adds a place to press it, not a second way to do it.
    var use: (Account) async -> Void = { _ in }
    /// Stores a database's connection string (#207). Answers the
    /// refusal's own sentence, or `nil`.
    let setDatabaseDSN: (
        _ projectPath: String, _ environment: String, _ name: String, _ driver: String,
        _ dsn: String, _ grantWrite: Bool, _ writeDsn: String
    ) async -> String?
    /// Drops a database, keeping its Keychain entry.
    let removeDatabase: (
        _ projectPath: String, _ environment: String, _ name: String
    ) async -> String?

    /// Adds a project from the folder chosen (2e-ii): its name, or the refusal whole.
    var createProject: (String) async -> (name: String?, error: String?) = { _ in (nil, nil) }
    /// 3a-iii: clone a link into a folder, then add it as a project.
    var cloneProject: (String, String) async -> (name: String?, error: String?) = { _, _ in (nil, nil) }
    /// Renames a project: old, new. Answers the refusal or nil.
    var renameProject: (String, String) async -> String? = { _, _ in nil }
    /// Removes a project from this organisation. Answers the refusal or nil.
    var removeProject: (String) async -> String? = { _ in nil }
    /// Adds an environment to a project: its name and its file's path.
    var createEnvironment: (String, String) async -> (name: String?, error: String?) = { _, _ in (nil, nil) }
    /// Renames an environment: project, project file, old, new. Answers the refusal or nil.
    var renameEnvironment: (String, String, String, String) async -> String? = { _, _, _, _ in nil }
    /// Removes an environment: project, project file, name. The receipt or the refusal.
    var removeEnvironment: (String, String, String) async -> (receipt: String?, error: String?) =
        { _, _, _ in (nil, nil) }
    /// Says a refusal in the window's status, for a Name field gone before its write answered.
    var showUnseenRefusal: (String) -> Void = { _ in }

    /// Writes in flight, by key (`addProject`, `addEnvironment.<p>`, `remove.<node>`): a control
    /// shows a spinner and cannot be fired a second time (Rule 5).
    @State private var lifecycleBusy: Set<String> = []
    /// A failed add or remove, whole, beside the control that caused it (Rule 8).
    @State private var lifecycleRefusals: [String: String] = [:]
    /// 3a-iii: + Add a project's sheet — Choose a folder… or Clone from a link….
    @State private var addingProject = false
    /// The removal awaiting its pane-local confirmation, by its key. Only a
    /// removal that passes a `confirmation` asks (Rule 1: the operator
    /// counts removing a project or an environment as destroying).
    @State private var confirmingRemoval: String?
    /// What a removal did, shown on the page it landed on until the operator moves.
    @State private var receipt: (node: SettingsNode, text: String)?
    /// The node whose Name field takes the keyboard when its page appears (Rule 3).
    @State private var pendingNameFocus: SettingsNode?

    /// The database form's fields, while it is open.
    ///
    /// **The passwords live here and nowhere else in this view.** They are
    /// never put into a confirmation string, never logged, and cleared the
    /// moment the write succeeds. The connection string they become is
    /// built by `databaseFormCredentials` at Save and never held.
    @State private var databaseName: String = ""
    @State private var databaseConnection = DatabaseConnectionFields(driver: "mysql")
    @State private var databaseGrantWrite: Bool = false
    @State private var databaseWriteUser: String = ""
    @State private var databaseWritePassword: String = ""
    /// Whether the DSN write is awaiting its pane-local confirmation.
    @State private var confirmingDSN: Bool = false
    @State private var databaseRefusal: String?

    /// The row whose unlink is awaiting confirmation.
    ///
    /// **Pane-local, destructive-only, and never the confirmation
    /// plane** — that plane renders verbatim and unelided, which is
    /// survivable for an account id and is not for #207's DSN. One
    /// mechanism for both is what keeps the second from being the leak.
    @State private var confirmingUnlink: Account?
    /// What the last unlink did, drawn until dismissed.
    @State private var unlinkReport: UnlinkReport?

    /// The id being typed for a new account. The only thing an operator
    /// types in this flow — never a path, never a token.
    @State private var newAccountId: String = ""
    /// The register form's `claude` path: prefilled from
    /// `resolvedClaudePath` when the form opens, and the override if edited.
    @State private var newAccountClaudePath: String = ""

    /// The row whose adoption is in flight, so its control says so rather
    /// than look inert, and a second press cannot start a second copy.
    @State private var adopting: String?
    /// The refusal for a row, drawn beside it. Rendered on the pane and
    /// beside the row that caused it — adoption stops pointing at the
    /// organisation plane, so it also stops borrowing that plane's error
    /// area.
    @State private var adoptRefusals: [String: String] = [:]
    /// What `quickTaskStatus()` last answered, read when the pane appears and after each save.
    @State private var quickStatus: QuickTaskStatus?
    /// A refused ghost-text or fast-path switch, whole under its row, by switch key.
    @State private var switchRefusals: [String: String] = [:]

    /// The value being typed, per field, while an editor is open. Absent
    /// means the field is not being edited and draws what is on disk.
    ///
    /// **Nothing here outlives a save.** A draft is a property of this
    /// window's editing gesture, not of the configuration, and a re-read
    /// that wiped it mid-type would be the pane fighting the operator.
    @State private var drafts: [WindowModel.OrganisationField: String] = [:]
    /// The refusal for a field, drawn beneath it. Rendered **on the pane**
    /// — this phase adds no new modal — and beneath the field that caused
    /// it rather than in a window-wide status line that outlives the form.
    @State private var refusals: [WindowModel.OrganisationField: String] = [:]
    /// The field whose save is in flight, so its control can say so rather
    /// than look inert.
    @State private var saving: WindowModel.OrganisationField?
    /// The Git fields on screen, read by a save that lands after its page went — left by a tree
    /// click — so its refusal goes to the window's status (Rule 8). A reference, as
    /// `LeaveSavedField`'s, so the save's task reads the live answer.
    @State private var gitFieldsShown = ShownFields()
    /// The text a Git field's last save sent, when it was refused: leaving does not send it again
    /// (the refusal is already under the field); Return and Save do.
    @State private var refusedDrafts: [WindowModel.OrganisationField: String] = [:]

    private final class ShownFields {
        var fields: Set<WindowModel.OrganisationField> = []
    }
    /// The organisation field holding the keyboard: Git name and email save when it leaves (3a-ii, Rule 2).
    @FocusState private var focusedOrgField: WindowModel.OrganisationField?
    /// The Author fields save a second after typing stops, as well as when left.
    @State private var autosave = EditorDebounce(delay: .seconds(1))

    /// Where the operator is standing in the tree. Window state, not
    /// configuration: it survives a re-read, and a re-read that dropped it
    /// would throw the operator back to the top every time anything
    /// changed. **Owned by the window** (`WakilWindow.settingsSelection`)
    /// so it also survives the pane being rebuilt, as a provider switch does.
    @Binding var selection: SettingsNode
    /// Which projects and environments are open in the tree. **Owned by the window**, for
    /// `selection`'s reason: window-life, never persisted, and it survives the pane being rebuilt.
    @Binding var expansion: SettingsTreeExpansion
    /// The place on screen, whose project and environment start open.
    var activeProject: String = ""
    var activeEnvironment: String = ""
    /// Whether the tree column holds the keyboard, for → and ←.
    @FocusState private var treeFocused: Bool
    /// Whether the Adopt door is open (#236). Window state, like
    /// `selection` — an operator who opened it to compare directories
    /// should not have it shut by a re-read.
    @State private var showingAdoptable = false
    /// Whether the Register door is open (#236).
    @State private var registering = false

    // MARK: - The scale

    /// **One scale, named, taken from `Settings.dc.html` and from the
    /// organisation plane that already ships it** (#269).
    ///
    /// The pane was built a whole band below both: 10–10.5pt body against
    /// the artboard's 12–13, rows a little over half the artboard's 44pt,
    /// and no horizontal padding at all where it asks for 22. Nothing was
    /// wrong in isolation; it read as cramped because every value was
    /// slightly under and the errors compounded.
    ///
    /// Named rather than inlined so the next surface can be checked
    /// against it by reading four numbers instead of counting literals.
    /// Shared with every settings form (`SettingsForm.swift`), so a form
    /// added later is checked against the same numbers.
    private typealias Scale = SettingsScale

    private var coolWhite: Color { SettingsPalette.coolWhite }
    private var caution: Color { SettingsPalette.caution }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            treeColumn
                .frame(width: 232, alignment: .leading)
            Divider().overlay(coolWhite.opacity(0.10))
            subjectColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // `.row { padding: 0 22px }` — the gutter the artboard
                // gives every row, applied once to the column they share.
                .padding(.leading, Scale.gutter)
        }
        // **The pane's width, never its content's.** `minWidth: 0` makes this frame the width it is
        // given; without it a page wider than the pane (the account table, 2026-10-21) grew the
        // whole slab, which the canvas then centred on the pane's frame — the tree cut off on the
        // left. A page that is still too wide now runs past the right edge, where
        // 2e-settings-pane and 2e-settings-narrow-rows hold its sections inside `settings.pane`.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The pane's extent, for those checks: a leaf behind the content, because macOS reports a
        // container's frame as the union of its children — the overflow it is meant to catch.
        .background(Color.clear.accessibilityElement().accessibilityIdentifier("settings.pane"))
        .task(id: tree) { quickStatus = await quickTaskStatus() }
        .sheet(isPresented: $addingProject) {
            AddProjectSheet(
                lastFolder: tree?.org.lastCloneFolder ?? "",
                chooseFolder: {
                    addingProject = false
                    Task { await addProject() }
                },
                clone: cloneProject,
                finished: { name in
                    addingProject = false
                    land(on: node(for: SettingsLanding.afterCreatingProject(name)), focusName: true)
                },
                close: { addingProject = false })
        }
    }

    // MARK: - The tree

    /// The tree, with every project and environment a branch that opens and closes (2026-10-21).
    ///
    /// **Collapsing is the operator's alone** (Rule 6): `expansion` lays its defaults once — the
    /// heading, the active project and its active environment open — and afterwards changes when
    /// a chevron is pressed, → or ← is pressed on the selected branch, or the heading is pressed.
    /// The one change made for them is an opening: a node selected inside a closed parent opens
    /// its ancestors (`revealSelection`), so a node the operator was taken to is never hidden. A
    /// place change, a rebuild or a reopened pane opens nothing once the defaults are laid.
    @ViewBuilder
    private var treeColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row(.editor, label: "Editor", depth: 0)
                row(.organisation, label: tree?.org.label ?? "Organisation", depth: 0)
                row(.providers, label: "Providers", depth: 0, badge: tree.map { "\($0.providers.count)" })

                projectsHeading
                if expansion.projectsOpen {
                    if let tree, tree.projects.isEmpty {
                        emptyLine("no projects")
                    }
                    ForEach(tree?.projects ?? [], id: \.name) { project in
                        let projectOpen = expansion.isOpen(project: project.name)
                        row(
                            .project(project.name), label: project.name, depth: 1,
                            disclosure: .branch(
                                open: projectOpen,
                                identifier: "settings.tree.project.\(project.name).disclosure")
                        ) {
                            expansion.setOpen(!projectOpen, project: project.name)
                        }
                        if projectOpen {
                            row(.projectEditor(project.name), label: "Editor", depth: 2, disclosure: .leaf)
                            ForEach(project.environments, id: \.name) { environment in
                                let environmentOpen = expansion.isOpen(
                                    project: project.name, environment: environment.name)
                                row(
                                    .environment(project: project.name, environment: environment.name),
                                    label: environment.name, depth: 2,
                                    disclosure: .branch(
                                        open: environmentOpen,
                                        identifier: "settings.tree.environment.\(project.name).\(environment.name).disclosure")
                                ) {
                                    expansion.setOpen(
                                        !environmentOpen, project: project.name, environment: environment.name)
                                }
                                if environmentOpen {
                                    row(
                                        .databases(project: project.name, environment: environment.name),
                                        label: "Databases", depth: 3, badge: "\(environment.databases.count)",
                                        disclosure: .leaf)
                                    // The API node is drawn whether or not the
                                    // environment declares an entry, and read-only
                                    // either way. The ninth artboard correction: *What
                                    // is editable* rules the API row read-only on
                                    // Decision 8's amendment, which presumes a row
                                    // exists, and none of the five drawn variants had
                                    // one until it was noticed.
                                    row(
                                        .api(project: project.name, environment: environment.name),
                                        label: "API", depth: 3, disclosure: .leaf)
                                }
                            }
                            addRow(
                                "+ Add an environment", depth: 2, key: "addEnvironment.\(project.name)",
                                identifier: "settings.tree.project.\(project.name).addEnvironment"
                            ) {
                                await addEnvironment(to: project)
                            }
                        }
                    }
                    addRow(
                        "+ Add a project", depth: 1, key: "addProject",
                        identifier: "settings.tree.addProject"
                    ) {
                        addingProject = true
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .contentShape(Rectangle())
        // The keyboard's way to open and close: → opens the selected branch, ← closes it. Taken
        // by the column when a row is clicked, as the editor's file tree takes it.
        .focusable()
        .focused($treeFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: treeKey)
        // Seeding only, on appear and on a place change: once the defaults are laid, neither
        // reopening the pane nor moving the place opens a branch the operator closed (Rule 6).
        .onAppear { seed() }
        .onChange(of: activeProject) { _, _ in seed() }
        .onChange(of: activeEnvironment) { _, _ in seed() }
        // Another organisation's tree: the window forgot the old one's branches, so lay these.
        .onChange(of: tree?.org.id) { _, _ in seed() }
        // A navigation to a node inside a closed parent is the one opening made for the operator.
        .onChange(of: selection) { _, _ in
            revealSelection()
            if let shown = receipt, shown.node != selection { receipt = nil }
        }
    }

    /// The PROJECTS heading: pressing it opens or closes every project at once.
    private var projectsHeading: some View {
        let open = expansion.projectsOpen
        return Button {
            expansion.projectsOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                chevron(open: open)
                Text("PROJECTS")
                    .font(.system(size: Scale.micro, weight: .medium))
                    .tracking(Scale.microTracking)
                    .foregroundStyle(coolWhite.opacity(0.32))
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(coolWhite.opacity(selection == .projects ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Projects, open" : "Projects, closed")
        .accessibilityValue(open ? "projects open" : "projects closed")
        .accessibilityIdentifier("settings.tree.projectsHeading")
    }

    /// A branch's ▾ / ▸, or the empty column a leaf keeps so its label lines up under its parent's.
    private func chevron(open: Bool?) -> some View {
        Group {
            if let open {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(coolWhite.opacity(0.45))
            } else {
                Color.clear
            }
        }
        .frame(width: 10, height: 10)
    }

    /// Lays the defaults if they were never laid; afterwards does nothing, so a place change, a
    /// rebuild or a reopened pane never opens what the operator closed (3a-ii review I3).
    private func seed() {
        expansion.seed(activeProject: activeProject, activeEnvironment: activeEnvironment)
    }

    /// Opens the selected node's ancestors, never the node: a project's heading, an environment's
    /// project, a database's environment. Run only when the selection CHANGES — a navigation —
    /// never on appear, so a selection left inside a branch the operator closed stays hidden.
    private func revealSelection() {
        switch selection {
        case .organisation, .providers, .editor, .projects: return
        case .project: expansion.projectsOpen = true
        case .projectEditor(let project), .environment(let project, _):
            expansion.reveal(project: project)
        case .databases(let project, let environment), .api(let project, let environment):
            expansion.reveal(project: project, environment: environment)
        }
    }

    /// → opens the selected project or environment, ← closes it. Any other key is not the tree's.
    private func treeKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
        let open: Bool
        switch press.key {
        case .rightArrow: open = true
        case .leftArrow: open = false
        default: return .ignored
        }
        switch selection {
        case .project(let project):
            expansion.setOpen(open, project: project)
        case .environment(let project, let environment):
            expansion.setOpen(open, project: project, environment: environment)
        default:
            return .ignored
        }
        return .handled
    }

    /// What a row draws before its label: nothing (the top-level rows), an empty chevron column
    /// (a leaf under a project, so its label lines up with its siblings'), or a branch's chevron.
    private enum Disclosure: Equatable {
        case none
        case leaf
        /// `identifier` is written out at the call site, whole, so the control harvest sees each
        /// family (`settings.tree.project.<…>.disclosure`) rather than one interpolated fragment.
        case branch(open: Bool, identifier: String)
    }

    /// One node. A branch's chevron is its own button, calling `toggle`, beside the row's button,
    /// so opening a branch never selects it and selecting one never opens or closes it.
    private func row(
        _ node: SettingsNode, label: String, depth: Int, badge: String? = nil,
        disclosure: Disclosure = .none, toggle: (() -> Void)? = nil
    ) -> some View {
        let selected = selection == node
        let fragment = node.identifierFragment
        return HStack(spacing: 4) {
            switch disclosure {
            case .none:
                EmptyView()
            case .leaf:
                chevron(open: nil)
            case .branch(let state, let identifier):
                if let toggle {
                    Button(action: toggle) {
                        chevron(open: state)
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, -2)
                    .accessibilityLabel(state ? "Close \(label)" : "Open \(label)")
                    // The state as words, named by the node, so the tree a check reads can say
                    // which branch is open: `environment.e2e-project.qa closed`.
                    .accessibilityValue(state ? "\(fragment) open" : "\(fragment) closed")
                    .accessibilityIdentifier(identifier)
                } else {
                    chevron(open: state)
                }
            }
            Button {
                selection = node
                treeFocused = true
            } label: {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: Scale.door))
                        .foregroundStyle(coolWhite.opacity(selected ? 0.95 : 0.62))
                        .lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.system(size: Scale.meta, design: .monospaced))
                            .foregroundStyle(coolWhite.opacity(0.35))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // **On the Button, not on its label.** A modifier inside the
            // `label:` closure names the content view; the accessibility
            // element the driver resolves is the Button, and it carried no
            // identifier at all. Caught by the check going red on a control
            // that was supposedly named.
            .accessibilityIdentifier("settings.tree.\(fragment)")
        }
        .padding(.leading, CGFloat(depth) * 12 + 8)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(coolWhite.opacity(selected ? 0.08 : 0)))
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Scale.body))
            .foregroundStyle(coolWhite.opacity(0.28))
            .padding(.leading, 20)
            .padding(.vertical, 3)
    }

    /// The tree's live add control (2e-ii), in the place the not-this-phase marker held. In
    /// flight it shows a spinner and cannot be pressed again (Rule 5); a failure is drawn whole
    /// beneath it (Rule 8).
    private func addRow(
        _ label: String, depth: Int, key: String, identifier: String,
        _ act: @escaping () async -> Void
    ) -> some View {
        let busy = lifecycleBusy.contains(key)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    guard !lifecycleBusy.contains(key) else { return }
                    lifecycleBusy.insert(key)
                    lifecycleRefusals[key] = nil
                    Task {
                        await act()
                        lifecycleBusy.remove(key)
                    }
                } label: {
                    Text(label)
                        .font(.system(size: Scale.body))
                        .foregroundStyle(coolWhite.opacity(busy ? 0.35 : 0.62))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier(identifier)
                if busy { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
            }
            if let refusal = lifecycleRefusals[key] {
                Text(refusal)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // After the chevron column its siblings keep, so it reads as one of them.
        .padding(.leading, CGFloat(depth) * 12 + 8 + 14)
        .padding(.vertical, 3)
    }

    /// The node a landing names.
    private func node(for landing: SettingsLanding) -> SettingsNode {
        switch landing {
        case .projects: return .projects
        case .project(let name): return .project(name)
        case .environment(let project, let environment):
            return .environment(project: project, environment: environment)
        }
    }

    /// + Add a project: the folder picker, then the project's page with its Name taking the
    /// keyboard. Cancelling the picker does nothing; the active project never changes (Rule 6).
    private func addProject() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose the project's folder"
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        let created = await createProject(folder)
        if let error = created.error {
            lifecycleRefusals["addProject"] = error
        } else if let name = created.name {
            land(on: node(for: SettingsLanding.afterCreatingProject(name)), focusName: true)
        }
    }

    /// + Add an environment: `wakil-ctx` picks the name; the page opens with it selected.
    private func addEnvironment(to project: SettingsProject) async {
        let created = await createEnvironment(project.name, project.path)
        if let error = created.error {
            lifecycleRefusals["addEnvironment.\(project.name)"] = error
        } else if let name = created.name {
            land(
                on: node(for: SettingsLanding.afterCreatingEnvironment(project: project.name, name: name)),
                focusName: true)
        }
    }

    /// Selects `target` and, for a create, asks its Name field for the keyboard (Rule 3).
    private func land(on target: SettingsNode, focusName: Bool = false) {
        receipt = nil
        pendingNameFocus = focusName ? target : nil
        selection = target
    }

    /// Whether the Name field on `node` has a pending request for the keyboard.
    private func wantsNameFocus(_ node: SettingsNode) -> Binding<Bool> {
        Binding(
            get: { pendingNameFocus == node },
            set: { if !$0, pendingNameFocus == node { pendingNameFocus = nil } })
    }

    /// Saves a project's new name. The selection and the open branches follow it, so a rename
    /// closes nothing and moves the operator nowhere (Rule 6).
    private func rename(project old: String, to new: String) async -> String? {
        if let refusal = await renameProject(old, new) { return refusal }
        selection = selection.renaming(project: old, to: new)
        expansion.renamed(project: old, to: new)
        return nil
    }

    private func rename(project: SettingsProject, environment old: String, to new: String) async -> String? {
        if let refusal = await renameEnvironment(project.name, project.path, old, new) { return refusal }
        selection = selection.renaming(project: project.name, environment: old, to: new)
        expansion.renamed(project: project.name, environment: old, to: new)
        return nil
    }

    /// The Remove control at the foot of a project's or an environment's page: the verb, a
    /// spinner while it runs (Rule 5), and a failure whole beneath it (Rule 8).
    private func removeSection(
        key: String, label: String, identifier: String, hint: String,
        confirmation: String? = nil,
        _ act: @escaping () async -> Void
    ) -> some View {
        let busy = lifecycleBusy.contains(key)
        let run: () -> Void = {
            guard !lifecycleBusy.contains(key) else { return }
            lifecycleBusy.insert(key)
            lifecycleRefusals[key] = nil
            Task {
                await act()
                lifecycleBusy.remove(key)
            }
        }
        return SettingsSection("Remove") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        if confirmation != nil {
                            lifecycleRefusals[key] = nil
                            confirmingRemoval = key
                        } else {
                            run()
                        }
                    } label: {
                        Text(label)
                            .font(.system(size: Scale.body))
                            .foregroundStyle(caution.opacity(busy ? 0.4 : 0.9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityIdentifier(identifier)
                    if busy { ProgressView().controlSize(.small) }
                }
                FormHint(hint)
                if let confirmation, confirmingRemoval == key {
                    // Says what will NOT be destroyed, as the unlink
                    // confirmation does.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(confirmation)
                            .font(.system(size: Scale.body))
                            .foregroundStyle(caution)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            confirmButton("Remove", tone: caution, filled: true,
                                          identifier: "\(identifier).confirm") {
                                confirmingRemoval = nil
                                run()
                            }
                            confirmButton("Keep it", tone: coolWhite.opacity(0.62),
                                          identifier: "\(identifier).keep") {
                                confirmingRemoval = nil
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.top, 4)
                }
                if let refusal = lifecycleRefusals[key] {
                    Text(refusal)
                        .font(.system(size: Scale.body))
                        .foregroundStyle(caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func remove(project: SettingsProject) async {
        if let error = await removeProject(project.name) {
            lifecycleRefusals["remove.project.\(project.name)"] = error
            return
        }
        let target = node(for: SettingsLanding.afterRemovingProject())
        land(on: target)
        receipt = (target, "Removed \(project.name) from this organisation — its folder is untouched.")
    }

    private func remove(environment: String, from project: SettingsProject) async {
        let removed = await removeEnvironment(project.name, project.path, environment)
        if let error = removed.error {
            lifecycleRefusals["remove.environment.\(project.name).\(environment)"] = error
            return
        }
        let target = node(for: SettingsLanding.afterRemovingEnvironment(project: project.name))
        land(on: target)
        if let text = removed.receipt { receipt = (target, text) }
    }

    /// What a removal said, drawn on the page it landed on.
    @ViewBuilder
    private func receiptLine(for node: SettingsNode) -> some View {
        if let receipt, receipt.node == node {
            note(receipt.text, tone: coolWhite.opacity(0.62))
                .accessibilityIdentifier("settings.receipt")
        }
    }

    // MARK: - The subject

    @ViewBuilder
    private var subjectColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            breadcrumb

            // **Only the subject scrolls.** The breadcrumb says where the
            // operator is standing and the footer says where what they are
            // looking at came from; both are claims about the PANE, not
            // about the subject, so they stay put while the thing they
            // describe moves under them.
            //
            // Without this the subject column had no bounded height at
            // all, and a pane is not a window — it is given its size by
            // the layout. The account table is the first subject long
            // enough for that to show: ten rows drew past the bottom of
            // the pane's own slab and over the message field below it,
            // in both placements. The tree column has scrolled since the
            // pane was built; this column is only now long enough to
            // need it.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let failure {
                        // Not an empty pane. A read that failed and a
                        // configuration that is empty are different facts.
                        note(failure, tone: caution)
                    } else if tree == nil {
                        emptyLine("reading…")
                    } else if let tree {
                        subject(of: tree)
                        if tree.hasResidue { residue(of: tree) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 10) {
                Button("Reload", action: reload)
                    .buttonStyle(.plain)
                    .font(.system(size: Scale.body))
                    .accessibilityIdentifier("settings.reload")
                    .foregroundStyle(coolWhite.opacity(0.45))
                Text("read from disk on open and on every read — nothing here is cached")
                    .font(.system(size: Scale.meta))
                    .foregroundStyle(coolWhite.opacity(0.26))
            }
        }
    }

    private var breadcrumb: some View {
        Text(selection.breadcrumb(in: tree).joined(separator: "  ›  "))
            .font(.system(size: Scale.micro, weight: .medium))
            .tracking(Scale.microTracking)
            .foregroundStyle(coolWhite.opacity(0.40))
            .lineLimit(1)
            .accessibilityIdentifier("settings.breadcrumb")
    }

    @ViewBuilder
    private func subject(of tree: SettingsTree) -> some View {
        switch selection {
        case .organisation:
            // Four headed sections (2026-10-21), each a hairline, a micro header and its rows.
            SettingsSection("Identity") {
                // The id is the directory name, so there is one place it can
                // be written and no way for the two to disagree. Not a
                // setting, and drawn as the fact it is.
                SettingsRow("ID") { SettingsValue(text: tree.org.id) }
                organisationEditor(.displayName, label: "Display name", in: tree)
            }
            SettingsSection("Accounts") {
                organisationEditor(.defaultProvider, label: "Default", in: tree)
                speechRow(tree: tree)
            }
            SettingsSection("Jira") {
                organisationEditor(.jiraBase, label: "Site", in: tree)
            }
            // 3a-ii: who commits from the Changes view.
            SettingsSection("Git") {
                // Who commits are by (3a-ii) — not who may push, which the accounts below are.
                authorRow(in: tree)
                FormHint("Who Wakil's commits are by; empty uses your git config.")
                    .underRowValue()
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                // 3a-iii: the accounts pushes and pulls use, and how Pull and Sync integrate.
                SettingsRow("Accounts", wraps: true) { GitAccountsBlock(org: tree.org, git: git) }
                SettingsRow("Pull strategy") { pullStrategyChoice(tree) }
            }
            // 3a-iii-b: the agent follows these after Wakil's own rules; ✨ drafts with Commits.
            SettingsSection("Agent instructions") {
                FormHint("The agent follows these after Wakil's own rules, from its next turn. ✨ uses Commits.")
                    .padding(.bottom, 6)
                organisationBox(.agentGeneral, placeholder: Self.generalPlaceholder,
                                identifier: "settings.org.agent.general", in: tree)
                organisationBox(.gitCommitInstructions, placeholder: Self.commitsPlaceholder,
                                identifier: "settings.org.git.commits", in: tree)
                organisationBox(.gitPRInstructions, placeholder: Self.pullRequestsPlaceholder,
                                identifier: "settings.org.git.pullRequests", in: tree)
            }
            readOnlyNote(
                "Saved one field at a time, read-modify-write from disk — so an edit you make "
                    + "to org.json by hand while this pane is open survives a save here.")

        case .providers:
            // Three headed sections (2026-10-21): the accounts, the local models, and the choice
            // quick tasks make between them — after both, so what it chooses from is read first.
            SettingsSection("Accounts") {
                // The subject column's own spacing, which the table's notes and rows were drawn in.
                VStack(alignment: .leading, spacing: 10) { accountTable() }
            }
            SettingsSection("Local models") {
                LocalProvidersSection(
                    providers: tree.providers, status: quickStatus,
                    save: { id, label, url in
                        let refusal = await saveLocalProvider(id, label, url)
                        quickStatus = await quickTaskStatus()
                        return refusal
                    },
                    remove: { id in
                        let refusal = await removeLocalProvider(id)
                        quickStatus = await quickTaskStatus()
                        return refusal
                    })
            }
            SettingsSection("Quick tasks", accessory: { QuickTasksAboutButton() }) {
                quickTasksRow(tree: tree)
            }
        case .editor:
            EditorAppSettingsForm(editor: tree.editor, error: tree.editorError, save: saveEditorSettings)
        case .projectEditor(let name):
            if let project = tree.projects.first(where: { $0.name == name }) {
                EditorProjectSettingsForm(
                    editor: project.editor,
                    save: { fields in await saveProjectEditorSettings(project.path, fields) }
                )
                // Row drafts and refusals are @State: key the form to its project so they do not
                // carry from one project's Editor node to another's.
                .id(project.path)
            } else {
                gone(name)
            }
        case .project(let name):
            if let project = tree.projects.first(where: { $0.name == name }) {
                // Two groups, two headed sections (2026-10-21): what the project is, and its roots.
                receiptLine(for: .project(name))
                SettingsSection("Project") {
                    LifecycleNameField(
                        stored: project.name, identifier: "settings.project.name",
                        wantsFocus: wantsNameFocus(.project(name)),
                        save: { new in await rename(project: name, to: new) },
                        unseen: showUnseenRefusal)
                    .id("name.\(project.path)")
                    fields([("File", project.path, true)])
                }
                // 3a-iii-b: this project's own instructions, after the organisation's.
                SettingsSection("Agent instructions") {
                    FormHint("This project's own, after the organisation's. The agent has them from its next turn.")
                        .padding(.bottom, 6)
                    projectBox("General", stored: project.agent.general, placeholder: Self.generalPlaceholder,
                               identifier: "settings.project.agent.general", project: project) { path, text in
                        await saveProjectAgentInstructions(path, text, nil, nil)
                    }
                    projectBox("Commits", stored: project.agent.commits, placeholder: Self.commitsPlaceholder,
                               identifier: "settings.project.agent.commits", project: project) { path, text in
                        await saveProjectAgentInstructions(path, nil, text, nil)
                    }
                    projectBox("Pull requests", stored: project.agent.pullRequests,
                               placeholder: Self.pullRequestsPlaceholder,
                               identifier: "settings.project.agent.pullRequests", project: project) { path, text in
                        await saveProjectAgentInstructions(path, nil, nil, text)
                    }
                }
                if !project.roots.isEmpty {
                    SettingsSection("Roots") {
                        // A root's role is its label, its path the value; a root with no role
                        // is labelled as what it is.
                        ForEach(project.roots, id: \.path) { root in
                            SettingsRow(root.role.isEmpty ? "Root" : root.role) {
                                SettingsValue(text: root.path)
                            }
                        }
                    }
                }
                removeSection(
                    key: "remove.project.\(project.name)", label: "Remove from this organisation",
                    identifier: "settings.project.remove",
                    hint: "The project leaves this organisation's list. Its folder and project.json are left alone.",
                    confirmation: "Remove \(project.name) from this organisation? Its folder and project.json "
                        + "stay on disk; adding the folder again brings it back."
                ) { await remove(project: project) }
            } else {
                gone(name)
            }

        case .projects:
            receiptLine(for: .projects)
            if receipt?.node != .projects {
                readOnlyNote("Choose a project, or add one from the tree.")
            }

        case .environment(let projectName, let environmentName):
            if let environment = environment(projectName, environmentName, in: tree) {
                if let project = tree.projects.first(where: { $0.name == projectName }) {
                    LifecycleNameField(
                        stored: environment.name, identifier: "settings.environment.name",
                        wantsFocus: wantsNameFocus(.environment(project: projectName, environment: environmentName)),
                        save: { new in await rename(project: project, environment: environmentName, to: new) },
                        unseen: showUnseenRefusal)
                    .id("name.\(project.path).\(environmentName)")
                }
                fields([
                    ("Databases", "\(environment.databases.count)", true),
                    // A COUNT, like `Databases` above it, because the API
                    // became a list of named entries in 2c-iv. Naming one
                    // of several would be the surface choosing which
                    // matters; the count is the honest summary and the
                    // entries are read below.
                    ("API", "\(environment.api.count)", true),
                ])
                readOnlyNote(
                    "An environment holds the databases and the API — which is why this tree "
                        + "is four levels deep and not three.")
                if let project = tree.projects.first(where: { $0.name == projectName }) {
                    removeSection(
                        key: "remove.environment.\(projectName).\(environmentName)",
                        label: "Remove environment", identifier: "settings.environment.remove",
                        hint: "Its file goes to the Trash, so it can be put back.",
                        confirmation: "Remove \(environmentName) from \(project.name)? A copy of project.json "
                            + "goes to the Trash first; Put Back returns it beside project.json."
                    ) { await remove(environment: environmentName, from: project) }
                }
            } else {
                gone(environmentName)
            }

        case .databases(let projectName, let environmentName):
            if let environment = environment(projectName, environmentName, in: tree) {
                if environment.databases.isEmpty {
                    emptyLine("no databases in this environment")
                }
                ForEach(environment.databases, id: \.name) { database in
                    // A row like the account table's (#327): what it is on
                    // the left, its one verb on the right edge.
                    HStack(alignment: .center, spacing: Scale.columnGap) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(database.name)
                                    .font(.system(size: Scale.identifier, design: .monospaced))
                                    .foregroundStyle(coolWhite.opacity(0.90))
                                Chip(text: database.driver, tone: coolWhite.opacity(0.62))
                                if database.writable { Chip(text: "writable", tone: caution) }
                            }
                            // The reference, never the value: the Keychain
                            // entry NAME. The secret it names is read by
                            // the driver at query time and by nothing here.
                            Text(database.writeRef.isEmpty
                                ? "read \(database.ref)"
                                : "read \(database.ref)   ·   write \(database.writeRef)")
                                .font(.system(size: Scale.meta, design: .monospaced))
                                .foregroundStyle(coolWhite.opacity(0.34))
                        }
                        Spacer(minLength: 0)
                        // **No confirmation, and that is a ruling.**
                        // Removing a database KEEPS its Keychain entry, so
                        // nothing is destroyed, and the pane-local
                        // confirmation list is destructive-only.
                        rowAction("Remove", tone: coolWhite.opacity(0.52),
                                  identifier: "settings.db.\(database.name).remove") {
                            let path = tree.projects
                                .first { $0.name == projectName }?.path ?? ""
                            databaseRefusal = nil
                            Task {
                                databaseRefusal = await removeDatabase(
                                    path, environmentName, database.name)
                            }
                        }
                    }
                    .frame(minHeight: Scale.rowHeight, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(coolWhite.opacity(0.06)).frame(height: 0.5)
                    }
                }
                databaseForm(project: projectName, environment: environmentName, in: tree)
            } else {
                gone(environmentName)
            }

        case .api(let projectName, let environmentName):
            if let environment = environment(projectName, environmentName, in: tree) {
                if environment.api.isEmpty {
                    emptyLine("this environment declares no API entries")
                } else {
                    // One block per entry, keyed by NAME — which is what a
                    // request records, so the same request can run against
                    // staging and then production (2c-iv).
                    ForEach(environment.api, id: \.name) { api in
                        // A section per entry, headed by its name (2026-10-21).
                        SettingsSection(api.name.isEmpty ? "unnamed" : api.name) {
                            fields([
                                ("Base URL", api.baseUrl, true),
                                ("Auth ref", api.authRef.isEmpty ? "none" : api.authRef, true),
                            ])
                        }
                    }
                }
                // Permanently read-only, and this merge is the argument
                // for it: the shape changed under this pane while it sat
                // in a branch, exactly as the note predicted, and the cost
                // was a list where a value had been — not a form to
                // rewrite.
                readOnlyNote(
                    "The API entries are read-only, and stay so: this shape changed once "
                        + "already while this pane was being built, and a form built on "
                        + "today's is one rebuilt on someone else's schedule.")
            } else {
                gone(environmentName)
            }
        }
    }

    /// An organisation field edited where it stands: empty, it reads its prompt; the field is there
    /// all along, so a click edits it in place.
    private func organisationField(
        _ field: WindowModel.OrganisationField, prompt: String, width: CGFloat, in tree: SettingsTree
    ) -> some View {
        let stored = storedValue(field, in: tree)
        let draft = drafts[field]
        return TextField(
            "",
            text: Binding(
                get: { draft ?? stored },
                set: { drafts[field] = $0 }),
            prompt: Text(prompt).foregroundStyle(coolWhite.opacity(0.30)))
            .textFieldStyle(.plain)
            .font(.system(size: Scale.body))
            .foregroundStyle(coolWhite.opacity(0.88))
            .frame(maxWidth: width)
            .inPlaceField(focused: focusedOrgField == field)
            .onSubmit { save(field, tree: tree) }
            .focused($focusedOrgField, equals: field)
            // 3a-ii, Rule 2: Git name and email save when the field is left, through Save's
            // path. A Return that saved already cleared the draft (or is still saving), so
            // leaving after it writes nothing twice. The other fields keep Return / Save.
            .onChange(of: focusedOrgField) { old, _ in
                guard old == field else { return }
                autosave.cancel()
                leave(field, tree: tree)
            }
            .onChange(of: drafts[field]) { _, draft in
                guard field.savesOnLeave, draft != nil else { return }
                autosave.schedule { leave(field, tree: tree) }
            }
            // Leaving the page by the tree is leaving the field too, and the focus change
            // above is never reported once the page is gone (2e-ii) — so going is a leave.
            .onAppear { if field.savesOnLeave { gitFieldsShown.fields.insert(field) } }
            .onDisappear {
                gitFieldsShown.fields.remove(field)
                leave(field, tree: tree)
            }
            .accessibilityIdentifier("settings.org.\(field.identifierFragment)")
    }

    /// Who Wakil's commits are by: the name and the email on one row, each saved when left (Rule 2).
    private func authorRow(in tree: SettingsTree) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow("Author") {
                HStack(spacing: 10) {
                    organisationField(.gitName, prompt: "Name", width: 170, in: tree)
                    organisationField(.gitEmail, prompt: "email@example.com", width: 240, in: tree)
                }
            }
            ForEach([WindowModel.OrganisationField.gitName, .gitEmail], id: \.self) { field in
                if let refusal = refusals[field] {
                    Text(refusal)
                        .font(.system(size: Scale.body))
                        .foregroundStyle(caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .underRowValue()
                        .padding(.vertical, 4)
                }
            }
        }
    }

    /// One editable string of the organisation record.
    ///
    /// **Edits render on the pane; this phase adds no new modal.** The
    /// refusal sits under the field that caused it, which is the whole
    /// reason `saveOrganisationField` answers a sentence rather than
    /// writing to the window's status line: a message about the Jira site
    /// belongs under the Jira site.
    @ViewBuilder
    private func organisationEditor(
        _ field: WindowModel.OrganisationField, label: String, in tree: SettingsTree
    ) -> some View {
        let stored = storedValue(field, in: tree)
        let draft = drafts[field]
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(label) {
                HStack(spacing: 8) {
                    organisationField(field, prompt: "—", width: 320, in: tree)
                    if draft != nil, draft != stored {
                        Button(saving == field ? "Saving…" : "Save") { save(field, tree: tree) }
                            .buttonStyle(.plain)
                            .font(.system(size: Scale.body))
                            .foregroundStyle(coolWhite.opacity(saving == field ? 0.35 : 0.70))
                            .disabled(saving == field)
                            .accessibilityIdentifier("settings.org.\(field.identifierFragment).save")
                        // Revert is the escape from a typed value the
                        // operator has changed their mind about. It clears
                        // the draft rather than writing anything, so the
                        // field goes back to showing disk.
                        Button("Revert") { drafts[field] = nil; refusals[field] = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: Scale.body))
                            .foregroundStyle(coolWhite.opacity(0.40))
                            .accessibilityIdentifier("settings.org.\(field.identifierFragment).revert")
                    }
                }
            }
            if let refusal = refusals[field] {
                Text(refusal)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .underRowValue()
                    .padding(.vertical, 4)
            }
        }
    }

    // 3a-iii-b: examples of what a box holds, read as its placeholder.
    private static let generalPlaceholder = "Tell the agent how to work here — e.g. ask before running migrations"
    private static let commitsPlaceholder = "Tell the agent how to write commits — e.g. imperative subject under 72 characters"
    private static let pullRequestsPlaceholder = "Tell the agent how to write pull requests — e.g. what changed and why, then how to test"

    /// An organisation's agent box, saved through the organisation's one-field write. Keyed to the
    /// organisation so a draft does not carry from one organisation's page to another's.
    private func organisationBox(
        _ field: WindowModel.OrganisationField, placeholder: String, identifier: String, in tree: SettingsTree
    ) -> some View {
        AgentInstructionBox(
            label: field.label, stored: storedValue(field, in: tree), placeholder: placeholder,
            identifier: identifier, save: { await saveOrganisationField(field, $0, tree.org.id) }, unseen: showUnseenRefusal)
            .id("\(identifier).\(tree.org.id)")
    }

    /// A project's agent box, keyed to the project for the same reason.
    private func projectBox(
        _ label: String, stored: String, placeholder: String, identifier: String,
        project: SettingsProject, save: @escaping (String, String) async -> String?
    ) -> some View {
        AgentInstructionBox(
            label: label, stored: stored, placeholder: placeholder, identifier: identifier,
            save: { await save(project.path, $0) }, unseen: showUnseenRefusal)
            .id("\(identifier).\(project.path)")
    }

    /// 2d-ii: the organisation's speech engine (Invariant 11). One segment
    /// per registered engine; a stored id no engine answers to is drawn as
    /// a held segment, with the registry's note beneath it (rule 7).
    private func speechRow(tree: SettingsTree) -> some View {
        let registry = SpeechRegistry.standard(environment: ProcessInfo.processInfo.environment)
        let stored = tree.org.speechProvider
        let engines = registry.engines
        let current = stored.isEmpty ? SpeechRegistry.defaultId : stored
        let known = engines.first(where: { $0.id == current })
        func idFor(_ name: String) -> String { engines.first(where: { $0.name == name })?.id ?? name }
        return VStack(alignment: .leading, spacing: 2) {
            SettingsRow("Speech", wraps: true) {
                SegmentedChoice(
                    options: engines.map(\.name),
                    selection: Binding(
                        get: { known?.name ?? current },
                        set: { name in
                            let id = idFor(name)
                            guard id != current else { return }
                            drafts[.speechProvider] = id
                            save(.speechProvider, tree: tree)
                        }),
                    // Hoisted: the identifier harvest reads `\(…)` up to the first
                    // `)`, so a call inside the literal harvested as
                    // `settings.org.speechProvider.<…>)` — a family no check could
                    // ever name, and so a control the coverage gate could never see
                    // covered.
                    identifier: { name in
                        let id = idFor(name)
                        return "settings.org.speechProvider.\(id)"
                    },
                    held: known == nil ? current : nil)
            }
            if let note = registry.note(for: stored) {
                Text(note)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .underRowValue()
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("settings.org.speechProvider.note")
            }
            if let refusal = refusals[.speechProvider] {
                Text(refusal).font(.system(size: Scale.body)).foregroundStyle(caution)
                    .underRowValue()
                    .padding(.vertical, 4)
            }
        }
    }

    /// 3b-viii: the provider quick tasks run on, as a dropdown. One item per provider that serves
    /// anything, "Same as agent" first; a stored id no provider answers to is held as the label,
    /// not dropped (Rule 7).
    private func quickTasksRow(tree: SettingsTree) -> some View {
        let options = quickTaskChoices(tree)
        let stored = tree.org.quickProvider
        let known = options.first(where: { $0.id == stored })
        let localIds = Set(tree.providers.filter { $0.kind == "local" }.map(\.id))
        func isLocal(_ id: String) -> Bool { localIds.contains(id) }
        // Under its section's header (`SettingsSection`), which carries the ⓘ.
        return VStack(alignment: .leading, spacing: 4) {
            // One table row, as the local models under it are drawn: the choice as plain text with
            // a chevron (the system's menu chrome would be the only bezel on the page), and where
            // code completion goes beside it.
            HStack(alignment: .firstTextBaseline, spacing: Scale.columnGap) {
                Text("Model")
                    .font(.system(size: Scale.body, weight: .medium))
                    .foregroundStyle(coolWhite.opacity(0.86))
                    .frame(width: Scale.labelWidth, alignment: .leading)
                // Same as agent, then the accounts, then the local models, each group headed.
                Menu {
                    quickTaskItems(options.filter { $0.id.isEmpty }, stored: stored, tree: tree)
                    Divider()
                    // Headed by disabled items, not `Section`: a menu item inside a SwiftUI
                    // Section loses its accessibility identifier (measured by the e2e, 2026-10-20).
                    Text("Accounts")
                    quickTaskItems(options.filter { !$0.id.isEmpty && !isLocal($0.id) }, stored: stored, tree: tree)
                    Divider()
                    Text("Local models")
                    quickTaskItems(options.filter { isLocal($0.id) }, stored: stored, tree: tree)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(known?.display ?? stored)
                            .font(.system(size: Scale.body, weight: .medium))
                            .foregroundStyle(coolWhite.opacity(0.86))
                        // Decoration: drawn, but not a second menu button carrying the same id.
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(coolWhite.opacity(0.40))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("settings.org.quickProvider")
                if let route = quickTaskRouteLine(tree, routed: quickStatus?.routedInfill) {
                    Text(route)
                        .font(.system(size: Scale.meta))
                        .foregroundStyle(coolWhite.opacity(0.40))
                        .lineLimit(1)
                        .accessibilityIdentifier("settings.org.quickProvider.route")
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Scale.rowHeight, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(coolWhite.opacity(0.06)).frame(height: 0.5) }
            quickTaskSwitchRow(
                "Ghost-text", hint: "suggestions as you type", on: tree.org.ghostText, key: .ghostText)
            quickTaskSwitchRow(
                "Fast path", hint: fastPathHint(tree), on: tree.org.fastPath, key: .fastPath)
            quickTaskSwitchRow(
                "Commit drafts", hint: "Drafts a message from what you are about to commit, when you press ✨",
                on: tree.org.commitDrafts, key: .commitDrafts)
            if let note = quickTaskNote(tree, activeProvider: runningAccountId) {
                Text(note)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .accessibilityIdentifier("settings.org.quickProvider.note")
            }
            if let configError = quickStatus?.configError {
                Text(configError)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.org.quickProvider.configError")
            }
            // The provider code completion goes to first, when its last call failed: the error
            // whole (Rule 8), whatever kind it is — a local row repeats it under its URL.
            if let routed = quickStatus?.routedInfill, let error = quickStatus?.errors[routed] {
                Text(error)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.org.quickProvider.error")
            }
            if let refusal = refusals[.quickProvider] {
                Text(refusal)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.org.quickProvider.refusal")
            }
        }
        .padding(.bottom, 4)
    }

    /// One Off/On row under QUICK TASKS, written on click (Rule 2) and kept where it stands (Rule 6).
    private func quickTaskSwitchRow(
        _ label: String, hint: String, on: Bool, key: WindowModel.OrganisationSwitch
    ) -> some View {
        let name = key.rawValue
        let refusalKey = name
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: Scale.columnGap) {
                Text(label)
                    .font(.system(size: Scale.body, weight: .medium))
                    .foregroundStyle(coolWhite.opacity(0.86))
                    .frame(width: Scale.labelWidth, alignment: .leading)
                SegmentedChoice(
                    options: ["Off", "On"],
                    selection: Binding(
                        get: { on ? "On" : "Off" },
                        set: { option in
                            let want = option == "On"
                            guard want != on else { return }
                            Task {
                                switchRefusals[refusalKey] = await saveOrganisationSwitch(key, want)
                                quickStatus = await quickTaskStatus()
                            }
                        }),
                    identifier: { option in
                        let side = option.lowercased()
                        return "settings.org.\(name).\(side)"
                    })
                Text(hint)
                    .font(.system(size: Scale.meta))
                    .foregroundStyle(coolWhite.opacity(0.40))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Scale.rowHeight, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(coolWhite.opacity(0.06)).frame(height: 0.5) }
            if let refusal = switchRefusals[refusalKey] {
                Text(refusal)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.org.\(name).refusal")
            }
        }
    }

    /// One Quick tasks menu item per option, named `settings.org.quickProvider.<id>` (`same` for
    /// Same as agent).
    private func quickTaskItems(
        _ options: [(id: String, display: String)], stored: String, tree: SettingsTree
    ) -> some View {
        ForEach(options, id: \.id) { option in
            let key = option.id.isEmpty ? "same" : option.id
            Button(option.display) {
                guard option.id != stored else { return }
                drafts[.quickProvider] = option.id
                save(.quickProvider, tree: tree)
            }
            .accessibilityIdentifier("settings.org.quickProvider.\(key)")
        }
    }

    /// Merge · Rebase · Fast-forward only, saved on click (Rule 2), Rebase by default (Rule 9).
    private func pullStrategyChoice(_ tree: SettingsTree) -> some View {
        let labels = ["rebase": "Rebase", "merge": "Merge", "ff-only": "Fast-forward only"]
        return SegmentedChoice(
            options: ["Rebase", "Merge", "Fast-forward only"],
            selection: Binding(
                get: { labels[tree.org.pullStrategy] ?? "Rebase" },
                set: { label in
                    guard let value = labels.first(where: { $0.value == label })?.key, value != tree.org.pullStrategy else { return }
                    Task { _ = await saveOrganisationField(.pullStrategy, value, tree.org.id) }
                }),
            identifier: { label in
                let value = labels.first(where: { $0.value == label })?.key ?? label
                return "settings.org.git.pullStrategy.\(value)"
            })
    }

    private func storedValue(
        _ field: WindowModel.OrganisationField, in tree: SettingsTree
    ) -> String {
        switch field {
        case .displayName: return tree.org.displayName
        case .jiraBase: return tree.org.jiraBase
        case .defaultProvider: return tree.org.defaultProvider
        case .speechProvider: return tree.org.speechProvider
        case .quickProvider: return tree.org.quickProvider
        // Drawn under GIT, not in the generic list (3a-ii).
        case .gitName: return tree.org.gitName
        case .gitEmail: return tree.org.gitEmail
        case .pullStrategy: return tree.org.pullStrategy
        // Drawn as multi-line boxes under AGENT and GIT (3a-iii-b).
        case .agentGeneral: return tree.org.agentGeneral
        case .gitCommitInstructions: return tree.org.gitCommitInstructions
        case .gitPRInstructions: return tree.org.gitPRInstructions
        }
    }

    /// A Git field left — focus moved on, or its page went: saves a changed draft (Rule 2).
    private func leave(_ field: WindowModel.OrganisationField, tree: SettingsTree) {
        guard field.savesOnLeave,
              LeaveSave.value(draft: drafts[field], stored: storedValue(field, in: tree),
                              saving: saving == field, refused: refusedDrafts[field]) != nil else { return }
        save(field, tree: tree)
    }

    private func save(_ field: WindowModel.OrganisationField, tree: SettingsTree) {
        guard let value = drafts[field], saving != field else { return }
        saving = field
        refusals[field] = nil
        let shown = gitFieldsShown
        Task {
            let refusal = await saveOrganisationField(field, value, tree.org.id)
            // The draft is cleared only on success, so a refused value
            // stays in front of the operator to be corrected rather than
            // vanishing along with the explanation of why it was refused.
            // Cleared WITH `saving`, before the await below: a leave in
            // between would otherwise see a draft and no write in flight,
            // and send the same value again.
            // Not when more was typed while it saved: that stays, to be the next save.
            if refusal == nil, drafts[field] == value { drafts[field] = nil }
            refusedDrafts[field] = refusal == nil ? nil : value
            saving = nil
            refusals[field] = refusal
            if let refusal, field.savesOnLeave, !shown.fields.contains(field) { showUnseenRefusal(refusal) }
            // Typed on while it saved: that is the next save.
            if refusal == nil, field.savesOnLeave, drafts[field] != nil { autosave.schedule { leave(field, tree: tree) } }
            quickStatus = await quickTaskStatus()
        }
    }

    // MARK: - The account table

    /// **One flat table with kind as a COLUMN**, not a kind-headed layout
    /// (#200). A kind-headed one would make the pane teach the wrong word:
    /// §9 defines *Provider* as the credential and does not define *Kind*
    /// at all.
    ///
    /// **An account registered in another organisation is a row in this
    /// same table**, so adopting it later (#201) is a gesture rather than
    /// a search.
    @ViewBuilder
    private func accountTable() -> some View {
        // In flight, the band leads — a browser trip is the only thing
        // happening and the table behind it is context. Idle, the doors
        // belong BELOW the list, which is the order `Settings.dc.html`
        // draws: what is registered, and then how to add to it.
        loginBand()
        if let accounts {
            if accounts.keychainUnavailable {
                // One line about the MACHINE, not a broken badge per row.
                // "Every account here is missing its credential" is the
                // most alarming and least true thing this pane could say.
                note(
                    "The Keychain tool could not be run, so no credential could be checked. "
                        + "Nothing below is a statement about your accounts.",
                    tone: caution)
            } else if !accounts.credentialLess.isEmpty {
                // **Named from a CHECK, not from session history.** The
                // organisation plane's warning fired on "an adoption
                // happened this session", so it was right by luck and
                // silent on relaunch; it is deleted rather than left
                // alongside this.
                note(
                    "\(accounts.credentialLess.count) binding(s) in this organisation have no "
                        + "stored credential: "
                        + accounts.credentialLess.map(\.accountId).joined(separator: ", ")
                        + ". A session cannot start under one until it is repaired.",
                    tone: caution)
            }
            if !accounts.credentialLessElsewhere.isEmpty {
                // **Named, not drawn as rows.** Scoping the table to this
                // organisation must not re-open the hole #200 closed: the
                // organisation plane's own warning was deleted because
                // this pane replaced it, and on this machine all four
                // credential-less bindings belong to other organisations.
                // Repairing one is a gesture in the organisation that
                // holds it, so this says which — and stops there.
                note(
                    "\(accounts.credentialLessElsewhere.count) binding(s) in other "
                        + "organisations have no stored credential: "
                        + accounts.credentialLessElsewhere
                            .map { "\($0.org)/\($0.accountId)" }
                            .joined(separator: ", ")
                        + ". Switch to that organisation to repair one.",
                    tone: coolWhite.opacity(0.45))
            }
            if !accounts.skipped.isEmpty {
                note("could not read: " + accounts.skipped.joined(separator: ", "), tone: caution)
            }

            if let unlinkReport {
                VStack(alignment: .leading, spacing: 3) {
                    // **The permanent sentence, every time.** Removing the
                    // stored item is not revoking the credential it held.
                    ForEach(unlinkReport.notes, id: \.self) { note in
                        Text(note)
                            .font(.system(size: Scale.body))
                            .foregroundStyle(coolWhite.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if unlinkReport.wasLastBinding {
                        // **An offer, never automatic**, and it warns that
                        // the CLI reports success even when it revoked
                        // nothing.
                        Text(UnlinkWording.revocationOffer)
                            .font(.system(size: Scale.body))
                            .foregroundStyle(caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !unlinkReport.backfilled.isEmpty {
                        Text("Kept working: " + unlinkReport.backfilled.joined(separator: ", "))
                            .font(.system(size: Scale.meta))
                            .foregroundStyle(coolWhite.opacity(0.34))
                    }
                    Button("Dismiss") { self.unlinkReport = nil }
                    .accessibilityIdentifier("settings.unlink.dismiss")
                        .buttonStyle(.plain)
                        .font(.system(size: Scale.body))
                        .foregroundStyle(coolWhite.opacity(0.45))
                }
                .padding(.vertical, 6)
            }

            let mineIds = Set(accounts.accounts.filter(\.mine).map(\.accountId))
            let strip = capacity.filter { mineIds.contains($0.account) }
            if !strip.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(strip) { reading in
                            CapacityRows(readings: [reading], inUse: runningAccountId, now: Date())
                        }
                    }
                    .padding(.bottom, 14)
                }
                .accessibilityIdentifier("settings.capacity.strip")
            }

            // **This organisation's bindings, and no others (#236).** The
            // table used to draw every binding on the machine, which on
            // this one is ten rows for three accounts — five of them
            // called `main`, spanning all three. Other organisations'
            // accounts are behind the Adopt door below, where the
            // operator is choosing rather than reading.
            let mine = accounts.accounts.filter(\.mine)
            // **A table where it fits, a list where it does not (2026-10-21).** The four columns
            // are fixed so their labels stay over them, and together they are wider than the
            // subject column of a pane at its 640pt default — so there each account is drawn as
            // its identity and then KIND, CREDENTIAL and SIGN-IN as labelled lines, the column
            // labels moving beside the values they name. The wide branch states its width, so the
            // choice turns on the columns and never on how long a note under a row happens to be.
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 10) {
                    accountTableHeader()
                    accountRows(mine, stacked: false)
                }
                .frame(minWidth: Self.accountTableWidth, idealWidth: Self.accountTableWidth,
                       maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    accountRows(mine, stacked: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if login.offersAddDoors { addAccountRow() }

            // The one sentence the surface owes about what liveness IS.
            // Without it a red row reads as a broken session, which it is
            // not: a lapsed sign-in still launches sessions, because the
            // MINTED TOKEN is what launches them.
            note(
                "Liveness describes your browser SIGN-IN, not the minted token. A lapsed "
                    + "sign-in still launches sessions — the token is what does that — so a red "
                    + "row means \"sign in again\", never \"this account is broken\".",
                tone: coolWhite.opacity(0.34))
        } else {
            emptyLine("reading…")
        }
    }

    // MARK: - The in-flight band (#202)

    /// **A persistent band on the pane, not a modal**, so the rest of
    /// settings stays visible while a browser trip runs — and so the
    /// operator can see what they are adding it to.
    ///
    /// **The band's chrome is justified conditionally**: databases share
    /// this pane, so if providers ever become the whole pane the band
    /// should go. That is why they share it rather than shipping later.
    @ViewBuilder
    private func loginBand() -> some View {
        switch login {
        case .idle:
            // Drawn after the table instead — see `accountTable`.
            EmptyView()

        case .preflight(let offer):
            band {
                // **The cost, before anything happens.** An operator told
                // after the fact that this takes a minute has already
                // spent it.
                Text(offer.sentence)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                if offer.existing.namesSomebody {
                    // **Re-entry shows the identity BEFORE reusing it**,
                    // which closes a misidentification hazard: nothing
                    // guarantees the second `acme` is the same human, and
                    // the operator is never silently continued as an
                    // account that is not theirs.
                    Text("This directory is already signed in as \(offer.existing.email)"
                        + (offer.existing.orgName.isEmpty ? "." : " (\(offer.existing.orgName))."))
                        .font(.system(size: Scale.body))
                        .foregroundStyle(coolWhite.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    confirmButton(
                        offer.existing.namesSomebody
                            ? "Continue as \(offer.existing.email)" : "Sign in",
                        tone: coolWhite.opacity(0.88), filled: true,
                        identifier: "settings.login.start")
                    {
                        Task { await startLogin() }
                    }
                    if offer.existing.namesSomebody {
                        // **The way out of a stale sign-in**, and it asks
                        // for no confirmation: it escalates nothing and is
                        // undone by the gesture that did it.
                        confirmButton(
                            "Sign in as someone else", tone: coolWhite.opacity(0.62),
                            identifier: "settings.login.someoneElse")
                        {
                            Task { await signInAsSomeoneElse() }
                        }
                    }
                    confirmButton("Not now", tone: coolWhite.opacity(0.50),
                                  identifier: "settings.login.notNow") {
                        Task { await dismissLogin() }
                    }
                }
                .padding(.top, 2)
            }

        case .signingIn(let trip, let total, let id):
            band {
                HStack(spacing: 8) {
                    // Which trip, so a long wait reads as progress rather
                    // than as a hang.
                    Text("Trip \(trip) of \(total)")
                        .font(.system(size: Scale.micro, weight: .medium)).tracking(Scale.microTracking)
                        .foregroundStyle(coolWhite.opacity(0.45))
                    Text("Signing in as \(id) — finish in your browser.")
                        .font(.system(size: Scale.body))
                        .foregroundStyle(coolWhite.opacity(0.72))
                }
                // **Trip 1's cancel is free, always offered, and says so.**
                // The only provably clean cancel in the flow.
                if login.offersCancel {
                Button("Cancel — nothing has been created") {
                        Task { await cancelLogin() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.45))
                    .accessibilityIdentifier("settings.login.cancel")
                }
            }

        case .signedIn(let identity, let id):
            band {
                Text(identity.namesSomebody
                    ? "Signed in as \(identity.email). The long-lived credential is next."
                    : "Signed in as \(id). The long-lived credential is next.")
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                // **No pause, and no control.** The session advances
                // straight to the mint (#101, confirmed on #203), so this
                // band is on screen only for as long as that takes to
                // start — a Continue button here would cost two app
                // switches to reach an exit the browser already offers.
                Text("Continuing to the credential step…")
                    .font(.system(size: Scale.meta))
                    .foregroundStyle(coolWhite.opacity(0.34))
            }

        case .minting(let trip, let total, let id):
            band {
                HStack(spacing: 8) {
                    Text("Trip \(trip) of \(total)")
                        .font(.system(size: Scale.micro, weight: .medium)).tracking(Scale.microTracking)
                        .foregroundStyle(coolWhite.opacity(0.45))
                    Text("Creating the long-lived credential for \(id) — approve it in your "
                        + "browser.")
                        .font(.system(size: Scale.body))
                        .foregroundStyle(coolWhite.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // **Still no CANCEL — what is offered is a way to stop
                // WAITING** (#240). The old ruling stands on its own
                // terms: a cancel here would claim to undo a one-year
                // credential printed once and kept nowhere, and nothing
                // can. What the ruling assumed is what broke — that this
                // step either finishes or times out promptly. Spawned on
                // a pipe the CLI printed nothing, so the operator sat
                // here for the full five minutes with no control at all
                // while a credential had already been created.
                Text("Wakil never shows you the credential. Nothing here can cancel the "
                    + "credential itself — it is created once — but you can stop waiting "
                    + "for it.")
                    .font(.system(size: Scale.meta))
                    .foregroundStyle(coolWhite.opacity(0.34))
                    .fixedSize(horizontal: false, vertical: true)
                confirmButton("Stop waiting", tone: coolWhite.opacity(0.62),
                                  identifier: "settings.mint.stopWaiting") {
                    Task { await stopWaitingForMint() }
                }
            }

        case .added(let account):
            band {
                Text("\(account.accountId) is added. Its credential expires "
                    + (account.credential.expiry().map {
                        $0.formatted(date: .abbreviated, time: .omitted)
                    } ?? "in a year") + ".")
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
                Text("You never saw a token.")
                    .font(.system(size: Scale.meta))
                    .foregroundStyle(coolWhite.opacity(0.34))
                dismissButton("Done")
            }

        case .uncertain(let detail):
            band(tone: caution) {
                // **Never rendered as a failure.** A credential may exist
                // that Wakil never caught, and an operator told "it
                // failed" would leave a live 365-day credential in their
                // account without knowing.
                Text("Wakil could not confirm what happened.")
                    .font(.system(size: Scale.body, weight: .medium))
                    .foregroundStyle(caution)
                Text(detail)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                dismissButton("Dismiss")
            }

        case .refused(let message):
            band(tone: caution) {
                // A refusal is OBSERVED, so it may say plainly that
                // nothing was created.
                Text("The sign-in was declined. Nothing was created.")
                    .font(.system(size: Scale.body)).foregroundStyle(caution)
                Text(message)
                    .font(.system(size: Scale.meta, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.40))
                    .fixedSize(horizontal: false, vertical: true)
                dismissButton("Dismiss")
            }

        case .timedOut(let claim):
            band(tone: caution) {
                // **A timeout may not claim what a refusal may**, so the
                // sentence comes from the claim rather than from here.
                Text(claim.message)
                    .font(.system(size: Scale.body)).foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                dismissButton("Dismiss")
            }

        case .cancelled(let claim):
            band {
                Text(cancelSentence(claim))
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                dismissButton("Dismiss")
            }

        case .failed(let message):
            band(tone: caution) {
                Text(message)
                    .font(.system(size: Scale.body)).foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                dismissButton("Dismiss")
            }
        }
    }

    /// **Cancel means three different things and the surface must not use
    /// one word for them.** Trip 1 costs nothing; trip 2 is recoverable
    /// rather than clean; the capture step has no cancel control at all.
    private func cancelSentence(_ claim: CancelClaim) -> String {
        switch claim {
        case .nothingHappened:
            return "Cancelled. Nothing was created."
        case .recoverable(let message):
            return message
        }
    }

    /// **Two doors, and the split is not cosmetic** — `Settings.dc.html`
    /// has drawn it this way since the settings map: adopting an account
    /// already on this machine copies a credential and opens no browser,
    /// while registering a new one costs two browser trips and a mint.
    /// One affordance offering both would have to describe two different
    /// costs in one line.
    ///
    /// **It replaces a bare `id` field that read as a label.** The field
    /// worked — typing an id enabled `Add`, and `Add` produced the
    /// preflight band — but it had no box, no underline and no
    /// accessibility presence, so the pane appeared to offer no way to
    /// add an account at all. Found by running the app.
    @ViewBuilder
    private func addAccountRow() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            door(
                "Adopt an account from this machine",
                note: adoptableNote,
                open: showingAdoptable,
                identifier: "settings.door.adopt"
            ) {
                showingAdoptable.toggle()
                if showingAdoptable { registering = false }
            }

            if showingAdoptable { adoptableList() }

            door(
                "Register a new account",
                note: "Two browser trips",
                open: registering,
                identifier: "settings.door.register"
            ) {
                registering.toggle()
                if registering { showingAdoptable = false }
            }

            if registering { registerForm() }
        }
        .padding(.vertical, 4)
    }

    private var adoptableNote: String {
        guard let accounts else { return "" }
        let count = accounts.adoptable.count
        if count == 0 { return "none left on this machine" }
        return "\(count) not in this organisation"
    }

    /// One `＋` row: the gesture, what it costs, and whether it is open.
    private func door(
        _ title: String, note: String, open: Bool, identifier: String,
        _ act: @escaping () -> Void
    ) -> some View {
        Button(action: act) {
            // `.add { height: 44px; padding: 0 22px; gap: 11px;
            // font-size: 13px }` — a row, not a button bar, so it sits in
            // the same rhythm as the rows above it.
            HStack(spacing: 11) {
                Text(open ? "−" : "+")
                    .font(.system(size: Scale.door, weight: .light, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.52))
                    .frame(width: 13)
                Text(title)
                    .font(.system(size: Scale.door))
                    .foregroundStyle(coolWhite.opacity(0.78))
                Spacer(minLength: 16)
                Text(note)
                    .font(.system(size: Scale.meta))
                    .foregroundStyle(coolWhite.opacity(0.44))
            }
            .frame(minHeight: Scale.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// The accounts this organisation does not hold, **one per config
    /// dir**. Each carries its directory, because that is what the
    /// operator is choosing between — the ids collide.
    @ViewBuilder
    private func adoptableList() -> some View {
        if let accounts {
            let rows = accounts.adoptable
            if rows.isEmpty {
                emptyLine("every account on this machine is already bound here")
            } else {
                // The table's rows where its columns fit, stacked where they do not — as above.
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { account in accountRow(account) }
                    }
                    .frame(minWidth: Self.accountTableWidth, idealWidth: Self.accountTableWidth,
                           maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { account in accountRow(account, stacked: true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 20)
            }
        } else {
            emptyLine("reading…")
        }
    }

    /// The id, and nothing else. **The config dir is derived from it and
    /// a token is never seen** — which is why one short field is the
    /// whole form.
    private func registerForm() -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("The directory is derived from this id, and Wakil never shows you a token.")
                .font(.system(size: Scale.body))
                .foregroundStyle(coolWhite.opacity(0.45))
            HStack(spacing: 10) {
                // **A field that looks like one.** The artboard's `.field`
                // treatment: a bordered box with its own background, so
                // it is not mistaken for a label.
                TextField("id", text: $newAccountId)
                    .textFieldStyle(.plain)
                    .font(.system(size: Scale.identifier, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.90))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(width: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(coolWhite.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(coolWhite.opacity(0.14), lineWidth: 0.5)))
                    .accessibilityLabel("account id")
                    .accessibilityIdentifier("settings.register.id")
                    .onSubmit { beginAdd() }
                Button("Add") { beginAdd() }
                    .buttonStyle(.plain)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(newAccountId.isEmpty ? 0.28 : 0.70))
                    .disabled(newAccountId.isEmpty)
                    .accessibilityIdentifier("settings.register.add")
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text("claude")
                    .font(.system(size: Scale.meta, weight: .medium)).tracking(0.8)
                    .foregroundStyle(coolWhite.opacity(0.42))
                TextField("path to the claude executable", text: $newAccountClaudePath)
                    .textFieldStyle(.plain)
                    .font(.system(size: Scale.identifier, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.90))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(width: 360)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(coolWhite.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(coolWhite.opacity(0.14), lineWidth: 0.5)))
                    .accessibilityLabel("claude executable")
                    .accessibilityIdentifier("settings.register.claudePath")
                    .onAppear {
                        if newAccountClaudePath.isEmpty { newAccountClaudePath = resolvedClaudePath }
                    }
            }
        }
        .padding(.leading, 20)
        .padding(.bottom, 4)
    }

    private func beginAdd() {
        let id = newAccountId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        // Only an edit is an override: the prefill is what Wakil would use
        // anyway, and sending it back would pin today's lookup onto the row.
        let path = newAccountClaudePath.trimmingCharacters(in: .whitespaces)
        let override = path == resolvedClaudePath ? "" : path
        Task { await offerLogin(id, override) }
    }

    /// The artboard's `.btn` — a padded, rounded, filled affordance, with
    /// a `quiet` variant for the side that changes nothing.
    ///
    /// **A confirmation is the one place in this pane that must not be
    /// quiet text.** Everywhere else a bare word is right: `Adopt`,
    /// `Unlink` and `Re-authenticate` sit in a row and read as the row's
    /// verbs, which is `Settings.dc.html`'s `.act micro`. A confirmation
    /// is a fork, and a fork whose branches look like prose gets read as
    /// prose.
    /// **`identifier` has no default, and that is the whole guard.** It
    /// defaulted to `""` and four call sites took the default — the
    /// database form's name and driver fields and the DSN confirmation's
    /// two buttons — which `.accessibilityIdentifier("")` renders as
    /// unnamed. `make controls` reported "all named" throughout, and could
    /// not have done otherwise: it looks for `Button(`/`TextField(` in the
    /// audited sources, so a helper that wraps one is named ONCE at its
    /// definition and every call site is invisible to it. The compiler can
    /// see what the gate cannot, so it holds this one.
    private func confirmButton(
        _ title: String, tone: Color, filled: Bool = false, identifier: String,
        _ act: @escaping () -> Void
    ) -> some View {
        FormButton(title: title, tone: tone, filled: filled, identifier: identifier, action: act)
    }

    private func dismissButton(_ title: String) -> some View {
        Button(title) { Task { await dismissLogin() } }
            .accessibilityIdentifier("settings.login.dismiss")
            .buttonStyle(.plain)
            .font(.system(size: Scale.body))
            .foregroundStyle(coolWhite.opacity(0.45))
    }

    @ViewBuilder
    private func band<Content: View>(
        tone: Color? = nil, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(coolWhite.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke((tone ?? coolWhite).opacity(0.18), lineWidth: 0.5)))
        .padding(.bottom, 8)
    }

    /// The account table's four columns, the gaps between them and the verbs, which stack to
    /// about the width of the longest (`RE-AUTHENTICATE (2 TRIPS)`). Narrower, rows are stacked.
    private static let accountTableWidth: CGFloat = 300 + 104 + 200 + 175 + 5 * SettingsScale.columnGap + 170

    @ViewBuilder
    private func accountRows(_ mine: [Account], stacked: Bool) -> some View {
        if mine.isEmpty {
            emptyLine("no accounts registered in this organisation")
        }
        ForEach(mine) { account in
            accountRow(account, stacked: stacked)
        }
    }

    private func accountTableHeader() -> some View {
        HStack(spacing: Scale.columnGap) {
            // **No ORGANISATION column (#236).** The table draws this
            // organisation's bindings and nothing else, so the column
            // held one repeated value. What an operator actually needs
            // to tell two rows apart is the config dir, which is the
            // ACCOUNT — it moved into that cell.
            columnLabel("ACCOUNT", width: 300)
            columnLabel("KIND", width: 104)
            columnLabel("CREDENTIAL", width: 200)
            columnLabel("SIGN-IN", width: 175)
            Spacer(minLength: 0)
        }
        // **No gutter here.** `subjectColumn` already carries it, and the
        // rows below carry none — so adding it again put every column
        // label 22pt right of the cell it names (#271). Found by review;
        // the agent that wrote it could not see the window.
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func columnLabel(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: Scale.micro, weight: .medium))
            .tracking(Scale.microTracking)
            .foregroundStyle(coolWhite.opacity(0.30))
            .frame(width: width, alignment: .leading)
    }

    /// **The id, and under it the ACCOUNT (#236).** Five bindings on this machine are called
    /// `main` and they span three different accounts, while `personal/work` and `initech/main`
    /// are one account under two names — so the id alone identifies nothing. Decision 32: the
    /// account is the config dir.
    private func accountIdentity(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.accountId)
                .font(.system(size: Scale.identifier, design: .monospaced))
                .foregroundStyle(coolWhite.opacity(0.92))
            accountDirectory(account)
            if !account.label.isEmpty {
                Text(account.label)
                    .font(.system(size: Scale.meta))
                    .foregroundStyle(coolWhite.opacity(0.38))
            }
        }
    }

    /// One account in a column too narrow for the table: its identity, then each column as a
    /// labelled line, then its verbs — in a row with room, as a stack of words without.
    private func stackedAccountLine(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            accountIdentity(account)
            stackedCell("KIND") {
                Text(account.kind)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.55))
            }
            stackedCell("CREDENTIAL") { credentialCell(account) }
            stackedCell("SIGN-IN") { livenessCell(account.liveness) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Scale.columnGap) { rowVerbs(account) }
                VStack(alignment: .leading, spacing: 6) { rowVerbs(account) }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stackedCell<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            columnLabel(label, width: 84)
            value()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func accountRow(_ account: Account, stacked: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if stacked {
                stackedAccountLine(account)
            } else {
                HStack(spacing: Scale.columnGap) {
                    accountIdentity(account)
                        .frame(width: 300, alignment: .leading)

                    Text(account.kind)
                        .font(.system(size: Scale.body))
                        .foregroundStyle(coolWhite.opacity(0.55))
                        .frame(width: 104, alignment: .leading)

                    credentialCell(account).frame(width: 200, alignment: .leading)
                    livenessCell(account.liveness).frame(width: 175, alignment: .leading)
                    Spacer(minLength: 0)
                    // **Whole words, never letters** (#326). The data columns
                    // are fixed so their labels stay over them; the verbs are
                    // what gives way. With room they sit in a row, and in a
                    // narrower window they stack as words, one above another,
                    // rather than being squeezed a letter per line.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Scale.columnGap) { rowVerbs(account) }
                        VStack(alignment: .trailing, spacing: 6) { rowVerbs(account) }
                    }
                }
                // `.row { height: 44px }`. A MINIMUM rather than a fixed
                // height, because a shared binding's directory line can wrap
                // and a clipped row is worse than a tall one.
                .frame(minHeight: Scale.rowHeight, alignment: .leading)
            }
            if confirmingUnlink?.id == account.id {
                // **The confirmation says what will NOT be destroyed**,
                // because that is the part an operator otherwise assumes.
                VStack(alignment: .leading, spacing: 4) {
                    Text(UnlinkWording.confirmation(for: account))
                        .font(.system(size: Scale.body))
                        .foregroundStyle(caution)
                        .fixedSize(horizontal: false, vertical: true)
                    // **These two read as buttons (#238).** They were
                    // 10.5pt bare text at the tail of a three-line amber
                    // sentence, in a pane where every other word is also
                    // 10.5pt — so the confirmation looked like a warning
                    // with no way to answer it, and unlinking looked
                    // broken when it was not. The artboard's own `.btn` /
                    // `.btn quiet` pair, which is what a decision between
                    // two named outcomes has always been drawn as.
                    HStack(spacing: 10) {
                        confirmButton("Unlink", tone: caution, filled: true,
                                      identifier: "settings.unlink.confirm") {
                            confirmingUnlink = nil
                            Task { unlinkReport = await unlink(account) }
                        }
                        confirmButton("Keep it", tone: coolWhite.opacity(0.62),
                                      identifier: "settings.unlink.keep") {
                            confirmingUnlink = nil
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 4)
            }
            if let refusal = adoptRefusals[account.id] {
                Text(refusal)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(coolWhite.opacity(0.07)).frame(height: 0.5)
        }
    }

    /// **Ref and presence, never a value or a liveness-of-secret.** The
    /// minted token's age is shown as a DATE, so a 365-day clock is
    /// visible rather than guessed at — computed from the Keychain item's
    /// own modification date, which is the only place this phase's zero
    /// schema bill leaves to store one.
    ///
    /// **The ref lives here now (#236).** It used to sit under the whole
    /// row, which put a Keychain name where an operator reads an
    /// account's identity — and the account is the config dir, which has
    /// that place instead. #200 asked for "the credential's ref and
    /// whether it is present": that is one column, and this is it.
    @ViewBuilder
    private func credentialCell(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            credentialState(account)
            if !account.credential.ref.isEmpty {
                Text(account.credential.ref)
                    .font(.system(size: Scale.meta, design: .monospaced))
                    .foregroundStyle(coolWhite.opacity(0.24))
            }
        }
    }

    /// A row's verbs: repair, RUNNING or USE, UNLINK, or ADOPT. Laid out
    /// by the caller, in a row or a stack, whichever fits (#326).
    @ViewBuilder
    private func rowVerbs(_ account: Account) -> some View {
                if account.mine,
                   account.credentialLess || !account.liveness.loggedIn
                       || account.binary.isEmpty {
                    // **Repaired from the row that names it**, so diagnosis and
                    // repair are in the same place. The label states the cost,
                    // and the cost comes from LIVENESS rather than from the
                    // directory existing: `1 of 1` is the mint alone, `2 of 2`
                    // signs in first — and the first trip is the one that
                    // clears the red.
                    // **`.act micro` — uppercase, 9pt, tracked** (#269).
                    // The artboard draws a row's verbs that way and the
                    // organisation plane already ships it as `ADOPT`;
                    // sentence case at 10.5 was this pane inventing a
                    // second convention for the same gesture.
                    rowAction(
                        "Re-authenticate (\(account.liveness.tripsToRepair) "
                            + (account.liveness.tripsToRepair == 1 ? "trip)" : "trips)"),
                        tone: caution.opacity(0.85),
                        identifier: "settings.row.\(account.accountId).reauthenticate")
                    {
                        Task { await reauthenticate(account) }
                    }
                }
                if account.mine {
                    // **Which one is in use, and how to change it** (#270).
                    // The table named a credential and a sign-in per row
                    // and never said which account the window was actually
                    // running under — that lived only in the indicator at
                    // the window's bottom edge and was only changeable
                    // from ⌘P, which an operator has to already know
                    // about. Each row now reads either RUNNING or USE.
                    if account.accountId == runningAccountId {
                        Text("RUNNING")
                            .font(.system(size: Scale.micro, weight: .medium))
                            .tracking(Scale.microTracking)
                            .foregroundStyle(coolWhite.opacity(0.70))
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        // **Offered even when the credential is missing.**
                        // `setProvider` refuses with the reason, and a
                        // refusal an operator can read beats an affordance
                        // that silently is not there — the row beside it
                        // already says the credential is missing and
                        // offers the repair.
                        rowAction("Use", tone: coolWhite.opacity(0.62),
                                  identifier: "settings.row.\(account.accountId).use") {
                            Task { await use(account) }
                        }
                    }
                    rowAction("Unlink", tone: coolWhite.opacity(0.52),
                        identifier: "settings.row.\(account.accountId).unlink") {
                        confirmingUnlink = account
                    }
                }
                if !account.mine {
                    // **Adopt renders in place** and stops pointing at the
                    // organisation plane (#201). The row IS the source, so
                    // the credential copy needs nothing typed and nothing
                    // searched for — and nothing opens a browser.
                    rowAction(
                        adopting == account.id ? "Adopting…" : "Adopt",
                        tone: coolWhite.opacity(adopting == account.id ? 0.35 : 0.62),
                        identifier: "settings.row.\(account.org).\(account.accountId).adopt",
                        enabled: adopting == nil)
                    {
                        guard adopting == nil else { return }
                        adopting = account.id
                        adoptRefusals[account.id] = nil
                        Task {
                            let refusal = await adopt(account)
                            adopting = nil
                            adoptRefusals[account.id] = refusal
                        }
                    }
                }
    }

    /// A row's verb: the artboard's `.act micro`.
    ///
    /// **Uppercase and tracked, because a row verb is a label, not a
    /// sentence.** `Settings.dc.html` draws `Edit` and `Remove` this way
    /// and `OrgPlane` already ships `ADOPT` as one; this pane had been
    /// drawing the same gesture in sentence case at a different size.
    private func rowAction(
        _ title: String, tone: Color, identifier: String, enabled: Bool = true,
        _ act: @escaping () -> Void
    ) -> some View {
        Button(title.uppercased(), action: act)
            .buttonStyle(.plain)
            .font(.system(size: Scale.micro, weight: .medium))
            .tracking(Scale.microTracking)
            .foregroundStyle(tone)
            // One line at its own width (#326): a narrower window squeezed
            // these until each word wrapped a letter per line.
            .lineLimit(1)
            .fixedSize()
            .disabled(!enabled)
            .accessibilityIdentifier(identifier)
    }

    /// The account's own line: the directory that IS the account, and
    /// what is surprising about it.
    ///
    /// Two things earn a qualifier. A binding this organisation does not
    /// hold says which one does, because it is only drawn behind the
    /// Adopt door and the operator is choosing between organisations.
    /// And a SHARED binding says where the directory homes: a plain
    /// `claude` session started in it runs as `homeOrg`, not as the
    /// organisation whose row this is, which is the genuinely surprising
    /// fact about sharing one directory across organisations.
    @ViewBuilder
    private func accountDirectory(_ account: Account) -> some View {
        if account.configDir.isEmpty {
            Text("no config dir")
                .font(.system(size: Scale.meta, design: .monospaced))
                .foregroundStyle(coolWhite.opacity(0.30))
        } else {
            Text(abbreviatingHome(account.configDir) + directoryQualifier(account))
                .font(.system(size: Scale.meta, design: .monospaced))
                .foregroundStyle(coolWhite.opacity(0.46))
        }
    }

    private func directoryQualifier(_ account: Account) -> String {
        if !account.mine { return "  ·  in \(account.org)" }
        if !account.homeOrg.isEmpty, account.homeOrg != account.org {
            return "  ·  shared, homes to \(account.homeOrg)"
        }
        return ""
    }

    /// `~` rather than the literal home, because the home directory is
    /// noise in every row and the same in all of them.
    private func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    @ViewBuilder
    private func credentialState(_ account: Account) -> some View {
        if !account.credential.readable {
            Text("not checked").font(.system(size: Scale.body))
                .foregroundStyle(coolWhite.opacity(0.32))
        } else if !account.credential.present {
            Text("missing").font(.system(size: Scale.body, weight: .medium))
                .foregroundStyle(caution)
        } else if let expiry = account.credential.expiry() {
            VStack(alignment: .leading, spacing: 0) {
                Text("present").font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.66))
                Text("expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: Scale.meta))
                    .foregroundStyle(coolWhite.opacity(0.36))
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("present").font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.66))
                // "Unknown" rather than a computed date from a date that
                // was never read — a wrong expiry is worse than none,
                // because it is the one fact an operator plans against.
                Text("expiry unknown").font(.system(size: Scale.meta))
                    .foregroundStyle(coolWhite.opacity(0.36))
            }
        }
    }

    @ViewBuilder
    private func livenessCell(_ liveness: SignInLiveness) -> some View {
        if !liveness.failure.isEmpty {
            // Could not look — which says nothing about the account, and
            // must not draw as "logged out".
            Text("not read").font(.system(size: Scale.body))
                .foregroundStyle(coolWhite.opacity(0.32))
        } else if liveness.loggedIn {
            VStack(alignment: .leading, spacing: 1) {
                Text("signed in").font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.66))
                if liveness.hasIdentity {
                    Text(liveness.email).font(.system(size: Scale.meta))
                        .foregroundStyle(coolWhite.opacity(0.38)).lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("signed out").font(.system(size: Scale.body, weight: .medium))
                    .foregroundStyle(caution)
                Text("\(liveness.tripsToRepair) trip(s) to repair")
                    .font(.system(size: Scale.meta)).foregroundStyle(coolWhite.opacity(0.38))
            }
        }
    }

    // MARK: - The database form (#207)

    /// **The one place in this product an operator types a secret.**
    ///
    /// Three rules shape it, and all three are about what does NOT happen:
    ///
    /// - **The DSN never reaches the project file.** It goes to the
    ///   Keychain; the file gets the entry NAME. That split is why a
    ///   config file can be read, copied and hand-edited at all.
    /// - **The confirmation renders no part of it.** The existing
    ///   confirmation plane renders verbatim and unelided and would have
    ///   put a password on screen — which is why this phase's two
    ///   confirmations are both pane-local.
    /// - **Granting write access is a deliberate control**, not a text
    ///   field, and it needs its own second credential: write authority is
    ///   proven to the database server rather than asserted by Wakil.
    @ViewBuilder
    private func databaseForm(
        project projectName: String, environment environmentName: String, in tree: SettingsTree
    ) -> some View {
        let path = tree.projects.first { $0.name == projectName }?.path ?? ""
        // **Its own card** (#327): the list above is what exists, and this
        // is how to add to it. Drawn from `SettingsForm.swift`'s vocabulary,
        // which the API settings form will use too.
        FormCard(title: "ADD OR REPLACE A DATABASE") {
            HStack(alignment: .bottom, spacing: 12) {
                LabelledField(label: "NAME", prompt: "orders", text: $databaseName,
                              width: 160, identifier: "settings.db.name")
                FormLabelled(label: "DRIVER") {
                    SegmentedChoice(options: databaseDrivers, selection: $databaseConnection.driver,
                                    identifier: { "settings.db.driver.\($0)" })
                }
            }
            if databaseDriverHasServer(databaseConnection.driver) {
                HStack(alignment: .bottom, spacing: 12) {
                    LabelledField(label: "HOST", prompt: "db.internal",
                                  text: $databaseConnection.host, width: 200,
                                  identifier: "settings.db.host")
                    LabelledField(label: "PORT",
                                  prompt: defaultDatabasePort(for: databaseConnection.driver) ?? "",
                                  text: $databaseConnection.port, width: 70,
                                  identifier: "settings.db.port")
                    LabelledField(label: "DATABASE", prompt: "orders",
                                  text: $databaseConnection.database, width: 160,
                                  identifier: "settings.db.database")
                }
                HStack(alignment: .bottom, spacing: 12) {
                    LabelledField(label: "USER", prompt: "reader",
                                  text: $databaseConnection.user, width: 200,
                                  identifier: "settings.db.user")
                    // Masked, so the one secret in this product is not on
                    // screen while it is typed.
                    LabelledField(label: "PASSWORD", text: $databaseConnection.password,
                                  width: 244, identifier: "settings.db.password", secure: true)
                }
            } else {
                LabelledField(label: "FILE", prompt: "/path/to/database.db",
                              text: $databaseConnection.path, width: 456,
                              identifier: "settings.db.path")
            }

            Toggle(isOn: $databaseGrantWrite) {
                Text("Allow writes — needs a second credential the server granted")
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.60))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("settings.db.grantWrite")
            // A file has no logins: its write credential is its own path.
            if databaseGrantWrite, databaseDriverHasServer(databaseConnection.driver) {
                HStack(alignment: .bottom, spacing: 12) {
                    LabelledField(label: "WRITE USER", prompt: "writer", text: $databaseWriteUser,
                                  width: 200, identifier: "settings.db.writeUser")
                    LabelledField(label: "WRITE PASSWORD", text: $databaseWritePassword,
                                  width: 244, identifier: "settings.db.writePassword", secure: true)
                }
            }

            if confirmingDSN {
                // **Renders NO part of the DSN.** It names the database,
                // the environment and what will happen — and the operator
                // already knows what they typed.
                Text("Store a connection string for \(databaseName) in \(environmentName)? "
                    + "It goes to your Keychain, not to the project file"
                    + (databaseGrantWrite
                        ? ", and this database becomes writable." : "."))
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
                // The pane's other fork, given the same affordance as the
                // unlink one (#238).
                HStack(spacing: 10) {
                    confirmButton("Store it", tone: caution, filled: true,
                                  identifier: "settings.dsn.confirm") {
                        confirmingDSN = false
                        commitDatabase(path: path, environment: environmentName)
                    }
                    confirmButton("Cancel", tone: coolWhite.opacity(0.62),
                                  identifier: "settings.dsn.cancel") {
                        confirmingDSN = false
                    }
                }
            } else {
                // **A button that looks like one** (#327): it read as a
                // stray word under the fields.
                confirmButton(
                    "Save", tone: coolWhite.opacity(databaseName.isEmpty || path.isEmpty ? 0.35 : 0.90),
                    filled: true, identifier: "settings.db.save"
                ) {
                    // Refused parts are said here, before the confirmation,
                    // where they can still be corrected.
                    if case .refused(let reason) = formCredentials() {
                        databaseRefusal = reason
                    } else {
                        databaseRefusal = nil
                        confirmingDSN = true
                    }
                }
                .disabled(databaseName.isEmpty || path.isEmpty)
            }

            if let databaseRefusal {
                Text(databaseRefusal)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 14)
    }

    private func formCredentials() -> DatabaseFormCredentials {
        databaseFormCredentials(
            databaseConnection, grantWrite: databaseGrantWrite,
            writeUser: databaseWriteUser, writePassword: databaseWritePassword)
    }

    private func commitDatabase(path: String, environment: String) {
        let name = databaseName, driver = databaseConnection.driver
        guard case .built(let dsn, let write) = formCredentials() else { return }
        databaseRefusal = nil
        Task {
            let refusal = await setDatabaseDSN(
                path, environment, name, driver, dsn, write != nil, write ?? "")
            databaseRefusal = refusal
            // **Cleared on success, and only on success.** A refused
            // value stays so the operator can correct it rather than
            // retype every field — and it never outlives a write that
            // landed.
            if refusal == nil {
                databaseName = ""
                databaseConnection = DatabaseConnectionFields(driver: driver)
                databaseWriteUser = ""
                databaseWritePassword = ""
                databaseGrantWrite = false
            }
        }
    }

    private func environment(
        _ projectName: String, _ environmentName: String, in tree: SettingsTree
    ) -> SettingsEnvironment? {
        tree.projects.first { $0.name == projectName }?
            .environments.first { $0.name == environmentName }
    }

    /// What the subject column draws when the node the operator was
    /// standing on is no longer in the tree — a project removed by hand
    /// while the pane was open, which is exactly the case reading disk on
    /// every read makes visible.
    private func gone(_ name: String) -> some View {
        note("\(name) is no longer in this organisation's configuration.", tone: caution)
    }

    /// Read values as page rows: the label left, the value right, `—` for an empty one. The
    /// third element says whether the value is an identifier, drawn monospace (§6).
    private func fields(_ rows: [(String, String, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.0) { row in
                SettingsRow(row.0) { SettingsValue(text: row.1, monospaced: row.2) }
            }
        }
    }

    private func readOnlyNote(_ text: String) -> some View {
        note(text, tone: coolWhite.opacity(0.34))
    }

    /// The artboard's `.note`: 12px at 1.5, in a tinted slab with 12/14
    /// padding — not a bare 10pt line, which is how this pane had been
    /// drawing every warning it owed (#269).
    private func note(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: Scale.body))
            .lineSpacing(Scale.body * 0.5 - 2)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tone.opacity(0.09)))
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    /// What could not be read, named.
    ///
    /// **The note is what makes the loss visible rather than silent**, the
    /// idiom used everywhere else in this product: a pane that draws
    /// "could not look" as "there is nothing there" is the failure the
    /// whole partiality convention exists to prevent.
    private func residue(of tree: SettingsTree) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !tree.unreadable.isEmpty {
                note("could not read: \(tree.unreadable.joined(separator: ", "))", tone: caution)
            }
            if !tree.misfiled.isEmpty {
                note(
                    "filed here but declaring another organisation: "
                        + tree.misfiled.map { "\($0.name) → \($0.declaredOrg)" }
                            .joined(separator: ", "),
                    tone: caution)
            }
            if !tree.providersSkipped.isEmpty {
                note(
                    "account records that could not be parsed: "
                        + tree.providersSkipped.joined(separator: ", "),
                    tone: caution)
            }
        }
    }
}

/// Where the operator is standing in the config tree.
///
/// Keyed by NAME rather than by index, for the reason a pane's column
/// widths are: the tree is re-read from disk on every read, so an index
/// into it survives a read that reordered or removed something and points
/// at a different subject afterwards. A name that is gone is gone, and the
/// subject column says so.
enum SettingsNode: Hashable {
    /// The PROJECTS heading: where a removed project leaves the operator, with nothing of its
    /// own to show but the receipt.
    case projects
    case organisation
    case providers
    case editor
    case projectEditor(String)

    /// A stable fragment for this node's accessibility identifier.
    ///
    /// **Not derived from the label**, which is the organisation's display
    /// name and changes the moment the pane's own form edits it — an
    /// identifier that moves when the thing it names is edited is no
    /// identifier at all.
    var identifierFragment: String {
        switch self {
        case .organisation: return "organisation"
        case .providers: return "providers"
        case .projects: return "projects"
        case .editor: return "editor"
        case .projectEditor(let name): return "projectEditor.\(name)"
        case .project(let name): return "project.\(name)"
        case .environment(let project, let environment):
            return "environment.\(project).\(environment)"
        case .databases(let project, let environment):
            return "databases.\(project).\(environment)"
        case .api(let project, let environment):
            return "api.\(project).\(environment)"
        }
    }
    case project(String)
    case environment(project: String, environment: String)
    case databases(project: String, environment: String)
    case api(project: String, environment: String)

    /// This node after a project is renamed: the same place under the new name, so a rename
    /// never throws the operator to a page that says the node is gone.
    func renaming(project old: String, to new: String) -> SettingsNode {
        switch self {
        case .project(old): return .project(new)
        case .projectEditor(old): return .projectEditor(new)
        case .environment(old, let e): return .environment(project: new, environment: e)
        case .databases(old, let e): return .databases(project: new, environment: e)
        case .api(old, let e): return .api(project: new, environment: e)
        default: return self
        }
    }

    /// This node after an environment is renamed.
    func renaming(project: String, environment old: String, to new: String) -> SettingsNode {
        switch self {
        case .environment(project, old): return .environment(project: project, environment: new)
        case .databases(project, old): return .databases(project: project, environment: new)
        case .api(project, old): return .api(project: project, environment: new)
        default: return self
        }
    }

    /// The breadcrumb for this node. Four levels down needs one to say
    /// where you are.
    func breadcrumb(in tree: SettingsTree?) -> [String] {
        let organisation = tree?.org.label ?? "Organisation"
        switch self {
        case .organisation:
            return [organisation]
        case .providers:
            return [organisation, "Providers"]
        case .projects:
            return [organisation, "Projects"]
        case .editor:
            return ["Wakil", "Editor"]
        case .projectEditor(let name):
            return [organisation, "Projects", name, "Editor"]
        case .project(let name):
            return [organisation, "Projects", name]
        case .environment(let project, let environment):
            return [organisation, "Projects", project, environment]
        case .databases(let project, let environment):
            return [organisation, "Projects", project, environment, "Databases"]
        case .api(let project, let environment):
            return [organisation, "Projects", project, environment, "API"]
        }
    }
}

/// The ⓘ beside QUICK TASKS. A click, not a hover tooltip: the text is a dozen lines, and a
/// tooltip can be neither reached by keyboard nor read at leisure. Click away or Esc closes it.
private struct QuickTasksAboutButton: View {
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(open ? 0.86 : 0.48))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About quick tasks")
        .accessibilityIdentifier("settings.quickTasks.about")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text((try? AttributedString(
                markdown: quickTasksAbout,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(quickTasksAbout))
                .font(.system(size: SettingsScale.body))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 420, alignment: .leading)
                .padding(14)
                .background(Color(red: 0.055, green: 0.063, blue: 0.098))   // #0e1019, as the agent chips' list
                .accessibilityIdentifier("settings.quickTasks.about.text")
        }
    }
}
