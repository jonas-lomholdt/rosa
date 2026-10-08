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
/// can be cleared for a time range ("last hour") precisely, and the address bar suggestions
/// picked for what was typed (`inputs`), so the same input brings the same page up first.
/// Recording is the caller's call (`PaneView.recordsHistory`), on top of the history setting.
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
    /// Every page, prepared for matching; loaded on the first search, then kept up to date.
    private var candidates: [HistoryMatcher.Candidate]?
    private var candidatesByURL: [String: HistoryMatcher.Candidate] = [:]
    /// Learned picks, loaded on the first search.
    private var picks: [Pick]?

    private struct Pick {
        let input: [UInt8]
        let url: String
        let uses: Double
        let lastUsed: Date
    }

    /// How many pages the address bar searches (most recent first), so typing stays instant.
    private static let searchablePages = 50_000
    /// How many learned picks are kept (most recent first).
    private static let keptPicks = 1_000

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
            CREATE TABLE IF NOT EXISTS inputs (
                input TEXT NOT NULL,
                url TEXT NOT NULL,
                uses REAL NOT NULL,
                last_used REAL NOT NULL,
                PRIMARY KEY (input, url)
            );
            """)
        // Columns added with typed-visit ranking; these fail harmlessly once they exist.
        execute("ALTER TABLE pages ADD COLUMN typed_count INTEGER NOT NULL DEFAULT 0;")
        execute("ALTER TABLE visits ADD COLUMN typed INTEGER NOT NULL DEFAULT 0;")
    }

    // MARK: - Recording

    /// Records a visit; `typed` when it came from the address bar (typed or a picked suggestion).
    func recordVisit(url: URL, title: String, typed: Bool = false) {
        guard Settings.historyEnabled, Self.isRecordable(url) else { return }
        let now = Date()
        let urlString = url.absoluteString
        let typedCount = typed ? 1 : 0
        run("""
            INSERT INTO pages (url, title, visit_count, last_visit, typed_count) VALUES (?1, ?2, 1, ?3, ?4)
            ON CONFLICT(url) DO UPDATE SET
                visit_count = visit_count + 1,
                last_visit = ?3,
                typed_count = typed_count + ?4,
                title = CASE WHEN ?2 = '' THEN title ELSE ?2 END
            """, [.text(urlString), .text(title), .real(now.timeIntervalSince1970), .integer(typedCount)])
        run("INSERT INTO visits (page_id, time, typed) SELECT id, ?2, ?3 FROM pages WHERE url = ?1",
            [.text(urlString), .real(now.timeIntervalSince1970), .integer(typedCount)])

        if candidates != nil {
            if let candidate = candidatesByURL[urlString] {
                let old = candidate.entry
                candidate.update(
                    HistoryEntry(url: url, title: title.isEmpty ? old.title : title, visitCount: old.visitCount + 1, lastVisit: now),
                    typedCount: candidate.typedCount + (typed ? 1 : 0)
                )
            } else {
                let candidate = HistoryMatcher.Candidate(
                    HistoryEntry(url: url, title: title, visitCount: 1, lastVisit: now), typedCount: typed ? 1 : 0
                )
                candidates?.append(candidate)
                candidatesByURL[urlString] = candidate
            }
        }
        notify()
    }

    func updateTitle(url: URL, title: String) {
        guard Settings.historyEnabled, Self.isRecordable(url), !title.isEmpty else { return }
        run("UPDATE pages SET title = ?2 WHERE url = ?1", [.text(url.absoluteString), .text(title)])
        if let candidate = candidatesByURL[url.absoluteString] {
            let old = candidate.entry
            candidate.update(
                HistoryEntry(url: old.url, title: title, visitCount: old.visitCount, lastVisit: old.lastVisit),
                typedCount: candidate.typedCount
            )
        }
    }

    /// Remembers that the suggestion for `url` was picked after typing `input`, so typing it (or
    /// the start of it) again puts that page first.
    func recordPick(input: String, url: URL) {
        guard Settings.historyEnabled, Self.isRecordable(url) else { return }
        let key = Self.inputKey(input)
        guard !key.isEmpty else { return }
        run("""
            INSERT INTO inputs (input, url, uses, last_used) VALUES (?1, ?2, 1, ?3)
            ON CONFLICT(input, url) DO UPDATE SET uses = uses + 1, last_used = ?3
            """, [.text(String(decoding: key, as: UTF8.self)), .text(url.absoluteString), .real(Date().timeIntervalSince1970)])
        run("DELETE FROM inputs WHERE rowid NOT IN (SELECT rowid FROM inputs ORDER BY last_used DESC LIMIT ?1)",
            [.integer(Self.keptPicks)])
        picks = nil
    }

    /// Deletes visits since `date` (or everything when nil) and drops pages left without visits.
    func clear(since date: Date?) {
        if let date {
            run("DELETE FROM visits WHERE time >= ?1", [.real(date.timeIntervalSince1970)])
            run("DELETE FROM inputs WHERE last_used >= ?1", [.real(date.timeIntervalSince1970)])
            execute("""
                UPDATE pages SET
                    visit_count = (SELECT COUNT(*) FROM visits WHERE page_id = pages.id),
                    typed_count = (SELECT COUNT(*) FROM visits WHERE page_id = pages.id AND typed = 1),
                    last_visit = COALESCE((SELECT MAX(time) FROM visits WHERE page_id = pages.id), 0);
                DELETE FROM pages WHERE visit_count = 0;
                DELETE FROM inputs WHERE url NOT IN (SELECT url FROM pages);
                """)
        } else {
            execute("DELETE FROM visits; DELETE FROM pages; DELETE FROM inputs;")
        }
        execute("VACUUM;")
        candidates = nil
        candidatesByURL = [:]
        picks = nil
        notify()
    }

    var pageCount: Int {
        rows("SELECT COUNT(*) FROM pages") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    /// The most recently visited page of each of the last `limit` sites (quick links on blank panes).
    func recentSites(limit: Int) -> [HistoryEntry] {
        var hosts = Set<String>()
        return rows("SELECT url, title, visit_count, last_visit FROM pages ORDER BY last_visit DESC LIMIT 300") { statement -> HistoryEntry? in
            guard let url = URL(string: Self.text(statement, 0)) else { return nil }
            return HistoryEntry(
                url: url,
                title: Self.text(statement, 1),
                visitCount: Int(sqlite3_column_int64(statement, 2)),
                lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
        }
        .compactMap { $0 }
        .filter { hosts.insert($0.displayHost).inserted }
        .prefix(limit)
        .map { $0 }
    }

    // MARK: - Suggestions

    /// History entries matching every word of `query` (see `HistoryMatcher`), best first: how well
    /// they match, plus how often and recently they were visited (typed visits count more), plus
    /// how often they were picked for this input before.
    func search(_ query: String, limit: Int = 8) -> [HistoryEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).prefix(8).map { HistoryMatcher.fold(String($0)) }
        guard !terms.isEmpty else { return [] }
        let learned = learnedBoosts(for: Self.inputKey(query))
        let now = Date()
        var scored: [(entry: HistoryEntry, score: Double)] = []
        for candidate in loadCandidates() {
            let boost = learned[candidate.entry.url.absoluteString] ?? 0
            guard let match = HistoryMatcher.relevance(terms, candidate) ?? (boost > 0 ? (0, false) : nil) else { continue }
            // A loose match on a busy page shouldn't outrank a real match on a quieter one.
            let frecency = Self.frecency(candidate, now: now) * (match.fuzzy ? 0.25 : 1)
            let score = match.points + frecency + boost - Double(candidate.url.count) * 0.05
            // Keep only the best `limit`, sorted, instead of sorting every match.
            guard scored.count < limit || score > scored[scored.count - 1].score else { continue }
            let index = scored.firstIndex { score > $0.score } ?? scored.count
            scored.insert((candidate.entry, score), at: index)
            if scored.count > limit { scored.removeLast() }
        }
        return scored.map(\.entry)
    }

    /// Loads what searching needs ahead of the first keystroke (the address bar calls this on focus).
    func prepareSearch() {
        _ = loadCandidates()
        _ = loadPicks()
    }

    /// Whether `url` was picked for exactly this input before, so ↩ should open it.
    func isLearnedPick(_ url: URL, for query: String) -> Bool {
        let key = Self.inputKey(query)
        let urlString = url.absoluteString
        return loadPicks().contains { $0.input == key && $0.url == urlString }
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

    /// Visits weighted by recency (halving every two weeks or so); typed visits count four times.
    private static func frecency(_ candidate: HistoryMatcher.Candidate, now: Date) -> Double {
        let entry = candidate.entry
        let days = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
        let visits = Double(entry.visitCount + 3 * candidate.typedCount)
        return log2(visits + 1) * 10 / (1 + days / 14)
    }

    /// Boost per URL picked for an input starting with `key`: large for exactly this input, more
    /// with each pick, fading over a month or so without one.
    private func learnedBoosts(for key: [UInt8]) -> [String: Double] {
        guard !key.isEmpty else { return [:] }
        let now = Date()
        var boosts: [String: Double] = [:]
        for pick in loadPicks() where pick.input.starts(with: key) {
            let days = max(0, now.timeIntervalSince(pick.lastUsed) / 86_400)
            let uses = pick.uses * pow(0.5, days / 30)
            let boost = (pick.input == key ? 100 : 0) + 40 * min(uses, 4)
            boosts[pick.url] = max(boosts[pick.url] ?? 0, boost)
        }
        return boosts
    }

    /// Folded input with single spaces, how picks are stored and looked up.
    private static func inputKey(_ input: String) -> [UInt8] {
        Array(input.split(whereSeparator: \.isWhitespace).map { HistoryMatcher.fold(String($0)) }.joined(separator: [32]))
    }

    private func loadCandidates() -> [HistoryMatcher.Candidate] {
        if let candidates { return candidates }
        let loaded = rows("""
            SELECT url, title, visit_count, last_visit, typed_count FROM pages
            ORDER BY last_visit DESC LIMIT ?1
            """, [.integer(Self.searchablePages)]) { statement -> HistoryMatcher.Candidate? in
            guard let url = URL(string: Self.text(statement, 0)) else { return nil }
            let entry = HistoryEntry(
                url: url,
                title: Self.text(statement, 1),
                visitCount: Int(sqlite3_column_int64(statement, 2)),
                lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
            return HistoryMatcher.Candidate(entry, typedCount: Int(sqlite3_column_int64(statement, 4)))
        }.compactMap { $0 }
        candidates = loaded
        candidatesByURL = Dictionary(loaded.map { ($0.entry.url.absoluteString, $0) }, uniquingKeysWith: { first, _ in first })
        return loaded
    }

    private func loadPicks() -> [Pick] {
        if let picks { return picks }
        let loaded = rows("SELECT input, url, uses, last_used FROM inputs") { statement in
            Pick(
                input: Array(Self.text(statement, 0).utf8),
                url: Self.text(statement, 1),
                uses: sqlite3_column_double(statement, 2),
                lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
        }
        picks = loaded
        return loaded
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
        case integer(Int)
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
            case .integer(let number): sqlite3_bind_int64(statement, index, Int64(number))
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
