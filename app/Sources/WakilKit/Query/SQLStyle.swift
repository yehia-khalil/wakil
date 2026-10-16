/// How a query-line token looks: an opacity step on the one text colour, plus weight and
/// italic. **No colour value lives here** — `design-language.md` §5 forbids decorative hue,
/// so structure is carried by brightness alone (operator, 2026-10-07).
public struct SQLTokenStyle: Equatable, Sendable {
    public let opacity: Double
    public let medium: Bool
    public let italic: Bool
    public init(opacity: Double, medium: Bool, italic: Bool) {
        self.opacity = opacity
        self.medium = medium
        self.italic = italic
    }
}

public enum SQLStyle {
    public static func style(for kind: SQLTokenKind) -> SQLTokenStyle {
        switch kind {
        case .keyword: return SQLTokenStyle(opacity: 1.0, medium: true, italic: false)
        case .identifier, .quotedIdentifier: return SQLTokenStyle(opacity: 0.85, medium: false, italic: false)
        case .string, .number, .op, .punctuation: return SQLTokenStyle(opacity: 0.6, medium: false, italic: false)
        case .comment: return SQLTokenStyle(opacity: 0.4, medium: false, italic: true)
        case .whitespace: return SQLTokenStyle(opacity: 1.0, medium: false, italic: false)
        }
    }
}
