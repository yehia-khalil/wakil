import Foundation
import Testing
@testable import WakilKit

/// The never-list: fields the agent never fills (Invariant 6), 3c-ii.

private func field(type: String = "", autocomplete: String = "", name: String = "", id: String = "",
                   label: String = "", placeholder: String = "") -> BrowserElement {
    BrowserElement(ref: "e1", role: "textbox", label: label, type: type, autocomplete: autocomplete,
                   name: name, id: id, placeholder: placeholder)
}

@Test func theNeverListOverEachFieldShape() {
    let table: [(String, BrowserElement, BrowserFieldReason?)] = [
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
    for (what, e, want) in table {
        #expect(BrowserFieldRules.yours(e) == want, "\(what)")
    }
}

@Test func theReasonsReadAsTheRefusalNamesThem() {
    #expect(BrowserFieldReason.password.rawValue == "password")
    #expect(BrowserFieldReason.card.rawValue == "card number")
    #expect(BrowserFieldReason.cardCode.rawValue == "card security code")
    #expect(BrowserFieldReason.oneTimeCode.rawValue == "one-time code")
}
