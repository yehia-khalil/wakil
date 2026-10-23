import Foundation

/// The file the Timeline and blame are about for `tab` (R2): a file tab's path relative to its root, or
/// a diff tab's root and path. Nil for a scratch tab or no tab.
public func editorTimelineSubject(_ tab: EditorTab?) -> (root: String, path: String)? {
    switch tab?.subject {
    case .file(let path, let root)? where path.hasPrefix(root + "/"): (root, String(path.dropFirst(root.count + 1)))
    case .diff(let root, let path, _, _)?: (root, path)
    default: nil
    }
}
