import Foundation

/// A terminal offers its working directory to the vocabulary (`PaneSource`).
extension TerminalSnapshot: OffersIdentifiers {
    public func identifiers(origin: String) -> [Identifier] {
        [Identifier(text: cwd, kind: .path, origin: origin, source: .panes)]
    }
}
