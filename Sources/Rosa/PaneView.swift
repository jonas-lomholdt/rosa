import AppKit
import WebKit

@MainActor
enum WebKitSupport {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = makeBaseConfiguration()
        configuration.webExtensionController = Extensions.shared.controller
        return configuration
    }

    /// Without extensions (they derive their own pages' configuration from it).
    static func makeBaseConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // One shared data store so cookies and logins are shared by all panes and tabs.
        configuration.websiteDataStore = .default()
        // Without a Safari-like suffix, some sites serve degraded pages to WKWebView.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        // Local Web Inspector (context menu / F12) needs WebKit's developer extras on, in addition
        // to `isInspectable`. Private preference key, set via KVC.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        return configuration
    }
}

@MainActor
protocol PaneViewDelegate: AnyObject {
    func paneDidBecomeFocused(_ pane: PaneView)
    func paneDidChangeState(_ pane: PaneView)
    /// ⌘-click: open without taking focus.
    func pane(_ pane: PaneView, openLinkInBackground request: URLRequest)
    func pane(_ pane: PaneView, createWebViewWith configuration: WKWebViewConfiguration) -> WKWebView?
    func pane(_ pane: PaneView, didStartDownload download: WKDownload)
    func paneRequestedHintsInAllPanes(_ pane: PaneView, background: Bool)
    func pane(_ pane: PaneView, typedHintKey key: String)
    func paneCancelledHints(_ pane: PaneView)
    /// Context menu → Add Page / Link to Bookmarks.
    func pane(_ pane: PaneView, bookmark url: URL, title: String)
}

/// WKWebView that reports when it gains keyboard focus, so the window can track the focused pane.
final class BrowserWebView: WKWebView {
    var onFocus: (() -> Void)?
    /// Called with downloads started from the context menu.
    var onDownload: ((WKDownload) -> Void)?
    /// Context menu → Add Page / Link to Bookmarks, with the URL and a suggested title.
    var onBookmark: ((URL, String) -> Void)?

    /// What was under the pointer at the last right-click (reported by the page script).
    struct ContextTarget {
        var image: URL?
        var link: URL?
        var linkTitle: String?
        var media: URL?
    }

    var contextTarget = ContextTarget()

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    // MARK: - Context menu downloads

    /// WebKit's own "Download Image / Linked File / Video" items only work with a private
    /// download delegate, so they're re-pointed to start a regular WKDownload.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            guard let url = downloadURL(for: item) else { continue }
            item.target = self
            item.action = #selector(downloadContextItem(_:))
            item.representedObject = url
        }
        addBookmarkItems(to: menu)
    }

    private func addBookmarkItems(to menu: NSMenu) {
        var items: [NSMenuItem] = []
        if let link = contextTarget.link, ["http", "https"].contains(link.scheme?.lowercased()) {
            let item = NSMenuItem(title: "Add Link to Bookmarks", action: #selector(bookmarkContextItem(_:)), keyEquivalent: "")
            item.representedObject = (link, contextTarget.linkTitle ?? "")
            items.append(item)
        } else if let page = url, !["about", "data"].contains(page.scheme?.lowercased()) {
            let item = NSMenuItem(title: "Add Page to Bookmarks", action: #selector(bookmarkContextItem(_:)), keyEquivalent: "")
            item.representedObject = (page, title ?? "")
            items.append(item)
        }
        guard !items.isEmpty else { return }
        // Above WebKit's trailing "Inspect Element" group when there is one.
        var index = menu.items.lastIndex { $0.isSeparatorItem } ?? menu.items.count
        if menu.items.isEmpty { index = 0 } else { menu.insertItem(.separator(), at: index); index += 1 }
        for item in items {
            item.target = self
            menu.insertItem(item, at: index)
            index += 1
        }
    }

    @objc func bookmarkContextItem(_ sender: NSMenuItem) {
        guard let (url, title) = sender.representedObject as? (URL, String) else { return }
        onBookmark?(url, title)
    }

    private func downloadURL(for item: NSMenuItem) -> URL? {
        let key = (item.identifier?.rawValue ?? "") + " " + item.title
        if key.contains("DownloadImage") || item.title == "Download Image" { return contextTarget.image }
        if key.contains("DownloadLinkedFile") || item.title == "Download Linked File" { return contextTarget.link }
        if key.contains("DownloadMedia") || ["Download Video", "Download Audio"].contains(item.title) { return contextTarget.media }
        return nil
    }

    @objc func downloadContextItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.onDownload?(download)
        }
    }
}

