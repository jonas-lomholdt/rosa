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

    /// Extra space on the left (traffic lights when the sidebar is hidden).
    var leadingInset: CGFloat = 0 { didSet { needsLayout = true } }

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
            x: leadingInset + inset, y: ((bounds.height - GlassAddressBar.height) / 2).rounded(),
            width: max(0, bounds.width - leadingInset - inset * 2), height: GlassAddressBar.height
        )
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: leadingInset + 16, y: ((bounds.height - titleHeight) / 2).rounded(),
            width: max(0, bounds.width - leadingInset - 32), height: titleHeight
        )
    }
}

/// Window content: translucent background, tab strip (top row or floating glass sidebar),
/// optional header, and the selected tab's split tree. The vertical sidebar can be resized
/// by dragging its edge, and can auto-hide to a rail of favicons (hover it to expand over the page).
final class BrowserContentView: NSView {
    static let defaultSidebarWidth: CGFloat = 220
    static let sidebarWidthRange: ClosedRange<CGFloat> = 160...420
    /// Room for the traffic-light buttons when the sidebar is hidden.
    static let trafficLightInset: CGFloat = 78
    /// Width of the auto-hiding sidebar's collapsed glass rail.
    static let railWidth: CGFloat = 44

    let tabStrip = TabStripView()
    let header = HeaderView()
    /// Called when a sidebar resize finishes, with the new width.
    var onSidebarResized: ((CGFloat) -> Void)?

    private let background = NSVisualEffectView()
    private let sidebarGlass = NSGlassEffectView()
    private let resizeHandle = SidebarResizeHandle()
    private let edgeHotZone = HoverZoneView()
    private let sidebarHoverZone = HoverZoneView()
    private var hideWorkItem: DispatchWorkItem?
    private var revealWorkItem: DispatchWorkItem?

    var tabLayout: TabLayout = .horizontal {
        didSet { tabStrip.tabLayout = tabLayout; needsLayout = true }
    }

    var showsSharedAddressBar = false {
        didSet { header.showsAddressField = showsSharedAddressBar; needsLayout = true }
    }

    var sidebarWidth: CGFloat = BrowserContentView.defaultSidebarWidth {
        didSet { needsLayout = true }
    }

    var sidebarAutoHide = false {
        didSet {
            guard sidebarAutoHide != oldValue else { return }
            isSidebarRevealed = false
            needsLayout = true
        }
    }

    /// Auto-hide mode only: whether the sidebar is expanded over the page (otherwise it's a favicon rail).
    private(set) var isSidebarRevealed = false

    private var isVerticalAutoHide: Bool { tabLayout == .vertical && sidebarAutoHide }

