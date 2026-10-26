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
        if e.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "password" { return .password }

        for token in e.autocomplete.lowercased().split(whereSeparator: \.isWhitespace) {
            if let reason = autocompleteRules[String(token)] { return reason }
        }

        // camelCase first (otpCode -> otp Code), then lowercase, then - and _ as spaces.
        let texts = [e.name, e.id, e.label, e.placeholder].map {
            $0.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
                .lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        for (reason, pattern) in textRules {
            if texts.contains(where: { $0.range(of: pattern, options: .regularExpression) != nil }) { return reason }
        }
        return nil
    }

    private static let autocompleteRules: [String: BrowserFieldReason] = [
        "current-password": .password, "new-password": .password,
        "cc-number": .card, "cc-csc": .cardCode, "one-time-code": .oneTimeCode,
    ]

    private static let textRules: [(BrowserFieldReason, String)] = [
        (.password, #"password|passwd|passcode|\bpwd\b"#),
        (.card, #"card ?number|card ?no\b|credit ?card|debit ?card|\bcc ?num(ber)?\b|\bccn\b"#),
        (.cardCode, #"\bcvv2?\b|\bcvc2?\b|\bcsc\b|security ?code|card ?verification"#),
        (.oneTimeCode, #"\botp\b|one ?time|\b2fa\b|\bmfa\b|\btotp\b|verification ?code|auth(entication)? ?code"#
            + #"|\bpin\b|authenticator|sms ?code|(login|access|sign ?in) ?code|verification ?(token|pin)"#),
    ]

    /// The same rules as the page script's JavaScript, `function wakilYours(e)` over an element's
    /// `type`, `autocomplete`, `name`, `id`, `label` and `placeholder`, answering the reason's word or
    /// null. Generated from the tables above, so the script's re-check at the act (3c-ii) cannot
    /// drift from Swift's; the patterns are ones ICU and JavaScript read alike.
    public static var scriptSource: String {
        func literal(_ s: String) -> String {
            String(decoding: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        let tokens = autocompleteRules.keys.sorted()
            .map { "\(literal($0)): \(literal(autocompleteRules[$0]!.rawValue))" }.joined(separator: ", ")
        let rules = textRules.map { "[\(literal($0.0.rawValue)), new RegExp(\(literal($0.1)))]" }
            .joined(separator: ", ")
        return """
            function wakilYours(e) {
              const tokens = {\(tokens)};
              const rules = [\(rules)];
              if (String(e.type || '').trim().toLowerCase() === 'password') return 'password';
              for (const token of String(e.autocomplete || '').toLowerCase().split(/\\s+/)) {
                if (Object.prototype.hasOwnProperty.call(tokens, token)) return tokens[token];
              }
              const texts = [e.name, e.id, e.label, e.placeholder].map(s => String(s || '')
                .replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().replace(/-/g, ' ').replace(/_/g, ' '));
              for (const [reason, pattern] of rules) {
                if (texts.some(t => pattern.test(t))) return reason;
              }
              return null;
            }
            """
    }
}
