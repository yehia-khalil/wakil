import Foundation

/// The active organisation's configuration, as the settings pane draws it.
///
/// A typed mirror of Go's `wakilcore.ConfigTree`, decoded from
/// `ctx_config_tree`'s reply. Typed rather than passed around as a
/// `JSONValue` for the reason `PaneSnapshot` is typed: the alternative is a
/// hand-written parser in the view whose failure mode is a silently empty
/// pane, which is the symptom this app is worst at surfacing.
///
/// **The shape is the layout** (`phase-2e-probe.md` §4, chosen from five
/// drawn variants), and two things about it are binding:
///
/// - **It is four deep, not three.** An `Environment` — not a project —
///   holds `databases` and `api` (`config.go`). A three-deep tree would
///   have to put a database under a project, and a project has none.
/// - **Providers cannot nest at all.** A binding is
///   `(organisation, provider id)`, so providers sit BESIDE the projects
///   and every project in the organisation draws on them. The credential
///   spine cuts across the tree rather than along it.
///
/// **Nothing here can hold a credential's value.** A database carries its
/// Keychain entry NAME — which is what an operator's own settings pane is
/// for — and there is no field on any of these types a secret could travel
/// in.
public struct SettingsTree: Sendable, Equatable, Decodable {
    public var org: SettingsOrg
    public var providers: [SettingsProvider]
    public var projects: [SettingsProject]

    /// Registry entries whose project file declares another organisation.
    /// **Named rather than dropped**, the same house rule `ProjectListing`,
    /// `SessionList` and `IssuePage` follow: a pane that draws "could not
    /// look" as "there is nothing there" is the failure this carries.
    public var misfiled: [SettingsMisfiledProject]
    /// Registry entries whose project file could not be read at all.
    public var unreadable: [String]
    /// Provider records that could not be parsed.
    public var providersSkipped: [String]
    public var editor: SettingsEditor
    public var editorError: String?
    /// The app-wide browser tier (3c-i), from the same settings.json; its read error is `editorError`.
    public var browser: SettingsBrowser

    public init(
        org: SettingsOrg,
        providers: [SettingsProvider] = [],
        projects: [SettingsProject] = [],
        misfiled: [SettingsMisfiledProject] = [],
        unreadable: [String] = [],
        providersSkipped: [String] = [],
        editor: SettingsEditor = .defaults,
        editorError: String? = nil,
        browser: SettingsBrowser = .defaults
    ) {
        self.org = org
        self.providers = providers
        self.projects = projects
        self.misfiled = misfiled
        self.unreadable = unreadable
        self.providersSkipped = providersSkipped
        self.editor = editor
        self.editorError = editorError
        self.browser = browser
    }

    /// Every optional-on-the-wire collection decodes to empty rather than
    /// failing. Go omits `misfiled`, `unreadable` and `providersSkipped`
    /// when there is nothing to report, and a decoder that treated an
    /// absent key as malformed would make the ordinary case — a healthy
    /// organisation — the one that draws nothing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        org = try container.decode(SettingsOrg.self, forKey: .org)
        providers = try container.decodeIfPresent([SettingsProvider].self, forKey: .providers) ?? []
        projects = try container.decodeIfPresent([SettingsProject].self, forKey: .projects) ?? []
        misfiled = try container.decodeIfPresent([SettingsMisfiledProject].self, forKey: .misfiled) ?? []
        unreadable = try container.decodeIfPresent([String].self, forKey: .unreadable) ?? []
        providersSkipped = try container.decodeIfPresent([String].self, forKey: .providersSkipped) ?? []
        editor = try container.decodeIfPresent(SettingsEditor.self, forKey: .editor) ?? .defaults
        editorError = try container.decodeIfPresent(String.self, forKey: .editorError)
        browser = try container.decodeIfPresent(SettingsBrowser.self, forKey: .browser) ?? .defaults
    }

    private enum CodingKeys: String, CodingKey {
        case org, providers, projects, misfiled, unreadable, providersSkipped, editor, editorError, browser
    }

    /// Whether anything could not be read. The pane draws a line saying so
    /// when this is true — the note is what makes the loss visible rather
    /// than silent, which is the idiom used everywhere else in this
    /// product.
    public var hasResidue: Bool {
        !misfiled.isEmpty || !unreadable.isEmpty || !providersSkipped.isEmpty
    }
}

