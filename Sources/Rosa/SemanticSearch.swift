import Accelerate
import Foundation
import SQLite3

/// Smart search (opt-in, `Settings.semanticSearch`): finds history pages and bookmarks by what
/// they're about, not just the words typed, for the address bar and ⌘P. Each page is embedded
/// once with EmbeddingGemma (`SemanticModel`): its title, address and the start of its text
/// (read when it loads, `PaneView.capturePageText`). A query is embedded too and compared with
/// every page; pages that stand out from the rest for this query are hits (`search`).
///
/// Vectors and page text live in `Semantic.sqlite` in Application Support (`BROWSER_SEMANTIC_DB`
/// overrides it), separate from history. The index follows history and bookmarks: pages leave
/// it with them (clearing history), and turning smart search off deletes it.
@MainActor
final class SemanticSearch {
    static let shared = SemanticSearch()
    static let didChange = Notification.Name("SemanticSearchDidChange")

    struct Hit {
        let url: URL
        let title: String
        /// How far above the other pages it scored for this query, in standard deviations.
        let z: Double
        let cosine: Float
    }

    /// Stored dimensions: EmbeddingGemma's first 256 of 768 (Matryoshka), nearly as good at a third
    /// of the size. 50,000 pages are ~50 MB in memory, ~25 MB on disk.
    static let dimensions = 256
    /// A hit scores this many standard deviations above the mean of all pages for the query: a
    /// page has to stand out, so an unrelated query finds nothing rather than the least bad page.
    static let zGate = 2.5
    /// And at least this similarity, for small indexes where the spread says little.
    static let minimumCosine: Float = 0.45
    /// Characters of page text kept per page (~400 tokens).
    static let pageTextLength = 1_500

    private var db: OpaquePointer?
    /// Indexed pages (with a vector), row-aligned with `matrix`.
    private var urls: [String] = []
    private var titles: [String] = []
    private var rowByURL: [String: Int] = [:]
    private var matrix: [Float] = []
    /// Pages waiting for a vector, and how many the current indexing pass started with.
    private(set) var pendingCount = 0
    private var indexer: Task<Void, Never>?
    private var queryVectors: [String: [Float]] = [:]
    private var queryOrder: [String] = []
    private var isStarted = false
    private var isActive = false

