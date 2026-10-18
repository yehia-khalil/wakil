import CoreText
import SwiftUI
import WakilKit

/// A file's language icon (3b-iv-b): one Seti glyph, drawn as text so it takes the colour and
/// opacity of the row it sits in. Decorative — hidden from accessibility so no row's label changes.
/// If the font did not register, it draws nothing and the row looks as it did before icons.
struct EditorFileIcon: View {
    let glyph: Character
    init(_ glyph: Character) { self.glyph = glyph }

    /// Registered once per process, on first use.
    private static let available: Bool = {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("seti/seti.woff") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    /// Seti's glyphs carry their own padding (VS Code draws them at 150 % of the label), so 13 pt
    /// sits at about the cap height of the 11.5–12 pt names. The walk judges it; change it here only.
    static let size: CGFloat = 13

    var body: some View {
        if Self.available {
            Text(String(glyph))
                .font(.custom("seti", size: Self.size))
                .frame(width: 10)
                .accessibilityHidden(true)
        }
    }
}
