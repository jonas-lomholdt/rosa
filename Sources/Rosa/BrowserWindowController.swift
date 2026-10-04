import AppKit
import SwiftUI
import WebKit

/// One browser window: a list of tabs, each holding a split tree of panes.
final class BrowserWindowController: NSWindowController, NSWindowDelegate,
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
    private lazy var downloadsPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DownloadsView(manager: DownloadManager.shared))
        return popover
    }()
    private static var focusCounter = 0

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
        sharedField.onSubmit = { [weak self] text in
            guard let pane = self?.focusedPane else { return }
            pane.load(text)
            pane.focusWebView()
        }
        contentRoot.header.onShieldClick = { [weak self] in
            self?.focusedPane?.toggleContentBlockingForSite()
        }
        sharedField.onCancel = { [weak self] in
            guard let self else { return }
            contentRoot.header.addressField.stringValue = focusedPane?.displayURL ?? ""
            focusedPane?.focusWebView()
        }

        contentRoot.bookmarksBar.bookmarks = Bookmarks.items
        contentRoot.bookmarksBar.onOpen = { [weak self] url, background in self?.openBookmark(url, background: background) }
        contentRoot.bookmarksBar.onEdit = { [weak self] path, anchor in
            self?.bookmarkEditor.show(path, added: false, relativeTo: anchor.bounds, of: anchor)
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
        selectedIndex = index
        let tab = tabs[index]
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
    }

    private func tab(containing pane: PaneView) -> Tab? {
        tabs.first { pane.isDescendant(of: $0.container) }
    }

    // MARK: - Panes

    private func makePane(configuration: WKWebViewConfiguration? = nil) -> PaneView {
        let pane = PaneView(configuration: configuration ?? WebKitSupport.makeConfiguration())
        pane.delegate = self
        pane.showsAddressBar = Settings.addressBarMode == .perPane
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
        if let request { newPane.webView.load(request) }
        if focusNew {
            focus(newPane, editAddress: request == nil && configuration == nil)
        } else {
            refreshPaneHighlights()
        }
        reloadTabStrip()
        return newPane
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
        tab.focusedPane = pane
        if tab === selectedTab {
            refreshPaneHighlights()
            updateTitle()
            syncSharedAddressField()
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
        if Settings.addressBarMode == .shared {
            window?.makeFirstResponder(contentRoot.header.addressField)
        } else {
            focusedPane?.focusAddressField()
        }
    }

    private func syncSharedAddressField() {
        let field = contentRoot.header.addressField
        contentRoot.header.icon = focusedPane?.favicon
        contentRoot.header.shieldState = focusedPane?.shieldState ?? .hidden
        if field.currentEditor() == nil {
            field.stringValue = focusedPane?.displayURL ?? ""
        }
    }

    private func updateTitle() {
        let title = focusedPane?.displayTitle ?? "New Tab"
        window?.title = title
        contentRoot.header.title = title
    }

    private func applySettings() {
        let perPane = Settings.addressBarMode == .perPane
        for tab in tabs {
            tab.panes.forEach { $0.showsAddressBar = perPane }
        }
        contentRoot.tabLayout = Settings.tabLayout
        contentRoot.sidebarWidth = Settings.sidebarWidth
        contentRoot.sidebarAutoHide = Settings.sidebarAutoHide
        contentRoot.showsSharedAddressBar = !perPane
        contentRoot.showsBookmarksBar = Settings.showBookmarksBar
        syncSharedAddressField()
        refreshPaneHighlights()
    }

    // MARK: - Menu actions

    @objc func newTab(_ sender: Any?) { addTab() }
    @objc func closeCurrentTab(_ sender: Any?) { closeTab(at: selectedIndex) }
    @objc func closePane(_ sender: Any?) { focusedPane.map(close) }
    @objc func splitRight(_ sender: Any?) { split(.horizontal) }
    @objc func splitDown(_ sender: Any?) { split(.vertical) }
    @objc func focusPaneLeft(_ sender: Any?) { focusNeighbor(.left) }
    @objc func focusPaneRight(_ sender: Any?) { focusNeighbor(.right) }
    @objc func focusPaneUp(_ sender: Any?) { focusNeighbor(.up) }
    @objc func focusPaneDown(_ sender: Any?) { focusNeighbor(.down) }
    @objc func equalizePanes(_ sender: Any?) { selectedTab.map { equalize($0.container.child) } }
    @objc func openLocation(_ sender: Any?) { focusAddressField() }
    @objc func reloadPage(_ sender: Any?) { focusedPane?.webView.reload() }
    @objc func toggleWebInspector(_ sender: Any?) { focusedPane?.toggleWebInspector() }
    @objc func showLinkHints(_ sender: Any?) { focusedPane?.showLinkHints() }
    @objc func toggleSidebar(_ sender: Any?) { contentRoot.toggleSidebar() }

    @objc func toggleDownloads(_ sender: Any?) {
        if downloadsPopover.isShown {
            downloadsPopover.performClose(nil)
        } else {
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
    /// anchored to the right end of the pane's address bar (where a star would be).
    private func bookmark(_ url: URL, title: String, from pane: PaneView) {
        bookmarkEditor.close()  // applies its edits first, so the paths below are current
        let existing = Bookmarks.path(of: url)
        let path = existing ?? Bookmarks.add(Bookmark(title: title.isEmpty ? (url.host() ?? "") : title, kind: .link(url)))
        let field: NSView = Settings.addressBarMode == .shared ? contentRoot.header.addressField : pane.addressField
        let anchor = NSRect(x: max(0, field.bounds.maxX - 24), y: 0, width: 24, height: field.bounds.height)
        bookmarkEditor.show(path, added: existing == nil, relativeTo: anchor, of: field)
    }

    private func addBookmarkFolder() {
        bookmarkEditor.close()
        let path = Bookmarks.add(Bookmark(title: "New Folder", kind: .folder([])))
        let bar = contentRoot.bookmarksBar
        bar.bookmarks = Bookmarks.items
        bar.layoutSubtreeIfNeeded()
        let anchor = path.last.flatMap(bar.itemView(at:)) ?? bar
        bookmarkEditor.show(path, added: true, relativeTo: anchor.bounds, of: anchor)
    }

    var isBookmarkEditorShown: Bool { bookmarkEditor.isShown }
    /// For the self-test.
    var debugBookmarkEditor: BookmarkEditor { bookmarkEditor }

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
        if pane === focusedPane {
            updateTitle()
            syncSharedAddressField()
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
        if window?.isKeyWindow == true { showDownloads() }
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
    var debugTabCenters: [NSPoint] { contentRoot.tabStrip.debugTabCenters }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for tab in tabs {
            tab.panes.forEach { $0.teardown() }
        }
        tabs.removeAll()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let downloadsObserver { NotificationCenter.default.removeObserver(downloadsObserver) }
        if let bookmarksObserver { NotificationCenter.default.removeObserver(bookmarksObserver) }
        onClose?(self)
    }
}
