import Foundation

/// The settings pane's ink (settings revamp): text is cool white stepped down by opacity, in four
/// steps, never more. Read text is `primary` or `secondary`, which both clear WCAG's 4.5:1 on the
/// void; `tertiary` is for hairlines and glyphs that are not read; `disabled` for what cannot be
/// pressed (WCAG exempts it).
public enum SettingsInk {
    /// Values and labels: 12.4:1.
    public static let primary = 0.86
    /// Section headers, hints, the breadcrumb, footnotes and an empty value's `—`: 6.7:1.
    public static let secondary = 0.62
    /// Not read: chevrons, hairlines, badges beside a label.
    public static let tertiary = 0.40
    /// A control that cannot be pressed now.
    public static let disabled = 0.32

    /// Cool white `#e8ecf6` at `opacity`, composited over the void's lightest stop `#070812`,
    /// against that void: WCAG 2's contrast ratio.
    public static func contrast(opacity: Double) -> Double {
        let ink = (0xE8, 0xEC, 0xF6), void = (0x07, 0x08, 0x12)
        func mix(_ a: Int, _ b: Int) -> Double { opacity * Double(a) + (1 - opacity) * Double(b) }
        let text = luminance(mix(ink.0, void.0), mix(ink.1, void.1), mix(ink.2, void.2))
        let ground = luminance(Double(void.0), Double(void.1), Double(void.2))
        return (text + 0.05) / (ground + 0.05)
    }

    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            let c = channel / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
