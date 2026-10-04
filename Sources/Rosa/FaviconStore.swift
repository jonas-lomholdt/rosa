import AppKit
import WebKit

/// Downloads and caches favicons. Icons are cached by icon URL, and the last icon seen
/// for each host is remembered so it can be shown immediately on the next visit.
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    /// Shown wherever a page has no favicon (yet).
    static let placeholder: NSImage = {
        let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? image
    }()

    private let iconsByURL = NSCache<NSURL, NSImage>()
    private var iconsByHost: [String: NSImage] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    func cachedIcon(forHost host: String?) -> NSImage? {
        host.flatMap { iconsByHost[$0] }
    }

    /// Finds the page's best favicon, trying declared icons first and `/favicon.ico` last.
    func icon(for webView: WKWebView) async -> NSImage? {
        guard let pageURL = webView.url, ["http", "https"].contains(pageURL.scheme?.lowercased()) else { return nil }
        for url in await candidates(in: webView, pageURL: pageURL) {
            if let image = await image(at: url) {
                if let host = pageURL.host() { iconsByHost[host] = image }
                return image
            }
        }
        return nil
    }

    /// Icon for a page that isn't open (bookmarks): the host's last seen icon, else `/favicon.ico`.
    func icon(forSite url: URL) async -> NSImage? {
        guard ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host() else { return nil }
        if let cached = iconsByHost[host] { return cached }
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = host
        components.port = url.port
        components.path = "/favicon.ico"
        guard let iconURL = components.url, let image = await image(at: iconURL) else { return nil }
        if iconsByHost[host] == nil { iconsByHost[host] = image }
        return image
    }

    private func image(at url: URL) async -> NSImage? {
        if let cached = iconsByURL.object(forKey: url as NSURL) { return cached }
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0 else { return nil }
        image.size = NSSize(width: 16, height: 16)
        iconsByURL.setObject(image, forKey: url as NSURL)
        return image
    }

    // MARK: - Candidate selection

    private static let linkScript = """
        [...document.querySelectorAll('link[rel~="icon" i], link[rel~="apple-touch-icon" i]')]
            .map(l => [l.href, l.getAttribute('sizes') || '', l.type || '', l.rel || ''])
        """

    private func candidates(in webView: WKWebView, pageURL: URL) async -> [URL] {
        let links = (try? await webView.evaluateJavaScript(Self.linkScript)) as? [[String]] ?? []
        var urls = links
            .compactMap { link -> (url: URL, score: Int)? in
                guard link.count == 4, let url = URL(string: link[0]) else { return nil }
                let score = Self.score(href: link[0], sizes: link[1], type: link[2])
                // Touch icons are big and often differently styled: use them only as a fallback.
                return (url, link[3].lowercased().contains("apple-touch-icon") ? score - 1000 : score)
            }
            .sorted { $0.score > $1.score }
            .map(\.url)

        var fallback = URLComponents()
        fallback.scheme = pageURL.scheme
        fallback.host = pageURL.host()
        fallback.port = pageURL.port
        fallback.path = "/favicon.ico"
        if let fallbackURL = fallback.url, !urls.contains(fallbackURL) {
            urls.append(fallbackURL)
        }
        return urls
    }

    /// Prefers icons close to 32px (a 16pt icon on Retina), then larger ones, then vector icons.
    private static func score(href: String, sizes: String, type: String) -> Int {
        if type.contains("svg") || href.lowercased().hasSuffix(".svg") || sizes == "any" { return 800 }
        let largest = sizes
            .split(separator: " ")
            .compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }
            .max()
        guard let largest else { return 700 }
        return largest >= 32 ? 1000 - largest : 500 + largest
    }
}