/// A leaf in the split tree: one web view plus its optional slim address bar.
final class PaneView: NSView, WKNavigationDelegate, WKUIDelegate {
    enum Highlight { case none, focused, unfocused }

    static let cornerRadius: CGFloat = 10
    static let barSpacing: CGFloat = 6

    weak var delegate: PaneViewDelegate?
    let webView: BrowserWebView
    var addressField: AddressField { addressBar.field }
    /// The address bar capsule (anchors the bookmark popover).
    var addressBarView: NSView { addressBar }
    var extensionToolbar: ExtensionToolbar { addressBar.extensionToolbar }
    /// Increases every time the pane is focused; used to pick the most recently used pane.
    var lastFocusSerial = 0

    var showsAddressBar = true {
        didSet { addressBar.isHidden = !showsAddressBar; needsLayout = true }
    }

    private(set) var favicon: NSImage? {
        didSet {
            guard favicon !== oldValue else { return }
            addressBar.icon = favicon
            delegate?.paneDidChangeState(self)
        }
    }
    /// Bumped on every navigation so a slow favicon fetch can't overwrite a newer page's icon.
    private var faviconGeneration = 0
    private var blockerObservers: [NSObjectProtocol] = []

    var shieldState: ShieldState { ContentBlocker.shared.shieldState(forHost: webView.url?.host()) }

