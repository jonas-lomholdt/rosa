import Foundation

/// The JSON file behind `Settings`. Loaded once, rewritten on every change, and
/// reloaded when edited by hand. Unknown keys are kept; a file that doesn't parse
/// leaves the last good values in place.
final class SettingsStore {
    let url: URL
    private(set) var values: [String: Any] = [:]
    /// False until the file has been written once (first launch).
    private(set) var fileExists = false
    /// Called on the main queue after a hand edit changed `values`.
    var onExternalChange: (() -> Void)?

    /// What we last read or wrote, so our own writes don't count as edits.
    private var lastData: Data?
    /// The file on disk doesn't parse; it's moved aside before we overwrite it.
    private var fileIsInvalid = false
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: url) else { return }
        fileExists = true
        if let parsed = Self.parse(data) {
            values = parsed
            lastData = data
        } else {
            fileIsInvalid = true
            print("[settings] \(url.path) isn't a valid JSON object; using defaults")
        }
    }

    func set(_ value: Any, forKey key: String) {
        values[key] = value
        write()
    }

    /// Merges `entries` without replacing values already present.
    func addMissing(_ entries: [String: Any]) {
        for (key, value) in entries where values[key] == nil {
            values[key] = value
        }
        write()
    }

    private func write() {
        guard let data = try? JSONSerialization.data(
            withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        if fileIsInvalid {
            // Keep the hand edit that didn't parse instead of silently overwriting it.
            let backup = url.appendingPathExtension("invalid")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            print("[settings] moved unparseable settings to \(backup.path)")
            fileIsInvalid = false
        }
        let output = data + Data("\n".utf8)
        do {
            try output.write(to: url, options: .atomic)
            lastData = output
            fileExists = true
        } catch {
            print("[settings] couldn't write \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: Watching

    /// Watches the file (in-place saves) and its folder (editors that save by replacing the file).
    func startWatching() {
        directorySource = watch(url.deletingLastPathComponent())
        fileSource = watch(url)
    }

    private func watch(_ target: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(target.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Editors often save in several steps (truncate, write, rename); wait for them to settle.
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func reloadFromDisk() {
        // The file may be a new inode now (atomic save), so watch it afresh.
        fileSource?.cancel()
        fileSource = watch(url)

        guard let data = try? Data(contentsOf: url), data != lastData else { return }
        lastData = data
        guard let parsed = Self.parse(data) else {
            fileIsInvalid = true
            print("[settings] \(url.path) isn't a valid JSON object; keeping previous settings")
            return
        }
        fileIsInvalid = false
        values = parsed
        onExternalChange?()
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
