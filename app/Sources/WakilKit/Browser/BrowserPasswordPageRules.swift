import Foundation

/// 3d-iv: the pure rules the window's password page (`BrowserPasswordScript`, the messages handler and
/// `BrowserPasswordAgent` in WakilApp) decides by — what a message from the page means, where the key
/// is drawn, and what the page's answer to a fill means. No WebKit here, and no value in any text.

/// A rect in the page, as plain numbers (`PaneFrame`'s reason: no AppKit or CoreGraphics in WakilKit).
public struct BrowserPasswordRect: Sendable, Equatable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The focused field's kind, as the page script reports it (ruling 11).
public enum BrowserPasswordFieldRole: String, Sendable, Equatable {
    case username, password
    /// `autocomplete="new-password"`: the key offers a strong password there.
    case new
}

/// One message from `wakil.passwords`. Anything else the page might post is nothing.
public enum BrowserPasswordPageMessage: Sendable, Equatable {
    /// A login field took focus (or moved): its rect in CSS pixels, from the viewport's top left.
    case field(role: BrowserPasswordFieldRole, rect: BrowserPasswordRect)
    case blur
    /// A form was sent (ruling 14). The only message that ever carries a password.
    case submit(username: String, password: String, isNew: Bool)

    /// The longest username or password taken from a page; a longer one is not a login.
    public static let maxValueLength = 4096

    /// The message's body as WebKit hands it over (`WKScriptMessage.body`: a dictionary of strings,
    /// numbers and booleans), or nil when it is not exactly one of the three.
    public static func parse(_ body: Any) -> BrowserPasswordPageMessage? {
        guard let object = body as? [String: Any], let kind = object["kind"] as? String else { return nil }
        switch kind {
        case "field":
            guard let raw = object["role"] as? String, let role = BrowserPasswordFieldRole(rawValue: raw),
                  let rect = object["rect"] as? [String: Any],
                  let x = number(rect["x"]), let y = number(rect["y"]),
                  let w = number(rect["w"]), let h = number(rect["h"]), w >= 0, h >= 0
            else { return nil }
            return .field(role: role, rect: BrowserPasswordRect(x: x, y: y, width: w, height: h))
        case "blur":
            return .blur
        case "submit":
            guard let username = object["username"] as? String, let password = object["password"] as? String,
                  username.count <= maxValueLength, password.count <= maxValueLength
            else { return nil }
            return .submit(username: username, password: password, isNew: (object["isNew"] as? Bool) ?? false)
        default:
            return nil
        }
    }

    /// A finite number. A `Bool` is not one, though Foundation would bridge it.
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// `location.origin` rebuilt from the sending frame's `WKSecurityOrigin` — never the page's own
    /// words (ruling 13). Port 0 is the scheme's default and is left out, as `location.origin` does.
    /// Nil for an origin with no host (`about:`, `data:`, a `file:` page).
    public static func origin(protocol scheme: String, host: String, port: Int) -> String? {
        let scheme = scheme.lowercased()
        guard scheme == "http" || scheme == "https", !host.isEmpty else { return nil }
        return port == 0 ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}

/// Where the key is drawn and when (ruling 11).
public enum BrowserPasswordKeyLayout {
    /// The key's square, in points.
    public static let size: Double = 16
    /// From the field's right edge, in points.
    public static let inset: Double = 4
    /// How long a blur is held before the key goes: a press on the key blurs the page first.
    public static let blurHold: Duration = .milliseconds(300)

    /// The key's frame in the page area's points: the field's CSS rect times the page's zoom, the key
    /// at its right edge, inset 4 pt, centred on its height.
    public static func frame(field: BrowserPasswordRect, zoom: Double) -> BrowserPasswordRect {
        let z = zoom > 0 ? zoom : 1
        let x = (field.x + field.width) * z - inset - size
        let y = (field.y + field.height / 2) * z - size / 2
        return BrowserPasswordRect(x: x, y: y, width: size, height: size)
    }

    /// Whether the focused field gets the key: a new-password field always; a login field once the
    /// site's logins are `read`, and only when it has a saved one. A list that could not be read
    /// (`hasLogins` nil) shows the key, so its list can show the Keychain's error whole (Rule 8).
    public static func showsKey(role: BrowserPasswordFieldRole, read: Bool, hasLogins: Bool?) -> Bool {
        role == .new || (read && hasLogins != false)
    }
}

/// What the page script's answer to a fill or a suggestion means. The script answers only `ok`,
/// `moved` or `nofield`; anything else is refused in Wakil's fixed words, never the answer's text — a
/// refusal reaches the journal (Review Focus 1).
public enum BrowserPasswordPageAnswer {
    public static let refusedReason = "the page's script refused, so nothing was put in the page."
    public static let noAnswerReason = "the page did not answer within 10 s, so nothing was put in the page."
    /// A fill or suggestion with the key's list not open on that tab: nothing is put in a page unpressed.
    public static let noPressReason = "the key's list is not open in that tab, so nothing was put in the page."

    /// Nil for `ok`. `now` is the tab's site as Wakil reads it, for `moved`.
    public static func error(_ answer: String?, now: String) -> BrowserPasswordPageError? {
        switch answer {
        case "ok": return nil
        case "moved": return .siteChanged(now: now)
        case "nofield": return .noField
        default: return .failed(refusedReason)
        }
    }
}
