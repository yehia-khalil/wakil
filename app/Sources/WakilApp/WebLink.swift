import SwiftUI
import WakilKit

/// A control that opens a web page (design-language §5, walk 2026-10-29): its words and ↗, in the
/// void's blue — blue's one meaning, so the operator knows before the click that it leaves the view.
enum WebLink {
    static let colour = Color(VoidPalette.blue)

    /// `details ↗`.
    static func label(_ words: String) -> String { "\(words) ↗" }
}
