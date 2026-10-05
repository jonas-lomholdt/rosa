import SwiftUI

/// Bridges `Settings` (~/.rosa/settings.json + change notification) to SwiftUI, so the window
/// stays in sync when settings change elsewhere (e.g. the View menu toggles).
@MainActor
final class SettingsModel: ObservableObject {
    @Published var tabLayout: TabLayout {
        didSet { if Settings.tabLayout != tabLayout { Settings.tabLayout = tabLayout } }
    }
    @Published var addressBarMode: AddressBarMode {
        didSet { if Settings.addressBarMode != addressBarMode { Settings.addressBarMode = addressBarMode } }
    }
    @Published var appearance: AppearanceMode {
        didSet { if Settings.appearance != appearance { Settings.appearance = appearance } }
    }
    @Published var inactivePaneOpacity: Double {
        didSet { if Settings.inactivePaneOpacity != inactivePaneOpacity { Settings.inactivePaneOpacity = inactivePaneOpacity } }
    }
    @Published var linkHintsEnabled: Bool {
        didSet { if Settings.linkHintsEnabled != linkHintsEnabled { Settings.linkHintsEnabled = linkHintsEnabled } }
    }
    @Published var linkHintColor: String {
        didSet { if Settings.linkHintColor != linkHintColor { Settings.linkHintColor = linkHintColor } }
    }
    @Published var linkHintsAllPanes: Bool {
        didSet { if Settings.linkHintsAllPanes != linkHintsAllPanes { Settings.linkHintsAllPanes = linkHintsAllPanes } }
    }
    @Published var findHighlightColor: String {
        didSet { if Settings.findHighlightColor != findHighlightColor { Settings.findHighlightColor = findHighlightColor } }
    }
    @Published var formatJSON: Bool {
        didSet { if Settings.formatJSON != formatJSON { Settings.formatJSON = formatJSON } }
    }
    @Published var vimKeysEnabled: Bool {
        didSet { if Settings.vimKeysEnabled != vimKeysEnabled { Settings.vimKeysEnabled = vimKeysEnabled } }
    }
    @Published var askWhereToSaveDownloads: Bool {
        didSet { if Settings.askWhereToSaveDownloads != askWhereToSaveDownloads { Settings.askWhereToSaveDownloads = askWhereToSaveDownloads } }
    }
    @Published var sidebarAutoHide: Bool {
        didSet { if Settings.sidebarAutoHide != sidebarAutoHide { Settings.sidebarAutoHide = sidebarAutoHide } }
    }
    @Published var linkTarget: LinkTarget {
        didSet { if Settings.linkTarget != linkTarget { Settings.linkTarget = linkTarget } }
    }
    @Published var searchEngine: SearchEngine {
        didSet { if Settings.searchEngine != searchEngine { Settings.searchEngine = searchEngine } }
    }
    @Published var historyEnabled: Bool {
        didSet { if Settings.historyEnabled != historyEnabled { Settings.historyEnabled = historyEnabled } }
    }
    @Published private(set) var historyPageCount = 0
    @Published var confirmingClear = false
    @Published var adBlockEnabled: Bool {
        didSet { if Settings.adBlockEnabled != adBlockEnabled { Settings.adBlockEnabled = adBlockEnabled } }
    }
    @Published private(set) var enabledFilterLists: Set<String>
    @Published private(set) var allowlist: [String]
    @Published private(set) var blockerStatus = ""
    @Published private(set) var blockerUpdating = false
    @Published var checkForUpdatesOnLaunch: Bool {
        didSet { if Settings.checkForUpdatesOnLaunch != checkForUpdatesOnLaunch { Settings.checkForUpdatesOnLaunch = checkForUpdatesOnLaunch } }
    }
    @Published private(set) var updateStatus = ""
    @Published private(set) var updaterBusy = false
    @Published private(set) var availableUpdate: Updater.Release?

    private var observer: NSObjectProtocol?
    private var historyObserver: NSObjectProtocol?
    private var blockerObserver: NSObjectProtocol?
    private var updaterObserver: NSObjectProtocol?