/// How autosave behaves (3b-v): never, a second after the last edit, or when focus leaves.
/// Declared here rather than in `Editor/`, because `Panes` may not depend on `Editor`.
public enum EditorAutosaveMode: String, Sendable, Equatable, CaseIterable {
    case off, pause, focus

    public var label: String {
        switch self {
        case .off: "Off"
        case .pause: "After a pause"
        case .focus: "When focus leaves"
        }
    }
}

/// The app-wide editor tier (`~/.wakil/settings.json`), defaults filled by Go. An absent key or an
/// unknown autosave value decodes to the default, so an older or hand-edited answer still draws.
public struct SettingsEditor: Sendable, Equatable, Decodable {
    public var fontSize: Int
    public var wordWrap: Bool
    public var autosave: EditorAutosaveMode
    /// Off hides gitignored files from the tree and ⌘P (3b-v part 2). On by default.
    public var showIgnored: Bool
    /// Off asks no model for a suggestion in any editor or query line (3b-viii). On by default.
    public var ghostText: Bool
    /// Off hides who last changed the cursor's line at its end (3a-v-a). On by default.
    public var inlineBlame: Bool

    public static let defaults = SettingsEditor(fontSize: 12, wordWrap: false, autosave: .off)

    public init(
        fontSize: Int, wordWrap: Bool, autosave: EditorAutosaveMode, showIgnored: Bool = true, ghostText: Bool = true,
        inlineBlame: Bool = true
    ) {
        self.fontSize = fontSize
        self.wordWrap = wordWrap
        self.autosave = autosave
        self.showIgnored = showIgnored
        self.ghostText = ghostText
        self.inlineBlame = inlineBlame
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? Self.defaults.fontSize
        wordWrap = try c.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? Self.defaults.wordWrap
        autosave = (try c.decodeIfPresent(String.self, forKey: .autosave)).flatMap(EditorAutosaveMode.init(rawValue:)) ?? .off
        showIgnored = try c.decodeIfPresent(Bool.self, forKey: .showIgnored) ?? Self.defaults.showIgnored
        ghostText = try c.decodeIfPresent(Bool.self, forKey: .ghostText) ?? Self.defaults.ghostText
        inlineBlame = try c.decodeIfPresent(Bool.self, forKey: .inlineBlame) ?? Self.defaults.inlineBlame
    }

    private enum CodingKeys: String, CodingKey { case fontSize, wordWrap, autosave, showIgnored, ghostText, inlineBlame }
}

/// The app-wide browser tier (`~/.wakil/settings.json`'s `browser`), defaults filled by Go (3c-i).
/// An absent key decodes to the default, so an older answer still draws.
public struct SettingsBrowser: Sendable, Equatable, Decodable {
    /// `google`, `duckduckgo`, `bing` or `kagi`.
    public var searchEngine: String
    /// An http or https URL a new tab opens; empty is blank.
    public var startPage: String
    /// Whether the address bar asks the search engine for suggestions as the operator types. Off by default.
    public var searchSuggestions: Bool
    /// `horizontal` or `vertical`: where the tab strip sits.
    public var tabs: String
    /// Whether the model names automatic tab groups. On by default.
    public var nameGroups: Bool
    /// Whether a playing video floats when the operator leaves its tab. On by default.
    public var pictureInPicture: Bool

    public static let defaults = SettingsBrowser(searchEngine: "google", startPage: "")

    public init(searchEngine: String, startPage: String, searchSuggestions: Bool = false,
                tabs: String = "horizontal", nameGroups: Bool = true, pictureInPicture: Bool = true) {
        self.searchEngine = searchEngine
        self.startPage = startPage
        self.searchSuggestions = searchSuggestions
        self.tabs = tabs
        self.nameGroups = nameGroups
        self.pictureInPicture = pictureInPicture
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchEngine = try c.decodeIfPresent(String.self, forKey: .searchEngine) ?? Self.defaults.searchEngine
        startPage = try c.decodeIfPresent(String.self, forKey: .startPage) ?? Self.defaults.startPage
        searchSuggestions = try c.decodeIfPresent(Bool.self, forKey: .searchSuggestions) ?? false
        tabs = try c.decodeIfPresent(String.self, forKey: .tabs) ?? "horizontal"
        nameGroups = try c.decodeIfPresent(Bool.self, forKey: .nameGroups) ?? true
        pictureInPicture = try c.decodeIfPresent(Bool.self, forKey: .pictureInPicture) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case searchEngine, startPage, searchSuggestions, tabs, nameGroups, pictureInPicture
    }
}

