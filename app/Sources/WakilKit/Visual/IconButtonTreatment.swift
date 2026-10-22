import Foundation

/// A small icon button's answer to the pointer (3a-ii walk): the Changes view's **+**, **−** and **↺**
/// had none, so a hover and a press looked like nothing. As VS Code's row actions: a rounded fill
/// under the glyph on hover, a stronger one while the mouse is down, and the glyph brightened. The
/// same cool white at stepped opacities — §5 steps by opacity, never by a hue.
public enum IconButtonTreatment {
    /// The glyph at rest, and lit (hovered or pressed).
    public static let restGlyph: Double = 0.75
    public static let litGlyph: Double = 1.0
    /// The fill under the glyph: hovered, then pressed. Twice the rail's row lift (0.05), which an
    /// icon 16pt wide over a lifted row did not show.
    public static let hoverFill: Double = 0.10
    public static let pressedFill: Double = 0.18

    /// The fill's opacity. A disabled button (a write in flight, Rule 5) answers nothing.
    public static func fill(hovered: Bool, pressed: Bool, enabled: Bool) -> Double {
        guard enabled else { return 0 }
        if pressed { return pressedFill }
        return hovered ? hoverFill : 0
    }

    /// The glyph's opacity.
    public static func glyph(hovered: Bool, pressed: Bool, enabled: Bool) -> Double {
        enabled && (hovered || pressed) ? litGlyph : restGlyph
    }

    /// How long the hover fill takes to come and go: a row's hover (`RailTreatment.rowHoverDuration`),
    /// or none under Reduce Motion. A press is never animated.
    public static func hoverDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : RailTreatment.rowHoverDuration
    }
}
