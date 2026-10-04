import Foundation

/// A bookmarks-bar entry: a link, or a folder that opens as a menu.
struct Bookmark {
    enum Kind {
        case link(URL)
        case folder([Bookmark])
    }

    var title: String
    var kind: Kind
}

/// Bookmarks live in `bookmarks.json` next to `settings.json` (`~/.rosa/`) and are edited by
/// hand; changes apply live. Format:
///
///     { "bookmarks": [
///         { "title": "GitHub", "url": "https://github.com" },
///         { "title": "Work", "children": [ { "title": "Jira", "url": "jira.example.com" } ] }
///     ] }
///
/// `title` may be omitted (links then show just their favicon); `url` may leave out the scheme.
enum Bookmarks {
    static let didChange = Notification.Name("BrowserBookmarksDidChange")

    /// `BROWSER_BOOKMARKS_FILE` points elsewhere; otherwise it sits beside the settings file.
    static let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["BROWSER_BOOKMARKS_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return Settings.fileURL.deletingLastPathComponent().appendingPathComponent("bookmarks.json")
    }()

    private static let store = SettingsStore(url: fileURL, name: "bookmarks")

    private(set) static var items: [Bookmark] = []

    /// Creates an empty file on first launch, reads it and starts watching for hand edits.
    static func load() {
        if !store.fileExists { store.addMissing(["bookmarks": [Any]()]) }
        items = parse(store.values["bookmarks"])
        store.onExternalChange = {
            items = parse(store.values["bookmarks"])
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        store.startWatching()
    }

    /// Skips entries it can't make sense of rather than rejecting the whole file.
    private static func parse(_ value: Any?) -> [Bookmark] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if let children = entry["children"] {
                return Bookmark(title: title.isEmpty ? "Folder" : title, kind: .folder(parse(children)))
            }
            guard let text = entry["url"] as? String, let url = linkURL(text) else { return nil }
            return Bookmark(title: title, kind: .link(url))
        }
    }

    private static func linkURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.contains("://") || text.hasPrefix("about:") || text.hasPrefix("data:") { return URL(string: text) }
        return URL(string: "https://" + text)
    }
}
