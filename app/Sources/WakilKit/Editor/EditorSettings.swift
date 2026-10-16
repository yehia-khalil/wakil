import Foundation

/// What Monaco is told (3b-v): the editor options the settings decide.
public struct EditorViewOptions: Sendable, Equatable {
    public var fontSize: Int
    public var wordWrap: Bool
    public var tabSize: Int
    public var insertSpaces: Bool
    public init(fontSize: Int, wordWrap: Bool, tabSize: Int, insertSpaces: Bool) {
        self.fontSize = fontSize
        self.wordWrap = wordWrap
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
    }
}

/// The editor settings in force: the app-wide tier and the active project's, as
/// `ctx_editor_settings` answers them (one flat object). `appError` is settings.json's error,
/// whole; the values are then the defaults.
public struct EditorSettings: Sendable, Equatable, Decodable {
    public var app: SettingsEditor
    public var project: SettingsProjectEditor
    public var appError: String?

    public static let defaults = EditorSettings(app: .defaults, project: .defaults, appError: nil)

    public init(app: SettingsEditor, project: SettingsProjectEditor, appError: String?) {
        self.app = app
        self.project = project
        self.appError = appError
    }

    /// Both halves read the same flat object.
    public init(from decoder: Decoder) throws {
        app = try SettingsEditor(from: decoder)
        project = try SettingsProjectEditor(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appError = try c.decodeIfPresent(String.self, forKey: .appError)
    }

    private enum CodingKeys: String, CodingKey { case appError }

    public var viewOptions: EditorViewOptions {
        EditorViewOptions(fontSize: app.fontSize, wordWrap: app.wordWrap,
                          tabSize: project.tabSize, insertSpaces: project.insertSpaces)
    }
}

/// `ctx_editor_settings`' reply, or nil when it is not one.
public func decodeEditorSettings(fromResult result: JSONValue?) -> EditorSettings? {
    guard case .object(let object)? = result, let structured = object["structuredContent"],
          let data = try? JSONEncoder().encode(structured) else { return nil }
    return try? JSONDecoder().decode(EditorSettings.self, from: data)
}
