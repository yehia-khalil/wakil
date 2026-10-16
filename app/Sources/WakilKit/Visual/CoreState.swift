import Foundation

/// Which of `design-language.md` §4's four states Wakil is in.
///
/// **Since 2b-iv the void carries these, not a sphere.** §4's "the Core" now
/// means Wakil's presence rather than an object, and the room expresses it —
/// `CoreMotion` turns each case below into periods, amplitudes and a frame
/// rate. The enum reaches Metal only through those numbers, which is why
/// there is no longer a `shaderIndex` here: the shader has no state to
/// branch on.
///
/// **All four are rendered; three are set.** Listening is set by push-to-talk
/// (2d-ii) through `WindowModel.isListening`. Speaking stays unset: nothing
/// delivers text-to-speech (open question 17).
public enum CoreState: String, Sendable, Equatable, CaseIterable {
    /// The lowest ceiling of the four — its amplitude never rises as high as
    /// the other three's — on a 5.4 s breath. Present but asleep.
    case idle
    /// Brightest, and the bleeds tighten; breath quickens to 1.5 s. **2d.**
    case listening
    /// The two bleeds trade dominance on a 12 s turnover and drift slowly —
    /// the room turning something over.
    case thinking
    /// The lower bleed alone pulses on a 0.42 s speech cadence. The upper
    /// field holds still. **2d.**
    case speaking

    /// The state for a session with, or without, a turn in flight.
    public static func forTurn(inFlight: Bool) -> CoreState {
        inFlight ? .thinking : .idle
    }
}