    init() {
        tabLayout = Settings.tabLayout
        addressBarMode = Settings.addressBarMode
        appearance = Settings.appearance
        inactivePaneOpacity = Settings.inactivePaneOpacity
        searchEngine = Settings.searchEngine
        linkTarget = Settings.linkTarget
        sidebarAutoHide = Settings.sidebarAutoHide
        askWhereToSaveDownloads = Settings.askWhereToSaveDownloads
        linkHintsEnabled = Settings.linkHintsEnabled
        linkHintColor = Settings.linkHintColor
        vimKeysEnabled = Settings.vimKeysEnabled
        findHighlightColor = Settings.findHighlightColor
        formatJSON = Settings.formatJSON
        linkHintsAllPanes = Settings.linkHintsAllPanes
        historyEnabled = Settings.historyEnabled
        historyPageCount = HistoryStore.shared.pageCount
        adBlockEnabled = Settings.adBlockEnabled
        enabledFilterLists = Settings.enabledFilterLists
        allowlist = Settings.adBlockAllowlist
        checkForUpdatesOnLaunch = Settings.checkForUpdatesOnLaunch
        refreshBlockerStatus()
        refreshUpdateStatus()
        updaterObserver = NotificationCenter.default.addObserver(
            forName: Updater.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUpdateStatus() }
        }
        blockerObserver = NotificationCenter.default.addObserver(
            forName: ContentBlocker.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBlockerStatus() }
        }
        historyObserver = NotificationCenter.default.addObserver(
            forName: HistoryStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.historyPageCount = HistoryStore.shared.pageCount }
        }
        observer = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        tabLayout = Settings.tabLayout
        addressBarMode = Settings.addressBarMode
        appearance = Settings.appearance
        inactivePaneOpacity = Settings.inactivePaneOpacity
        searchEngine = Settings.searchEngine
        linkTarget = Settings.linkTarget
        sidebarAutoHide = Settings.sidebarAutoHide
        askWhereToSaveDownloads = Settings.askWhereToSaveDownloads
        linkHintsEnabled = Settings.linkHintsEnabled
        linkHintColor = Settings.linkHintColor
        vimKeysEnabled = Settings.vimKeysEnabled
        findHighlightColor = Settings.findHighlightColor
        formatJSON = Settings.formatJSON
        linkHintsAllPanes = Settings.linkHintsAllPanes
        historyEnabled = Settings.historyEnabled
        adBlockEnabled = Settings.adBlockEnabled
        enabledFilterLists = Settings.enabledFilterLists
        allowlist = Settings.adBlockAllowlist
        checkForUpdatesOnLaunch = Settings.checkForUpdatesOnLaunch
    }

    private func refreshUpdateStatus() {
        let updater = Updater.shared
        updateStatus = updater.statusDescription
        updaterBusy = updater.isBusy
        if case .available(let release) = updater.status { availableUpdate = release } else { availableUpdate = nil }
    }

    func checkForUpdates() {
        Updater.shared.checkNow()
    }

    func installUpdate() {
        availableUpdate.map(Updater.shared.install)
    }

    private func refreshBlockerStatus() {
        blockerStatus = ContentBlocker.shared.statusDescription
        blockerUpdating = ContentBlocker.shared.isUpdating
    }

    func isListEnabled(_ list: FilterList) -> Binding<Bool> {
        Binding(
            get: { self.enabledFilterLists.contains(list.id) },
            set: { enabled in
                var lists = Settings.enabledFilterLists
                if enabled { lists.insert(list.id) } else { lists.remove(list.id) }
                Settings.enabledFilterLists = lists
            }
        )
    }

    var findHighlightColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: self.findHighlightColor) ?? .systemGreen) },
            set: { self.findHighlightColor = NSColor($0).hexString }
        )
    }

    var linkHintColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: self.linkHintColor) ?? .systemYellow) },
            set: { self.linkHintColor = NSColor($0).hexString }
        )
    }

    func updateFilterLists() {
        ContentBlocker.shared.reload(forceDownload: true)
    }

    func removeFromAllowlist(_ host: String) {
        Settings.adBlockAllowlist = Settings.adBlockAllowlist.filter { $0 != host }
    }

    func clearHistory(since date: Date?) {
        HistoryStore.shared.clear(since: date)
    }
}

