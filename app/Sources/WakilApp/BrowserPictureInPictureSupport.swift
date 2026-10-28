import Foundation
import ObjectiveC
import WebKit

/// Whether this Mac's WebKit has the private API automatic picture in picture needs (3d-iii, ruling 7).
///
/// **Three checks, made once per launch.** Picture in picture is WebKit's only through private API:
/// - the **private** `WKPreferences` KVC key `allowsPictureInPictureMediaPlayback`. KVC's
///   `setValue(_:forKey:)` looks for `set<Key>:` and then `_set<Key>:`, and macOS has only the second,
///   so the key resolves to `_setAllowsPictureInPictureMediaPlayback:`. Without it the KVC set would
///   raise, so the preference is set only when this check passes.
/// - WebKit's **private** `WKUIDelegatePrivate` protocol declaring the two callbacks
///   `BrowserTabDelegate` implements, as optional instance methods. A delegate callback cannot be
///   checked with `responds(to:)` on our own object, because WebKit is the one that asks; the protocol
///   says whether this WebKit asks at all. With no such protocol, both count as missing.
///
/// Anything missing: nothing is configured, nothing floats, and Settings shows
/// `BrowserPictureInPicture.unavailableLine(missing:)`.
@MainActor
enum BrowserPictureInPictureSupport {
    /// Private: `WKPreferences`' KVC key, set with `setValue(true, forKey:)`.
    static let preferenceKey = "allowsPictureInPictureMediaPlayback"

    /// The selectors this WebKit lacks, named as the selectors read; empty when all are there.
    static let missing: [String] = {
        var missing: [String] = []
        // Private: the setter the KVC key resolves to (3d-iii probe e).
        let setter = "_setAllowsPictureInPictureMediaPlayback:"
        if !WKPreferences.instancesRespond(to: NSSelectorFromString(setter)) { missing.append(setter) }
        // Private: `WKUIDelegatePrivate`'s two callbacks, optional instance methods.
        let callbacks = ["_webView:hasVideoInPictureInPictureDidChange:", "_webViewFullscreenMayReturnToInline:"]
        guard let delegate = NSProtocolFromString("WKUIDelegatePrivate") else { return missing + callbacks }
        for name in callbacks {
            let method = protocol_getMethodDescription(delegate, NSSelectorFromString(name), false, true)
            if method.name == nil { missing.append(name) }
        }
        return missing
    }()

    static var available: Bool { missing.isEmpty }
}
