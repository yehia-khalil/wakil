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
    let saveOrganisationField: (WindowModel.OrganisationField, String) async -> String?
    /// Saves app-wide editor fields (3b-v) and answers the refusal's sentence, or nil.
    var saveEditorSettings: ([String: JSONValue]) async -> String? = { _ in nil }
    /// Saves one project's editor fields: the project file's path, then the fields.
    var saveProjectEditorSettings: (String, [String: JSONValue]) async -> String? = { _, _ in nil }
    /// Saves a local model: id, label, URL, the operations it serves (3b-viii). Answers the refusal or nil.
    var saveLocalProvider: (String, String, String, Set<QuickOperation>) async -> String? = { _, _, _, _ in nil }
    /// Removes a local model by id (3b-viii). Answers the refusal or nil.
    var removeLocalProvider: (String) async -> String? = { _ in nil }
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

    /// Where the operator is standing in the tree. Window state, not
    /// configuration: it survives a re-read, and a re-read that dropped it
    /// would throw the operator back to the top every time anything
    /// changed. **Owned by the window** (`WakilWindow.settingsSelection`)
    /// so it also survives the pane being rebuilt, as a provider switch does.
    @Binding var selection: SettingsNode
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: tree) { quickStatus = await quickTaskStatus() }
    }

    // MARK: - The tree

    @ViewBuilder
    private var treeColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row(.editor, label: "Editor", depth: 0)
                row(.organisation, label: tree?.org.label ?? "Organisation", depth: 0)
                row(.providers, label: "Providers", depth: 0, badge: tree.map { "\($0.providers.count)" })

                sectionLabel("Projects")
                if let tree, tree.projects.isEmpty {
                    emptyLine("no projects")
                }
                ForEach(tree?.projects ?? [], id: \.name) { project in
                    row(.project(project.name), label: project.name, depth: 1)
                    row(.projectEditor(project.name), label: "Editor", depth: 2)
                    ForEach(project.environments, id: \.name) { environment in
                        row(
                            .environment(project: project.name, environment: environment.name),
                            label: environment.name, depth: 2)
                        row(
                            .databases(project: project.name, environment: environment.name),
                            label: "Databases", depth: 3,
                            badge: "\(environment.databases.count)")
                        // The API node is drawn whether or not the
                        // environment declares an entry, and read-only
                        // either way. The ninth artboard correction: *What
                        // is editable* rules the API row read-only on
                        // Decision 8's amendment, which presumes a row
                        // exists, and none of the five drawn variants had
                        // one until it was noticed.
                        row(
                            .api(project: project.name, environment: environment.name),
                            label: "API", depth: 3)
                    }
                    // Marked rather than drawn silently, so the operator
                    // learns the boundary by looking rather than by
                    // pressing. Environment create, rename and remove are
                    // #45 and are out of this phase.
                    notThisPhase("+ Add an environment", depth: 2)
                }
                notThisPhase("+ Add a project", depth: 1)
            }
            .padding(.vertical, 2)
        }
    }

    private func row(
        _ node: SettingsNode, label: String, depth: Int, badge: String? = nil
    ) -> some View {
        Button {
            selection = node
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: Scale.door))
                    .foregroundStyle(coolWhite.opacity(selection == node ? 0.95 : 0.62))
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: Scale.meta, design: .monospaced))
                        .foregroundStyle(coolWhite.opacity(0.35))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 12 + 8)
            .padding(.vertical, 3)
            .padding(.trailing, 8)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(coolWhite.opacity(selection == node ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // **On the Button, not on its label.** A modifier inside the
        // `label:` closure names the content view; the accessibility
        // element the driver resolves is the Button, and it carried no
        // identifier at all. Caught by the check going red on a control
        // that was supposedly named.
        .accessibilityIdentifier("settings.tree.\(node.identifierFragment)")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: Scale.micro, weight: .medium))
            .tracking(Scale.microTracking)
            .foregroundStyle(coolWhite.opacity(0.32))
            .padding(.leading, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Scale.body))
            .foregroundStyle(coolWhite.opacity(0.28))
            .padding(.leading, 20)
            .padding(.vertical, 3)
    }

    /// A control that is visible and does nothing, labelled with why.
    ///
    /// **Drawn rather than omitted**, deliberately: an operator looking for
    /// "add a project" and finding nothing cannot tell a missing feature
    /// from a control they have not found. One that says *not this phase*
    /// answers the question it raises.
    private func notThisPhase(_ label: String, depth: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: Scale.body))
                .foregroundStyle(coolWhite.opacity(0.24))
            Text("not this phase")
                .font(.system(size: Scale.micro, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(coolWhite.opacity(0.24))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(coolWhite.opacity(0.14), lineWidth: 0.5))
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12 + 8)
        .padding(.vertical, 3)
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
    }

    @ViewBuilder
    private func subject(of tree: SettingsTree) -> some View {
        switch selection {
        case .organisation:
            // The id is the directory name, so there is one place it can
            // be written and no way for the two to disagree. Not a
            // setting, and drawn as the fact it is.
            fields([("Id", tree.org.id, true)])
            ForEach(WindowModel.OrganisationField.allCases.filter { $0 != .speechProvider && $0 != .quickProvider }, id: \.self) { field in
                organisationEditor(field, in: tree)
            }
            speechRow(tree: tree)
            quickTasksRow(tree: tree)
            readOnlyNote(
                "Saved one field at a time, read-modify-write from disk — so an edit you make "
                    + "to org.json by hand while this pane is open survives a save here.")

        case .providers:
            accountTable()
            LocalProvidersSection(
                providers: tree.providers, status: quickStatus,
                save: { id, label, url, serves in
                    let refusal = await saveLocalProvider(id, label, url, serves)
                    quickStatus = await quickTaskStatus()
                    return refusal
                },
                remove: { id in
                    let refusal = await removeLocalProvider(id)
                    quickStatus = await quickTaskStatus()
                    return refusal
                })
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
                fields([("Name", project.name, true), ("File", project.path, true)])
                if !project.roots.isEmpty {
                    label("Roots")
                    ForEach(project.roots, id: \.path) { root in
                        HStack(spacing: 8) {
                            Text(root.path).font(.system(size: Scale.meta, design: .monospaced))
                                .foregroundStyle(coolWhite.opacity(0.70))
                            if !root.role.isEmpty {
                                Text(root.role).font(.system(size: Scale.meta)).foregroundStyle(coolWhite.opacity(0.40))
                            }
                        }
                    }
                }
            } else {
                gone(name)
            }

        case .environment(let projectName, let environmentName):
            if let environment = environment(projectName, environmentName, in: tree) {
                fields([
                    ("Name", environment.name, true),
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
                        + "is four levels deep and not three. Create, rename and remove are #45.")
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
                        fields([
                            ("Name", api.name.isEmpty ? "unnamed" : api.name, true),
                            ("Base URL", api.baseUrl, true),
                            ("Auth ref", api.authRef.isEmpty ? "none" : api.authRef, true),
                        ])
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

    /// One editable string of the organisation record.
    ///
    /// **Edits render on the pane; this phase adds no new modal.** The
    /// refusal sits under the field that caused it, which is the whole
    /// reason `saveOrganisationField` answers a sentence rather than
    /// writing to the window's status line: a message about the Jira site
    /// belongs under the Jira site.
    @ViewBuilder
    private func organisationEditor(
        _ field: WindowModel.OrganisationField, in tree: SettingsTree
    ) -> some View {
        let stored = storedValue(field, in: tree)
        let draft = drafts[field]
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label.uppercased())
                .font(.system(size: Scale.micro, weight: .medium))
                .tracking(Scale.microTracking)
                .foregroundStyle(coolWhite.opacity(0.32))
            HStack(spacing: 8) {
                TextField(
                    "",
                    text: Binding(
                        get: { draft ?? stored },
                        set: { drafts[field] = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(coolWhite.opacity(0.88))
                    .onSubmit { save(field, tree: tree) }
                    .accessibilityIdentifier("settings.org.\(field.identifierFragment)")
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
            .padding(.vertical, 3)
            .overlay(alignment: .bottom) {
                Rectangle().fill(coolWhite.opacity(0.12)).frame(height: 0.5)
            }
            if let refusal = refusals[field] {
                Text(refusal)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
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
            Text("SPEECH")
                .font(.system(size: Scale.micro, weight: .medium))
                .tracking(Scale.microTracking)
                .foregroundStyle(coolWhite.opacity(0.32))
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
            if let note = registry.note(for: stored) {
                Text(note)
                    .font(.system(size: Scale.body))
                    .foregroundStyle(caution)
                    .accessibilityIdentifier("settings.org.speechProvider.note")
            }
            if let refusal = refusals[.speechProvider] {
                Text(refusal).font(.system(size: Scale.body)).foregroundStyle(caution)
            }
        }
        .padding(.bottom, 4)
    }

    /// 3b-viii: the provider quick tasks run on. One segment per provider that serves anything,
    /// "Same as agent" first; a stored id no provider answers to is held, not dropped (Rule 7).
    private func quickTasksRow(tree: SettingsTree) -> some View {
        let options = quickTaskChoices(tree)
        let stored = tree.org.quickProvider
        let known = options.first(where: { $0.id == stored })
        func labelFor(_ id: String) -> String { options.first(where: { $0.id == id })?.display ?? id }
        func idFor(_ label: String) -> String { options.first(where: { $0.display == label })?.id ?? label }
        return VStack(alignment: .leading, spacing: 2) {
            Text("QUICK TASKS")
                .font(.system(size: Scale.micro, weight: .medium))
                .tracking(Scale.microTracking)
                .foregroundStyle(coolWhite.opacity(0.32))
            SegmentedChoice(
                options: options.map(\.display),
                selection: Binding(
                    get: { known?.display ?? labelFor(stored) },
                    set: { label in
                        let id = idFor(label)
                        guard id != stored else { return }
                        drafts[.quickProvider] = id
                        save(.quickProvider, tree: tree)
                    }),
                identifier: { label in
                    let id = idFor(label)
                    let key = id.isEmpty ? "same" : id
                    return "settings.org.quickProvider.\(key)"
                },
                held: known == nil ? stored : nil)
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

    private func storedValue(
        _ field: WindowModel.OrganisationField, in tree: SettingsTree
    ) -> String {
        switch field {
        case .displayName: return tree.org.displayName
        case .jiraBase: return tree.org.jiraBase
        case .defaultProvider: return tree.org.defaultProvider
        case .speechProvider: return tree.org.speechProvider
        case .quickProvider: return tree.org.quickProvider
        }
    }

    private func save(_ field: WindowModel.OrganisationField, tree: SettingsTree) {
        guard let value = drafts[field], saving != field else { return }
        saving = field
        refusals[field] = nil
        Task {
            let refusal = await saveOrganisationField(field, value)
            saving = nil
            refusals[field] = refusal
            quickStatus = await quickTaskStatus()
            // The draft is cleared only on success, so a refused value
            // stays in front of the operator to be corrected rather than
            // vanishing along with the explanation of why it was refused.
            if refusal == nil { drafts[field] = nil }
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

            accountTableHeader()
            // **This organisation's bindings, and no others (#236).** The
            // table used to draw every binding on the machine, which on
            // this one is ten rows for three accounts — five of them
            // called `main`, spanning all three. Other organisations'
            // accounts are behind the Adopt door below, where the
            // operator is choosing rather than reading.
            let mine = accounts.accounts.filter(\.mine)
            if mine.isEmpty {
                emptyLine("no accounts registered in this organisation")
            }
            ForEach(mine) { account in
                accountRow(account)
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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { account in
                        accountRow(account)
                    }
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

    @ViewBuilder
    private func accountRow(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Scale.columnGap) {
                // **The id, and under it the ACCOUNT (#236).** Five
                // bindings on this machine are called `main` and they
                // span three different accounts, while `personal/work`
                // and `initech/main` are one account under two names — so
                // the id alone identifies nothing. Decision 32: the
                // account is the config dir.
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

    private func fields(_ rows: [(String, String, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.0.uppercased())
                        .font(.system(size: Scale.micro, weight: .medium))
                        .tracking(Scale.microTracking)
                        .foregroundStyle(coolWhite.opacity(0.32))
                    Text(row.1.isEmpty ? "—" : row.1)
                        .font(.system(size: row.2 ? Scale.identifier : Scale.body,
                                      design: row.2 ? .monospaced : .default))
                        .foregroundStyle(coolWhite.opacity(row.1.isEmpty ? 0.30 : 0.85))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: Scale.micro, weight: .medium))
            .tracking(Scale.microTracking)
            .foregroundStyle(coolWhite.opacity(0.32))
            .padding(.top, 4)
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

    /// The breadcrumb for this node. Four levels down needs one to say
    /// where you are.
    func breadcrumb(in tree: SettingsTree?) -> [String] {
        let organisation = tree?.org.label ?? "Organisation"
        switch self {
        case .organisation:
            return [organisation]
        case .providers:
            return [organisation, "Providers"]
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
