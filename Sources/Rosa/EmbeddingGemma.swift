import CoreML
import Foundation

/// Google's EmbeddingGemma 2 text encoder, run with Core ML (the Neural Engine when there is
/// one): text in, a 768-d unit vector out. Built from the files of the Core ML conversion
/// `FluidInference/embeddinggemma-2-coreml` in one folder (`SemanticModel` downloads them):
/// the model takes token embeddings rather than IDs, so tokenizing and the embedding-table
/// lookup happen here. Only Foundation and Core ML, so a scratch harness can compile it alone.
actor EmbeddingGemma {
    static let dimensions = 768
    /// The model's functions: one per padded sequence length.
    private static let lengths = [32, 48, 64, 128, 256, 512]
    private static let hiddenSize = 512
    private static let embedScale = Float(22.627417)  // √512

    static let packageName = "EmbeddingGemma2Text.mlpackage"
    static let compiledName = "EmbeddingGemma2Text.mlmodelc"
    static let tableName = "embeddings.bf16"
    static let tokenizerName = "tokenizer.json"

    /// Prefixes the model was trained with (asymmetric retrieval).
    static func query(_ text: String) -> String { "task: search result | query: \(text)" }
    static func document(title: String, text: String) -> String {
        "title: \(title.isEmpty ? "none" : title) | text: \(text)"
    }

    private let tokenizer: GemmaTokenizer
    /// 262,144 × 512 bfloat16, memory-mapped.
    private let table: Data
    private let compiled: URL
    private let computeUnits: MLComputeUnits
    private var models: [Int: MLModel] = [:]

    /// Loads the tokenizer and table, compiling the model package on first use (kept beside it
    /// as `.mlmodelc`). Slow the first time (seconds); call off the main thread.
    init(directory: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) async throws {
        let compiled = directory.appendingPathComponent(Self.compiledName)
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let temporary = try await MLModel.compileModel(at: directory.appendingPathComponent(Self.packageName))
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: temporary, to: compiled)
        }
        self.compiled = compiled
        self.computeUnits = computeUnits
        table = try Data(contentsOf: directory.appendingPathComponent(Self.tableName), options: .alwaysMapped)
        guard table.count == GemmaTokenizer.vocabularySize * Self.hiddenSize * 2 else {
            throw EmbeddingError.badFile(Self.tableName)
        }
        tokenizer = try GemmaTokenizer(contentsOf: directory.appendingPathComponent(Self.tokenizerName))
    }

    /// Loads every function, so the first searches don't wait for Core ML to prepare them
    /// for the Neural Engine (it caches that across launches).
    func warmUp() async throws {
        for length in Self.lengths { _ = try await model(for: length) }
    }

    /// The unit vector for `text` (already prefixed with `query` / `document`); past 512
    /// tokens it's cut off.
    func embed(_ text: String) async throws -> [Float] {
        let maxLength = Self.lengths.last!
        let tokens = tokenizer.encode(text, maxTokens: maxLength)
        let length = Self.lengths.first { $0 >= tokens.count } ?? maxLength
        let model = try await model(for: length)

        let embeds = try MLMultiArray(shape: [1, NSNumber(value: length), NSNumber(value: Self.hiddenSize)], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float16)
        let embedsPointer = embeds.dataPointer.assumingMemoryBound(to: Float16.self)
        let maskPointer = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        embedsPointer.initialize(repeating: 0, count: length * Self.hiddenSize)
        for position in 0..<length { maskPointer[position] = position < tokens.count ? 1 : 0 }
        table.withUnsafeBytes { raw in
            let rows = raw.bindMemory(to: UInt16.self)
            for (position, token) in tokens.enumerated() {
                let row = Int(token) * Self.hiddenSize
                let out = embedsPointer + position * Self.hiddenSize
                for index in 0..<Self.hiddenSize {
                    // bfloat16 is the top half of a float32.
                    out[index] = Float16(Float(bitPattern: UInt32(rows[row + index]) << 16) * Self.embedScale)
                }
            }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["inputs_embeds": embeds, "attention_mask": mask])
        let output = try await model.prediction(from: input)
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue, vector.count == Self.dimensions else {
            throw EmbeddingError.badOutput
        }
        var result = [Float](repeating: 0, count: Self.dimensions)
        switch vector.dataType {
        case .float16:
            let pointer = vector.dataPointer.assumingMemoryBound(to: Float16.self)
            for index in 0..<Self.dimensions { result[index] = Float(pointer[index]) }
        case .float32:
            let pointer = vector.dataPointer.assumingMemoryBound(to: Float.self)
            for index in 0..<Self.dimensions { result[index] = pointer[index] }
        default:
            for index in 0..<Self.dimensions { result[index] = vector[index].floatValue }
        }
        return result
    }

    /// Token IDs as the model sees them (`<bos>` … `<eos>`), for checking the tokenizer.
    func tokens(_ text: String) -> [Int32] { tokenizer.encode(text, maxTokens: .max) }

    private func model(for length: Int) async throws -> MLModel {
        if let model = models[length] { return model }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        configuration.functionName = "embed_\(length)"
        let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
        models[length] = model
        return model
    }
}