    /// The selected tab's pane container.
    var tabContent: NSView? {
        didSet {
            guard oldValue !== tabContent else { return }
            oldValue?.removeFromSuperview()
            if let tabContent { addSubview(tabContent, positioned: .above, relativeTo: background) }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        sidebarGlass.cornerRadius = 16

        resizeHandle.onDrag = { [weak self] x in self?.resizeSidebar(toWindowX: x) }
        resizeHandle.onDragEnded = { [weak self] in
            guard let self else { return }
            onSidebarResized?(sidebarWidth)
        }
        resizeHandle.onDoubleClick = { [weak self] in
            self?.onSidebarResized?(BrowserContentView.defaultSidebarWidth)
        }
        edgeHotZone.onEnter = { [weak self] in self?.scheduleReveal() }
        edgeHotZone.onExit = { [weak self] in self?.revealWorkItem?.cancel() }
        sidebarHoverZone.onEnter = { [weak self] in self?.hideWorkItem?.cancel() }
        sidebarHoverZone.onExit = { [weak self] in self?.scheduleHide() }

        // Back to front: page content, header, then the sidebar (it floats over both when auto-hiding).
        for view in [background, header, sidebarGlass, tabStrip, resizeHandle, edgeHotZone, sidebarHoverZone] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: - Sidebar

    func toggleSidebar() {
        guard isVerticalAutoHide else { return }
        setSidebarRevealed(!isSidebarRevealed)
    }

    private func setSidebarRevealed(_ revealed: Bool) {
        hideWorkItem?.cancel()
        revealWorkItem?.cancel()
        guard isVerticalAutoHide, revealed != isSidebarRevealed else { return }
        isSidebarRevealed = revealed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    /// A short delay so the mouse passing over the rail (or clicking a favicon) doesn't pop the sidebar open.
    private func scheduleReveal() {
        revealWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.setSidebarRevealed(true) }
        revealWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.setSidebarRevealed(false) }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func resizeSidebar(toWindowX x: CGFloat) {
        let local = convert(NSPoint(x: x, y: 0), from: nil).x
        let range = Self.sidebarWidthRange
        sidebarWidth = min(max(local, range.lowerBound), min(range.upperBound, bounds.width / 2))
        layoutSubtreeIfNeeded()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        background.frame = bounds
        let margin = PaneContainerView.margin
        let contentRect: NSRect

        switch tabLayout {
        case .horizontal:
            sidebarGlass.isHidden = true
            resizeHandle.isHidden = true
            edgeHotZone.isHidden = true
            sidebarHoverZone.isHidden = true
            header.leadingInset = 0
            tabStrip.isCollapsed = false
            let stripHeight = TabStripView.horizontalHeight
            tabStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
            var top = stripHeight
            header.isHidden = !showsSharedAddressBar
            if showsSharedAddressBar {
                header.frame = NSRect(x: 0, y: top, width: bounds.width, height: HeaderView.height)
                top += HeaderView.height - margin
            }
            contentRect = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))

        case .vertical:
            let fullWidth = min(sidebarWidth, bounds.width / 2)
            let autoHide = sidebarAutoHide
            let collapsed = autoHide && !isSidebarRevealed
            // When auto-hiding, the page sits beside the favicon rail and the expanded sidebar floats over it.
            let railWidth = margin + Self.railWidth
            let contentX = autoHide ? railWidth : fullWidth
            let width = collapsed ? railWidth : fullWidth
            let sidebarX = margin
            tabStrip.isCollapsed = collapsed

            sidebarGlass.isHidden = false
            // The glass panel lines up with the panes (top of their address bars to their bottom);
            // the strip's top row (+ and downloads) sits above it, beside the traffic lights.
            let paneTop = HeaderView.height
            sidebarGlass.frame = NSRect(x: sidebarX, y: paneTop, width: width - margin,
                                        height: max(0, bounds.height - paneTop - margin))
            tabStrip.frame = NSRect(x: sidebarX, y: 0, width: width - margin, height: bounds.height - margin)
            sidebarGlass.shadow = autoHide && !collapsed ? Self.floatingShadow : nil

            resizeHandle.isHidden = collapsed
            resizeHandle.frame = NSRect(x: sidebarGlass.frame.maxX - 2, y: sidebarGlass.frame.minY, width: 8, height: sidebarGlass.frame.height)

            edgeHotZone.isHidden = !collapsed
            edgeHotZone.frame = NSRect(x: 0, y: HeaderView.height, width: railWidth,
                                       height: max(0, bounds.height - HeaderView.height))
            sidebarHoverZone.isHidden = !autoHide || !isSidebarRevealed
            sidebarHoverZone.frame = tabStrip.frame.insetBy(dx: -margin, dy: -margin)

            header.isHidden = false
            header.leadingInset = autoHide ? max(0, Self.trafficLightInset - contentX) : 0
            header.frame = NSRect(x: contentX, y: 0, width: bounds.width - contentX, height: HeaderView.height)
            let top = HeaderView.height - margin
            contentRect = NSRect(x: contentX, y: top, width: bounds.width - contentX, height: max(0, bounds.height - top))
        }

        tabContent?.frame = contentRect
    }

    private static let floatingShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        return shadow
    }()

    // MARK: - Testing

    var debugSidebarFrame: NSRect { sidebarGlass.frame }
}

/// Invisible strip on the sidebar's right edge: drag to resize, double-click to reset.
private final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount < 2 { onDragEnded?() }
    }
}

/// Transparent region that reports the mouse entering/leaving, without taking clicks.
private final class HoverZoneView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
