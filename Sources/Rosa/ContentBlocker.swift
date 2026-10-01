import CryptoKit
import Foundation
import WebKit

struct FilterList: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let url: URL
    let enabledByDefault: Bool

    static let all: [FilterList] = [
        FilterList(id: "easylist", name: "EasyList", detail: "Ads",
                   url: URL(string: "https://easylist.to/easylist/easylist.txt")!, enabledByDefault: true),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", detail: "Trackers",
                   url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, enabledByDefault: true),
        FilterList(id: "cookies", name: "EasyList Cookie List", detail: "Cookie banners",
                   url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!, enabledByDefault: false),
    ]
}

/// State of the shield button in the address bar.
enum ShieldState {
    case hidden
    /// Blocking is active on this site.
    case blocking
    /// The user turned blocking off for this site.
    case allowed
}

/// Downloads filter lists, converts and compiles them into `WKContentRuleList`s, and applies
/// them to panes. Compiled lists are cached by WebKit, so launches after the first are instant.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()
    static let didChange = Notification.Name("ContentBlockerDidChange")

    enum Status {
        case idle
        case updating(String)
        case ready(rules: Int, updated: Date?)
        case failed(String)
    }

    private(set) var status: Status = .idle {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    var isUpdating: Bool {
        if case .updating = status { return true }
        return false
    }

    private static let refreshInterval: TimeInterval = 7 * 86_400

    private var compiled: [String: WKContentRuleList] = [:]
    private var isReloading = false
    private var pendingReload: Bool?
    private var loadedListIDs: Set<String> = []
    private var settingsObserver: NSObjectProtocol?
    private let session = URLSession(configuration: .ephemeral)

    private let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Rosa", isDirectory: true)
            .appendingPathComponent("FilterLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func start() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Settings.enabledFilterLists != self.loadedListIDs else { return }
                self.reload()
            }
        }
        reload()
    }

    // MARK: - Applying

    /// Attaches the compiled lists to a pane's content controller, unless blocking is
    /// off globally or for the page's site.
    func apply(to controller: WKUserContentController, host: String?) {
        controller.removeAllContentRuleLists()
        guard Settings.adBlockEnabled, !isAllowed(host: host) else { return }
        for list in compiled.values {
            controller.add(list)
        }
    }

    func shieldState(forHost host: String?) -> ShieldState {
        guard Settings.adBlockEnabled, Self.normalized(host) != nil else { return .hidden }
        return isAllowed(host: host) ? .allowed : .blocking
    }

    func isAllowed(host: String?) -> Bool {
        guard let host = Self.normalized(host) else { return false }
        return Settings.adBlockAllowlist.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func setAllowed(_ allowed: Bool, host: String?) {
        guard let host = Self.normalized(host) else { return }
        var allowlist = Settings.adBlockAllowlist.filter { $0 != host && !host.hasSuffix("." + $0) }
        if allowed { allowlist.append(host) }
        Settings.adBlockAllowlist = allowlist.sorted()
    }

    private static func normalized(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Loading

    func reload(forceDownload: Bool = false) {
        guard !isReloading else {
            pendingReload = (pendingReload ?? false) || forceDownload
            return
        }
        isReloading = true
        Task {
            await performReload(forceDownload: forceDownload)
            isReloading = false
            if let force = pendingReload {
                pendingReload = nil
                reload(forceDownload: force)
            }
        }
    }

    var statusDescription: String {
        switch status {
        case .idle:
            return "Not loaded yet"
        case .updating(let message):
            return message
        case .ready(let rules, let updated):
            let count = rules.formatted()
            guard let updated else { return "\(count) rules" }
            let ago = RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: Date())
            return "\(count) rules · updated \(ago)"
        case .failed(let message):
            return "Error: \(message)"
        }
    }

    private func performReload(forceDownload: Bool) async {
        let enabledIDs = Settings.enabledFilterLists
        var next: [String: WKContentRuleList] = [:]
        var totalRules = 0
        var failures: [String] = []
        var oldestDownload: Date?

        guard let store = WKContentRuleListStore.default() else {
            status = .failed("Content blocker store unavailable")
            return
        }

        for list in FilterList.all where enabledIDs.contains(list.id) {
            let file = directory.appendingPathComponent("\(list.id).txt")
            var text = try? String(contentsOf: file, encoding: .utf8)

            if text == nil || forceDownload || isStale(file) {
                status = .updating("Downloading \(list.name)…")
                if let fresh = await download(list) {
                    try? fresh.write(to: file, atomically: true, encoding: .utf8)
                    text = fresh
                }
            }
            guard let text else {
                failures.append("couldn't download \(list.name)")
                continue
            }
            if let date = modificationDate(file) { oldestDownload = min(oldestDownload ?? date, date) }

            let fingerprint = Self.fingerprint(text)
            let defaults = UserDefaults.standard
            if defaults.string(forKey: "adblock.\(list.id).fingerprint") == fingerprint,
               let cached = try? await store.contentRuleList(forIdentifier: list.id) {
                next[list.id] = cached
                totalRules += defaults.integer(forKey: "adblock.\(list.id).rules")
                continue
            }

            status = .updating("Compiling \(list.name)…")
            let result = await Task.detached(priority: .utility) { FilterListConverter.convert(text) }.value
            print("[adblock] \(list.id): \(result.ruleCount) rules, \(result.skipped) skipped")
            do {
                guard let ruleList = try await store.compileContentRuleList(
                    forIdentifier: list.id, encodedContentRuleList: result.json
                ) else { throw CocoaError(.featureUnsupported) }
                next[list.id] = ruleList
                totalRules += result.ruleCount
                defaults.set(fingerprint, forKey: "adblock.\(list.id).fingerprint")
                defaults.set(result.ruleCount, forKey: "adblock.\(list.id).rules")
            } catch {
                print("[adblock] \(list.id) failed to compile: \(error)")
                failures.append("\(list.name) failed to compile")
            }
        }

        compiled = next
        loadedListIDs = enabledIDs
        status = failures.isEmpty
            ? .ready(rules: totalRules, updated: oldestDownload)
            : .failed(failures.joined(separator: ", "))
    }

    private func download(_ list: FilterList) async -> String? {
        guard let (data, response) = try? await session.data(from: list.url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              text.count > 1_000 else { return nil }
        return text
    }

    private func isStale(_ file: URL) -> Bool {
        guard let date = modificationDate(file) else { return true }
        return Date().timeIntervalSince(date) > Self.refreshInterval
    }

    private func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private static func fingerprint(_ text: String) -> String {
        let digest = SHA256.hash(data: Data((text + "#converter-v\(FilterListConverter.version)").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