/// One project's editor tier (`project.json`'s `editor`), defaults filled by Go.
public struct SettingsProjectEditor: Sendable, Equatable, Decodable {
    public var tabSize: Int
    public var insertSpaces: Bool
    /// The heavy folders besides .git, which is always heavy (3b-v part 2). Empty is a value.
    public var heavyFolders: [String]

    public static let defaults = SettingsProjectEditor(tabSize: 4, insertSpaces: true)

    public init(tabSize: Int, insertSpaces: Bool, heavyFolders: [String] = ["vendor", "node_modules"]) {
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
        self.heavyFolders = heavyFolders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabSize = try c.decodeIfPresent(Int.self, forKey: .tabSize) ?? Self.defaults.tabSize
        insertSpaces = try c.decodeIfPresent(Bool.self, forKey: .insertSpaces) ?? Self.defaults.insertSpaces
        heavyFolders = try c.decodeIfPresent([String].self, forKey: .heavyFolders) ?? Self.defaults.heavyFolders
    }

    private enum CodingKeys: String, CodingKey { case tabSize, insertSpaces, heavyFolders }
}

/// One of the organisation's git accounts, as `config_tree` sends it (3a-iii): never a secret.
public struct SettingsGitAccount: Sendable, Equatable, Decodable {
    public var host: String
    public var provider: String
    public var method: String
    public var user: String
    public var keyPath: String
    public var username: String
    /// An SSH GitHub account's optional API credential: "" (none), "signin" or "token".
    public var apiAccess: String

    public init(host: String, provider: String, method: String, user: String = "", keyPath: String = "", username: String = "",
                apiAccess: String = "") {
        self.host = host
        self.provider = provider
        self.method = method
        self.user = user
        self.keyPath = keyPath
        self.username = username
        self.apiAccess = apiAccess
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "other"
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "ssh"
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        apiAccess = try c.decodeIfPresent(String.self, forKey: .apiAccess) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case host, provider, method, user, keyPath, username, apiAccess }
}

/// One value a connection asks for (a catalog kind's field): a secret one is drawn masked and
/// written through `connection_secrets_set`; its value never travels in the tree.
public struct SettingsConnectionField: Sendable, Equatable, Decodable {
    public var id: String
    public var label: String
    public var secret: Bool

    public init(id: String, label: String, secret: Bool = false) {
        self.id = id
        self.label = label
        self.secret = secret
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
    }

    private enum CodingKeys: String, CodingKey { case id, label, secret }
}

/// One of the organisation's own MCP servers, as Go's `ConfigTreeConnection` draws it: no secret,
/// only which Keychain keys hold one (`secretKeys`). `hints` is the server's word on each tool as
/// last checked (readOnly, writes, destructive or ""); `allow` the operator's switches.
public struct SettingsConnection: Sendable, Equatable, Decodable {
    public var name: String
    public var kind: String
    public var title: String
    public var transport: String
    public var url: String
    public var command: String
    public var args: [String]
    /// token, fields, browser or none.
    public var signIn: String
    public var values: [String: String]
    public var fields: [SettingsConnectionField]
    public var allow: [String: Bool]
    public var hints: [String: String]
    public var signedIn: Bool
    public var secretKeys: [String]

    public init(
        name: String, kind: String = "custom", title: String = "", transport: String = "", url: String = "",
        command: String = "", args: [String] = [], signIn: String = "none", values: [String: String] = [:],
        fields: [SettingsConnectionField] = [], allow: [String: Bool] = [:], hints: [String: String] = [:],
        signedIn: Bool = false, secretKeys: [String] = []
    ) {
        self.name = name
        self.kind = kind
        self.title = title
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.signIn = signIn
        self.values = values
        self.fields = fields
        self.allow = allow
        self.hints = hints
        self.signedIn = signedIn
        self.secretKeys = secretKeys
    }

