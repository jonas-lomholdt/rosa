import AppKit

enum AddressBarMode: String, CaseIterable {
    /// A slim address bar at the top of every pane.
    case perPane
    /// One address bar for the window that follows the focused pane.
    case shared
}

enum TabLayout: String, CaseIterable {
    case horizontal
    case vertical
}

enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    /// `nil` follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Where links that would open a new window (target=_blank, window.open, ⌘-click) go.
enum LinkTarget: String, CaseIterable {
    case tab
    /// Split the pane the link was clicked in, to the right.
    case pane
}

enum SearchEngine: String, CaseIterable {
    case google, duckDuckGo, bing, kagi, ecosia

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        }
    }

    var searchURL: String {
        switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .kagi: "https://kagi.com/search"
        case .ecosia: "https://www.ecosia.org/search"
        }
    }
}

/// Which releases the updater follows.
enum UpdateChannel: String, CaseIterable {
    /// Tagged releases (`vX.Y.Z`).
    case stable
    /// A build of every push to main (`vX.Y.Z-canary.N`), newest stable release included.
    case canary

    var name: String {
        switch self {
        case .stable: "Stable"
        case .canary: "Canary"
        }
    }
}

enum AppInfo {
    static let repositoryURL = URL(string: "https://github.com/jonas-lomholdt/rosa")!

    /// "0.1.0 (12)" — marketing version and build number from Info.plist (set from the git tag on release).
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(isDevelopmentBuild ? "dev" : build))"
    }

    /// Local builds keep build number 0 from Resources/Info.plist; release.yml and canary.yml stamp the run number.
    static var isDevelopmentBuild: Bool {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String == "0"
    }

    /// Built by canary.yml: "0.8.1-canary.3" is the third commit after v0.8.1.
    static var isCanaryBuild: Bool {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?.contains("-canary") == true
    }
}

enum Settings {
    static let didChange = Notification.Name("BrowserSettingsDidChange")

