import Foundation

/// 3d-i walk: which address a tab's icon comes from, and which answers are kept. Pure, so the
/// rules are tested; the fetch itself (an ephemeral URLSession) is the app's (`BrowserFaviconLoader`).
///
/// **Why the network is touched at all.** 3c-i kept only `data:` icons, so nearly every real tab
/// showed the globe. The page has already contacted that site, so asking it for its own icon
/// reveals nothing new; the request carries no cookies, no credentials and no cache (an ephemeral
/// session), so nothing ties it to the organisation's browsing data.
public enum BrowserFaviconRules {
    /// The most bytes an icon may be, as a `data:` icon always was.
    public static let maxBytes = 64 * 1024
    /// How long one fetch may take.
    public static let timeout: TimeInterval = 5

    /// Where to fetch the icon of the page at `pageURL`: the page's `link rel=icon` `href` (resolved
    /// against the page), else `<origin>/favicon.ico` when the page names none. http(s) only; nil for
    /// a `data:` icon (decoded, never fetched), any other scheme, or a page that is not http(s).
    public static func url(href: String?, pageURL: String) -> URL? {
        let page = URL(string: pageURL)
        guard let page, isWeb(page), page.host?.isEmpty == false else { return nil }
        let named = href?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if named.isEmpty {
            var origin = URLComponents()
            origin.scheme = page.scheme?.lowercased()
            origin.host = page.host
            origin.port = page.port
            origin.path = "/favicon.ico"
            return origin.url
        }
        if isData(named) { return nil }
        guard let icon = URL(string: named, relativeTo: page)?.absoluteURL, isWeb(icon),
              icon.host?.isEmpty == false else { return nil }
        return icon
    }

    /// An icon given inline.
    public static func isData(_ href: String) -> Bool { href.lowercased().hasPrefix("data:") }

    /// Whether a reply is worth decoding: a 2xx status, at most 64 KB and not empty, and a type that
    /// is not plainly a page (a site's 404 page is HTML). No type, or an image, `octet-stream` or
    /// `x-icon`, is tried by the decoder, which is the last word (only data that decodes is kept).
    public static func accepts(status: Int, mimeType: String?, byteCount: Int) -> Bool {
        guard (200..<300).contains(status), byteCount > 0, byteCount <= maxBytes else { return false }
        guard let type = mimeType?.lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !type.isEmpty else { return true }
        return type.hasPrefix("image/") || type == "application/octet-stream" || type == "application/x-icon"
    }

    private static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}