    /// A connection known only by its name, as a launch needs it (`AgentConnection(name:)`).
    public init(name: String) { self.init(name: name, kind: "custom") }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "custom"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        signIn = try c.decodeIfPresent(String.self, forKey: .signIn) ?? "none"
        values = try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        // Per element: one malformed field is dropped, not the connection (nor, with it, every
        // connection a launch reads).
        fields = (try? c.decodeIfPresent([LenientElement<SettingsConnectionField>].self, forKey: .fields))?
            .compactMap(\.value) ?? []
        allow = try c.decodeIfPresent([String: Bool].self, forKey: .allow) ?? [:]
        hints = try c.decodeIfPresent([String: String].self, forKey: .hints) ?? [:]
        signedIn = try c.decodeIfPresent(Bool.self, forKey: .signedIn) ?? false
        secretKeys = try c.decodeIfPresent([String].self, forKey: .secretKeys) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, title, transport, url, command, args, signIn, values, fields, allow, hints, signedIn, secretKeys
    }

    /// What the list and the page call it: the catalog's title, else the name.
    public var displayTitle: String { title.isEmpty || kind == "custom" ? name : title }
}

/// One element of a list decoded on its own: a malformed one is nil and the rest survive.
struct LenientElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// A session launch reads only a connection's name (`AgentConnectionsBox`); it is the same record.
public typealias AgentConnection = SettingsConnection

/// The organisation's four editable strings, and the id, which is the
/// directory name and therefore not editable at all.
public struct SettingsOrg: Sendable, Equatable, Decodable {
    public var id: String
    public var displayName: String
    public var jiraBase: String
    public var defaultProvider: String
    public var speechProvider: String
    /// The provider quick tasks run on (3b-viii, Decision 42). Empty means the active provider.
    public var quickProvider: String
    /// The organisation's ghost-text switch (3b-ix), resolved by Go. On unless the org turned it off.
    public var ghostText: Bool
    /// The organisation's fast-path switch (3b-ix): one-line composer commands without an agent turn.
    public var fastPath: Bool
    /// The organisation's commit-drafts switch (3a-ii-b): the commit box's ✨. On unless switched off.
    public var commitDrafts: Bool
    /// The organisation's conversation-naming switch (names phase): the quick model names a conversation. On unless switched off.
    public var conversationNames: Bool
    /// 3a-iii: the organisation's git accounts (no secrets) and its pull strategy (rebase when unset).
    public var gitAccounts: [SettingsGitAccount]
    public var pullStrategy: String
    /// The folder the operator last cloned into (3a-iii): Clone's default destination.
    public var lastCloneFolder: String
    /// Which providers Sign in is offered for: those Wakil has an OAuth client id for (3a-iii, R4).
    public var gitSignIn: [String]
    /// 3a-iii-b: the organisation's agent instructions.
    public var agentGeneral: String
    public var gitCommitInstructions: String
    public var gitPRInstructions: String
    /// Workspaces (decision 10): how a workspace's branch is named.
    public var gitBranchInstructions: String = ""
    /// The organisation's git author (3a-ii): the name and email commits from the Changes view carry.
    /// Empty means the repository's own git config decides.
    public var gitName: String
    public var gitEmail: String
    /// The organisation's connections (Settings → Connections); a session launch reads their
    /// names (`AgentConnectionsBox`).
    public var connections: [SettingsConnection]
    /// Whether the organisation's Jira sign-in (`jira:<org>`) is in the Keychain — presence only.
    public var jiraTokenStored: Bool

