import Foundation

/// The environment page's Production row (settings revamp, Rule 9): the operator declares an
/// environment production or not, or leaves it to its name — the name suggests, the operator
/// decides.
public enum SettingsProductionChoice: String, CaseIterable, Sendable {
    case no = "No"
    case yes = "Yes"
    case fromName = "From the name"

    /// The choice that reads `declared`, the environment's raw flag.
    public static func current(declared: Bool?) -> Self {
        switch declared {
        case true?: return .yes
        case false?: return .no
        case nil: return .fromName
        }
    }

    /// What choosing it writes: the flag, or nil to clear it.
    public var declared: Bool? {
        switch self {
        case .yes: return true
        case .no: return false
        case .fromName: return nil
        }
    }

    /// What the name decided, under the row, when nothing is declared; nil once declared, or when
    /// an older `wakil-ctx` did not say.
    public static func hint(declared: Bool?, production: Bool?) -> String? {
        guard declared == nil, let production else { return nil }
        return production ? "From the name: production." : "From the name: not production."
    }
}
