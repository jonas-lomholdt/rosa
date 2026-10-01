import AppKit
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
        window.title = "New Tab"
        super.init(window: window)

        window.delegate = self
        window.contentView = contentRoot
        contentRoot.tabStrip.delegate = self

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
        guard let pane = focusedPane, let parent = pane.superview as? PaneParent else { return }
        let newPane = makePane()
        let frame = pane.frame
        // Creating the split reparents `pane`; the parent then takes the split in its place.
        let split = SplitView(axis: axis, first: pane, second: newPane)
        split.frame = frame
        parent.replaceChild(pane, with: split)
        split.layoutSubtreeIfNeeded()
        focus(newPane, editAddress: true)
        reloadTabStrip()
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
        contentRoot.showsSharedAddressBar = !perPane
        syncSharedAddressField()
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

    func pane(_ pane: PaneView, openInNewTab request: URLRequest) {
        addTab(request: request, nextToCurrent: true, select: false)
    }

    func pane(_ pane: PaneView, createWebViewWith configuration: WKWebViewConfiguration) -> WKWebView? {
        addTab(configuration: configuration, nextToCurrent: true).webView
    }

    // MARK: - TabStripDelegate

    func tabStrip(_ strip: TabStripView, didSelectTabAt index: Int) { selectTab(at: index) }
    func tabStrip(_ strip: TabStripView, didCloseTabAt index: Int) { closeTab(at: index) }
    func tabStripDidRequestNewTab(_ strip: TabStripView) { addTab() }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for tab in tabs {
            tab.panes.forEach { $0.teardown() }
        }
        tabs.removeAll()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        onClose?(self)
    }
}
