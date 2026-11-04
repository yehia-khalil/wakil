import Foundation

extension RunTone {
    /// Design-language §5: violet working, amber waiting, green healthy only, red `#e85c5c` failed.
    public var colour: RGB {
        switch self {
        // §5's luminance violet raised to read as text (`#9e82ff`); `#7c5cff` is the working dot's.
        case .working: VoidPalette.accent
        case .waiting: HomePalette.amber
        case .ready: HomePalette.green
        case .failed: HomePalette.red
        }
    }
}