    /// `~/.rosa/settings.json`; `BROWSER_SETTINGS_FILE` points elsewhere (self-tests use a scratch file).
    static let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["BROWSER_SETTINGS_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rosa", isDirectory: true)
            .appendingPathComponent("settings.json")
    }()

    private static let store = SettingsStore(url: fileURL)

    /// Creates the file on first launch, carrying over settings from UserDefaults (where
    /// they lived before), and starts watching it for hand edits.
    static func load() {
        if !store.fileExists {
            let legacy = UserDefaults.standard
            var imported: [String: Any] = [:]
            for key in snapshot().keys {
                if let value = legacy.object(forKey: key) { imported[key] = value }
            }
            store.addMissing(imported)
            // Write every setting, defaults included, so the file shows what can be configured.
            store.addMissing(snapshot())
        }
        store.onExternalChange = notify
        store.startWatching()
    }

    /// Every setting in its JSON form.
    private static func snapshot() -> [String: Any] {
        [
            "addressBarMode": addressBarMode.rawValue,
            "tabLayout": tabLayout.rawValue,
            "sidebarWidth": Double(sidebarWidth),
            "sidebarAutoHide": sidebarAutoHide,
            "showBookmarksBar": showBookmarksBar,
            "inactivePaneOpacity": inactivePaneOpacity,
            "appearance": appearance.rawValue,
            "historyEnabled": historyEnabled,
            "adBlockEnabled": adBlockEnabled,
            "enabledFilterLists": enabledFilterLists.sorted(),
            "adBlockAllowlist": adBlockAllowlist,
            "linkTarget": linkTarget.rawValue,
            "linkHintsEnabled": linkHintsEnabled,
            "linkHintsAllPanes": linkHintsAllPanes,
            "linkHintColor": linkHintColor,
            "vimKeysEnabled": vimKeysEnabled,
            "findHighlightColor": findHighlightColor,
            "formatJSON": formatJSON,
            "showQuickLinks": showQuickLinks,
            "askWhereToSaveDownloads": askWhereToSaveDownloads,
            "checkForUpdatesOnLaunch": checkForUpdatesOnLaunch,
            "updateChannel": updateChannel.rawValue,
            "searchEngine": searchEngine.rawValue,
            "hiddenToolbarExtensions": hiddenToolbarExtensions,
        ]
    }

    private static func value<T>(_ key: String) -> T? {
        store.values[key] as? T
    }

    private static func set(_ value: Any, _ key: String) {
        store.set(value, forKey: key)
        notify()
    }

    static var addressBarMode: AddressBarMode {
        get { value("addressBarMode").flatMap(AddressBarMode.init) ?? .perPane }
        set { set(newValue.rawValue, "addressBarMode") }
    }

    static var tabLayout: TabLayout {
        get { value("tabLayout").flatMap(TabLayout.init) ?? .horizontal }
        set { set(newValue.rawValue, "tabLayout") }
    }

    /// Vertical sidebar width in points.
    static var sidebarWidth: CGFloat {
        get { (value("sidebarWidth") as Double?).map { CGFloat($0) } ?? BrowserContentView.defaultSidebarWidth }
        set { set(Double(newValue), "sidebarWidth") }
    }

    /// Vertical sidebar hides until the mouse reaches the window's left edge (or ⌃⌘S).
    static var sidebarAutoHide: Bool {
        get { value("sidebarAutoHide") ?? false }
        set { set(newValue, "sidebarAutoHide") }
    }

    /// Bookmarks bar under the tab strip / address bar (⌘⇧B).
    static var showBookmarksBar: Bool {
        get { value("showBookmarksBar") ?? true }
        set { set(newValue, "showBookmarksBar") }
    }

    static let inactivePaneOpacityRange: ClosedRange<Double> = 0.2...1

    /// Opacity of the panes that don't have focus, when a tab is split (1 = fully opaque).
    static var inactivePaneOpacity: Double {
        get { min(max(value("inactivePaneOpacity") ?? 1, inactivePaneOpacityRange.lowerBound), inactivePaneOpacityRange.upperBound) }
        set { set(newValue, "inactivePaneOpacity") }
    }

    static var appearance: AppearanceMode {
        get { value("appearance").flatMap(AppearanceMode.init) ?? .system }
        set { set(newValue.rawValue, "appearance") }
    }

    static var historyEnabled: Bool {
        get { value("historyEnabled") ?? true }
        set { set(newValue, "historyEnabled") }
    }

    static var adBlockEnabled: Bool {
        get { value("adBlockEnabled") ?? true }
        set { set(newValue, "adBlockEnabled") }
    }

    static var enabledFilterLists: Set<String> {
        get {
            (value("enabledFilterLists") as [String]?).map(Set.init)
                ?? Set(FilterList.all.filter(\.enabledByDefault).map(\.id))
        }
        set { set(newValue.sorted(), "enabledFilterLists") }
    }

    /// Sites (normalized hosts, subdomains included) where content blocking is off.
    static var adBlockAllowlist: [String] {
        get { value("adBlockAllowlist") ?? [] }
        set { set(newValue, "adBlockAllowlist") }
    }

    static var linkTarget: LinkTarget {
        get { value("linkTarget").flatMap(LinkTarget.init) ?? .tab }
        set { set(newValue.rawValue, "linkTarget") }
    }

    static var linkHintsEnabled: Bool {
        get { value("linkHintsEnabled") ?? true }
        set { set(newValue, "linkHintsEnabled") }
    }

    /// `f` labels links in every pane of the tab, not just the focused one.
    static var linkHintsAllPanes: Bool {
        get { value("linkHintsAllPanes") ?? true }
        set { set(newValue, "linkHintsAllPanes") }
    }

    /// "#RRGGBB"
    static var linkHintColor: String {
        get { value("linkHintColor") ?? "#FFD60A" }
        set { set(newValue, "linkHintColor") }
    }

    /// j/k scroll, gg/G top/bottom.
    static var vimKeysEnabled: Bool {
        get { value("vimKeysEnabled") ?? true }
        set { set(newValue, "vimKeysEnabled") }
    }

    /// "#RRGGBB" — find-in-page matches (current match solid, others tinted).
    static var findHighlightColor: String {
        get { value("findHighlightColor") ?? "#32D74B" }
        set { set(newValue, "findHighlightColor") }
    }

    /// Pretty-print and colour JSON responses (`JSONViewer`).
    static var formatJSON: Bool {
        get { value("formatJSON") ?? true }
        set { set(newValue, "formatJSON") }
    }

    /// Blank panes show pinned bookmarks, or recently visited sites when none are pinned (`QuickLinksView`).
    static var showQuickLinks: Bool {
        get { value("showQuickLinks") ?? true }
        set { set(newValue, "showQuickLinks") }
    }

    /// Show a save panel for each download instead of saving straight to Downloads.
    static var askWhereToSaveDownloads: Bool {
        get { value("askWhereToSaveDownloads") ?? false }
        set { set(newValue, "askWhereToSaveDownloads") }
    }

    static var checkForUpdatesOnLaunch: Bool {
        get { value("checkForUpdatesOnLaunch") ?? true }
        set { set(newValue, "checkForUpdatesOnLaunch") }
    }

    /// Defaults to the channel the running build came from.
    static var updateChannel: UpdateChannel {
        get { value("updateChannel").flatMap(UpdateChannel.init) ?? (AppInfo.isCanaryBuild ? .canary : .stable) }
        set { set(newValue.rawValue, "updateChannel") }
    }

    static var searchEngine: SearchEngine {
        get { value("searchEngine").flatMap(SearchEngine.init) ?? .google }
        set { set(newValue.rawValue, "searchEngine") }
    }

    /// Installed extensions (by folder name in `extensions/`) without a toolbar button. They still
    /// run, and open from Rosa → Extensions or their shortcut.
    static var hiddenToolbarExtensions: [String] {
        get { value("hiddenToolbarExtensions") ?? [] }
        set { set(newValue, "hiddenToolbarExtensions") }
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Turns address bar input into a URL: full URLs pass through, things that look
    /// like hosts get a scheme, and everything else becomes a search.
    static func url(fromUserInput input: String) -> URL? {
        if let url = addressURL(fromUserInput: input) { return url }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var components = URLComponents(string: searchEngine.searchURL)
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    /// The address that input names (a URL, or something that looks like a host), or nil when
    /// it would be searched for instead.
    static func addressURL(fromUserInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.contains("://") || text.hasPrefix("about:") || text.hasPrefix("data:"),
           let url = URL(string: text) {
            return url
        }

        if !text.contains(" ") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let isLocal = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1")
            if isLocal, let url = URL(string: "http://" + text) { return url }
            if host.contains("."), let url = URL(string: "https://" + text) { return url }
        }
        return nil
    }
}