    public init(
        id: String, displayName: String = "", jiraBase: String = "", defaultProvider: String = "",
        speechProvider: String = "", quickProvider: String = "", ghostText: Bool = true,
        fastPath: Bool = false, gitName: String = "", gitEmail: String = "", commitDrafts: Bool = true, conversationNames: Bool = true,
        gitAccounts: [SettingsGitAccount] = [], pullStrategy: String = "rebase", lastCloneFolder: String = "",
        gitSignIn: [String] = [], agentGeneral: String = "", gitCommitInstructions: String = "",
        gitPRInstructions: String = "", connections: [SettingsConnection] = [], jiraTokenStored: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.jiraBase = jiraBase
        self.defaultProvider = defaultProvider
        self.speechProvider = speechProvider
        self.quickProvider = quickProvider
        self.ghostText = ghostText
        self.fastPath = fastPath
        self.commitDrafts = commitDrafts
        self.conversationNames = conversationNames
        self.gitAccounts = gitAccounts
        self.pullStrategy = pullStrategy
        self.lastCloneFolder = lastCloneFolder
        self.gitSignIn = gitSignIn
        self.agentGeneral = agentGeneral
        self.gitCommitInstructions = gitCommitInstructions
        self.gitPRInstructions = gitPRInstructions
        self.gitName = gitName
        self.gitEmail = gitEmail
        self.connections = connections
        self.jiraTokenStored = jiraTokenStored
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        jiraBase = try container.decodeIfPresent(String.self, forKey: .jiraBase) ?? ""
        defaultProvider = try container.decodeIfPresent(String.self, forKey: .defaultProvider) ?? ""
        speechProvider = try container.decodeIfPresent(String.self, forKey: .speechProvider) ?? ""
        quickProvider = try container.decodeIfPresent(String.self, forKey: .quickProvider) ?? ""
        ghostText = try container.decodeIfPresent(Bool.self, forKey: .ghostText) ?? true
        fastPath = try container.decodeIfPresent(Bool.self, forKey: .fastPath) ?? false
        commitDrafts = try container.decodeIfPresent(Bool.self, forKey: .commitDrafts) ?? true
        conversationNames = try container.decodeIfPresent(Bool.self, forKey: .conversationNames) ?? true
        gitAccounts = try container.decodeIfPresent([SettingsGitAccount].self, forKey: .gitAccounts) ?? []
        pullStrategy = try container.decodeIfPresent(String.self, forKey: .pullStrategy) ?? "rebase"
        lastCloneFolder = try container.decodeIfPresent(String.self, forKey: .lastCloneFolder) ?? ""
        gitSignIn = try container.decodeIfPresent([String].self, forKey: .gitSignIn) ?? []
        agentGeneral = try container.decodeIfPresent(String.self, forKey: .agentGeneral) ?? ""
        gitCommitInstructions = try container.decodeIfPresent(String.self, forKey: .gitCommitInstructions) ?? ""
        gitPRInstructions = try container.decodeIfPresent(String.self, forKey: .gitPRInstructions) ?? ""
        gitBranchInstructions = try container.decodeIfPresent(String.self, forKey: .gitBranchInstructions) ?? ""
        gitName = try container.decodeIfPresent(String.self, forKey: .gitName) ?? ""
        gitEmail = try container.decodeIfPresent(String.self, forKey: .gitEmail) ?? ""
        // `try?`: a malformed connections field must not blank the whole Settings tree.
        connections = (try? container.decodeIfPresent([LenientElement<SettingsConnection>].self, forKey: .connections))?
            .compactMap(\.value) ?? []
        jiraTokenStored = (try? container.decodeIfPresent(Bool.self, forKey: .jiraTokenStored)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, jiraBase, defaultProvider, speechProvider, quickProvider, ghostText, fastPath, commitDrafts, conversationNames, gitAccounts, pullStrategy, lastCloneFolder, gitSignIn,
            agentGeneral, gitCommitInstructions, gitPRInstructions, gitBranchInstructions
        case gitName, gitEmail, connections, jiraTokenStored
    }

    /// What the tree's Organisation node is labelled with: the display
    /// name when there is one, the id otherwise. The same fallback
    /// `list_orgs` describes — *"an organisation without a display name
    /// falls back to showing its id"* — so the pane and the org picker
    /// name the same organisation the same way.
    public var label: String { displayName.isEmpty ? id : displayName }
}

/// One provider binding, org-level.
///
/// Deliberately thinner than #200's account table, which adds credential
/// presence, liveness and the minted token's date, and lists accounts
/// homed in OTHER organisations too. This answers "what has this
/// organisation registered", which is what a read-only tree needs.
public struct SettingsProvider: Sendable, Equatable, Decodable {
    public var id: String
    public var kind: String
    public var label: String
    public var configDir: String
    /// That this binding did not claim the config dir's headless home.
    /// Drawn as a **fact rather than a control**: it is add-time only, so
    /// remove-and-re-add is the honest gesture and there is nothing here
    /// to edit.
    public var shared: Bool
    /// A `local` provider's endpoint (3b-viii). Empty for every other kind.
    public var baseURL: String
    /// The quick-task operations this provider serves (`infill`, `respond`), resolved by Go from
    /// the kind when the record does not say.
    public var serves: [String]

    public init(
        id: String, kind: String, label: String = "", configDir: String = "", shared: Bool = false,
        baseURL: String = "", serves: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.configDir = configDir
        self.shared = shared
        self.baseURL = baseURL
        self.serves = serves
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        configDir = try container.decodeIfPresent(String.self, forKey: .configDir) ?? ""
        shared = try container.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        serves = try container.decodeIfPresent([String].self, forKey: .serves) ?? []
    }

