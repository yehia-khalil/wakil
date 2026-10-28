import AppKit
import Foundation
import WakilKit

/// Fetches a page's icon over the network (3d-i walk), for `BrowserTabHost.readFavicon`.
///
/// **Why it may touch the network.** The page has already contacted that site, so asking it for its
/// own icon reveals nothing new; the request carries no cookies, no credentials and no cache (an
/// ephemeral session with none of them), so nothing ties it to the organisation's browsing data.
/// Which address, and which answers are kept, are `BrowserFaviconRules`.
///
/// Every failure is nil: the tab keeps its globe. An icon is held in memory by its URL, so a second
/// tab (or a reload) of the same icon asks nothing; two asks for one URL at once share one fetch.
@MainActor
final class BrowserFaviconLoader {
    private let session: URLSession
    private var cache: [URL: NSImage] = [:]
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private static let limit = 256

    init(session: URLSession = BrowserFaviconLoader.makeSession()) { self.session = session }

    /// An ephemeral session: no cookie storage, no credential storage, no cache, a short timeout.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = BrowserFaviconRules.timeout
        config.timeoutIntervalForResource = BrowserFaviconRules.timeout * 2
        config.httpAdditionalHeaders = ["Accept": "image/*"]
        return URLSession(configuration: config)
    }

    /// The icon already held for `url`.
    func cached(_ url: URL) -> NSImage? { cache[url] }

    /// The icon at `url`, from memory or the network; nil on any failure.
    func load(_ url: URL) async -> NSImage? {
        if let hit = cache[url] { return hit }
        if let running = inFlight[url] { return await running.value }
        let session = self.session
        let task = Task { await Self.fetch(url, session: session) }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            if cache.count >= Self.limit { cache.removeAll() }
            cache[url] = image
        }
        return image
    }

    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> NSImage? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = BrowserFaviconRules.timeout
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  BrowserFaviconRules.accepts(status: http.statusCode, mimeType: http.mimeType, byteCount: 1),
                  http.expectedContentLength <= Int64(BrowserFaviconRules.maxBytes) else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > BrowserFaviconRules.maxBytes { return nil }
            }
            guard BrowserFaviconRules.accepts(status: http.statusCode, mimeType: http.mimeType, byteCount: data.count)
            else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
}
