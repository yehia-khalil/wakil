import Foundation

/// Why a field is the operator's to fill. The raw value is the word the refusal uses (Invariant 6).
public enum BrowserFieldReason: String, Sendable {
    case password = "password"
    case card = "card number"
    case cardCode = "card security code"
    case oneTimeCode = "one-time code"
}

/// The never-list: password, card and one-time-code fields the agent never types into.
/// Judged from the element as read, and again on the live element at the act.
public enum BrowserFieldRules {
    public static func yours(_ e: BrowserElement) -> BrowserFieldReason? {
        if e.type.lowercased() == "password" { return .password }

        for token in e.autocomplete.lowercased().split(whereSeparator: \.isWhitespace) {
            switch token {
            case "current-password", "new-password": return .password
            case "cc-number": return .card
            case "cc-csc": return .cardCode
            case "one-time-code": return .oneTimeCode
            default: continue
            }
        }

        let texts = [e.name, e.id, e.label, e.placeholder].map {
            $0.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        for (reason, pattern) in textRules {
            if texts.contains(where: { $0.range(of: pattern, options: .regularExpression) != nil }) { return reason }
        }
        return nil
    }

    private static let textRules: [(BrowserFieldReason, String)] = [
        (.password, #"password|passwd|passcode|\bpwd\b"#),
        (.card, #"card ?number|card ?no\b|credit ?card|debit ?card|\bcc ?num(ber)?\b|\bccn\b"#),
        (.cardCode, #"\bcvv2?\b|\bcvc2?\b|\bcsc\b|security ?code|card ?verification"#),
        (.oneTimeCode, #"\botp\b|one ?time|\b2fa\b|\bmfa\b|\btotp\b|verification ?code|auth(entication)? ?code"#),
    ]
}
