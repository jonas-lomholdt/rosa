import AppKit

/// Transparent container for browser chrome (tab strip, header). Optionally acts as a
/// window drag handle, since the window uses a transparent, full-size title bar.
class ChromeView: NSView {
    var dragsWindow = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { dragsWindow }

    override func mouseDown(with event: NSEvent) {
        guard dragsWindow, let window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            // Honour System Settings → Desktop & Dock → "Double-click a window's title bar to".
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

/// A Liquid Glass capsule holding an address field.
final class GlassAddressBar: NSView {
    static let height: CGFloat = 28

    let field = AddressField()
    /// Extension buttons, before the shield.
    let extensionToolbar = ExtensionToolbar()
    var onShieldClick: (() -> Void)?
    private let iconView = FaviconView()
    private let shieldButton = NSButton()
    private let glass = NSGlassEffectView()
    private let content = NSView()

    var shieldState: ShieldState = .hidden {
        didSet { updateShield() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = Self.height / 2
        glass.contentView = content
        shieldButton.isBordered = false
        shieldButton.target = self
        shieldButton.action = #selector(shieldClicked(_:))
        content.addSubview(iconView)
        content.addSubview(field)
        content.addSubview(shieldButton)
        content.addSubview(extensionToolbar)
        extensionToolbar.onWidthChange = { [weak self] in self?.needsLayout = true }
        addSubview(glass)
        updateShield()
    }

    private func updateShield() {
        shieldButton.isHidden = shieldState == .hidden
        let blocking = shieldState == .blocking
        let symbol = blocking ? "shield.lefthalf.filled" : "shield.slash"
        shieldButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Content blocking")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        shieldButton.contentTintColor = blocking ? .controlAccentColor : .secondaryLabelColor
        shieldButton.toolTip = blocking
            ? "Ads and trackers are blocked on this site. Click to allow them."
            : "Blocking is off for this site. Click to turn it back on."
        needsLayout = true
    }

    @objc private func shieldClicked(_ sender: Any?) {
        onShieldClick?()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var icon: NSImage? {
        get { iconView.favicon }
        set { iconView.favicon = newValue }
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let fieldHeight = field.intrinsicContentSize.height
        iconView.frame = NSRect(x: 10, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16)
        let shieldWidth: CGFloat = shieldButton.isHidden ? 0 : 24
        shieldButton.frame = NSRect(x: bounds.width - 8 - 20, y: ((bounds.height - 20) / 2).rounded(), width: 20, height: 20)
        let toolbarWidth = extensionToolbar.width
        extensionToolbar.frame = NSRect(x: bounds.width - 8 - shieldWidth - toolbarWidth, y: 0, width: toolbarWidth, height: bounds.height)
        field.frame = NSRect(
            x: 32, y: ((bounds.height - fieldHeight) / 2).rounded(),
            width: max(0, bounds.width - 44 - shieldWidth - toolbarWidth), height: fieldHeight
        )
    }
}

/// 16pt image view showing a favicon, or a tinted globe placeholder.
final class FaviconView: NSImageView {
    var favicon: NSImage? {
        didSet { showFavicon() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        showFavicon()
    }

    private func showFavicon() {
        image = favicon ?? FaviconStore.placeholder
        contentTintColor = favicon == nil ? .secondaryLabelColor : nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}
