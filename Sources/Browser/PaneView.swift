import AppKit
import WebKit

@MainActor
enum WebKitSupport {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // One shared data store so cookies and logins are shared by all panes and tabs.
        configuration.websiteDataStore = .default()
        // Without a Safari-like suffix, some sites serve degraded pages to WKWebView.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }
}

@MainActor
protocol PaneViewDelegate: AnyObject {
    func paneDidBecomeFocused(_ pane: PaneView)
    func paneDidChangeState(_ pane: PaneView)
    func pane(_ pane: PaneView, openInNewTab request: URLRequest)
    func pane(_ pane: PaneView, createWebViewWith configuration: WKWebViewConfiguration) -> WKWebView?
}

/// WKWebView that reports when it gains keyboard focus, so the window can track the focused pane.
final class BrowserWebView: WKWebView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// A leaf in the split tree: one web view plus its optional slim address bar.
final class PaneView: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    enum Highlight { case none, focused, unfocused }

    static let cornerRadius: CGFloat = 10
    static let barSpacing: CGFloat = 6

    weak var delegate: PaneViewDelegate?
    let webView: BrowserWebView
    var addressField: AddressField { addressBar.field }
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

    var highlight: Highlight = .none {
        didSet { overlay.highlight = highlight }
    }

    private let addressBar = GlassAddressBar()
    /// Rounded card that clips the web view.
    private let card = CardView()
    private let progressLine = ProgressLineView()
    private let overlay = FocusOverlayView()
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration) {
        webView = BrowserWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.onFocus = { [weak self] in self.map { $0.delegate?.paneDidBecomeFocused($0) } }

        addressField.onFocus = { [weak self] in self.map { $0.delegate?.paneDidBecomeFocused($0) } }
        addressField.target = self
        addressField.action = #selector(addressSubmitted(_:))
        addressField.delegate = self
        progressLine.isHidden = true

        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.addSubview(webView)
        card.addSubview(progressLine)

        for view in [card, addressBar, overlay] {
            addSubview(view)
        }
        observeWebView()
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
        progressLine.frame = NSRect(x: 0, y: 0, width: card.bounds.width * webView.estimatedProgress, height: 2)
        overlay.frame = card.frame
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
    func teardown() {
        observations.removeAll()
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onFocus = nil
        addressField.onFocus = nil
    }

    @objc private func addressSubmitted(_ sender: Any?) {
        load(addressField.stringValue)
        focusWebView()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        addressField.stringValue = displayURL
        focusWebView()
        return true
    }

    // MARK: - Web view state

    private func observeWebView() {
        observations = [
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.pageStateChanged() } },
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.pageStateChanged() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressChanged() } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressChanged() } },
        ]
    }

    private func pageStateChanged() {
        if addressField.currentEditor() == nil {
            addressField.stringValue = displayURL
        }
        delegate?.paneDidChangeState(self)
    }

    private func progressChanged() {
        progressLine.isHidden = !webView.isLoading
        needsLayout = true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        faviconGeneration += 1
        favicon = FaviconStore.shared.cachedIcon(forHost: webView.url?.host())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
           !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            delegate?.pane(self, openInNewTab: navigationAction.request)
            return .cancel
        }
        return .allow
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
