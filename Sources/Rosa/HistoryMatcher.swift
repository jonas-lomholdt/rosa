import Foundation

/// Matches address bar input against history pages. Every word must match the page's host, URL
/// or title; from best to weakest: the start of the host, the start of the URL, the start of a
/// title word, the start of a URL word, anywhere, letters in order ("gthb" → github.com, "rlb" →
/// Rust Language Book), or one typo ("postgers" → PostgreSQL). Case and accents are ignored
/// ("brod" finds "Brød"). Ranking by visits and learned picks is `HistoryStore`'s job.
enum HistoryMatcher {
    /// A page prepared once (folded bytes, word starts), so each keystroke only compares bytes.
    final class Candidate {
        private(set) var entry: HistoryEntry
        private(set) var typedCount: Int
        private(set) var host: [UInt8] = []
        private(set) var url: [UInt8] = []
        private(set) var title: [UInt8] = []
        private(set) var urlWords: [Int] = []
        private(set) var titleWords: [Int] = []

        init(_ entry: HistoryEntry, typedCount: Int) {
            self.entry = entry
            self.typedCount = typedCount
            prepare()
        }

        func update(_ entry: HistoryEntry, typedCount: Int) {
            let titleChanged = entry.title != self.entry.title
            self.entry = entry
            self.typedCount = typedCount
            if titleChanged { prepare() }
        }

        private func prepare() {
            host = HistoryMatcher.fold(entry.displayHost)
            url = HistoryMatcher.fold(entry.displayURL)
            title = HistoryMatcher.fold(entry.title)
            urlWords = HistoryMatcher.wordStarts(url)
            titleWords = HistoryMatcher.wordStarts(title)
        }
    }

    /// How well every term matches, or nil when one doesn't. `fuzzy` when some term only matched
    /// by letters in order or with a typo.
    static func relevance(_ terms: [[UInt8]], _ candidate: Candidate) -> (points: Double, fuzzy: Bool)? {
        var total = 0.0
        var fuzzy = false
        for term in terms {
            guard let points = points(term, candidate) else { return nil }
            total += points
            fuzzy = fuzzy || points < 15
        }
        return (total, fuzzy)
    }

    /// Lowercased, accent-free UTF-8, with letters that have no decomposition spelled out (ø → o).
    static func fold(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        if bytes.allSatisfy({ $0 < 0x80 }) {
            for index in bytes.indices where bytes[index] >= 65 && bytes[index] <= 90 { bytes[index] += 32 }
            return bytes
        }
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        for (letter, spelled) in spelledLetters where folded.contains(letter) {
            folded = folded.replacingOccurrences(of: letter, with: spelled)
        }
        return Array(folded.utf8)
    }

    private static let spelledLetters = [
        ("ø", "o"), ("æ", "ae"), ("œ", "oe"), ("ß", "ss"), ("ł", "l"), ("đ", "d"), ("ı", "i"), ("þ", "th"),
    ]

    private static func points(_ term: [UInt8], _ candidate: Candidate) -> Double? {
        let title = candidate.title, url = candidate.url
        if hasPrefix(candidate.host, term, at: 0) { return 100 }
        if hasPrefix(url, term, at: 0) { return 60 }
        if candidate.titleWords.contains(where: { hasPrefix(title, term, at: $0) }) { return 30 }
        if candidate.urlWords.contains(where: { hasPrefix(url, term, at: $0) }) { return 25 }
        if contains(title, term) || contains(url, term) { return 15 }
        if term.count >= 3 {
            let best = max(inOrder(term, title, candidate.titleWords) ?? 0, inOrder(term, url, candidate.urlWords) ?? 0)
            if best > 0 { return best }
        }
        if term.count >= 5,
           oneTypo(term, title, candidate.titleWords) || oneTypo(term, url, candidate.urlWords) {
            return 8
        }
        return nil
    }

    // MARK: - Byte matching

    private static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 0x80 || (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90)
    }

    private static func wordStarts(_ text: [UInt8]) -> [Int] {
        text.indices.filter { isWordByte(text[$0]) && ($0 == 0 || !isWordByte(text[$0 - 1])) }
    }

    private static func hasPrefix(_ text: [UInt8], _ term: [UInt8], at start: Int) -> Bool {
        guard start + term.count <= text.count else { return false }
        for offset in term.indices where text[start + offset] != term[offset] { return false }
        return true
    }

    private static func contains(_ text: [UInt8], _ term: [UInt8]) -> Bool {
        guard let first = term.first, term.count <= text.count else { return false }
        for start in 0...(text.count - term.count) where text[start] == first && hasPrefix(text, term, at: start) {
            return true
        }
        return false
    }

    /// Letters in order, starting at a word start: an acronym (every letter starts a word) or a
    /// tight run with few letters skipped. Scores 1...12, below any substring match.
    private static func inOrder(_ term: [UInt8], _ text: [UInt8], _ words: [Int]) -> Double? {
        // Acronym first: each next letter at the next word start that has it.
        var position = 0
        var acronym = true
        for byte in term {
            guard let next = words.first(where: { $0 >= position && text[$0] == byte }) else { acronym = false; break }
            position = next + 1
        }
        if acronym { return 12 }

        var best: Double?
        for start in words where text[start] == term[0] {
            var position = start + 1
            var wordStartCount = 1
            for byte in term.dropFirst() {
                while position < text.count, text[position] != byte { position += 1 }
                guard position < text.count else { return best }
                if !isWordByte(text[position - 1]) { wordStartCount += 1 }
                position += 1
            }
            let skipped = position - start - term.count
            guard skipped <= term.count else { continue }
            best = max(best ?? 0, min(11, max(1, Double(6 + 2 * wordStartCount - skipped))))
        }
        return best
    }

    /// Whether `term` is one edit (a wrong, missing, extra or swapped letter) away from the start
    /// of a word that begins with the same letter.
    private static func oneTypo(_ term: [UInt8], _ text: [UInt8], _ words: [Int]) -> Bool {
        for start in words where text[start] == term[0] {
            var end = start
            while end < text.count, isWordByte(text[end]) { end += 1 }
            for length in (term.count - 1)...(term.count + 1) where start + length <= end {
                if withinOneEdit(term[...], text[start..<start + length]) { return true }
            }
        }
        return false
    }

    private static func withinOneEdit(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Bool {
        let a = Array(a), b = Array(b)
        if a.count == b.count {
            guard let index = a.indices.first(where: { a[$0] != b[$0] }) else { return true }
            if a[(index + 1)...] == b[(index + 1)...] { return true }
            return index + 1 < a.count && a[index] == b[index + 1] && a[index + 1] == b[index]
                && a[(index + 2)...] == b[(index + 2)...]
        }
        guard abs(a.count - b.count) == 1 else { return false }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        let index = short.indices.first(where: { short[$0] != long[$0] }) ?? short.count
        return short[index...] == long[(index + 1)...]
    }
}