    var highlight: Highlight = .none {
        didSet {
            overlay.highlight = highlight
            let alpha = highlight == .unfocused ? Settings.inactivePaneOpacity : 1
            guard alphaValue != alpha else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = alpha
            }
        }
    }

    private let addressBar = GlassAddressBar()
    /// Rounded card that clips the web view.
    private let card = CardView()
    private let progressLine = ProgressLineView()
    /// Commands and shortcuts; only the pane Rosa opens at launch has one (`showWelcome()`).
    private(set) var welcome: WelcomeView?
    /// Every other blank pane's background, with pinned bookmarks / recent sites (`Settings.showQuickLinks`).
    private(set) var quickLinks: QuickLinksView?
    private let overlay = FocusOverlayView()
    let findBar = FindBar()
    let zoomIndicator = ZoomIndicator()
    /// Bumped per search so a slow result can't overwrite a newer one.
    private var findGeneration = 0
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration) {
        webView = BrowserWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Enables Web Inspector ("Inspect Element" in the context menu, and Safari's Develop menu).
        webView.isInspectable = true
        webView.onFocus = { [weak self] in self.map { $0.delegate?.paneDidBecomeFocused($0) } }
        webView.onDownload = { [weak self] download in self.map { $0.delegate?.pane($0, didStartDownload: download) } }
        webView.onBookmark = { [weak self] url, title in self.map { $0.delegate?.pane($0, bookmark: url, title: title) } }

        addressField.onFocus = { [weak self] in self.map { $0.delegate?.paneDidBecomeFocused($0) } }
        addressField.onSubmit = { [weak self] text in
            self?.load(text)
            self?.focusWebView()
        }
        addressField.onCancel = { [weak self] in
            guard let self else { return }
            addressField.stringValue = displayURL
            focusWebView()
        }
        progressLine.isHidden = true

        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.addSubview(webView)
        card.addSubview(progressLine)

        findBar.isHidden = true
        findBar.onChange = { [weak self] text in self?.find(text, fresh: true) }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose = { [weak self] in self?.hideFindBar() }

        for view in [card, addressBar, findBar, zoomIndicator, overlay] {
            addSubview(view)
        }
        observeWebView()

        addressBar.onShieldClick = { [weak self] in self?.toggleContentBlockingForSite() }
        for name in [ContentBlocker.didChange, Settings.didChange] {
            blockerObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshContentBlocking()
                    self?.refreshLinkHints()
                    self?.updateQuickLinks()
                }
            })
        }
        refreshContentBlocking()
        LinkHints.install(on: webView.configuration.userContentController)
        LinkHintsRouter.shared.register(self)
        extensionToolbar.pane = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayURL: String {
        guard let url = webView.url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }

    var displayTitle: String {
        if let title = webView.title, !title.isEmpty { return title }
        if let host = webView.url?.host() { return host }
        return "New Tab"
    }

    override func layout() {
        super.layout()
        var top: CGFloat = 0
        if showsAddressBar {
            addressBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: GlassAddressBar.height)
            top = GlassAddressBar.height + Self.barSpacing
        }
        card.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        webView.frame = card.bounds
        welcome?.frame = card.bounds
        updateWelcome()
        updateQuickLinks()
        quickLinks?.frame = card.bounds
        progressLine.frame = NSRect(x: 0, y: 0, width: card.bounds.width * webView.estimatedProgress, height: 2)
        overlay.frame = card.frame
        findBar.frame = NSRect(
            x: card.frame.maxX - FindBar.size.width - 10, y: card.frame.minY + 10,
            width: min(FindBar.size.width, card.frame.width - 20), height: FindBar.size.height
        )
        zoomIndicator.frame = NSRect(
            x: (card.frame.midX - ZoomIndicator.size.width / 2).rounded(), y: card.frame.minY + 10,
            width: ZoomIndicator.size.width, height: ZoomIndicator.size.height
        )
    }

    /// Nothing loaded or loading yet.
    var isBlank: Bool {
        guard !webView.isLoading else { return false }
        return webView.url == nil || webView.url?.absoluteString == "about:blank"
    }

    /// Shows the welcome commands until this pane loads something (then they're removed for good).
    func showWelcome() {
        guard welcome == nil, isBlank else { return }
        let welcome = WelcomeView()
        welcome.onCommand = { [weak self] action in
            guard let self else { return }
            // Act on this pane even if another one had focus.
            delegate?.paneDidBecomeFocused(self)
            // Up this pane's own responder chain (reaches the window controller even when the
            // window isn't key), then the app's for app-level actions like Settings.
            if !tryToPerform(action, with: self) { NSApp.sendAction(action, to: nil, from: self) }
        }
        card.addSubview(welcome, positioned: .above, relativeTo: webView)
        self.welcome = welcome
        needsLayout = true
    }

    /// Hidden in panes too small to fit it.
    private func updateWelcome() {
        guard let welcome else { return }
        guard isBlank else {
            welcome.removeFromSuperview()
            self.welcome = nil
            return
        }
        welcome.isHidden = card.bounds.height < WelcomeView.contentHeight + 48 || card.bounds.width < 320
    }

    /// Added while the pane is blank (and has no welcome page), removed once it loads something.
    /// Also with quick links turned off: it draws the themed background a blank web view lacks.
    private func updateQuickLinks() {
        guard isBlank, welcome == nil else {
            quickLinks?.removeFromSuperview()
            quickLinks = nil
            return
        }
        guard quickLinks == nil else { return }
        let view = QuickLinksView(frame: card.bounds)
        view.onOpen = { [weak self] url, background in
            guard let self else { return }
            if background {
                delegate?.pane(self, openLinkInBackground: URLRequest(url: url))
            } else {
                webView.load(URLRequest(url: url))
                focusWebView()
            }
        }
        card.addSubview(view, positioned: .above, relativeTo: webView)
        quickLinks = view
    }

    // MARK: - Actions

    func load(_ input: String) {
        guard let url = Settings.url(fromUserInput: input) else { return }
        webView.load(URLRequest(url: url))
    }

    func focusWebView() {
        window?.makeFirstResponder(webView)
    }

    func focusAddressField() {
        window?.makeFirstResponder(addressField)
    }

    /// Stops the page and breaks references before the pane is discarded.
    func teardown(windowIsClosing: Bool = false) {
        Extensions.shared.controller.didCloseTab(self, windowIsClosing: windowIsClosing)
        blockerObservers.forEach(NotificationCenter.default.removeObserver)
        blockerObservers.removeAll()
        quickLinks?.removeFromSuperview()
        quickLinks = nil
        observations.removeAll()
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onFocus = nil
        addressField.onFocus = nil
        addressField.onSubmit = nil
        addressField.onCancel = nil
    }

    // MARK: - Web Inspector

    /// WebKit has no public API to open the inspector programmatically, so this uses the
    /// private `_inspector` object (fine outside the App Store). Fails silently if it changes.
    private var inspector: NSObject? {
        let selector = Selector(("_inspector"))
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    var isWebInspectorVisible: Bool {
        (inspector?.value(forKey: "visible") as? Bool) ?? false
    }

    func toggleWebInspector() {
        guard let inspector else { return }
        let selector = Selector((isWebInspectorVisible ? "close" : "show"))
        if inspector.responds(to: selector) { inspector.perform(selector) }
    }

    // MARK: - Zoom

    func zoomIn() { setZoom(PageZoom.next(after: webView.pageZoom)) }
    func zoomOut() { setZoom(PageZoom.previous(before: webView.pageZoom)) }

    /// Also undoes pinch magnification.
    func resetZoom() {
        webView.magnification = 1
        setZoom(1)
    }

    private func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = zoom
        zoomIndicator.show(zoom)
    }

    // MARK: - Find in page

    func showFindBar() {
        findBar.isHidden = false
        window?.makeFirstResponder(findBar.field)
        findBar.field.selectText(nil)
        if !findBar.field.stringValue.isEmpty { find(findBar.field.stringValue, fresh: true) }
    }

    func hideFindBar() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findGeneration += 1
        Task { await FindInPage.clear(in: webView) }
        focusWebView()
    }

    func findNext() {
        guard !findBar.isHidden else { return showFindBar() }
        find(findBar.field.stringValue, fresh: false)
    }

    func findPrevious() {
        guard !findBar.isHidden else { return showFindBar() }
        find(findBar.field.stringValue, fresh: false, backwards: true)
    }

    private func find(_ query: String, fresh: Bool, backwards: Bool = false) {
        findGeneration += 1
        let generation = findGeneration
        Task {
            let result = fresh
                ? await FindInPage.start(query, in: webView)
                : await FindInPage.step(backwards ? -1 : 1, in: webView)
            guard generation == findGeneration else { return }
            findBar.setStatus(index: result.index, count: result.count, query: query)
        }
    }

    // MARK: - Link hints

    private func refreshLinkHints() {
        LinkHints.install(on: webView.configuration.userContentController)
        LinkHints.configure(webView)
    }

    func showLinkHints(background: Bool = false) {
        focusWebView()
        LinkHints.start(in: webView, background: background)
    }

    // All-panes hint session (driven by BrowserWindowController).

    func collectHintTargets() async -> Int {
        await callHints("return window.__browserHints ? window.__browserHints.collect() : 0") as? Int ?? 0
    }

    func showHints(_ labels: [String], background: Bool) async {
        _ = await callHints("window.__browserHints && window.__browserHints.show(labels, background)",
                            ["labels": labels, "background": background])
    }

    func filterHints(_ typed: String) async -> (matches: Int, exact: Bool) {
        let result = await callHints("return window.__browserHints ? window.__browserHints.filter(typed) : null",
                                     ["typed": typed]) as? [String: Any]
        return (result?["matches"] as? Int ?? 0, result?["exact"] as? Bool ?? false)
    }

    func activateHint(_ label: String) async {
        _ = await callHints("window.__browserHints && window.__browserHints.activateLabel(label)", ["label": label])
    }

    func stopHints() async {
        _ = await callHints("window.__browserHints && window.__browserHints.stop()")
    }

    private func callHints(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
        try? await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: LinkHints.contentWorld)
    }

    func openLinkInBackground(_ url: URL) {
        delegate?.pane(self, openLinkInBackground: URLRequest(url: url))
    }

    // MARK: - Content blocking

    /// Re-attaches rule lists for the current site (used when settings or lists change).
    private func refreshContentBlocking() {
        ContentBlocker.shared.apply(to: webView.configuration.userContentController, host: webView.url?.host())
        updateShield()
    }

    private func updateShield() {
        let state = shieldState
        guard addressBar.shieldState != state else { return }
        addressBar.shieldState = state
        delegate?.paneDidChangeState(self)
    }

    /// Shield button: allow or block ads on the current site, then reload so it takes effect.
    func toggleContentBlockingForSite() {
        let host = webView.url?.host()
        ContentBlocker.shared.setAllowed(shieldState == .blocking, host: host)
        webView.reload()
    }

    // MARK: - Web view state

    private func observeWebView() {
        observations = [
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.pageStateChanged() } },
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.titleChanged() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressChanged() } },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.progressChanged()
                    self.map {
                        Extensions.shared.controller.didChangeTabProperties(.loading, for: $0)
                        $0.delegate?.paneDidChangeState($0)
                    }
                }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self.map { $0.delegate?.paneDidChangeState($0) } } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self.map { $0.delegate?.paneDidChangeState($0) } } },
        ]
    }

    private func pageStateChanged() {
        Extensions.shared.controller.didChangeTabProperties([.URL, .title], for: self)
        extensionToolbar.refresh()
        updateWelcome()
        updateQuickLinks()
        addressBar.shieldState = shieldState
        if addressField.currentEditor() == nil {
            addressField.stringValue = displayURL
        }
        delegate?.paneDidChangeState(self)
    }

    private func titleChanged() {
        if let url = webView.url, let title = webView.title {
            HistoryStore.shared.updateTitle(url: url, title: title)
        }
        pageStateChanged()
    }

    private func progressChanged() {
        progressLine.isHidden = !webView.isLoading
        updateWelcome()
        updateQuickLinks()
        needsLayout = true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url {
            HistoryStore.shared.recordVisit(url: url, title: webView.title ?? "")
        }
        faviconGeneration += 1
        favicon = FaviconStore.shared.cachedIcon(forHost: webView.url?.host())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // New page: refresh the match count if the find bar is open.
        if !findBar.isHidden { find(findBar.field.stringValue, fresh: true) }
        let generation = faviconGeneration
        Task {
            let icon = await FaviconStore.shared.icon(for: webView)
            guard generation == faviconGeneration, let icon else { return }
            favicon = icon
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "file", "javascript", "webkit-extension"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        if navigationAction.shouldPerformDownload {
            return .download
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            delegate?.pane(self, openLinkInBackground: navigationAction.request)
            return .cancel
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            // Rules must match the site we're going to before its subresources start loading.
            ContentBlocker.shared.apply(to: webView.configuration.userContentController, host: navigationAction.request.url?.host())
        }
        return .allow
    }

    /// Files WebKit can't display, or that the server marks as attachments, are downloaded.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        delegate?.pane(self, didStartDownload: download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        delegate?.pane(self, didStartDownload: download)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        delegate?.pane(self, createWebViewWith: configuration)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        return response == .OK ? panel.urls : nil
    }

    private func makeAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }
}

/// Draws the focus ring / dimming on top of a pane without intercepting clicks.
private final class FocusOverlayView: NSView {
    var highlight: PaneView.Highlight = .none { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        switch highlight {
        case .none:
            break
        case .focused:
            NSColor.controlAccentColor.setStroke()
            let radius = PaneView.cornerRadius - 1
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            path.lineWidth = 2
            path.stroke()
        case .unfocused:
            NSColor.black.withAlphaComponent(0.12).setFill()
            let radius = PaneView.cornerRadius
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }
}

private final class CardView: NSView {
    override var isFlipped: Bool { true }
}

private final class ProgressLineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        bounds.fill()
    }
}
