import WakilKit
import SwiftUI

extension Color {
    /// A `WakilKit` palette colour as a SwiftUI `Color`.
    ///
    /// `RGB` stays free of SwiftUI so that every colour question with a right
    /// answer can be decided and tested without a display (spec §2.3); this is
    /// the one place that crossing happens.
    ///
    /// Added 2026-09-14 for the environment badge, which previously repeated
    /// `#e85c5c` and `#e8ecf6` as literals a few lines from the palette that
    /// already owned them. The rest of the view layer still carries its own
    /// literals — converting those belongs with the colour-token pass, not
    /// with a contrast fix.
    init(_ rgb: RGB) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
