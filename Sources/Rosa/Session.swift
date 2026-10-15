import AppKit

/// One pane as saved: enough to bring back its page and back/forward history.
struct SessionPane: Codable {
    var url: URL?
    var title: String
    /// `WKWebView.interactionState` (opaque: the back/forward list and scroll positions).
    var state: Data?
    /// `WKWebView.pageZoom`, when it isn't 1.
    var zoom: Double?
    var focused: Bool

    /// Nothing to load: a blank pane.
    var isBlank: Bool { url == nil && state == nil }
}

/// A tab's split tree as saved. Also what ⌘⇧T reopens.
indirect enum SessionLayout: Codable {
    case pane(SessionPane)
    case split(SplitView.Axis, ratio: Double, SessionLayout, SessionLayout)

    private enum CodingKeys: String, CodingKey { case pane, axis, ratio, first, second }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try container.decodeIfPresent(SessionPane.self, forKey: .pane) {
            self = .pane(pane)
        } else {
            self = .split(
                try container.decode(SplitView.Axis.self, forKey: .axis),
                ratio: try container.decode(Double.self, forKey: .ratio),
                try container.decode(SessionLayout.self, forKey: .first),
                try container.decode(SessionLayout.self, forKey: .second)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode(pane, forKey: .pane)
        case .split(let axis, let ratio, let first, let second):
            try container.encode(axis, forKey: .axis)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }

    var panes: [SessionPane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }
}

struct SessionWindow: Codable {
    /// `NSWindow.frameDescriptor`.
    var frame: String?
    var selectedTab: Int
    var tabs: [SessionLayout]
}

/// The open windows, front to back.
struct SavedSession: Codable {
    var windows: [SessionWindow]
}

/// Keeps the open windows, tabs and panes in a file so they come back after a restart (an
/// update relaunches Rosa). Saved at most once a second while browsing, and when quitting.
/// `Settings.restoreSession` turns it off (and removes the file).
@MainActor
final class SessionStore {
    static let shared = SessionStore()

    /// `~/Library/Application Support/<bundle id>/Session.json`; `BROWSER_SESSION_FILE` points
    /// elsewhere. Self-tests without one don't touch the session at all.
    static let fileURL: URL? = {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["BROWSER_SESSION_FILE"] { return URL(fileURLWithPath: override) }
        if environment["BROWSER_SELFTEST"] != nil { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Rosa", isDirectory: true)
            .appendingPathComponent("Session.json")
    }()

    /// The windows to save, front to back (set by the app delegate).
    var currentSession: (() -> SavedSession)?

    private var pendingSave: DispatchWorkItem?
    private var settingsObserver: NSObjectProtocol?
    private var wasEnabled: Bool

    var isEnabled: Bool { Self.fileURL != nil && Settings.restoreSession }

    private init() {
        wasEnabled = Self.fileURL != nil && Settings.restoreSession
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    /// The last saved session, or nil when there's none (or restoring is off).
    func load() -> SavedSession? {
        guard isEnabled, let url = Self.fileURL, let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(SavedSession.self, from: data)
        } catch {
            print("[session] couldn't read \(url.path): \(error)")
            return nil
        }
    }

    /// Something worth saving changed; it's written within a second.
    func setNeedsSave() {
        guard isEnabled, pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isEnabled, let url = Self.fileURL, let session = currentSession?() else { return }
        do {
            let data = try JSONEncoder().encode(session)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[session] couldn't write \(url.path): \(error.localizedDescription)")
        }
    }

    private func settingsChanged() {
        guard isEnabled != wasEnabled else { return }
        wasEnabled = isEnabled
        if isEnabled {
            saveNow()
        } else {
            // Off means nothing is kept: a stale file mustn't come back if it's turned on again.
            pendingSave?.cancel()
            pendingSave = nil
            if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
        }
    }
}
