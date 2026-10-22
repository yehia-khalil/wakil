import Foundation

/// The editor pane's two surfaces, here rather than in `EditorPaneStyle` so a test can measure the
/// text drawn on them against `PRODUCT.md`'s 4.5:1 floor (3a-ii review I4).
public enum EditorSurface {
    /// The pane's body and its column.
    public static let slab = RGB(0x0b / 255.0, 0x0d / 255.0, 0x14 / 255.0)
    /// A highlighted row and the commit message box.
    public static let lifted = RGB(0x1c / 255.0, 0x20 / 255.0, 0x30 / 255.0)
}
