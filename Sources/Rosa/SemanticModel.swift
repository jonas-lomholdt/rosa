import CoreML
import CryptoKit
import Foundation

/// The EmbeddingGemma model behind smart search, downloaded only when the feature is turned on:
/// ~585 MB into `~/.rosa/models/embeddinggemma-2/` (beside the settings file;
/// `BROWSER_MODEL_DIR` points at another copy). Files come from a pinned revision of the Core ML
/// conversion and are checked against their SHA-256 before use; an interrupted download resumes
/// where it stopped, even after a relaunch.
@MainActor
final class SemanticModel {
    static let shared = SemanticModel()
    static let didChange = Notification.Name("SemanticModelDidChange")

    enum State: Equatable {
        case notDownloaded
        /// Downloaded, not loaded (smart search is off).
        case downloaded
        case downloading(Double)
        /// Compiling and loading for the Neural Engine (seconds, longer the first time).
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded {
        didSet { if state != oldValue { NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    }

    /// Loaded once `state` is `.ready`.
    private(set) var engine: EmbeddingGemma?

    static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["BROWSER_MODEL_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Settings.fileURL.deletingLastPathComponent()
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("embeddinggemma-2", isDirectory: true)
    }()

    private struct File {
        let path: String
        let size: Int64
        let sha256: String
    }

    private static let source = URL(string:
        "https://huggingface.co/FluidInference/embeddinggemma-2-coreml/resolve/3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4/")!
    private static let files = [
        File(path: "EmbeddingGemma2Text.mlpackage/Manifest.json", size: 617,
             sha256: "83eace80b69b46f8415af620ba1b40d7c490d00f7c00ba9dedd2e29da6e9ac19"),
        File(path: "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 7_323_423,
             sha256: "0df9aca02807cf490db6d4f1c68607a8c7f486ad23b376d1968fd3be5eb14677"),
        File(path: "tokenizer.json", size: 32_170_510,
             sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
        File(path: "embeddings.bf16", size: 268_435_456,
             sha256: "56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877"),
        File(path: "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 276_815_424,
             sha256: "75b97ab036ca87eae60560c4034a63d604201498dc4b6f6971dd0b1e4558d61f"),
    ]

    static let downloadSize = files.reduce(0) { $0 + $1.size }

    private var task: Task<Void, Never>?
    private var reportedFraction = -1.0

    private init() {
        state = isDownloaded ? .downloaded : .notDownloaded
    }

    /// Every file is in place at its expected size (hashes are checked when downloading).
    var isDownloaded: Bool {
        Self.files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: Self.directory.appendingPathComponent(file.path).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    /// Downloads what's missing, then loads the model. Does nothing while that's under way or done.
    func prepare() {
        guard task == nil, engine == nil else { return }
        task = Task {
            await run()
            task = nil
        }
    }

    /// Stops a download (it resumes next time) or unloads the model.
    func stop() {
        task?.cancel()
        task = nil
        engine = nil
        state = isDownloaded ? .downloaded : .notDownloaded
    }

    /// Deletes the downloaded model.
    func remove() {
        stop()
        try? FileManager.default.removeItem(at: Self.directory)
        state = .notDownloaded
    }

    private func run() async {
        do {
            if !isDownloaded { try await download() }
            state = .preparing
            let directory = Self.directory
            let engine: EmbeddingGemma
            do {
                engine = try await Task.detached(priority: .utility) {
                    let engine = try await EmbeddingGemma(directory: directory)
                    try await engine.warmUp()
                    return engine
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // No Neural Engine to be had (or it refused the model): the CPU is ~3× slower, still fine.
                engine = try await Task.detached(priority: .utility) {
                    let engine = try await EmbeddingGemma(directory: directory, computeUnits: .cpuOnly)
                    try await engine.warmUp()
                    return engine
                }.value
            }
            try Task.checkCancellation()
            self.engine = engine
            state = .ready
        } catch is CancellationError {
            // `stop()` set the state.
        } catch {
            if !Task.isCancelled { state = .failed(error.localizedDescription) }
        }
    }

    private func download() async throws {
        let fileManager = FileManager.default
        var completed: Int64 = 0
        reportedFraction = -1
        state = .downloading(0)
        for file in Self.files {
            let destination = Self.directory.appendingPathComponent(file.path)
            let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            if size == file.size {
                completed += file.size
                continue
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("partial")
            let base = completed
            let digest = try await FileDownload.fetch(Self.source.appendingPathComponent(file.path), to: partial) { bytes in
                Task { @MainActor in
                    let fraction = Double(base + bytes) / Double(Self.downloadSize)
                    // Every half percent is plenty for a progress line.
                    guard fraction - self.reportedFraction >= 0.005, case .downloading = self.state else { return }
                    self.reportedFraction = fraction
                    self.state = .downloading(fraction)
                }
            }
            guard digest == file.sha256 else {
                try? fileManager.removeItem(at: partial)
                throw DownloadError.corrupt(file.path)
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: partial, to: destination)
            completed += file.size
        }
        // A stale compiled model would no longer match.
        try? fileManager.removeItem(at: Self.directory.appendingPathComponent(EmbeddingGemma.compiledName))
    }

    enum DownloadError: LocalizedError {
        case http(Int)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .http(let status): "The download failed (HTTP \(status))."
            case .corrupt(let name): "\((name as NSString).lastPathComponent) didn't download correctly. Try again."
            }
        }
    }
}

/// One file over HTTP, appended to `partial` (resuming with a Range request when it already
/// has bytes) and hashed as it arrives.
private final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let progress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var written: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<String, Error>?

    private init(partial: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.partial = partial
        self.progress = progress
    }

    /// The SHA-256 (hex) of the whole file.
    static func fetch(_ url: URL, to partial: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        let download = FileDownload(partial: partial, progress: progress)
        return try await download.run(url)
    }

    private func run(_ url: URL) async throws -> String {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: partial.path) { fileManager.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forUpdating: partial)
        self.handle = handle
        // Hash what an earlier attempt already got.
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            written += Int64(chunk.count)
        }
        var request = URLRequest(url: url)
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    self.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:
            completionHandler(.allow)
        case 200:
            // The whole file after all: start over.
            if written > 0 {
                try? handle?.truncate(atOffset: 0)
                hasher = SHA256()
                written = 0
            }
            completionHandler(.allow)
        case 416 where written > 0:
            // Nothing past what we have; the hash decides whether it's whole.
            completionHandler(.cancel)
        default:
            failure = SemanticModel.DownloadError.http(status)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        written += Int64(data.count)
        progress(written)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error, !(status == 416 && (error as? URLError)?.code == .cancelled) {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else {
            continuation?.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
        continuation = nil
    }
}
