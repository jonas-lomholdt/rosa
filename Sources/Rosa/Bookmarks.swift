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

/// Bookmarks are stored in `bookmarks.json` next to `settings.json` (`~/.rosa/`), the single
/// source of truth: the UI (⌘B, the bar's context menu) writes it, and hand edits apply live.
/// Format:
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

    /// Index path into the tree: `[2]` is the bar's third item, `[2, 0]` the first item in that folder.
    typealias Path = [Int]

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

    // MARK: - Lookup

    static func bookmark(at path: Path) -> Bookmark? {
        var list = items
        for (depth, index) in path.enumerated() {
            guard list.indices.contains(index) else { return nil }
            if depth == path.count - 1 { return list[index] }
            guard case .folder(let children) = list[index].kind else { return nil }
            list = children
        }
        return nil
    }

    /// The first bookmark for `url` (ignoring a trailing slash), searching folders depth first.
    static func path(of url: URL) -> Path? {
        func search(_ list: [Bookmark], _ prefix: Path) -> Path? {
            for (index, bookmark) in list.enumerated() {
                switch bookmark.kind {
                case .link(let link) where sameURL(link, url): return prefix + [index]
                case .folder(let children): if let found = search(children, prefix + [index]) { return found }
                default: break
                }
            }
            return nil
        }
        return search(items, [])
    }

    /// Every folder, depth first, for pickers.
    static var folders: [(path: Path, title: String, depth: Int)] {
        func collect(_ list: [Bookmark], _ prefix: Path) -> [(path: Path, title: String, depth: Int)] {
            list.enumerated().flatMap { index, bookmark -> [(path: Path, title: String, depth: Int)] in
                guard case .folder(let children) = bookmark.kind else { return [] }
                let path = prefix + [index]
                return [(path, bookmark.title, prefix.count)] + collect(children, path)
            }
        }
        return collect(items, [])
    }

    private static func sameURL(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            var text = url.absoluteString
            if text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return key(a) == key(b)
    }

    // MARK: - Editing (each change rewrites the file)

    /// Appends to the end of `folder` (the bar by default) and returns the new bookmark's path.
    @discardableResult
    static func add(_ bookmark: Bookmark, to folder: Path = []) -> Path {
        var path = folder
        modify(folder) { list in
            list.append(bookmark)
            path.append(list.count - 1)
        }
        save()
        return path
    }

    static func rename(at path: Path, to title: String) {
        guard let last = path.last else { return }
        modify(Array(path.dropLast())) { list in
            if list.indices.contains(last) { list[last].title = title }
        }
        save()
    }

    static func remove(at path: Path) {
        guard let last = path.last else { return }
        modify(Array(path.dropLast())) { list in
            if list.indices.contains(last) { list.remove(at: last) }
        }
        save()
    }

    /// Moves a bookmark to the end of `folder`, unless it's already in it. Returns its new path.
    @discardableResult
    static func move(_ path: Path, to folder: Path) -> Path {
        guard let bookmark = bookmark(at: path), let last = path.last else { return path }
        let parent = Array(path.dropLast())
        // Not into itself or its own subfolders, and nothing to do if it's already there.
        guard parent != folder, !folder.starts(with: path) else { return path }
        modify(parent) { $0.remove(at: last) }
        // Removing shifts later siblings (and so the destination, if it was one of them) up by one.
        var destination = folder
        if destination.count > parent.count, destination.starts(with: parent), destination[parent.count] > last {
            destination[parent.count] -= 1
        }
        var newPath = destination
        modify(destination) { list in
            list.append(bookmark)
            newPath.append(list.count - 1)
        }
        save()
        return newPath
    }

    /// Runs `body` on the children of the folder at `folder` (`[]` = the bar).
    private static func modify(_ folder: Path, _ body: (inout [Bookmark]) -> Void) {
        func descend(_ list: inout [Bookmark], _ rest: ArraySlice<Int>) {
            guard let index = rest.first else { return body(&list) }
            guard list.indices.contains(index), case .folder(var children) = list[index].kind else { return }
            descend(&children, rest.dropFirst())
            list[index].kind = .folder(children)
        }
        descend(&items, folder[...])
    }

    private static func save() {
        func encode(_ list: [Bookmark]) -> [[String: Any]] {
            list.map { bookmark in
                var entry: [String: Any] = [:]
                if !bookmark.title.isEmpty { entry["title"] = bookmark.title }
                switch bookmark.kind {
                case .link(let url): entry["url"] = url.absoluteString
                case .folder(let children): entry["children"] = encode(children)
                }
                return entry
            }
        }
        store.set(encode(items), forKey: "bookmarks")
        NotificationCenter.default.post(name: didChange, object: nil)
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
