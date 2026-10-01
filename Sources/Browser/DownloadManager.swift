import AppKit
import WebKit

/// Tracks every WKDownload: picks destinations (Downloads folder or a save panel), reports
/// progress, and offers cancel / reveal / open. Shared by all windows.
@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    /// Posted when downloads are added, finish, fail or are cleared (not on every progress tick).
    static let didChange = Notification.Name("DownloadsDidChange")

    @MainActor
    final class Item: ObservableObject, Identifiable {
        enum State: Equatable {
            case downloading
            case finished
            case cancelled
            case failed(String)
        }

        let id = UUID()
        let sourceURL: URL?
        @Published var filename: String
        @Published var destination: URL?
        @Published var state: State = .downloading
        @Published var receivedBytes: Int64 = 0
        @Published var totalBytes: Int64 = 0
        fileprivate weak var download: WKDownload?
        fileprivate var observation: NSKeyValueObservation?

        init(filename: String, sourceURL: URL?) {
            self.filename = filename
            self.sourceURL = sourceURL
        }

        var fraction: Double {
            totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
        }
    }

    @Published private(set) var items: [Item] = []

    var activeCount: Int { items.filter { $0.state == .downloading }.count }

    private var itemsByDownload: [ObjectIdentifier: Item] = [:]

    /// Downloads folder; `BROWSER_DOWNLOADS_DIR` overrides it (self-test).
    var downloadsFolder: URL {
        if let override = ProcessInfo.processInfo.environment["BROWSER_DOWNLOADS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let source = download.originalRequest?.url
        let item = Item(filename: source?.lastPathComponent.nilIfEmpty ?? "Download", sourceURL: source)
        item.download = download
        item.observation = download.progress.observe(\.completedUnitCount) { [weak item] progress, _ in
            let received = progress.completedUnitCount, total = progress.totalUnitCount
            MainActor.assumeIsolated {
                item?.receivedBytes = received
                item?.totalBytes = max(total, 0)
            }
        }
        itemsByDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
        notify()
    }

    // MARK: - Actions

    func cancel(_ item: Item) {
        item.download?.cancel()
    }

    func reveal(_ item: Item) {
        guard let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    func open(_ item: Item) {
        guard item.state == .finished, let destination = item.destination else { return }
        NSWorkspace.shared.open(destination)
    }

    /// Removes everything that isn't still downloading.
    func clearInactive() {
        items.removeAll { $0.state != .downloading }
        notify()
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let item = itemsByDownload[ObjectIdentifier(download)]
        let filename = Self.sanitized(suggestedFilename)
        let destination: URL?
        if Settings.askWhereToSaveDownloads {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.directoryURL = downloadsFolder
            destination = await panel.begin() == .OK ? panel.url : nil
            // The save panel already confirmed replacing an existing file.
            if let destination { try? FileManager.default.removeItem(at: destination) }
        } else {
            try? FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
            destination = Self.uniqueURL(for: filename, in: downloadsFolder)
        }
        if let destination {
            item?.filename = destination.lastPathComponent
            item?.destination = destination
            item?.totalBytes = max(response.expectedContentLength, 0)
        } else {
            item?.state = .cancelled
            notify()
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = itemsByDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.state = .finished
        if item.totalBytes == 0 { item.totalBytes = item.receivedBytes }
        item.receivedBytes = max(item.receivedBytes, item.totalBytes)
        item.observation = nil
        if let path = item.destination?.path {
            // Bounces the Downloads stack in the Dock, like Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
        notify()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = itemsByDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.observation = nil
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        item.state = cancelled ? .cancelled : .failed(error.localizedDescription)
        notify()
    }

    // MARK: - Helpers

    private func notify() {
        objectWillChange.send()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func sanitized(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Download" : cleaned
    }

    /// "file.zip", then "file (1).zip", "file (2).zip", …
    static func uniqueURL(for filename: String, in folder: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty || self == "/" ? nil : self }
}
