import AppKit
import SwiftUI
import WebKit

/// One browser window: a list of tabs, each holding a split tree of panes.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    PaneViewDelegate, TabStripDelegate {

    enum Direction { case left, right, up, down }

    var onClose: ((BrowserWindowController) -> Void)?

    private let contentRoot = BrowserContentView()
    private var tabs: [Tab] = []
    private var selectedIndex = 0
    private var settingsObserver: NSObjectProtocol?
    private var downloadsObserver: NSObjectProtocol?
    private var bookmarksObserver: NSObjectProtocol?
    private let bookmarkEditor = BookmarkEditor()
    private let commandPalette = CommandPaletteView()
    private let tabOverview = TabOverviewView()
    private lazy var downloadsPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DownloadsView(manager: DownloadManager.shared))
        return popover
    }()
    private static var focusCounter = 0
    /// ⌃⌘Z: only the pages, no browser chrome (for presenting). Per window, not saved. ⌘L still
    /// works: the shared address bar shows until the address is entered.
    private(set) var isZenMode = false

    private var selectedTab: Tab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }
    var focusedPane: PaneView? { selectedTab?.focusedPane }
    var tabCount: Int { tabs.count }
    var selectedTabIndex: Int { selectedIndex }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        // No automatic window dragging: macOS would otherwise grab clicks on tabs in the
        // title-bar area before we see them. Empty chrome starts drags itself (ChromeView).
        window.isMovable = false
        window.title = "New Tab"
        super.init(window: window)

        window.delegate = self
        window.contentView = contentRoot
        contentRoot.tabStrip.delegate = self
        contentRoot.onSidebarResized = { width in Settings.sidebarWidth = width }
        contentRoot.tabStrip.onDownloadsClick = { [weak self] in self?.toggleDownloads(nil) }
        downloadsObserver = NotificationCenter.default.addObserver(
            forName: DownloadManager.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDownloadsButton() }
        }
        updateDownloadsButton()

        let sharedField = contentRoot.header.addressField
        sharedField.onSubmit = { [weak self] text, pickedFor in
            guard let pane = self?.focusedPane else { return }
            pane.loadFromAddressBar(text, pickedFor: pickedFor)
            pane.focusWebView()
        }
        contentRoot.header.onShieldClick = { [weak self] in
            self?.focusedPane?.toggleContentBlockingForSite()
        }
        sharedField.onEndEditing = { [weak self] in self?.contentRoot.showsZenAddressBar = false }
        sharedField.onCancel = { [weak self] in
            guard let self else { return }
            contentRoot.header.addressField.stringValue = focusedPane?.displayURL ?? ""
            focusedPane?.focusWebView()
        }

        let navigation = contentRoot.navigationButtons
        navigation.onBack = { [weak self] in self?.focusedPane?.webView.goBack() }
        navigation.onForward = { [weak self] in self?.focusedPane?.webView.goForward() }
        navigation.onReload = { [weak self] in self?.focusedPane?.webView.reload() }
        navigation.onStop = { [weak self] in self?.focusedPane?.webView.stopLoading() }

        contentRoot.bookmarksBar.bookmarks = Bookmarks.items
        contentRoot.bookmarksBar.onOpen = { [weak self] url, background in self?.openBookmark(url, background: background) }
        contentRoot.bookmarksBar.onEdit = { [weak self] path, anchor in
            self?.bookmarkEditor.show(path, added: false, below: anchor)
        }
        contentRoot.bookmarksBar.onNewFolder = { [weak self] in self?.addBookmarkFolder() }
        bookmarksObserver = NotificationCenter.default.addObserver(
            forName: Bookmarks.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.contentRoot.bookmarksBar.bookmarks = Bookmarks.items }
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        applySettings()
        Extensions.shared.controller.didOpenWindow(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Tabs

    /// Adds a tab. `configuration` is only passed when WebKit asks for a new web view (window.open).
    @discardableResult
    func addTab(
        configuration: WKWebViewConfiguration? = nil,
        request: URLRequest? = nil,
        nextToCurrent: Bool = false,
        select: Bool = true
    ) -> PaneView {
        let pane = makePane(configuration: configuration)
        let index = nextToCurrent && !tabs.isEmpty ? selectedIndex + 1 : tabs.count
        tabs.insert(Tab(pane: pane), at: index)
        Extensions.shared.didOpen(pane)
        if let request { pane.webView.load(request) }

        if select || tabs.count == 1 {
            selectTab(at: index, editAddress: request == nil && configuration == nil)
        } else {
            if index <= selectedIndex { selectedIndex += 1 }
            reloadTabStrip()
        }
        return pane
    }

    func selectTab(at index: Int, editAddress: Bool = false) {
        guard tabs.indices.contains(index) else { return }
        if hintSession != nil { enqueueHintOperation { [weak self] in await self?.endHintSession() } }
        let tab = tabs[index]
        // Last look at the tab being left, for the tab overview.
        if let previous = selectedTab, previous !== tab {
            Task { await previous.capturePreview() }
        }
        selectedIndex = index
        contentRoot.tabContent = tab.container
        contentRoot.layoutSubtreeIfNeeded()
        reloadTabStrip()
        if let pane = tab.focusedPane ?? tab.panes.first {
            focus(pane, editAddress: editAddress)
        }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let wasSelected = index == selectedIndex
        let tab = tabs.remove(at: index)
        rememberClosedTab(tab, at: index)
        tab.panes.forEach { $0.teardown() }
        tab.container.removeFromSuperview()

        if tabs.isEmpty {
            window?.close()
            return
        }
        if wasSelected {
            selectTab(at: min(index, tabs.count - 1))
        } else {
            if index < selectedIndex { selectedIndex -= 1 }
            reloadTabStrip()
        }
    }

    private func reloadTabStrip() {
        let items = tabs.map { TabItem(title: $0.title, paneCount: $0.panes.count, favicon: $0.favicon) }
        contentRoot.tabStrip.update(items: items, selectedIndex: selectedIndex)
        if tabOverview.isShown { tabOverview.update(tabs: tabs) }
    }

    private func tab(containing pane: PaneView) -> Tab? {
        tabs.first { pane.isDescendant(of: $0.container) }
    }

    // MARK: - Panes

    private func makePane(configuration: WKWebViewConfiguration? = nil) -> PaneView {
        let pane = PaneView(configuration: configuration ?? WebKitSupport.makeConfiguration())
        pane.delegate = self
        pane.showsAddressBar = Settings.addressBarMode == .perPane && !isZenMode
        return pane
    }

    private func split(_ axis: SplitView.Axis) {
        guard let pane = focusedPane else { return }
        split(pane, axis: axis)
    }

    /// Splits `pane`, putting a new pane after it. `configuration` is passed when WebKit asks
    /// for a new web view (window.open); `focusNew: false` keeps focus where it is (⌘-click).
    @discardableResult
    private func split(
        _ pane: PaneView,
        axis: SplitView.Axis,
        configuration: WKWebViewConfiguration? = nil,
        request: URLRequest? = nil,
        focusNew: Bool = true
    ) -> PaneView? {
        guard let parent = pane.superview as? PaneParent else { return nil }
        let newPane = makePane(configuration: configuration)
        let frame = pane.frame
        // Creating the split reparents `pane`; the parent then takes the split in its place.
        let split = SplitView(axis: axis, first: pane, second: newPane)
        split.frame = frame
        parent.replaceChild(pane, with: split)
        split.layoutSubtreeIfNeeded()
        Extensions.shared.didOpen(newPane)
        if let request { newPane.webView.load(request) }
        if focusNew {
            focus(newPane, editAddress: request == nil && configuration == nil)
        } else {
            refreshPaneHighlights()
        }
        reloadTabStrip()
        return newPane
    }

    // MARK: - Reopening closed tabs (⌘⇧T)

    /// A closed tab's split layout, with each pane's back/forward history.
    private indirect enum ClosedLayout {
        case pane(url: URL?, state: Any?, focused: Bool)
        case split(SplitView.Axis, ratio: CGFloat, ClosedLayout, ClosedLayout)
    }

    /// Most recent last; shared by all windows so a tab can come back in any of them.
    private static var closedTabs: [(layout: ClosedLayout, index: Int)] = []
    private static let closedTabsLimit = 25

    private func rememberClosedTab(_ tab: Tab, at index: Int) {
        // Nothing worth reopening in a single blank pane.
        if tab.panes.count == 1, tab.panes.first?.webView.url == nil { return }
        func capture(_ view: NSView) -> ClosedLayout? {
            if let pane = view as? PaneView {
                return .pane(url: pane.webView.url, state: pane.webView.interactionState, focused: pane === tab.focusedPane)
            }
            guard let split = view as? SplitView, let first = capture(split.first), let second = capture(split.second) else { return nil }
            return .split(split.axis, ratio: split.ratio, first, second)
        }
        guard let layout = capture(tab.container.child) else { return }
        Self.closedTabs.append((layout, index))
        if Self.closedTabs.count > Self.closedTabsLimit { Self.closedTabs.removeFirst() }
    }

    static var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    @objc func reopenClosedTab(_ sender: Any?) {
        if tabOverview.isShown { return reopenTabFromOverview() }
        restoreClosedTab()
    }

    private func restoreClosedTab() {
        guard let closed = Self.closedTabs.popLast() else { return NSSound.beep() }
        var focused: PaneView?
        func restore(_ layout: ClosedLayout) -> NSView {
            switch layout {
            case .pane(let url, let state, let isFocused):
                let pane = makePane()
                if let state {
                    pane.webView.interactionState = state
                } else if let url {
                    pane.webView.load(URLRequest(url: url))
                }
                if isFocused { focused = pane }
                return pane
            case .split(let axis, let ratio, let first, let second):
                let split = SplitView(axis: axis, first: restore(first), second: restore(second))
                split.ratio = ratio
                return split
            }
        }
        let tab = Tab(root: restore(closed.layout), focusedPane: focused)
        let index = min(closed.index, tabs.count)
        tabs.insert(tab, at: index)
        tab.panes.forEach(Extensions.shared.didOpen)
        selectTab(at: index)
    }

    private func close(_ pane: PaneView) {
        guard let split = pane.superview as? SplitView, let grandparent = split.superview as? PaneParent else {
            // Last pane in the tab: close the tab.
            if let tab = tab(containing: pane), let index = tabs.firstIndex(where: { $0 === tab }) {
                closeTab(at: index)
            }
            return
        }
        let sibling = split.sibling(of: pane)
        pane.teardown()
        pane.removeFromSuperview()
        grandparent.replaceChild(split, with: sibling)
        grandparent.layoutSubtreeIfNeeded()

        if let next = sibling.paneLeaves.max(by: { $0.lastFocusSerial < $1.lastFocusSerial }) {
            focus(next)
        }
        reloadTabStrip()
    }

    func focus(_ pane: PaneView, editAddress: Bool = false) {
        setFocusedPane(pane)
        if editAddress {
            focusAddressField()
        } else {
            pane.focusWebView()
        }
    }

    private func setFocusedPane(_ pane: PaneView) {
        guard let tab = tab(containing: pane) else { return }
        Self.focusCounter += 1
        pane.lastFocusSerial = Self.focusCounter
        let previous = focusedPane
        tab.focusedPane = pane
        if tab === selectedTab, previous !== pane {
            Extensions.shared.controller.didActivateTab(pane, previousActiveTab: previous)
        }
        if tab === selectedTab {
            refreshPaneHighlights()
            updateTitle()
            syncSharedAddressField()
            updateNavigationButtons()
        }
        reloadTabStrip()
    }

    private func refreshPaneHighlights() {
        guard let tab = selectedTab else { return }
        let panes = tab.panes
        for pane in panes {
            if panes.count < 2 {
                pane.highlight = .none
            } else {
                pane.highlight = pane === tab.focusedPane ? .focused : .unfocused
            }
        }
    }

    /// Handles ⌃H/J/K/L pane navigation. Returns false when the tab has a single pane,
    /// so the keys keep their text-editing meaning (⌃K kills a line, ⌃H deletes back).
    func handleVimPaneNavigation(_ direction: Direction) -> Bool {
        if tabOverview.isShown {
            tabOverview.handleVimKey(direction)
            return true
        }
        // In the command palette, ⌃J / ⌃K move the selection instead.
        if commandPalette.isShown {
            guard direction == .up || direction == .down else { return false }
            commandPalette.handleVimKey(down: direction == .down)
            return true
        }
        guard let tab = selectedTab, tab.panes.count > 1 else { return false }
        focusNeighbor(direction)
        return true
    }

    /// Moves focus to the pane visually adjacent in `direction`. Among equally close
    /// candidates, the most recently focused one wins (like tmux/iTerm).
    private func focusNeighbor(_ direction: Direction) {
        guard let current = focusedPane, let tab = selectedTab else { return }
        let tolerance: CGFloat = 2
        // Window coordinates: y grows upward.
        let origin = current.convert(current.bounds, to: nil)

        let candidates: [(pane: PaneView, gap: CGFloat)] = tab.panes.compactMap { pane in
            guard pane !== current else { return nil }
            let frame = pane.convert(pane.bounds, to: nil)
            let overlapsVertically = frame.minY < origin.maxY - tolerance && frame.maxY > origin.minY + tolerance
            let overlapsHorizontally = frame.minX < origin.maxX - tolerance && frame.maxX > origin.minX + tolerance
            let gap: CGFloat
            let overlaps: Bool
            switch direction {
            case .left: gap = origin.minX - frame.maxX; overlaps = overlapsVertically
            case .right: gap = frame.minX - origin.maxX; overlaps = overlapsVertically
            case .up: gap = frame.minY - origin.maxY; overlaps = overlapsHorizontally
            case .down: gap = origin.minY - frame.maxY; overlaps = overlapsHorizontally
            }
            guard overlaps, gap >= -tolerance else { return nil }
            return (pane, gap)
        }

        let best = candidates.min { a, b in
            if abs(a.gap - b.gap) > tolerance { return a.gap < b.gap }
            return a.pane.lastFocusSerial > b.pane.lastFocusSerial
        }
        if let best { focus(best.pane) }
    }

    private func equalize(_ view: NSView) {
        guard let split = view as? SplitView else { return }
        equalize(split.first)
        equalize(split.second)
        let firstCount = leafCount(split.first, along: split.axis)
        let secondCount = leafCount(split.second, along: split.axis)
        split.ratio = CGFloat(firstCount) / CGFloat(firstCount + secondCount)
    }

    /// Number of panes laid out side by side along `axis`, so equalizing gives every pane equal size.
    private func leafCount(_ view: NSView, along axis: SplitView.Axis) -> Int {
        guard let split = view as? SplitView, split.axis == axis else { return 1 }
        return leafCount(split.first, along: axis) + leafCount(split.second, along: axis)
    }

    // MARK: - Address bar & settings

    private func focusAddressField() {
        if isZenMode {
            // Zen mode shows the shared address bar just while typing; it goes again once editing ends.
            contentRoot.showsZenAddressBar = true
            contentRoot.layoutSubtreeIfNeeded()
            syncSharedAddressField()
            window?.makeFirstResponder(contentRoot.header.addressField)
        } else if Settings.addressBarMode == .shared {
            window?.makeFirstResponder(contentRoot.header.addressField)
        } else {
            focusedPane?.focusAddressField()
        }
    }

    private func syncSharedAddressField() {
        let field = contentRoot.header.addressField
        contentRoot.header.icon = focusedPane?.favicon
        contentRoot.header.shieldState = focusedPane?.shieldState ?? .hidden
        contentRoot.header.extensionToolbar.pane = focusedPane
        if field.currentEditor() == nil {
            field.stringValue = focusedPane?.displayURL ?? ""
        }
    }

    private func updateNavigationButtons() {
        let webView = focusedPane?.webView
        contentRoot.navigationButtons.update(
            canGoBack: webView?.canGoBack ?? false, canGoForward: webView?.canGoForward ?? false,
            isLoading: webView?.isLoading ?? false
        )
    }

    private func updateTitle() {
        let title = focusedPane?.displayTitle ?? "New Tab"
        window?.title = title
        contentRoot.header.title = title
    }

    private func applySettings() {
        let perPane = Settings.addressBarMode == .perPane
        for tab in tabs {
            tab.panes.forEach { $0.showsAddressBar = perPane && !isZenMode }
        }
        contentRoot.tabLayout = Settings.tabLayout
        contentRoot.sidebarWidth = Settings.sidebarWidth
        contentRoot.sidebarAutoHide = Settings.sidebarAutoHide
        contentRoot.showsSharedAddressBar = !perPane
        contentRoot.showsBookmarksBar = Settings.showBookmarksBar
        contentRoot.isZenMode = isZenMode
        syncSharedAddressField()
        refreshPaneHighlights()
    }

    private func setZenMode(_ on: Bool) {
        guard on != isZenMode else { return }
        isZenMode = on
        if on {
            bookmarkEditor.close()
            if downloadsPopover.isShown { downloadsPopover.performClose(nil) }
            // The address bar is about to disappear; keep typing out of it.
            let editingAddress = contentRoot.header.addressField.currentEditor() != nil
                || focusedPane?.addressField.currentEditor() != nil
            if editingAddress { focusedPane?.focusWebView() }
        }
        applySettings()
        // Callers leaving zen mode anchor popovers to (or focus) the chrome right away.
        contentRoot.layoutSubtreeIfNeeded()
    }

    // MARK: - Menu actions

    @objc func newTab(_ sender: Any?) {
        if tabOverview.isShown { closeTabOverview(selecting: nil) }
        addTab()
    }

    /// In the tab overview, ⌘W and ⌘⇧W close the highlighted tab.
    @objc func closeCurrentTab(_ sender: Any?) {
        if tabOverview.isShown { return closeTabFromOverview(at: tabOverview.highlightedIndex) }
        closeTab(at: selectedIndex)
    }

    @objc func closePane(_ sender: Any?) {
        if tabOverview.isShown { return closeTabFromOverview(at: tabOverview.highlightedIndex) }
        focusedPane.map(close)
    }

    @objc func splitRight(_ sender: Any?) { split(.horizontal) }
    @objc func splitDown(_ sender: Any?) { split(.vertical) }
    @objc func focusPaneLeft(_ sender: Any?) { focusNeighbor(.left) }
    @objc func focusPaneRight(_ sender: Any?) { focusNeighbor(.right) }
    @objc func focusPaneUp(_ sender: Any?) { focusNeighbor(.up) }
    @objc func focusPaneDown(_ sender: Any?) { focusNeighbor(.down) }
    @objc func equalizePanes(_ sender: Any?) { selectedTab.map { equalize($0.container.child) } }
    @objc func openLocation(_ sender: Any?) { focusAddressField() }
    @objc func reloadPage(_ sender: Any?) { focusedPane?.webView.reload() }
    @objc func zoomIn(_ sender: Any?) { focusedPane?.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { focusedPane?.zoomOut() }
    @objc func resetZoom(_ sender: Any?) { focusedPane?.resetZoom() }
    @objc func toggleWebInspector(_ sender: Any?) { focusedPane?.toggleWebInspector() }
    @objc func showLinkHints(_ sender: Any?) { focusedPane?.showLinkHints() }
    @objc func toggleSidebar(_ sender: Any?) { contentRoot.toggleSidebar() }
    @objc func toggleZenMode(_ sender: Any?) { setZenMode(!isZenMode) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleZenMode(_:)) { menuItem.state = isZenMode ? .on : .off }
        // The overview covers the tab: commands that act on the page wait until it's closed.
        // (A disabled item still swallows its shortcut, so nothing reaches the page either.)
        if tabOverview.isShown, let action = menuItem.action, !Self.tabOverviewActions.contains(action) {
            return false
        }
        return true
    }

    // MARK: - Tab overview (⌘§)

    private static let tabOverviewActions: Set<Selector> = [
        #selector(toggleTabOverview(_:)), #selector(newTab(_:)), #selector(closePane(_:)),
        #selector(closeCurrentTab(_:)), #selector(reopenClosedTab(_:)),
    ]

    /// ⌘§: every tab in this window as a grid of previews; pressing it again goes back.
    @objc func toggleTabOverview(_ sender: Any?) {
        if tabOverview.isShown { return closeTabOverview(selecting: nil) }
        guard !tabs.isEmpty else { return }
        commandPalette.close(restoringFocus: false)
        bookmarkEditor.close()
        if downloadsPopover.isShown { downloadsPopover.performClose(nil) }
        if hintSession != nil { enqueueHintOperation { [weak self] in await self?.endHintSession() } }

        tabOverview.onSelect = { [weak self] index in self?.closeTabOverview(selecting: index) }
        tabOverview.onCancel = { [weak self] in self?.closeTabOverview(selecting: nil) }
        tabOverview.onCloseTab = { [weak self] index in self?.closeTabFromOverview(at: index) }
        tabOverview.onReopenTab = { [weak self] in self?.reopenTabFromOverview() }
        contentRoot.layoutSubtreeIfNeeded()
        let content = contentRoot.tabContent?.frame ?? contentRoot.bounds
        // Tabs opened in the background have never been laid out, and others may have been left
        // at an older window size: size them like the current one so they can be captured.
        for tab in tabs where tab.container.frame.size != content.size {
            tab.container.frame = content
            tab.container.layoutSubtreeIfNeeded()
        }
        tabOverview.show(in: contentRoot, tabs: tabs, selected: selectedIndex, liveSize: content.size)
        // Cached previews show right away; fresh ones replace them as they come in.
        for tab in tabs {
            Task { [weak self] in
                await tab.capturePreview()
                self?.tabOverview.refreshPreviews()
            }
        }
    }

    private func closeTabOverview(selecting index: Int?) {
        guard tabOverview.isShown else { return }
        tabOverview.close()
        contentRoot.reattachTabContent()
        if let index, index != selectedIndex {
            selectTab(at: index)
        } else if let pane = focusedPane {
            focus(pane)
        }
    }

    private func closeTabFromOverview(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        closeTab(at: index)  // closing the last tab closes the window
        guard tabOverview.isShown else { return }
        // Closing the selected tab selects (and focuses) another; the overview keeps the keys.
        tabOverview.takeFocus()
    }

    private func reopenTabFromOverview() {
        guard Self.canReopenClosedTab else { return NSSound.beep() }
        restoreClosedTab()
        tabOverview.update(tabs: tabs, highlight: selectedIndex)
        tabOverview.takeFocus()
        if let tab = selectedTab {
            Task { [weak self] in
                await tab.capturePreview()
                self?.tabOverview.refreshPreviews()
            }
        }
    }

    /// For the self-test.
    var debugTabOverview: TabOverviewView { tabOverview }

    @objc func toggleDownloads(_ sender: Any?) {
        if downloadsPopover.isShown {
            downloadsPopover.performClose(nil)
        } else {
            setZenMode(false)
            showDownloads()
        }
    }

    @objc func bookmarkCurrentPage(_ sender: Any?) {
        guard let pane = focusedPane, let url = pane.webView.url, !["about", "data"].contains(url.scheme?.lowercased()) else {
            NSSound.beep()
            return
        }
        bookmark(url, title: pane.webView.title ?? "", from: pane)
    }

    /// Adds `url` to the end of the bar (or finds its existing bookmark) and opens the editor,
    /// hanging from the right end of the address bar (where a star button would be).
    private func bookmark(_ url: URL, title: String, from pane: PaneView) {
        setZenMode(false)  // the editor hangs from the address bar
        bookmarkEditor.close()  // applies its edits first, so the paths below are current
        let existing = Bookmarks.path(of: url)
        let path = existing ?? Bookmarks.add(Bookmark(title: title.isEmpty ? (url.host() ?? "") : title, kind: .link(url)))
        let bar = Settings.addressBarMode == .shared ? contentRoot.header.addressBarView : pane.addressBarView
        bookmarkEditor.show(path, added: existing == nil, below: bar, arrow: .trailing)
    }

    private func addBookmarkFolder() {
        bookmarkEditor.close()
        let path = Bookmarks.add(Bookmark(title: "New Folder", kind: .folder([])))
        let bar = contentRoot.bookmarksBar
        bar.bookmarks = Bookmarks.items
        bar.layoutSubtreeIfNeeded()
        let anchor = path.last.flatMap(bar.itemView(at:)) ?? bar
        bookmarkEditor.show(path, added: true, below: anchor)
    }

    var isBookmarkEditorShown: Bool { bookmarkEditor.isShown }
    /// For the self-test.
    var debugBookmarkEditor: BookmarkEditor { bookmarkEditor }

    /// ⌘P: search bookmarks and open one in the focused pane, or enter an address or search.
    /// Pressing it again closes the palette; with the commands showing, it switches to bookmarks.
    @objc func searchBookmarks(_ sender: Any?) { togglePalette(prefix: "") }

    /// ⌘⇧P: run any menu command, like VS Code's palette (it opens with `>`; deleting that goes to
    /// bookmarks). Pressing it again closes the palette; with bookmarks showing, it switches to commands.
    @objc func showCommandPalette(_ sender: Any?) { togglePalette(prefix: ">") }

    private func togglePalette(prefix: String) {
        if let current = commandPalette.modePrefix {
            return current == prefix ? commandPalette.close(restoringFocus: true) : commandPalette.setQuery(prefix)
        }
        bookmarkEditor.close()
        let open: (URL, Bool) -> Void = { [weak self] url, background in self?.openBookmark(url, background: background) }
        commandPalette.show(in: contentRoot, modes: [
            CommandPaletteMode(sources: [BookmarksPaletteSource(open: open)],
                               placeholder: "Search bookmarks or enter an address (> for commands)",
                               emptyText: "No bookmarks yet. Press ⌘B to bookmark the current page, or type > for commands.",
                               queryItem: { BookmarksPaletteSource.queryItem($0, open: open) }),
            CommandPaletteMode(prefix: ">", sources: [MenuCommandsPaletteSource()], emptyText: "No commands", symbol: "command"),
        ], query: prefix)
    }

    /// For the self-test.
    var debugCommandPalette: CommandPaletteView { commandPalette }

    /// From the bookmarks manager: a new tab, or the focused pane.
    func open(_ url: URL, newTab: Bool) {
        if newTab {
            addTab(request: URLRequest(url: url))
        } else {
            openBookmark(url, background: false)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Bookmarks open in the focused pane; in the background they go where ⌘-clicked links go.
    private func openBookmark(_ url: URL, background: Bool) {
        guard let pane = focusedPane else { return }
        if background {
            self.pane(pane, openLinkInBackground: URLRequest(url: url))
        } else {
            pane.webView.load(URLRequest(url: url))
            pane.focusWebView()
        }
    }

    private func showDownloads() {
        let strip = contentRoot.tabStrip
        strip.showsDownloadsButton = true
        strip.layoutSubtreeIfNeeded()
        let anchor = strip.downloadsButton
        downloadsPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func updateDownloadsButton() {
        let manager = DownloadManager.shared
        contentRoot.tabStrip.showsDownloadsButton = !manager.items.isEmpty
        contentRoot.tabStrip.downloadsActive = manager.activeCount > 0
    }

    var isDownloadsPopoverShown: Bool { downloadsPopover.isShown }
    /// For the self-test.
    var debugContentRoot: BrowserContentView { contentRoot }
    @objc func showFindBar(_ sender: Any?) { focusedPane?.showFindBar() }
    @objc func findNextMatch(_ sender: Any?) { focusedPane?.findNext() }
    @objc func findPreviousMatch(_ sender: Any?) { focusedPane?.findPrevious() }
    @objc func navigateBack(_ sender: Any?) { focusedPane?.webView.goBack() }
    @objc func navigateForward(_ sender: Any?) { focusedPane?.webView.goForward() }

    @objc func showNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedIndex + 1) % tabs.count)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedIndex - 1 + tabs.count) % tabs.count)
    }

    /// ⌘1–⌘8 select that tab, ⌘9 selects the last tab.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        selectTab(at: sender.tag == 9 ? tabs.count - 1 : sender.tag - 1)
    }

    // MARK: - PaneViewDelegate

    func paneDidBecomeFocused(_ pane: PaneView) {
        setFocusedPane(pane)
    }

    func paneDidChangeState(_ pane: PaneView) {
        reloadTabStrip()
        // A page that finished loading behind the overview (a reopened tab) gets a fresh preview.
        if tabOverview.isShown, !pane.webView.isLoading, let tab = tab(containing: pane) {
            Task { [weak self] in
                await tab.capturePreview()
                self?.tabOverview.refreshPreviews()
            }
        }
        if pane === focusedPane {
            updateTitle()
            syncSharedAddressField()
            updateNavigationButtons()
        }
    }

    func pane(_ pane: PaneView, openLinkInBackground request: URLRequest) {
        switch Settings.linkTarget {
        case .tab: addTab(request: request, nextToCurrent: true, select: false)
        case .pane: split(pane, axis: .horizontal, request: request, focusNew: false)
        }
    }

    func pane(_ pane: PaneView, createWebViewWith configuration: WKWebViewConfiguration) -> WKWebView? {
        switch Settings.linkTarget {
        case .tab: return addTab(configuration: configuration, nextToCurrent: true).webView
        case .pane: return split(pane, axis: .horizontal, configuration: configuration)?.webView
        }
    }

    // MARK: - Link hints across panes

    private struct HintSession {
        var panes: [PaneView]
        var typed = ""
        var background: Bool
    }

    private var hintSession: HintSession?
    private var hintOperations: [() async -> Void] = []
    private var runningHintOperations = false

    func pane(_ pane: PaneView, didStartDownload download: WKDownload) {
        DownloadManager.shared.track(download)
        // A pane opened only to fetch a file (e.g. a link that opened a new tab) has nothing to show.
        if pane.webView.url == nil || pane.webView.url?.absoluteString == "about:blank",
           pane.webView.backForwardList.currentItem == nil,
           tabs.count > 1 || (selectedTab?.panes.count ?? 0) > 1 {
            close(pane)
        }
        if window?.isKeyWindow == true, !isZenMode { showDownloads() }
    }

    func pane(_ pane: PaneView, bookmark url: URL, title: String) {
        bookmark(url, title: title, from: pane)
    }

    func paneRequestedHintsInAllPanes(_ pane: PaneView, background: Bool) {
        enqueueHintOperation { [weak self] in await self?.startHintSession(from: pane, background: background) }
    }

    func pane(_ pane: PaneView, typedHintKey key: String) {
        enqueueHintOperation { [weak self] in await self?.handleHintKey(key) }
    }

    func paneCancelledHints(_ pane: PaneView) {
        enqueueHintOperation { [weak self] in await self?.endHintSession() }
    }

    /// Hint operations talk to several web views asynchronously; run them one at a time, in order,
    /// so fast typing can't interleave.
    private func enqueueHintOperation(_ operation: @escaping () async -> Void) {
        hintOperations.append(operation)
        guard !runningHintOperations else { return }
        runningHintOperations = true
        Task {
            while !hintOperations.isEmpty {
                await hintOperations.removeFirst()()
            }
            runningHintOperations = false
        }
    }

    /// Collects targets from every pane in the tab and hands out labels unique across all of them.
    private func startHintSession(from source: PaneView, background: Bool) async {
        await endHintSession()
        guard let tab = tab(containing: source) else { return }
        let panes = tab.panes
        var counts: [Int] = []
        for pane in panes {
            counts.append(await pane.collectHintTargets())
        }
        let labels = LinkHints.labels(count: counts.reduce(0, +))
        guard !labels.isEmpty else { return await endHintSession(panes) }
        var offset = 0
        for (pane, count) in zip(panes, counts) {
            await pane.showHints(Array(labels[offset..<(offset + count)]), background: background)
            offset += count
        }
        hintSession = HintSession(panes: panes, background: background)
    }

    private func handleHintKey(_ key: String) async {
        guard var session = hintSession else { return }
        switch key {
        case "Escape":
            return await endHintSession()
        case "Backspace":
            if !session.typed.isEmpty { session.typed.removeLast() }
        default:
            session.typed += key
        }

        var results: [(pane: PaneView, matches: Int, exact: Bool)] = []
        for pane in session.panes {
            let result = await pane.filterHints(session.typed)
            results.append((pane, result.matches, result.exact))
        }
        let total = results.reduce(0) { $0 + $1.matches }

        if total == 0, !session.typed.isEmpty {
            // A key that matches nothing is ignored.
            session.typed.removeLast()
            for pane in session.panes { _ = await pane.filterHints(session.typed) }
        } else if total == 1, let winner = results.first(where: \.exact)?.pane {
            hintSession = nil
            for pane in session.panes where pane !== winner { await pane.stopHints() }
            if !session.background { focus(winner) }
            await winner.activateHint(session.typed)
            return
        }
        hintSession = session
    }

    private func endHintSession(_ panes: [PaneView]? = nil) async {
        let targets = panes ?? hintSession?.panes ?? selectedTab?.panes ?? []
        hintSession = nil
        for pane in targets { await pane.stopHints() }
    }

    // MARK: - TabStripDelegate

    func tabStrip(_ strip: TabStripView, didSelectTabAt index: Int) { selectTab(at: index) }
    func tabStrip(_ strip: TabStripView, didCloseTabAt index: Int) { closeTab(at: index) }
    func tabStripDidRequestNewTab(_ strip: TabStripView) { addTab() }

    func tabStrip(_ strip: TabStripView, didMoveTabFrom source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination) else { return }
        let selected = selectedTab
        tabs.insert(tabs.remove(at: source), at: destination)
        if let selected, let index = tabs.firstIndex(where: { $0 === selected }) {
            selectedIndex = index
        }
        reloadTabStrip()
    }

    /// For the self-test.
    var debugTabTitles: [String] { tabs.map(\.title) }
    var debugTabPreviews: [NSImage?] { tabs.map(\.preview) }
    var debugPanes: [PaneView] { selectedTab?.panes ?? [] }
    var debugTabCenters: [NSPoint] { contentRoot.tabStrip.debugTabCenters }

    // MARK: - Extensions

    /// Every pane in every tab, in tab order: what extensions see as this window's tabs.
    var allPanes: [PaneView] { tabs.flatMap(\.panes) }

    /// A tab opened by an extension (`tabs.create`, its settings page). Its own pages need the
    /// extension's web view configuration.
    @discardableResult
    func addTab(for url: URL?, extensionContext: WKWebExtensionContext, select: Bool) -> PaneView {
        let configuration = url.flatMap { Extensions.shared.controller.extensionContext(for: $0) }?.webViewConfiguration
        let pane = addTab(configuration: configuration, request: url.map { URLRequest(url: $0) }, nextToCurrent: true, select: select)
        if select { window?.makeKeyAndOrderFront(nil) }
        return pane
    }

    /// Selects `pane`'s tab and focuses it.
    func reveal(_ pane: PaneView) {
        guard let tab = tab(containing: pane), let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if index != selectedIndex { selectTab(at: index) }
        focus(pane)
    }

    func closeFromExtension(_ pane: PaneView) { close(pane) }

    /// The visible toolbar button for `context` acting on `pane`, to anchor its popup.
    func extensionButton(for context: WKWebExtensionContext, in pane: PaneView) -> NSView? {
        let toolbars = [pane.extensionToolbar, contentRoot.header.extensionToolbar]
        return toolbars.lazy
            .filter { $0.pane === pane && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            .compactMap { $0.buttons.first { $0.context === context } }
            .first
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        Extensions.shared.controller.didFocusWindow(self)
    }

    func windowWillClose(_ notification: Notification) {
        for tab in tabs {
            tab.panes.forEach { $0.teardown(windowIsClosing: true) }
        }
        tabs.removeAll()
        Extensions.shared.controller.didCloseWindow(self)
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let downloadsObserver { NotificationCenter.default.removeObserver(downloadsObserver) }
        if let bookmarksObserver { NotificationCenter.default.removeObserver(bookmarksObserver) }
        onClose?(self)
    }
}