    private static let databaseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["BROWSER_SEMANTIC_DB"] {
            return URL(fileURLWithPath: override)
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Rosa", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Semantic.sqlite")
    }()

    private init() {}

    /// At launch: follows the setting, the model, history and bookmarks from here on.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SemanticSearch.shared.apply() }
        }
        center.addObserver(forName: SemanticModel.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SemanticSearch.shared.modelDidChange() }
        }
        center.addObserver(forName: HistoryStore.didClear, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SemanticSearch.shared.sync() }
        }
        center.addObserver(forName: Bookmarks.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SemanticSearch.shared.sync() }
        }
        apply()
    }

    /// Whether searches can return anything yet.
    var isAvailable: Bool { isActive && SemanticModel.shared.state == .ready && !urls.isEmpty }

    var indexedCount: Int { urls.count }

    /// One line for Settings: download progress, preparing, indexing, or how many pages are in.
    var statusDescription: String {
        let model = SemanticModel.shared
        let size = ByteCountFormatter.string(fromByteCount: SemanticModel.downloadSize, countStyle: .file)
        switch model.state {
        case .notDownloaded: return isActive ? "" : "The model (\(size)) downloads when you turn this on."
        case .downloaded: return "Model downloaded (\(size))."
        case .downloading(let fraction): return "Downloading model… \(Int(fraction * 100))% of \(size)"
        case .preparing: return "Preparing model… (about a minute the first time)"
        case .failed(let message): return "Couldn't load the model: \(message)"
        case .ready:
            let total = urls.count + pendingCount
            if pendingCount > 0 { return "Indexing… \(urls.count.formatted()) of \(total.formatted()) pages" }
            return "Ready · \(urls.count.formatted()) pages indexed"
        }
    }

    // MARK: - Lifecycle

    private func apply() {
        let enabled = Settings.semanticSearch
        guard enabled != isActive else { return }
        isActive = enabled
        if enabled {
            open()
            SemanticModel.shared.prepare()
            modelDidChange()
        } else {
            indexer?.cancel()
            indexer = nil
            SemanticModel.shared.stop()
            closeAndDelete()
        }
        notify()
    }

    private func modelDidChange() {
        if isActive, SemanticModel.shared.state == .ready, indexer == nil {
            sync()
        } else if isActive, case .downloaded = SemanticModel.shared.state {
            // Removed and downloaded again, or stopped by hand: load it.
            SemanticModel.shared.prepare()
        }
        notify()
    }

    private func open() {
        guard db == nil else { return }
        guard sqlite3_open(Self.databaseURL.path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA secure_delete = ON;
            CREATE TABLE IF NOT EXISTS docs (
                url TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                text TEXT NOT NULL DEFAULT '',
                vec BLOB
            );
            CREATE INDEX IF NOT EXISTS docs_pending ON docs(url) WHERE vec IS NULL;
            """)
        loadVectors()
    }

    private func closeAndDelete() {
        if let db { sqlite3_close(db) }
        db = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: Self.databaseURL.path + suffix)
        }
        urls = []
        titles = []
        rowByURL = [:]
        matrix = []
        pendingCount = 0
        queryVectors = [:]
        queryOrder = []
    }

    // MARK: - Keeping up with history and bookmarks

    /// Brings the index in line with history and bookmarks: adds new pages, drops ones that are
    /// gone, re-embeds renamed ones; then indexes what's missing.
    func sync() {
        guard isActive, db != nil else { return }
        var wanted: [String: String] = [:]
        for page in HistoryStore.shared.indexablePages() { wanted[page.url] = page.title }
        // A bookmark's own title wins: it's what the user named it.
        for link in Self.bookmarkLinks() { wanted[link.url.absoluteString] = link.title }
        let existing = Dictionary(
            rows("SELECT url, title FROM docs") { (Self.text($0, 0), Self.text($0, 1)) },
            uniquingKeysWith: { first, _ in first }
        )
        execute("BEGIN")
        for url in existing.keys where wanted[url] == nil {
            run("DELETE FROM docs WHERE url = ?1", [.text(url)])
        }
        for (url, title) in wanted {
            if let old = existing[url] {
                if old != title, !title.isEmpty {
                    run("UPDATE docs SET title = ?2, vec = NULL WHERE url = ?1", [.text(url), .text(title)])
                }
            } else {
                run("INSERT INTO docs (url, title) VALUES (?1, ?2)", [.text(url), .text(title)])
            }
        }
        execute("COMMIT")
        loadVectors()
        startIndexing()
    }

    /// A page finished loading (`PaneView`): its title and the start of its text. The page is
    /// re-embedded when either changed.
    func update(url: URL, title: String, text: String) {
        guard isActive, db != nil, ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        let text = String(text.prefix(Self.pageTextLength))
        let key = url.absoluteString
        let current = rows("SELECT title, text FROM docs WHERE url = ?1", [.text(key)]) { (Self.text($0, 0), Self.text($0, 1)) }.first
        if let current, current.0 == title || title.isEmpty, current.1 == text { return }
        run("""
            INSERT INTO docs (url, title, text) VALUES (?1, ?2, ?3)
            ON CONFLICT(url) DO UPDATE SET
                title = CASE WHEN ?2 = '' THEN title ELSE ?2 END, text = ?3, vec = NULL
            """, [.text(key), .text(title), .text(text)])
        startIndexing()
    }

    private static func bookmarkLinks() -> [(url: URL, title: String)] {
        var links: [(url: URL, title: String)] = []
        func collect(_ list: [Bookmark]) {
            for bookmark in list {
                switch bookmark.kind {
                case .link(let url): links.append((url, bookmark.title))
                case .folder(let children): collect(children)
                }
            }
        }
        collect(Bookmarks.items)
        return links
    }

    // MARK: - Indexing

    private func startIndexing() {
        pendingCount = rows("SELECT COUNT(*) FROM docs WHERE vec IS NULL") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        notify()
        guard indexer == nil, pendingCount > 0, let engine = SemanticModel.shared.engine else { return }
        indexer = Task { [weak self] in
            await self?.index(with: engine)
            self?.indexer = nil
        }
    }

    private func index(with engine: EmbeddingGemma) async {
        var lastNotified = Date.distantPast
        var failures = 0
        while !Task.isCancelled, isActive {
            // Most recently added first: what was just visited is what's likely searched for.
            let batch = rows("SELECT url, title, text FROM docs WHERE vec IS NULL ORDER BY rowid DESC LIMIT 32") {
                (url: Self.text($0, 0), title: Self.text($0, 1), text: Self.text($0, 2))
            }
            if batch.isEmpty { break }
            for doc in batch {
                guard !Task.isCancelled, isActive else { return }
                let input = EmbeddingGemma.document(title: doc.title, text: Self.documentText(url: doc.url, text: doc.text))
                let vector: [Float]
                do {
                    vector = try await engine.embed(input)
                } catch {
                    failures += 1
                    if failures > 20 { return }  // something's wrong with the model; try again next launch
                    // An empty vector: skipped from now on rather than retried forever.
                    store(doc, vector: [])
                    continue
                }
                guard isActive else { return }
                store(doc, vector: Self.truncated(vector))
                if Date().timeIntervalSince(lastNotified) > 0.5 {
                    lastNotified = Date()
                    notify()
                }
            }
        }
        if !Task.isCancelled { pendingCount = 0 }
        notify()
    }

    /// Saves a page's vector, unless it changed while being embedded (then it's done again).
    private func store(_ doc: (url: String, title: String, text: String), vector: [Float]) {
        let halves = vector.map { Float16($0) }
        let blob = halves.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let statement = prepare(
            "UPDATE docs SET vec = ?4 WHERE url = ?1 AND title = ?2 AND text = ?3",
            [.text(doc.url), .text(doc.title), .text(doc.text)]
        ) else { return }
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(blob.count), Self.transient) }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
        guard sqlite3_changes(db) > 0 else { return }
        pendingCount = max(0, pendingCount - 1)
        guard vector.count == Self.dimensions else { return }
        if let row = rowByURL[doc.url] {
            matrix.replaceSubrange(row * Self.dimensions..<(row + 1) * Self.dimensions, with: vector)
            titles[row] = doc.title
        } else {
            rowByURL[doc.url] = urls.count
            urls.append(doc.url)
            titles.append(doc.title)
            matrix.append(contentsOf: vector)
        }
    }

    /// The address without its scheme or "www.", then the page text.
    private static func documentText(url: String, text: String) -> String {
        var address = url
        if let range = address.range(of: "://") { address = String(address[range.upperBound...]) }
        if address.hasPrefix("www.") { address.removeFirst(4) }
        return text.isEmpty ? address : "\(address) \(text)"
    }

    /// The first `dimensions` values, scaled back to unit length.
    private static func truncated(_ vector: [Float]) -> [Float] {
        let head = Array(vector.prefix(dimensions))
        var norm: Float = 0
        vDSP_svesq(head, 1, &norm, vDSP_Length(head.count))
        let scale = norm > 0 ? 1 / norm.squareRoot() : 0
        return head.map { $0 * scale }
    }

    private func loadVectors() {
        urls = []
        titles = []
        rowByURL = [:]
        matrix = []
        let byteCount = Self.dimensions * MemoryLayout<Float16>.size
        for row in rows("SELECT url, title, vec FROM docs WHERE vec IS NOT NULL", [], { statement -> (String, String, [Float])? in
            guard sqlite3_column_bytes(statement, 2) == byteCount, let bytes = sqlite3_column_blob(statement, 2) else { return nil }
            let halves = UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float16.self), count: Self.dimensions)
            return (Self.text(statement, 0), Self.text(statement, 1), halves.map { Float($0) })
        }) {
            guard let (url, title, vector) = row else { continue }
            rowByURL[url] = urls.count
            urls.append(url)
            titles.append(title)
            matrix.append(contentsOf: vector)
        }
    }

    // MARK: - Searching

    /// Whether `query` is worth a semantic search: a few letters, and not an address.
    static func isSearchable(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 4 && trimmed.contains(where: \.isLetter) && Settings.addressURL(fromUserInput: trimmed) == nil
    }

    /// Pages that stand out for `query`, best first.
    func search(_ query: String, limit: Int = 6) async -> [Hit] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard isAvailable, Self.isSearchable(query), let engine = SemanticModel.shared.engine else { return [] }
        let vector: [Float]
        if let cached = queryVectors[query] {
            vector = cached
        } else {
            guard let embedded = try? await engine.embed(EmbeddingGemma.query(query)) else { return [] }
            vector = Self.truncated(embedded)
            queryVectors[query] = vector
            queryOrder.append(query)
            if queryOrder.count > 64 { queryVectors[queryOrder.removeFirst()] = nil }
        }
        let (scores, mean, spread) = score(vector)
        var hits: [Hit] = []
        for row in scores.indices {
            let z = (Double(scores[row]) - mean) / spread
            guard z >= Self.zGate, scores[row] >= Self.minimumCosine, let url = URL(string: urls[row]) else { continue }
            hits.append(Hit(url: url, title: titles[row], z: z, cosine: scores[row]))
        }
        hits.sort { $0.cosine > $1.cosine }
        return Array(hits.prefix(limit))
    }

    /// Cosine similarity of every page with `vector` (unit length, so a dot product: one
    /// matrix-vector multiply, ~2 ms for 50,000 pages), with their mean and spread.
    private func score(_ vector: [Float]) -> (scores: [Float], mean: Double, spread: Double) {
        let rows = urls.count
        guard rows > 0, matrix.count == rows * Self.dimensions else { return ([], 0, 1) }
        var scores = [Float](repeating: 0, count: rows)
        vDSP_mmul(matrix, 1, vector, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(Self.dimensions))
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(scores, 1, nil, 1, &mean, &deviation, vDSP_Length(rows))
        // With few pages the spread is unreliable; don't let a tiny one make everything stand out.
        return (scores, Double(mean), Double(max(deviation, 0.03)))
    }

    /// Scores for every indexed page (best first), for tuning and the self-test.
    func debugScores(_ query: String) async -> [(url: String, cosine: Float, z: Double)] {
        guard let engine = SemanticModel.shared.engine, let embedded = try? await engine.embed(EmbeddingGemma.query(query)) else { return [] }
        let (scores, mean, spread) = score(Self.truncated(embedded))
        return scores.indices.map { (urls[$0], scores[$0], (Double(scores[$0]) - mean) / spread) }
            .sorted { $0.cosine > $1.cosine }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - SQLite

    private enum Value {
        case text(String)
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
            switch value {
            case .text(let text): sqlite3_bind_text(statement, Int32(offset + 1), text, -1, Self.transient)
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