    private enum CodingKeys: String, CodingKey { case id, kind, label, configDir, shared, baseURL, serves }
}

/// A project's agent instructions as `config_tree` sends them (3a-iii-b); empty when unset.
public struct SettingsAgentTexts: Sendable, Equatable, Decodable {
    public var general: String
    public var commits: String
    public var pullRequests: String
    /// Workspaces (decision 10): how a workspace's branch is named.
    public var branches: String

    public init(general: String = "", commits: String = "", pullRequests: String = "", branches: String = "") {
        self.general = general
        self.commits = commits
        self.pullRequests = pullRequests
        self.branches = branches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = try c.decodeIfPresent(String.self, forKey: .general) ?? ""
        commits = try c.decodeIfPresent(String.self, forKey: .commits) ?? ""
        pullRequests = try c.decodeIfPresent(String.self, forKey: .pullRequests) ?? ""
        branches = try c.decodeIfPresent(String.self, forKey: .branches) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case general, commits, pullRequests, branches }
}

public struct SettingsProject: Sendable, Equatable, Decodable {
    public var name: String
    public var path: String
    public var roots: [SettingsRoot]
    public var environments: [SettingsEnvironment]
    public var editor: SettingsProjectEditor
    /// 3a-iii-b: the project's agent instructions.
    public var agent: SettingsAgentTexts

    public init(
        name: String, path: String = "",
        roots: [SettingsRoot] = [], environments: [SettingsEnvironment] = [],
        editor: SettingsProjectEditor = .defaults, agent: SettingsAgentTexts = SettingsAgentTexts()
    ) {
        self.name = name
        self.path = path
        self.roots = roots
        self.environments = environments
        self.editor = editor
        self.agent = agent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decodeIfPresent(SettingsAgentTexts.self, forKey: .agent) ?? SettingsAgentTexts()
        name = try container.decode(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        roots = try container.decodeIfPresent([SettingsRoot].self, forKey: .roots) ?? []
        environments = try container.decodeIfPresent([SettingsEnvironment].self, forKey: .environments) ?? []
        editor = try container.decodeIfPresent(SettingsProjectEditor.self, forKey: .editor) ?? .defaults
    }

    private enum CodingKeys: String, CodingKey { case name, path, roots, environments, editor, agent }
}

public struct SettingsRoot: Sendable, Equatable, Decodable {
    public var path: String
    public var role: String

    public init(path: String, role: String = "") {
        self.path = path
        self.role = role
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case path, role }
}

/// The level that holds things, and the reason the tree is four deep.
public struct SettingsEnvironment: Sendable, Equatable, Decodable {
    public var name: String
    public var databases: [SettingsDatabase]
    /// The environment's API entries, **drawn read-only permanently**.
    ///
    /// **A LIST, because it became one.** This was a single optional entry
    /// and the comment here said a form built on today's API shape is one
    /// rebuilt on someone else's schedule. 2c-iv then made it a list of
    /// NAMED entries, so one request can run against staging and then
    /// production. Read-only is what kept the cost to a shape change.
    public var api: [SettingsAPI]
    /// Whether the org counts this environment as production (the Go side's `EnvironmentIsProduction`:
    /// the explicit flag, else the name). nil when the `wakil-ctx` that wrote the tree predates the field —
    /// a reader treats nil as "not known" and fails toward asking.
    public var production: Bool?

    public init(name: String, databases: [SettingsDatabase] = [], api: [SettingsAPI] = [], production: Bool? = nil) {
        self.name = name
        self.databases = databases
        self.api = api
        self.production = production
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        databases = try container.decodeIfPresent([SettingsDatabase].self, forKey: .databases) ?? []
        api = try container.decodeIfPresent([SettingsAPI].self, forKey: .api) ?? []
        production = try container.decodeIfPresent(Bool.self, forKey: .production)
    }

    private enum CodingKeys: String, CodingKey { case name, databases, api, production }
}

/// A database row: its name, driver, and the Keychain entry NAMES of its
/// credentials. Never a value.
public struct SettingsDatabase: Sendable, Equatable, Decodable {
    public var name: String
    public var driver: String
    public var ref: String
    public var writeRef: String
    /// Derived on the Go side from `writeRef` rather than stored, so the
    /// two cannot disagree — the class of lie issue #14 was.
    public var writable: Bool
    /// Where the database lives, when it was saved as parts (2e-iv); nil for a legacy record.
    /// Never a password — the Go type has none.
    public var connection: SettingsDatabaseConnection?

