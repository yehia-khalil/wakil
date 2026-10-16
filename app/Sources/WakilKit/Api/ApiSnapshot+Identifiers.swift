import Foundation

/// An api pane offers its entry and its rendered path to the vocabulary (`PaneSource`).
extension ApiSnapshot: OffersIdentifiers {
    public func identifiers(origin: String) -> [Identifier] {
        [Identifier(text: entry, kind: .endpoint, origin: origin, source: .panes),
         Identifier(text: apiRenderedPath(request.path), kind: .endpoint, origin: origin, source: .panes)]
    }
}
