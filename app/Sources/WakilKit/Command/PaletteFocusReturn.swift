/// Where the keyboard goes when the palette closes (rule 6: stay where the operator was).
///
/// **AppKit's first responder is not always what held the keyboard.** A SwiftUI `.focusable()`
/// view — the terminal pane, the git pane — has no `NSView` of its own: while it holds focus,
/// AppKit's first responder is the window's hosting view (or the window), and the pane's own
/// `@FocusState` is what routes keys to it. Handing that hosting view back with
/// `makeFirstResponder` focuses nothing inside it — the keyboard lands on an unnamed group and
/// the terminal never sees another key (spec 46, the e2e auditor's palette-escape red). Such a
/// close asks the focused pane to take the keyboard instead (`WindowModel.keyboardReturns`).
public enum PaletteFocusReturn: Equatable, Sendable {
    /// Leave the keyboard where it is: a run already moved it, a plane that takes over focuses
    /// its own field, or nothing held it at open.
    case leave
    /// Hand the AppKit responder captured at open back to its window.
    case responder
    /// Ask the window's focused pane to take the keyboard back through SwiftUI focus.
    case focusedPane

    /// What held the keyboard when the palette opened.
    public enum Holder: Equatable, Sendable {
        /// No first responder at all.
        case nothing
        /// The window or its hosting view: a SwiftUI focusable inside it held the keyboard.
        case swiftUIFocus
        /// A real AppKit view — a text view, a field, a web view — that takes the keyboard itself.
        case appKitView
    }

    public static func decide(restoringFocus: Bool, runMovedFocus: Bool, heldBy: Holder) -> PaletteFocusReturn {
        guard restoringFocus, !runMovedFocus else { return .leave }
        switch heldBy {
        case .nothing: return .leave
        case .swiftUIFocus: return .focusedPane
        case .appKitView: return .responder
        }
    }
}
