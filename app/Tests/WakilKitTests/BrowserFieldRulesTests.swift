import Foundation
import JavaScriptCore
import Testing
@testable import WakilKit

/// The never-list: fields the agent never fills (Invariant 6), 3c-ii.

private func field(type: String = "", autocomplete: String = "", name: String = "", id: String = "",
                   label: String = "", placeholder: String = "") -> BrowserElement {
    BrowserElement(ref: "e1", role: "textbox", label: label, type: type, autocomplete: autocomplete,
                   name: name, id: id, placeholder: placeholder)
}

/// Every field shape the never-list is pinned over: Swift's rule and the page script's must agree on each.
private let neverListTable: [(String, BrowserElement, BrowserFieldReason?)] = [
        ("type=password", field(type: "password"), .password),
        ("current-password under type=text", field(type: "text", autocomplete: "section-a current-password"), .password),
        ("new-password", field(autocomplete: "new-password"), .password),
        ("billing cc-number", field(autocomplete: "billing cc-number"), .card),
        ("cc-csc", field(autocomplete: "cc-csc"), .cardCode),
        ("one-time-code", field(autocomplete: "one-time-code"), .oneTimeCode),
        ("name card_number", field(name: "card_number"), .card),
        ("label Credit card", field(label: "Credit card"), .card),
        ("placeholder CVV", field(placeholder: "CVV"), .cardCode),
        ("label Security code", field(label: "Security code"), .cardCode),
        ("id otp", field(id: "otp"), .oneTimeCode),
        ("label Verification code", field(label: "Verification code"), .oneTimeCode),
        ("name user_pwd", field(name: "user_pwd"), .password),
        ("label Guest name", field(label: "Guest name"), nil),
        ("label Passport number", field(label: "Passport number"), nil),
        ("label Promo code", field(label: "Promo code"), nil),
        ("label Card holder name", field(label: "Card holder name"), nil),
        ("label Booking reference", field(label: "Booking reference"), nil),
        ("autocomplete cc-name", field(autocomplete: "cc-name"), nil),
        ("camel otpCode", field(name: "otpCode"), .oneTimeCode),
        ("camel cardCvv", field(id: "cardCvv"), .cardCode),
        ("camel userOtp", field(name: "userOtp"), .oneTimeCode),
        ("camel cardNumber", field(name: "cardNumber"), .card),
        ("camel totpToken", field(name: "totpToken"), .oneTimeCode),
        ("camel cvvCode", field(name: "cvvCode"), .cardCode),
        ("name cc-num", field(name: "cc-num"), .card),
        ("lowercase cvv", field(name: "cvv"), .cardCode),
        ("label otp", field(label: "otp"), .oneTimeCode),
        ("type PASSWORD", field(type: "PASSWORD"), .password),
        ("type padded", field(type: " password"), .password),
        ("Enter PIN", field(label: "Enter PIN"), .oneTimeCode),
        ("Authenticator code", field(label: "Authenticator code"), .oneTimeCode),
        ("SMS code", field(label: "SMS code"), .oneTimeCode),
        ("Login code", field(label: "Login code"), .oneTimeCode),
        ("Verification token", field(label: "Verification token"), .oneTimeCode),
]

@Test func theNeverListOverEachFieldShape() {
    for (what, e, want) in neverListTable {
        #expect(BrowserFieldRules.yours(e) == want, "\(what)")
    }
}

@Test func theReasonsReadAsTheRefusalNamesThem() {
    #expect(BrowserFieldReason.password.rawValue == "password")
    #expect(BrowserFieldReason.card.rawValue == "card number")
    #expect(BrowserFieldReason.cardCode.rawValue == "card security code")
    #expect(BrowserFieldReason.oneTimeCode.rawValue == "one-time code")
}

/// The page script re-checks the never-list on the live element at the act (3c-ii), in JavaScript: the
/// same rules, generated from Swift's, give the same answer over every row.
@Test func thePageScriptsNeverListAgreesWithSwiftsOverEachFieldShape() throws {
    let context = try #require(JSContext())
    context.evaluateScript(BrowserFieldRules.scriptSource)
    #expect(context.exception == nil, "\(String(describing: context.exception))")
    let yours = try #require(context.objectForKeyedSubscript("wakilYours"))
    for (what, e, want) in neverListTable {
        let fields: [String: String] = ["type": e.type, "autocomplete": e.autocomplete, "name": e.name,
                                        "id": e.id, "label": e.label, "placeholder": e.placeholder]
        let answer = yours.call(withArguments: [fields])
        let got = answer.flatMap { $0.isNull || $0.isUndefined ? nil : $0.toString() }
        #expect(got == want?.rawValue, "\(what)")
    }
}
