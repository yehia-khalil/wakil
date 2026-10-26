import Foundation

/// **The browser's address rule** (3c-i): typed text becomes a URL or a search.
///
/// Pure: no state, no I/O. `browser_navigate` and the address field both call `resolve`.
public enum BrowserAddress {
    /// The search engines' query prefixes. An unknown engine uses Google's.
    private static let enginePrefixes: [String: String] = [
        "google": "https://www.google.com/search?q=",
        "duckduckgo": "https://duckduckgo.com/?q=",
        "bing": "https://www.bing.com/search?q=",
        "kagi": "https://kagi.com/search?q=",
    ]

    /// `urlQueryAllowed` minus the characters that could end or split the query.
    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?")
        return set
    }()

    /// The URL for `typed`, or nil when it is empty or only whitespace.
    ///
    /// A scheme followed by `:` with no space keeps the text as it is. Text with a space searches.
    /// A host of `localhost`, an IPv4 address or a bracketed IPv6 literal gets `http://`; a host
    /// with a dot and a letters-only last label gets `https://`. Anything else searches.
    public static func resolve(_ typed: String, searchEngine: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains(where: \.isWhitespace) {
            if hasScheme(text), let url = URL(string: text) { return url }
            if let url = urlForHost(text) { return url }
        }
        return search(text, searchEngine: searchEngine)
    }

    /// `https`, `file`, and `http` to a loopback host.
    /// Whether a page shows `url` itself. Any other scheme (`mailto:`, `zoommtg:`) belongs to an app
    /// on the Mac, and the tab asks in place before handing it over (final review I4, Rule 7).
    public static func opensInPage(_ url: URL) -> Bool {
        ["http", "https", "file", "about", "data", "blob"].contains(url.scheme?.lowercased() ?? "")
    }

    /// The in-place question before an app's link leaves the page (Open · Cancel), as Safari asks.
    public static func openInAppQuestion(app: String) -> String { "Open in \(app)?" }

    /// What the tab says when no app on the Mac takes the link's scheme.
    public static func noAppLine(scheme: String) -> String { "No app on this Mac opens \(scheme): links." }

    public static func isSecure(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "file": return true
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }

    /// What the address field's padlock says under the pointer (3c-i; the footer's host and
    /// transport moved into the field): the page's host and how it came — TLS for https (WebKit's
    /// `serverTrust` names no protocol version, so none is given), plain HTTP for http, which is
    /// Not Secure except to a loopback host (`isSecure`) — and, when the certificate was not
    /// trusted, why. Nil where the field draws no padlock: a blank or `about:` page.
    public static func lockDetail(_ url: URL, certificate: String? = nil) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme.isEmpty || scheme == "about" { return nil }
        let host = url.host ?? ""
        let line: String
        switch scheme {
        case "https":
            line = "\(host) over TLS." + (certificate == nil ? " The certificate is trusted." : "")
        case "http" where isSecure(url):
            line = "\(host) over plain HTTP — a loopback address, so nothing leaves this Mac."
        case "http":
            line = "Not Secure: \(host) over plain HTTP — anyone on the network can read or change it."
        case "file":
            line = "A file on this Mac."
        default:
            line = "Not Secure: a \(scheme): page."
        }
        guard let certificate, !certificate.isEmpty else { return line }
        return line + "\n" + certificate
    }

    /// The host without `www.`, or the file name for a `file:` URL.
    public static func displayHost(_ url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Pieces

    private static func search(_ text: String, searchEngine: String) -> URL? {
        let prefix = enginePrefixes[searchEngine] ?? enginePrefixes["google"]!
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: queryAllowed) else { return nil }
        return URL(string: prefix + encoded)
    }

    /// `scheme:` where the scheme is letters/digits/`+-.` and what follows is not a port
    /// (`localhost:3000` is a host and a port, not a scheme).
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return false }
        let rest = text[text.index(after: colon)...]
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        let afterDigits = rest.dropFirst(digits.count)
        let looksLikePort = !digits.isEmpty && (afterDigits.isEmpty || "/?#".contains(afterDigits.first!))
        return !looksLikePort
    }

    private static func urlForHost(_ text: String) -> URL? {
        let hostAndPort = text.prefix(while: { !"/?#".contains($0) })
        var host: Substring
        var port: Substring = ""
        if hostAndPort.hasPrefix("[") {
            guard let close = hostAndPort.firstIndex(of: "]") else { return nil }
            host = hostAndPort[...close]
            let after = hostAndPort[hostAndPort.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                port = after.dropFirst()
            }
            let inner = host.dropFirst().dropLast()
            guard !inner.isEmpty, inner.contains(":"),
                  inner.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
            return validPort(port) ? URL(string: "http://" + text) : nil
        }
        if let colon = hostAndPort.lastIndex(of: ":") {
            host = hostAndPort[..<colon]
            port = hostAndPort[hostAndPort.index(after: colon)...]
        } else {
            host = hostAndPort
        }
        guard validPort(port), !host.isEmpty else { return nil }
        let lower = host.lowercased()
        if lower == "localhost" || isIPv4(lower) { return URL(string: "http://" + text) }
        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                  && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        return URL(string: "https://" + text)
    }

    private static func validPort(_ port: Substring) -> Bool {
        port.isEmpty || (port.allSatisfy { $0.isASCII && $0.isNumber } && port.count <= 5)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy { $0.isASCII && $0.isNumber } && Int(p)! <= 255
        }
    }
}