enum EmbeddingError: LocalizedError {
    case badFile(String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .badFile(let name): "The model file \(name) is damaged."
        case .badOutput: "The model returned an unexpected result."
        }
    }
}

/// Gemma's tokenizer (`tokenizer.json`): BPE over the whole text, spaces written as `▁`, with
/// characters outside the vocabulary spelled as UTF-8 byte tokens. Matches Hugging Face
/// `tokenizers` for ordinary text; special-token strings ("<bos>") in the text aren't treated
/// as special.
final class GemmaTokenizer: @unchecked Sendable {
    static let vocabularySize = 262_144
    static let bos: Int32 = 2
    static let eos: Int32 = 1

    /// Tokens that are a single Unicode scalar, the symbols BPE starts from.
    private var scalars: [UInt32: Int32] = [:]
    /// `<0x00>` … `<0xFF>`.
    private var bytes = [Int32](repeating: 0, count: 256)
    /// (left << 32 | right) → (rank << 32 | merged token).
    private var merges: [UInt64: UInt64] = [:]

    /// Reads `tokenizer.json`, or the compact copy made from it the first time (`<name>.bin`
    /// beside it: parsing the 32 MB JSON takes ~2 s and a few hundred MB).
    init(contentsOf url: URL) throws {
        let cache = url.appendingPathExtension("bin")
        if let data = try? Data(contentsOf: cache), read(data) { return }
        try parse(Data(contentsOf: url))
        try? serialized().write(to: cache, options: .atomic)
    }

    private func parse(_ data: Data) throws {
        // Foundation types throughout: Swift strings compare by canonical equivalence, which would
        // merge distinct tokens (";" and the Greek question mark, precomposed and combining accents).
        guard let root = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let model = root["model"] as? NSDictionary,
              let vocabulary = model["vocab"] as? NSDictionary,
              let mergeList = model["merges"] as? NSArray else {
            throw EmbeddingError.badFile(EmbeddingGemma.tokenizerName)
        }
        for case let (token as NSString, id as NSNumber) in vocabulary {
            let text = token as String
            let unicodeScalars = text.unicodeScalars
            if unicodeScalars.count == 1, let scalar = unicodeScalars.first {
                scalars[scalar.value] = id.int32Value
            }
            if token.length == 6, text.hasPrefix("<0x"), text.hasSuffix(">"),
               let byte = UInt8(text.dropFirst(3).prefix(2), radix: 16) {
                bytes[Int(byte)] = id.int32Value
            }
        }
        merges.reserveCapacity(mergeList.count)
        for (rank, entry) in mergeList.enumerated() {
            // Pairs are ["a", "b"] (or "a b" in older files).
            let pair: [NSString]
            if let array = entry as? NSArray {
                pair = array.compactMap { $0 as? NSString }
            } else if let text = entry as? NSString {
                let space = text.range(of: " ")
                guard space.location != NSNotFound else { continue }
                pair = [text.substring(to: space.location) as NSString, text.substring(from: space.location + 1) as NSString]
            } else {
                continue
            }
            guard pair.count == 2, let left = vocabulary[pair[0]] as? NSNumber, let right = vocabulary[pair[1]] as? NSNumber,
                  let merged = vocabulary[pair[0].appending(pair[1] as String)] as? NSNumber else { continue }
            let key = UInt64(left.uint32Value) << 32 | UInt64(right.uint32Value)
            if merges[key] == nil { merges[key] = UInt64(rank) << 32 | UInt64(merged.uint32Value) }
        }
    }

    // MARK: Cache

    private static let cacheMagic: UInt32 = 0x6D67_7431  // "mgt1"

