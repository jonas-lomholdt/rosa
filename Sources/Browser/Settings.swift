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

enum Settings {
    static let didChange = Notification.Name("BrowserSettingsDidChange")

    private static let defaults = UserDefaults.standard

    static var addressBarMode: AddressBarMode {
        get { defaults.string(forKey: "addressBarMode").flatMap(AddressBarMode.init) ?? .perPane }
        set { defaults.set(newValue.rawValue, forKey: "addressBarMode"); notify() }
    }

    static var tabLayout: TabLayout {
        get { defaults.string(forKey: "tabLayout").flatMap(TabLayout.init) ?? .horizontal }
        set { defaults.set(newValue.rawValue, forKey: "tabLayout"); notify() }
    }

    static var appearance: AppearanceMode {
        get { defaults.string(forKey: "appearance").flatMap(AppearanceMode.init) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance"); notify() }
    }

    static var historyEnabled: Bool {
        get { defaults.object(forKey: "historyEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "historyEnabled"); notify() }
    }

    static var adBlockEnabled: Bool {
        get { defaults.object(forKey: "adBlockEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "adBlockEnabled"); notify() }
    }

    static var enabledFilterLists: Set<String> {
        get {
            (defaults.array(forKey: "enabledFilterLists") as? [String]).map(Set.init)
                ?? Set(FilterList.all.filter(\.enabledByDefault).map(\.id))
        }
        set { defaults.set(newValue.sorted(), forKey: "enabledFilterLists"); notify() }
    }

    /// Sites (normalized hosts, subdomains included) where content blocking is off.
    static var adBlockAllowlist: [String] {
        get { defaults.stringArray(forKey: "adBlockAllowlist") ?? [] }
        set { defaults.set(newValue, forKey: "adBlockAllowlist"); notify() }
    }

    static var linkTarget: LinkTarget {
        get { defaults.string(forKey: "linkTarget").flatMap(LinkTarget.init) ?? .tab }
        set { defaults.set(newValue.rawValue, forKey: "linkTarget"); notify() }
    }

    static var linkHintsEnabled: Bool {
        get { defaults.object(forKey: "linkHintsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "linkHintsEnabled"); notify() }
    }

    /// `f` labels links in every pane of the tab, not just the focused one.
    static var linkHintsAllPanes: Bool {
        get { defaults.object(forKey: "linkHintsAllPanes") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "linkHintsAllPanes"); notify() }
    }

    /// "#RRGGBB"
    static var linkHintColor: String {
        get { defaults.string(forKey: "linkHintColor") ?? "#FFD60A" }
        set { defaults.set(newValue, forKey: "linkHintColor"); notify() }
    }

    /// j/k scroll, gg/G top/bottom.
    static var vimKeysEnabled: Bool {
        get { defaults.object(forKey: "vimKeysEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "vimKeysEnabled"); notify() }
    }

    /// "#RRGGBB" — find-in-page matches (current match solid, others tinted).
    static var findHighlightColor: String {
        get { defaults.string(forKey: "findHighlightColor") ?? "#32D74B" }
        set { defaults.set(newValue, forKey: "findHighlightColor"); notify() }
    }

    static var searchEngine: SearchEngine {
        get { defaults.string(forKey: "searchEngine").flatMap(SearchEngine.init) ?? .google }
        set { defaults.set(newValue.rawValue, forKey: "searchEngine"); notify() }
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Turns address bar input into a URL: full URLs pass through, things that look
    /// like hosts get a scheme, and everything else becomes a search.
    static func url(fromUserInput input: String) -> URL? {
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

        var components = URLComponents(string: searchEngine.searchURL)
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }
}
