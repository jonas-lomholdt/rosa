import Foundation
import SQLite3

struct HistoryEntry {
    let url: URL
    let title: String
    let visitCount: Int
    let lastVisit: Date

    /// Host without a leading "www.", e.g. "github.com".
    var displayHost: String {
        let host = url.host() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// URL without scheme, "www." or trailing slash, e.g. "github.com/apple/swift".
    var displayURL: String {
        var text = url.absoluteString
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// Browsing history in SQLite: one row per page plus a row per visit, so history
/// can be cleared for a time range ("last hour") precisely.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()
    static let didChange = Notification.Name("HistoryDidChange")

    struct InlineCompletion {
        /// The full field text: what the user typed plus the completed remainder.
        let text: String
        let url: URL
    }

    private var db: OpaquePointer?

    private init() {
        let path: String
        if let override = ProcessInfo.processInfo.environment["BROWSER_HISTORY_DB"] {
            path = override
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Rosa", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("History.sqlite").path
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA secure_delete = ON;
            CREATE TABLE IF NOT EXISTS pages (
                id INTEGER PRIMARY KEY,
                url TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL DEFAULT '',
                visit_count INTEGER NOT NULL DEFAULT 0,
                last_visit REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS visits (
                page_id INTEGER NOT NULL,
                time REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS visits_time ON visits(time);
            CREATE INDEX IF NOT EXISTS visits_page ON visits(page_id);
            """)
    }

    // MARK: - Recording

    func recordVisit(url: URL, title: String) {
        guard Settings.historyEnabled, Self.isRecordable(url) else { return }
        let now = Date().timeIntervalSince1970
        let urlString = url.absoluteString
        run("""
            INSERT INTO pages (url, title, visit_count, last_visit) VALUES (?1, ?2, 1, ?3)
            ON CONFLICT(url) DO UPDATE SET
                visit_count = visit_count + 1,
                last_visit = ?3,
                title = CASE WHEN ?2 = '' THEN title ELSE ?2 END
            """, [.text(urlString), .text(title), .real(now)])
        run("INSERT INTO visits (page_id, time) SELECT id, ?2 FROM pages WHERE url = ?1",
            [.text(urlString), .real(now)])
        notify()
    }

    func updateTitle(url: URL, title: String) {
        guard Settings.historyEnabled, Self.isRecordable(url), !title.isEmpty else { return }
        run("UPDATE pages SET title = ?2 WHERE url = ?1", [.text(url.absoluteString), .text(title)])
    }

    /// Deletes visits since `date` (or everything when nil) and drops pages left without visits.
    func clear(since date: Date?) {
        if let date {
            run("DELETE FROM visits WHERE time >= ?1", [.real(date.timeIntervalSince1970)])
            execute("""
                UPDATE pages SET
                    visit_count = (SELECT COUNT(*) FROM visits WHERE page_id = pages.id),
                    last_visit = COALESCE((SELECT MAX(time) FROM visits WHERE page_id = pages.id), 0);
                DELETE FROM pages WHERE visit_count = 0;
                """)
        } else {
            execute("DELETE FROM visits; DELETE FROM pages;")
        }
        execute("VACUUM;")
        notify()
    }

    var pageCount: Int {
        rows("SELECT COUNT(*) FROM pages") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    // MARK: - Suggestions

    /// History entries matching `query`, best first.
    func search(_ query: String, limit: Int = 8) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let pattern = "%" + needle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"

        let candidates = rows("""
            SELECT url, title, visit_count, last_visit FROM pages
            WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
            ORDER BY visit_count DESC, last_visit DESC
            LIMIT 300
            """, [.text(pattern)]) { statement -> HistoryEntry? in
            guard let url = URL(string: Self.text(statement, 0)) else { return nil }
            return HistoryEntry(
                url: url,
                title: Self.text(statement, 1),
                visitCount: Int(sqlite3_column_int64(statement, 2)),
                lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
        }.compactMap { $0 }

        let now = Date()
        return candidates
            .map { ($0, Self.score($0, query: needle, now: now)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Safari-style inline completion: completes to a host first ("gi" → "github.com"),
    /// then to a full URL once the typed text goes past the host.
    static func inlineCompletion(for typed: String, in entries: [HistoryEntry]) -> InlineCompletion? {
        let needle = typed.lowercased()
        guard !needle.isEmpty, !needle.contains(" ") else { return nil }

        for entry in entries {
            let host = entry.displayHost
            if host.lowercased().hasPrefix(needle), host.count > typed.count {
                var components = URLComponents()
                components.scheme = entry.url.scheme
                components.host = entry.url.host()
                components.port = entry.url.port
                guard let url = components.url else { continue }
                return InlineCompletion(text: typed + host.dropFirst(typed.count), url: url)
            }
            let display = entry.displayURL
            if display.lowercased().hasPrefix(needle), display.count > typed.count {
                return InlineCompletion(text: typed + display.dropFirst(typed.count), url: entry.url)
            }
        }
        return nil
    }

    /// Frequency and recency, plus big boosts for prefix matches; shorter URLs win ties
    /// so "github.com" ranks above "github.com/some/deep/page".
    private static func score(_ entry: HistoryEntry, query: String, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
        var score = log2(Double(entry.visitCount) + 1) * 10 / (1 + days / 14)
        let display = entry.displayURL.lowercased()
        if entry.displayHost.lowercased().hasPrefix(query) {
            score += 100
        } else if display.hasPrefix(query) {
            score += 60
        } else if entry.title.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
            score += 30
        }
        return score - Double(display.count) * 0.05
    }

    private static func isRecordable(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased())
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - SQLite

    private enum Value {
        case text(String)
        case real(Double)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value] = []) {
        guard let statement = prepare(sql, values) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func rows<T>(_ sql: String, _ values: [Value] = [], _ read: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(read(statement))
        }
        return results
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
