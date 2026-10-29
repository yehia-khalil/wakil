import Foundation

/// The collapsed rail (design-language §10): a spine of short 2 pt marks, one per open pane, in the
/// rail's own order, so "what is open" and "what is working" stay readable with the rail put away.
/// Pure: the view draws what this says, and `RailSpineTests` asserts it, because `WakilApp` has no
/// test target.
public enum RailSpine {
    /// One pane's mark. Colour and length are separate questions: the **active** pane's mark is the
    /// longer one, and a **working** pane's mark is green — so a pane that is both is long and green,
    /// as the rail's tick is one mark where working outranks active.
    public struct Mark: Sendable, Equatable, Identifiable {
        public enum Tone: Sendable, Equatable {
            /// `RailTreatment.workingTickColour`; wins on a pane that is also active.
            case working
            /// `RailTreatment.activeTickColour`.
            case active
            /// Quiet: the far plane's treatment, no hue.
            case quiet
        }
        public let id: String
        public let isActive: Bool
        public let isWorking: Bool
        public var tone: Tone { isWorking ? .working : (isActive ? .active : .quiet) }
        public var length: Double { isActive ? RailSpine.activeLength : RailSpine.restLength }
    }

    /// Marks are 3 pt: thicker than the rail's tick, so they read in the context line's band.
    public static let thickness: Double = 3
    /// A pane that is open and not active.
    public static let restLength: Double = 10
    /// The active pane's, longer so it reads without hue.
    public static let activeLength: Double = 18
    /// Between one mark and the next.
    public static let gap: Double = 6
    /// The strip at the window's right edge that peeks the rail, full height.
    public static let edgeZone: Double = 6
    /// The spine's own hit width: the longest mark plus room to land on it.
    public static let hitWidth: Double = 32
    /// The spine's hit height, laid across in the context line's band.
    public static let hitHeight: Double = 24
    /// How far above the canvas row's top the spine's centre sits: the context line's band.
    public static let lift: Double = 30
    /// How long the pointer rests before the rail comes out, and how long after it leaves before
    /// the rail goes back. Short in, longer out: a pointer that overshoots the rail's edge does not
    /// lose it.
    public static let peekDelay: Duration = .milliseconds(150)
    public static let leaveDelay: Duration = .milliseconds(300)
    /// How far from the right the peeked rail travels as it arrives; the rest of the entrance is the
    /// plane's own opacity and blur release (§3, §7). A short step, never a swoop.
    public static let travel: Double = 28

    /// One mark per pane, in the order `panes` has them.
    public static func marks(panes: [Pane], focusedId: String?) -> [Mark] {
        panes.map { Mark(id: $0.id, isActive: $0.id == focusedId, isWorking: $0.busy) }
    }

    /// The spine's accessibility label: one element for the whole stack.
    public static let label = "Open panes"

    /// "4 panes, editor active" — the count, and the active pane's kind; a working count only when
    /// something is working. The marks carry colour alone, so this is where VoiceOver gets it.
    public static func value(panes: [Pane], focusedId: String?) -> String {
        guard !panes.isEmpty else { return "No panes" }
        var parts = [panes.count == 1 ? "1 pane" : "\(panes.count) panes"]
        if let active = panes.first(where: { $0.id == focusedId }) { parts.append("\(active.kind) active") }
        let working = panes.filter(\.busy).count
        if working > 0 { parts.append("\(working) working") }
        return parts.joined(separator: ", ")
    }
}

/// What the window remembers about itself across a relaunch. One window today (`AppScene`), so
/// "per window" is one file.
public struct WindowState: Sendable, Equatable, Codable {
    /// §10's collapsed rail. Starts false: the rail is shown until the operator puts it away.
    public var railCollapsed: Bool

    public init(railCollapsed: Bool = false) { self.railCollapsed = railCollapsed }
}
