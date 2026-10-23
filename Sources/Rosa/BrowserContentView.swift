import AppKit

/// Header row: holds the shared address bar, or just the page title when address
/// bars live in the panes (vertical-tabs mode needs this row for the window drag area).
final class HeaderView: ChromeView {
    static let height: CGFloat = TabStripView.horizontalHeight

    private let addressBar = GlassAddressBar()
    private let titleLabel = NSTextField(labelWithString: "")

    var addressField: AddressField { addressBar.field }
    /// The address bar capsule (anchors the bookmark popover).
    var addressBarView: NSView { addressBar }
    var extensionToolbar: ExtensionToolbar { addressBar.extensionToolbar }

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
        didSet { updateVisibility() }
    }

    /// The page title when there's no address bar (the status bar layout shows it in the bar instead).
    var showsTitle = true {
        didSet { updateVisibility() }
    }

    private func updateVisibility() {
        addressBar.isHidden = !showsAddressField
        titleLabel.isHidden = showsAddressField || !showsTitle
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
    let navigationButtons = NavigationButtonsView()
    let bookmarksBar = BookmarksBarView()
    /// The status bar layout's tab bar.
    let statusBar = StatusBarView()
    /// Called when a sidebar resize finishes, with the new width.
    var onSidebarResized: ((CGFloat) -> Void)?

    private let background = NSVisualEffectView()
    private let sidebarGlass = NSGlassEffectView()
    private let resizeHandle = SidebarResizeHandle()
    private let edgeHotZone = HoverZoneView()
    private let sidebarHoverZone = HoverZoneView()
    private let dragOverlay = WindowDragOverlay()
    private var keyMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var showOverlayWorkItem: DispatchWorkItem?
    /// ⌃ went into a shortcut (a key, or another modifier, joined it); stays set until ⌃ is released.
    private var isControlChord = false
    /// ⌃ is held on its own, with no key pressed since it went down.
    private var isControlHeld = false {
        didSet { if isControlHeld != oldValue { controlHeldChanged() } }
    }
    /// ⌃ has been held long enough to show the hand: a quick ⌃Tab or ⌃A never flashes it.
    private var isControlSettled = false {
        didSet { if isControlSettled != oldValue { updateDragOverlay() } }
    }

    var tabLayout: TabLayout = .horizontal {
        didSet { tabStrip.tabLayout = tabLayout; needsLayout = true }
    }

    var statusBarPosition: StatusBarPosition = .bottom {
        didSet { needsLayout = true }
    }

    var showsSharedAddressBar = false {
        didSet { header.showsAddressField = showsSharedAddressBar; needsLayout = true }
    }

    var showsBookmarksBar = false {
        didSet { bookmarksBar.isHidden = !showsBookmarksBar; needsLayout = true }
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

    /// Zen (presenter) mode: no tabs, address bar, bookmarks bar or traffic lights; the panes take the whole window.
    var isZenMode = false {
        didSet {
            guard isZenMode != oldValue else { return }
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(kind)?.isHidden = isZenMode
            }
            if isZenMode { isSidebarRevealed = false }
            showsZenAddressBar = false
            needsLayout = true
        }
    }

    /// Holding ⌃ (alone) lets you drag the window from anywhere, the page included.
    var allowsControlDrag = true {
        didSet { updateDragOverlay() }
    }

    /// Zen mode only: the shared address bar across the top while an address is being typed.
    var showsZenAddressBar = false {
        didSet { if showsZenAddressBar != oldValue { needsLayout = true } }
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
        edgeHotZone.onEnter = { [weak self] in self?.setSidebarRevealed(true) }
        sidebarHoverZone.onExit = { [weak self] in self?.setSidebarRevealed(false) }

        // Back to front: page content, header, then the sidebar (it floats over both when auto-hiding).
        bookmarksBar.isHidden = true
        for view in [background, header, bookmarksBar, statusBar, sidebarGlass, tabStrip, navigationButtons, resizeHandle, edgeHotZone, sidebarHoverZone] {
            addSubview(view)
        }
        // Above everything, the page included, while it's shown.
        dragOverlay.isHidden = true
        dragOverlay.onClick = { [weak self] event in self?.passClickThrough(event) }
        addSubview(dragOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: - Sidebar

    func toggleSidebar() {
        guard isVerticalAutoHide, !isZenMode else { return }
        setSidebarRevealed(!isSidebarRevealed)
    }

    private func setSidebarRevealed(_ revealed: Bool) {
        guard isVerticalAutoHide, !isZenMode || !revealed, revealed != isSidebarRevealed else { return }
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

    private func resizeSidebar(toWindowX x: CGFloat) {
        let local = convert(NSPoint(x: x, y: 0), from: nil).x
        let range = Self.sidebarWidthRange
        sidebarWidth = min(max(local, range.lowerBound), min(range.upperBound, bounds.width / 2))
        layoutSubtreeIfNeeded()
    }

    // MARK: - ⌃-drag to move the window

    /// How long ⌃ must be held alone before the hand cursor shows.
    nonisolated static let controlSettleDelay: TimeInterval = 0.25

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        keyMonitor = nil
        resignKeyObserver = nil
        isControlChord = false
        isControlHeld = false
        guard let window else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.type {
            case .flagsChanged: controlFlagsChanged(event.modifierFlags)
            // ⌃ is part of a shortcut (⌃Tab, ⌃A in a field…): leave the mouse alone until it's released.
            case .keyDown: if isControlHeld { isControlChord = true; isControlHeld = false }
            // Clicked before the hand showed: show the overlay now so this mouse-down lands on it.
            default: if isControlHeld && !isControlSettled { isControlSettled = true }
            }
            return event
        }
        // ⌃ released in another app never reaches us.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isControlChord = false; self?.isControlHeld = false }
        }
    }

    func controlFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let modifiers = flags.intersection([.control, .command, .option, .shift])
        if !modifiers.contains(.control) { isControlChord = false } else if modifiers != .control { isControlChord = true }
        isControlHeld = modifiers == .control && !isControlChord
    }

    private func controlHeldChanged() {
        showOverlayWorkItem?.cancel()
        showOverlayWorkItem = nil
        guard isControlHeld else { isControlSettled = false; return }
        let item = DispatchWorkItem { [weak self] in self?.isControlSettled = true }
        showOverlayWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlSettleDelay, execute: item)
    }

    private func updateDragOverlay() {
        let show = allowsControlDrag && isControlHeld && isControlSettled
        guard show == dragOverlay.isHidden else { return }
        dragOverlay.isHidden = !show
        window?.invalidateCursorRects(for: dragOverlay)
        // Cursor rects only apply once the mouse moves; switch the cursor now.
        guard let window, window.isKeyWindow,
              bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        (show ? NSCursor.openHand : NSCursor.arrow).set()
    }

    /// A ⌃-click that didn't move the window goes to the page (a context menu, usually).
    private func passClickThrough(_ mouseDown: NSEvent) {
        guard let window else { return }
        dragOverlay.isHidden = true
        window.sendEvent(mouseDown)
        let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: mouseDown.locationInWindow, modifierFlags: mouseDown.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mouseDown.windowNumber, context: nil,
            eventNumber: mouseDown.eventNumber, clickCount: mouseDown.clickCount, pressure: 0
        )
        mouseUp.map(window.sendEvent)
        dragOverlay.isHidden = false
        updateDragOverlay()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        background.frame = bounds
        dragOverlay.frame = bounds
        let chrome: [NSView] = [tabStrip, header, bookmarksBar, statusBar, sidebarGlass, navigationButtons, resizeHandle, edgeHotZone, sidebarHoverZone]
        if isZenMode {
            // The panes keep their margin, so the page sits just inside the window's edge.
            chrome.forEach { $0.isHidden = true }
            var top: CGFloat = 0
            if showsZenAddressBar {
                // The shared bar, whatever the address bar setting, where it usually sits.
                header.isHidden = false
                header.showsAddressField = true
                header.leadingInset = 0
                header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: HeaderView.height)
                top = HeaderView.height - PaneContainerView.margin
            }
            placeTabContent(NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top)))
            return
        }
        header.showsAddressField = showsSharedAddressBar
        header.showsTitle = tabLayout != .statusBar
        tabStrip.isHidden = tabLayout == .statusBar
        statusBar.isHidden = tabLayout != .statusBar
        navigationButtons.isHidden = false
        bookmarksBar.isHidden = !showsBookmarksBar
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
            top = layoutBookmarksBar(x: 0, top: top)
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
            // Frames below come from these, not from the views: while the auto-hide sidebar
            // animates open, reading a view's frame back still gives the collapsed one.
            let paneTop = HeaderView.height
            let glassFrame = NSRect(x: sidebarX, y: paneTop, width: width - margin,
                                    height: max(0, bounds.height - paneTop - margin))
            let stripFrame = NSRect(x: sidebarX, y: 0, width: width - margin, height: bounds.height - margin)
            sidebarGlass.frame = glassFrame
            tabStrip.frame = stripFrame
            sidebarGlass.shadow = autoHide && !collapsed ? Self.floatingShadow : nil

            resizeHandle.isHidden = collapsed
            resizeHandle.frame = NSRect(x: glassFrame.maxX - 2, y: glassFrame.minY, width: 8, height: glassFrame.height)

            edgeHotZone.isHidden = !collapsed
            edgeHotZone.frame = NSRect(x: 0, y: HeaderView.height, width: railWidth,
                                       height: max(0, bounds.height - HeaderView.height))
            sidebarHoverZone.isHidden = !autoHide || !isSidebarRevealed
            sidebarHoverZone.frame = stripFrame.insetBy(dx: -margin, dy: -margin)

            header.isHidden = false
            header.leadingInset = autoHide ? max(0, Self.trafficLightInset - contentX) : 0
            header.frame = NSRect(x: contentX, y: 0, width: bounds.width - contentX, height: HeaderView.height)
            let top = layoutBookmarksBar(x: contentX, top: HeaderView.height - margin)
            contentRect = NSRect(x: contentX, y: top, width: bounds.width - contentX, height: max(0, bounds.height - top))

        case .statusBar:
            // The header row stays for the traffic lights and navigation buttons (and the shared address bar).
            for view in [sidebarGlass, resizeHandle, edgeHotZone, sidebarHoverZone] { view.isHidden = true }
            tabStrip.isCollapsed = false
            header.isHidden = false
            header.leadingInset = 0
            header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: HeaderView.height)
            let barHeight = statusBar.size.height
            var top = HeaderView.height - margin
            var bottom = bounds.height
            switch statusBarPosition {
            case .top:
                statusBar.frame = NSRect(x: 0, y: top + margin / 2, width: bounds.width, height: barHeight)
                top = statusBar.frame.maxY - margin / 2
            case .bottom:
                // Its own margin below, so it doesn't sit in the window's rounded corners' curve.
                statusBar.frame = NSRect(x: 0, y: bounds.height - barHeight - margin / 2, width: bounds.width, height: barHeight)
                bottom = statusBar.frame.minY + margin / 2
            }
            top = layoutBookmarksBar(x: 0, top: top)
            contentRect = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bottom - top))
        }

        placeTabContent(contentRect)
        layoutNavigationButtons()
    }

    /// The tab overview borrows the selected tab's container for its live card; it keeps its size there.
    private func placeTabContent(_ frame: NSRect) {
        guard let tabContent, tabContent.superview === self else { return }
        tabContent.frame = frame
    }

    /// Puts the selected tab's container back after the tab overview borrowed it.
    func reattachTabContent() {
        guard let tabContent, tabContent.superview !== self else { return }
        tabContent.removeFromSuperview()
        addSubview(tabContent, positioned: .above, relativeTo: background)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Back / forward / reload right after the traffic lights, in the top row of every layout:
    /// the tabs (horizontal), the sidebar's top row, or the header beside the collapsed rail make room.
    private func layoutNavigationButtons() {
        let size = navigationButtons.fittingSize
        var centerY = TabStripView.horizontalHeight / 2
        var minX = Self.trafficLightInset - 4
        if let zoom = window?.standardWindowButton(.zoomButton), let superview = zoom.superview {
            let frame = convert(superview.convert(zoom.frame, to: nil), from: nil)
            centerY = frame.midY
            minX = frame.maxX + 12
        }
        let y = (centerY - size.height / 2).rounded()
        switch tabLayout {
        case .horizontal:
            navigationButtons.frame = NSRect(x: minX, y: y, width: size.width, height: size.height)
            tabStrip.trafficLightInset = navigationButtons.frame.maxX + 4
        case .statusBar:
            navigationButtons.frame = NSRect(x: minX, y: y, width: size.width, height: size.height)
            header.leadingInset = navigationButtons.frame.maxX + 4 - header.frame.minX
        case .vertical:
            let sidebarButtons = tabStrip.frame.minX + tabStrip.topRowButtonsMinX
            // Auto-hide keeps them in the header either way, so revealing the sidebar doesn't move the address bar.
            let fitsInSidebar = !isVerticalAutoHide && minX + size.width + 4 <= sidebarButtons
            if fitsInSidebar {
                navigationButtons.frame = NSRect(x: minX, y: y, width: size.width, height: size.height)
            } else {
                // Auto-hide or narrow sidebar: at the start of the header, past the traffic lights.
                let x = max(minX, header.frame.minX + 8)
                navigationButtons.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
                header.leadingInset = max(header.leadingInset, navigationButtons.frame.maxX + 4 - header.frame.minX)
            }
        }
    }

    /// Places the bookmarks bar (if shown) where the panes would start; returns the panes' new top.
    private func layoutBookmarksBar(x: CGFloat, top: CGFloat) -> CGFloat {
        guard showsBookmarksBar else { return top }
        let margin = PaneContainerView.margin
        // `top` includes the panes' margin; the bar's items line up with the panes' edges.
        bookmarksBar.leadingInset = margin
        bookmarksBar.frame = NSRect(x: x, y: top + margin / 2, width: bounds.width - x, height: BookmarksBarView.height)
        return bookmarksBar.frame.maxY - margin
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
    var debugDragOverlayShown: Bool { !dragOverlay.isHidden }
}

/// Covers the window while ⌃ is held: drag anywhere to move the window.
private final class WindowDragOverlay: NSView {
    /// A click that didn't drag, with its mouse-down event.
    var onClick: ((NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // Screen coordinates: the events' window coordinates shift as the window moves under them.
        let start = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false
        NSCursor.closedHand.set()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let point = NSEvent.mouseLocation
            let dx = point.x - start.x, dy = point.y - start.y
            if !moved, hypot(dx, dy) < 3 { continue }
            moved = true
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
        if moved { NSCursor.openHand.set() } else { onClick?(event) }
    }
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

/// Borderless toolbar button with feedback: the icon brightens and a rounded background appears on
/// hover, darker while pressed. (`showsBorderOnlyWhileMouseInside` does nothing without a border.)
final class NavigationButton: NSButton {
    private var isHovered = false { didSet { if isHovered != oldValue { updateAppearance() } } }

    var debugHovered: Bool {
        get { isHovered }
        set { isHovered = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isEnabled: Bool { didSet { updateAppearance() } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    private func updateAppearance() {
        contentTintColor = !isEnabled ? .tertiaryLabelColor : (isHovered ? .labelColor : .secondaryLabelColor)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, isHovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        // Buttons shift when forward appears or hides, so entered/exited can be missed.
        if let window {
            isHovered = !isHidden && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }
}

/// Back, forward (only when there's somewhere to go) and reload/stop, beside the traffic lights.
final class NavigationButtonsView: NSView {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onStop: (() -> Void)?

    private let back = NavigationButtonsView.button("arrow.left", "Back (⌘[)")
    private let forward = NavigationButtonsView.button("arrow.right", "Forward (⌘])")
    private let reload = NavigationButtonsView.button("arrow.clockwise", "Reload (⌘R)")
    private var isLoading = false
    private static let buttonSize: CGFloat = 26

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [back, forward, reload] {
            button.target = self
            addSubview(button)
        }
        back.action = #selector(backClicked)
        forward.action = #selector(forwardClicked)
        reload.action = #selector(reloadClicked)
        update(canGoBack: false, canGoForward: false, isLoading: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        back.isEnabled = canGoBack
        forward.isHidden = !canGoForward
        self.isLoading = isLoading
        reload.image = Self.symbol(isLoading ? "xmark" : "arrow.clockwise")
        reload.toolTip = isLoading ? "Stop" : "Reload (⌘R)"
        if frame.width != fittingSize.width { superview?.needsLayout = true }
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let count = CGFloat(forward.isHidden ? 2 : 3)
        return NSSize(width: count * Self.buttonSize + (count - 1) * 2, height: Self.buttonSize)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for button in [back, forward, reload] where !button.isHidden {
            button.frame = NSRect(x: x, y: 0, width: Self.buttonSize, height: Self.buttonSize)
            x += Self.buttonSize + 2
        }
    }

    @objc private func backClicked() { onBack?() }
    @objc private func forwardClicked() { onForward?() }
    @objc private func reloadClicked() { isLoading ? onStop?() : onReload?() }

    private static func button(_ symbol: String, _ tip: String) -> NavigationButton {
        let button = NavigationButton(image: Self.symbol(symbol), target: nil, action: nil)
        button.toolTip = tip
        return button
    }

    /// Self-test: hover / press states for a snapshot.
    func debugSetStates(hoverBack: Bool, pressReload: Bool) {
        back.debugHovered = hoverBack
        reload.isHighlighted = pressReload
    }

    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? image
    }
}