    public init(
        name: String, driver: String = "", ref: String = "", writeRef: String = "", writable: Bool = false,
        connection: SettingsDatabaseConnection? = nil
    ) {
        self.connection = connection
        self.name = name
        self.driver = driver
        self.ref = ref
        self.writeRef = writeRef
        self.writable = writable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        driver = try container.decodeIfPresent(String.self, forKey: .driver) ?? ""
        ref = try container.decodeIfPresent(String.self, forKey: .ref) ?? ""
        writeRef = try container.decodeIfPresent(String.self, forKey: .writeRef) ?? ""
        writable = try container.decodeIfPresent(Bool.self, forKey: .writable) ?? false
        connection = try container.decodeIfPresent(SettingsDatabaseConnection.self, forKey: .connection)
    }

    private enum CodingKeys: String, CodingKey { case name, driver, ref, writeRef, writable, connection }
}

/// A database's non-secret parts, as `ctx_config_tree` reports them (2e-iv).
public struct SettingsDatabaseConnection: Sendable, Equatable, Decodable {
    public var host: String
    public var port: String
    public var database: String
    public var user: String
    public var path: String
    public var writeUser: String

    public init(
        host: String = "", port: String = "", database: String = "", user: String = "",
        path: String = "", writeUser: String = ""
    ) {
        self.host = host; self.port = port; self.database = database
        self.user = user; self.path = path; self.writeUser = writeUser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(String.self, forKey: .port) ?? ""
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        writeUser = try c.decodeIfPresent(String.self, forKey: .writeUser) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case host, port, database, user, path, writeUser }
}

public struct SettingsAPI: Sendable, Equatable, Decodable {
    /// What a request records — never the origin, which is what lets one
    /// request run against staging and then production (2c-iv).
    public var name: String
    public var baseUrl: String
    public var authRef: String
    /// The header the credential travels in; empty when none is set (2e-iii).
    public var authHeader: String

    public init(name: String = "", baseUrl: String, authRef: String = "", authHeader: String = "") {
        self.name = name
        self.baseUrl = baseUrl
        self.authRef = authRef
        self.authHeader = authHeader
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        authRef = try container.decodeIfPresent(String.self, forKey: .authRef) ?? ""
        authHeader = try container.decodeIfPresent(String.self, forKey: .authHeader) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case name, baseUrl, authRef, authHeader }
}

public struct SettingsMisfiledProject: Sendable, Equatable, Decodable {
    public var name: String
    public var path: String
    public var filedUnder: String
    public var declaredOrg: String

    public init(name: String, path: String = "", filedUnder: String = "", declaredOrg: String = "") {
        self.name = name
        self.path = path
        self.filedUnder = filedUnder
        self.declaredOrg = declaredOrg
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        filedUnder = try container.decodeIfPresent(String.self, forKey: .filedUnder) ?? ""
        declaredOrg = try container.decodeIfPresent(String.self, forKey: .declaredOrg) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case name, path, filedUnder, declaredOrg }
}

/// Decodes `ctx_config_tree`'s reply into a `SettingsTree`.
///
/// **Extracted and tested directly**, which is this phase's standing rule
/// for a decoder (the spec's *Testing Decisions*, following
/// `decodeProviderCredentials`): the browser trip and the Keychain are the
/// operator's machine and belong to the runbook, and everything either
/// side of them is a pure function of bytes.
///
/// **It refuses rather than passing a half-read tree on.** `nil` means the
/// reply was not a config tree, and the pane says so; a decoder that
/// returned an empty tree for a malformed reply would draw an organisation
/// with no projects, which is a sentence about the operator's machine that
/// may be false.
public func decodeSettingsTree(fromResult result: JSONValue?) -> SettingsTree? {
    guard case .object(let object)? = result,
          let structured = object["structuredContent"]
    else { return nil }
    // Round-tripped through `Data` rather than walked by hand: the tree is
    // four levels of nested objects and arrays, and a hand-written walk of
    // it is exactly the parser whose failure mode is a silently empty
    // pane.
    guard let data = try? JSONEncoder().encode(structured) else { return nil }
    return try? JSONDecoder().decode(SettingsTree.self, from: data)
}