struct SettingsView: View {
    // Note: avoid @State and other macro-based SwiftUI APIs; the Command Line Tools ship
    // without SwiftUI's macro plugins. Keep view state in SettingsModel instead.
    @StateObject private var model = SettingsModel()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                ColorPicker("Find highlight colour", selection: model.findHighlightColorBinding, supportsOpacity: false)
                LabeledContent("Unfocused pane opacity") {
                    HStack {
                        Slider(value: $model.inactivePaneOpacity, in: Settings.inactivePaneOpacityRange, step: 0.05)
                        Text("\(Int((model.inactivePaneOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Format JSON responses", isOn: $model.formatJSON)
            }

            Section {
                Picker("Tab layout", selection: $model.tabLayout) {
                    Text("Horizontal").tag(TabLayout.horizontal)
                    Text("Vertical sidebar").tag(TabLayout.vertical)
                }
                .pickerStyle(.segmented)
                Toggle("Auto-hide sidebar", isOn: $model.sidebarAutoHide)
                    .disabled(model.tabLayout != .vertical)
                Picker("Open links in", selection: $model.linkTarget) {
                    Text("New tab").tag(LinkTarget.tab)
                    Text("New pane").tag(LinkTarget.pane)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Tabs & Links")
            } footer: {
                Text("Drag the sidebar's edge to resize it. When auto-hiding, it shrinks to a column of favicons; hover it (or press ⌃⌘S) to expand it. Open links in: applies to links that open a new window, and to ⌘-click (which opens in the background).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Address bar", selection: $model.addressBarMode) {
                    Text("Per pane").tag(AddressBarMode.perPane)
                    Text("Shared").tag(AddressBarMode.shared)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Address Bar")
            } footer: {
                Text(model.addressBarMode == .perPane
                     ? "Every pane has its own slim address bar."
                     : "One address bar at the top follows the focused pane.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Link hints", isOn: $model.linkHintsEnabled)
                Toggle("Show hints in all panes", isOn: $model.linkHintsAllPanes)
                    .disabled(!model.linkHintsEnabled)
                ColorPicker("Hint colour", selection: model.linkHintColorBinding, supportsOpacity: false)
                    .disabled(!model.linkHintsEnabled)
                Toggle("Vim-style scrolling", isOn: $model.vimKeysEnabled)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Link hints: press F on a page, then type a label to click it (Shift-F opens in the background, Esc cancels). Vim-style scrolling: J/K scroll, H/L scroll sideways, GG jumps to the top, Shift-G to the bottom. Keys are ignored while typing in a field.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Remember browsing history", isOn: $model.historyEnabled)
                LabeledContent("\(model.historyPageCount) pages in history") {
                    Button("Clear History…") { model.confirmingClear = true }
                        .disabled(model.historyPageCount == 0)
                }
            } header: {
                Text("History")
            } footer: {
                Text("History powers address bar suggestions. It never leaves this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog("Clear browsing history?", isPresented: $model.confirmingClear) {
                Button("Last Hour", role: .destructive) { model.clearHistory(since: Date().addingTimeInterval(-3600)) }
                Button("Today", role: .destructive) { model.clearHistory(since: Calendar.current.startOfDay(for: Date())) }
                Button("All History", role: .destructive) { model.clearHistory(since: nil) }
                Button("Cancel", role: .cancel) {}
            }

            Section {
                Toggle("Block ads and trackers", isOn: $model.adBlockEnabled)
                ForEach(FilterList.all) { list in
                    Toggle(isOn: model.isListEnabled(list)) {
                        Text(list.name)
                        Text(list.detail)
                    }
                    .disabled(!model.adBlockEnabled)
                }
                LabeledContent(model.blockerStatus) {
                    Button("Update Now") { model.updateFilterLists() }
                        .disabled(model.blockerUpdating || !model.adBlockEnabled)
                }
            } header: {
                Text("Content Blocking")
            } footer: {
                Text("Filter lists are downloaded from EasyList and refreshed weekly. Use the shield in the address bar to turn blocking off for a single site.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !model.allowlist.isEmpty {
                Section("Sites Without Blocking") {
                    ForEach(model.allowlist, id: \.self) { host in
                        LabeledContent(host) {
                            Button("Remove") { model.removeFromAllowlist(host) }
                        }
                    }
                }
            }

            Section {
                Toggle("Ask where to save each download", isOn: $model.askWhereToSaveDownloads)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Otherwise files go straight to your Downloads folder. ⌥⌘L shows downloads.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Search") {
                Picker("Search engine", selection: $model.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.name).tag(engine)
                    }
                }
            }

            Section {
                Toggle("Check for updates on launch", isOn: $model.checkForUpdatesOnLaunch)
                LabeledContent(model.updateStatus) {
                    if let release = model.availableUpdate {
                        Button("Install \(release.version)") { model.installUpdate() }
                    } else {
                        Button("Check Now") { model.checkForUpdates() }
                            .disabled(model.updaterBusy)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates come from GitHub releases. Installing quits Rosa, replaces it and reopens it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Rosa", value: AppInfo.version)
                Link("github.com/jonas-lomholdt/rosa", destination: AppInfo.repositoryURL)
                LabeledContent("Settings file") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Settings.fileURL]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
    }
}