    private func serialized() -> Data {
        var words: [UInt32] = [Self.cacheMagic, UInt32(scalars.count), UInt32(merges.count)]
        words.reserveCapacity(3 + 256 + scalars.count * 2 + merges.count * 4)
        words += bytes.map { UInt32(bitPattern: $0) }
        for (scalar, id) in scalars { words += [scalar, UInt32(bitPattern: id)] }
        for (key, value) in merges {
            words += [UInt32(key >> 32), UInt32(key & 0xFFFF_FFFF), UInt32(value >> 32), UInt32(value & 0xFFFF_FFFF)]
        }
        return words.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func read(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let words = raw.bindMemory(to: UInt32.self)
            guard words.count >= 3 + 256, words[0] == Self.cacheMagic else { return false }
            let scalarCount = Int(words[1]), mergeCount = Int(words[2])
            guard words.count == 3 + 256 + scalarCount * 2 + mergeCount * 4 else { return false }
            var index = 3
            for byte in 0..<256 { bytes[byte] = Int32(bitPattern: words[index + byte]) }
            index += 256
            scalars.reserveCapacity(scalarCount)
            for _ in 0..<scalarCount {
                scalars[words[index]] = Int32(bitPattern: words[index + 1])
                index += 2
            }
            merges.reserveCapacity(mergeCount)
            for _ in 0..<mergeCount {
                merges[UInt64(words[index]) << 32 | UInt64(words[index + 1])] = UInt64(words[index + 2]) << 32 | UInt64(words[index + 3])
                index += 4
            }
            return true
        }
    }

    /// `<bos>` + tokens + `<eos>`, at most `maxTokens` in all (cut before `<eos>`).
    func encode(_ text: String, maxTokens: Int) -> [Int32] {
        // Symbols as a linked list, merged lowest rank first (leftmost on ties).
        var ids: [Int32] = []
        // Text past what fits can't affect the kept tokens much; cap the work on long pages.
        let limit = maxTokens == .max ? Int.max : maxTokens * 8
        for scalar in text.unicodeScalars.prefix(limit) {
            let value = scalar == " " ? 0x2581 : scalar.value
            if let id = scalars[value] {
                ids.append(id)
            } else {
                for byte in String(scalar).utf8 { ids.append(bytes[Int(byte)]) }
            }
        }
        let count = ids.count
        var next = Array(1...max(count, 1)).map { Int32($0) }
        var previous = (0..<max(count, 1)).map { Int32($0 - 1) }
        var alive = [Bool](repeating: true, count: count)
        var heap = MergeHeap()
        func push(_ position: Int) {
            let right = Int(next[position])
            guard right < count else { return }
            let key = UInt64(UInt32(ids[position])) << 32 | UInt64(UInt32(ids[right]))
            if let value = merges[key] {
                heap.push(.init(rank: UInt32(value >> 32), position: Int32(position), left: ids[position], right: ids[right]))
            }
        }
        for position in 0..<max(count - 1, 0) { push(position) }
        while let candidate = heap.pop() {
            let position = Int(candidate.position)
            let right = Int(next[position])
            // Stale: one side already merged into something else.
            guard alive[position], right < count, alive[right], ids[position] == candidate.left, ids[right] == candidate.right,
                  let value = merges[UInt64(UInt32(candidate.left)) << 32 | UInt64(UInt32(candidate.right))] else { continue }
            ids[position] = Int32(truncatingIfNeeded: value & 0xFFFF_FFFF)
            alive[right] = false
            next[position] = next[right]
            if Int(next[right]) < count { previous[Int(next[right])] = Int32(position) }
            if previous[position] >= 0 { push(Int(previous[position])) }
            push(position)
        }
        var result: [Int32] = [Self.bos]
        var position = 0
        while position < count, result.count < maxTokens - 1 {
            if alive[position] { result.append(ids[position]) }
            position = Int(next[position])
        }
        result.append(Self.eos)
        return result
    }
}

/// Min-heap of merge candidates by rank, then position.
private struct MergeHeap {
    struct Entry {
        let rank: UInt32
        let position: Int32
        let left: Int32
        let right: Int32

        func precedes(_ other: Entry) -> Bool {
            rank != other.rank ? rank < other.rank : position < other.position
        }
    }

    private var entries: [Entry] = []

    mutating func push(_ entry: Entry) {
        entries.append(entry)
        var child = entries.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard entries[child].precedes(entries[parent]) else { break }
            entries.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Entry? {
        guard let first = entries.first else { return nil }
        let last = entries.removeLast()
        if !entries.isEmpty {
            entries[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < entries.count, entries[left].precedes(entries[smallest]) { smallest = left }
                if right < entries.count, entries[right].precedes(entries[smallest]) { smallest = right }
                if smallest == parent { break }
                entries.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return first
    }
}
