/// The query line's key chords, by physical key so they work on every keyboard layout.
public enum QueryLineKeys {
    /// `kVK_ANSI_F`: the key in the F position whatever character the layout gives it.
    public static let formatKeyCode: UInt16 = 3

    /// ⌥⇧F: the F-position key with exactly Option and Shift among ⌘⌃⌥⇧. Matching the
    /// character instead (`charactersIgnoringModifiers == "f"`) fails on non-Latin layouts.
    public static func isFormat(keyCode: UInt16, option: Bool, shift: Bool, command: Bool, control: Bool) -> Bool {
        keyCode == formatKeyCode && option && shift && !command && !control
    }
}
