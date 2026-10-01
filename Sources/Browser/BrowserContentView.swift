import AppKit

/// Header row: holds the shared address bar, or just the page title when address
/// bars live in the panes (vertical-tabs mode needs this row for the window drag area).
final class HeaderView: ChromeView {
    static let height: CGFloat = TabStripView.horizontalHeight

    private let addressBar = GlassAddressBar()
    private let titleLabel = NSTextField(labelWithString: "")

    var addressField: AddressField { addressBar.field }

    var icon: NSImage? {
        get { addressBar.icon }
        set { addressBar.icon = newValue }
    }

    var shieldState: ShieldState {
        get { addressBar.shieldState }
        set { addressBar.shieldState = newValue }
    }

    var onShieldClick: (() -> Void)? {
        get { addressBar.onShieldClick }
        set { addressBar.onShieldClick = newValue }
    }

    var showsAddressField = false {
        didSet {
            addressBar.isHidden = !showsAddressField
            titleLabel.isHidden = showsAddressField
        }
    }

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dragsWindow = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(addressBar)
        addSubview(titleLabel)
        showsAddressField = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let inset = PaneContainerView.margin
        addressBar.frame = NSRect(
            x: inset, y: ((bounds.height - GlassAddressBar.height) / 2).rounded(),
            width: max(0, bounds.width - inset * 2), height: GlassAddressBar.height
        )
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: 16, y: ((bounds.height - titleHeight) / 2).rounded(),
            width: max(0, bounds.width - 32), height: titleHeight
        )
    }
}

/// Window content: translucent background, tab strip (top row or floating glass sidebar),
/// optional header, and the selected tab's split tree.
final class BrowserContentView: NSView {
    static let sidebarWidth: CGFloat = 220

    let tabStrip = TabStripView()
    let header = HeaderView()
    private let background = NSVisualEffectView()
    private let sidebarGlass = NSGlassEffectView()

    var tabLayout: TabLayout = .horizontal {
        didSet { tabStrip.tabLayout = tabLayout; needsLayout = true }
    }

    var showsSharedAddressBar = false {
        didSet { header.showsAddressField = showsSharedAddressBar; needsLayout = true }
    }

    /// The selected tab's pane container.
    var tabContent: NSView? {
        didSet {
            guard oldValue !== tabContent else { return }
            oldValue?.removeFromSuperview()
            if let tabContent { addSubview(tabContent, positioned: .below, relativeTo: sidebarGlass) }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        sidebarGlass.cornerRadius = 16

        addSubview(background)
        addSubview(sidebarGlass)
        addSubview(tabStrip)
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        background.frame = bounds
        let contentRect: NSRect

        switch tabLayout {
        case .horizontal:
            sidebarGlass.isHidden = true
            let stripHeight = TabStripView.horizontalHeight
            tabStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
            var top = stripHeight
            header.isHidden = !showsSharedAddressBar
            if showsSharedAddressBar {
                header.frame = NSRect(x: 0, y: top, width: bounds.width, height: HeaderView.height)
                top += HeaderView.height - PaneContainerView.margin
            }
            contentRect = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))

        case .vertical:
            let margin = PaneContainerView.margin
            let sidebarWidth = min(Self.sidebarWidth, bounds.width / 2)
            sidebarGlass.isHidden = false
            sidebarGlass.frame = NSRect(x: margin, y: margin, width: sidebarWidth - margin, height: bounds.height - margin * 2)
            tabStrip.frame = sidebarGlass.frame
            header.isHidden = false
            header.frame = NSRect(x: sidebarWidth, y: 0, width: bounds.width - sidebarWidth, height: HeaderView.height)
            let top = HeaderView.height - margin
            contentRect = NSRect(
                x: sidebarWidth, y: top,
                width: bounds.width - sidebarWidth, height: max(0, bounds.height - top)
            )
        }

        tabContent?.frame = contentRect
    }
}
