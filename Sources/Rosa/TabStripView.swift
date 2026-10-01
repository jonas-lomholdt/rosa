import AppKit

@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, didSelectTabAt index: Int)
    func tabStrip(_ strip: TabStripView, didCloseTabAt index: Int)
    func tabStripDidRequestNewTab(_ strip: TabStripView)
    func tabStrip(_ strip: TabStripView, didMoveTabFrom source: Int, to destination: Int)
}

struct TabItem {
    var title: String
    var paneCount: Int
    var favicon: NSImage?
}

/// The tab list. Lays out as a row in the title bar (horizontal) or as a sidebar (vertical).
final class TabStripView: ChromeView {
    static let horizontalHeight: CGFloat = 38
    static let verticalWidth: CGFloat = 220
    /// Empty space always kept before the + button so the window can be dragged with many tabs open.
    static let reservedDragSpace: CGFloat = 50

    weak var delegate: TabStripDelegate?

    var tabLayout: TabLayout = .horizontal {
        didSet {
            scrollView.hasVerticalScroller = tabLayout == .vertical
            needsLayout = true
        }
    }

    /// Space kept free for the window's traffic-light buttons.
    var trafficLightInset: CGFloat = 78 { didSet { needsLayout = true } }

    private let scrollView = NSScrollView()
    private let documentView = TabListDocumentView()
    private let newTabButton: NSButton
    /// Shown once there are downloads; opens the downloads popover.
    let downloadsButton = NSButton()
    var onDownloadsClick: (() -> Void)?

    var showsDownloadsButton = false {
        didSet { downloadsButton.isHidden = !showsDownloadsButton; needsLayout = true }
    }

    /// Accent tint while downloads are in progress.
    var downloadsActive = false {
        didSet {
            downloadsButton.contentTintColor = downloadsActive ? .controlAccentColor : .secondaryLabelColor
            let symbol = downloadsActive ? "arrow.down.circle.fill" : "arrow.down.circle"
            downloadsButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Downloads")
        }
    }
    private var itemViews: [TabItemView] = []
    private var selectedIndex = 0
    /// Where each tab sits, in document-view coordinates, in display order.
    private var slots: [NSRect] = []
    /// Visual order while a tab is being dragged (nil otherwise).
    private var dragOrder: [TabItemView]?
    private weak var draggedView: TabItemView?

    override init(frame frameRect: NSRect) {
        let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab") ?? NSImage()
        newTabButton = NSButton(image: plus, target: nil, action: nil)
        super.init(frame: frameRect)
        dragsWindow = true

        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked(_:))
        newTabButton.isBordered = false
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.toolTip = "New Tab (⌘T)"

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = documentView

        addSubview(scrollView)
        addSubview(newTabButton)

        downloadsButton.isBordered = false
        downloadsButton.target = self
        downloadsButton.action = #selector(downloadsClicked(_:))
        downloadsButton.toolTip = "Downloads (⌥⌘L)"
        downloadsButton.isHidden = true
        downloadsActive = false
        addSubview(downloadsButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(items: [TabItem], selectedIndex: Int) {
        while itemViews.count < items.count {
            let view = TabItemView()
            view.onPress = { [weak self, weak view] event in
                guard let self, let view else { return }
                self.trackDrag(of: view, from: event)
            }
            view.onClose = { [weak self, weak view] in
                guard let self, let view, let index = self.itemViews.firstIndex(where: { $0 === view }) else { return }
                self.delegate?.tabStrip(self, didCloseTabAt: index)
            }
            documentView.addSubview(view)
            itemViews.append(view)
        }
        while itemViews.count > items.count {
            itemViews.removeLast().removeFromSuperview()
        }
        for (index, (view, item)) in zip(itemViews, items).enumerated() {
            view.configure(item, selected: index == selectedIndex)
        }
        self.selectedIndex = selectedIndex
        needsLayout = true
        layoutSubtreeIfNeeded()
        if itemViews.indices.contains(selectedIndex) {
            let selected = itemViews[selectedIndex]
            selected.scrollToVisible(selected.bounds)
        }
    }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 28
        let spacing: CGFloat = 4

        switch tabLayout {
        case .horizontal:
            newTabButton.frame = NSRect(
                x: bounds.width - buttonSize - 8, y: (bounds.height - buttonSize) / 2,
                width: buttonSize, height: buttonSize
            )
            downloadsButton.frame = newTabButton.frame.offsetBy(dx: -(buttonSize + 2), dy: 0)
            let buttonsMinX = showsDownloadsButton ? downloadsButton.frame.minX : newTabButton.frame.minX
            scrollView.frame = NSRect(
                x: trafficLightInset, y: 0,
                width: max(0, buttonsMinX - 4 - Self.reservedDragSpace - trafficLightInset), height: bounds.height - 1
            )
            let available = scrollView.frame.width
            let count = CGFloat(max(itemViews.count, 1))
            let width = min(240, max(110, ((available - spacing * (count - 1)) / count).rounded(.down)))
            let height = scrollView.frame.height
            slots = itemViews.indices.map { index in
                NSRect(x: CGFloat(index) * (width + spacing), y: 4, width: width, height: height - 8)
            }
            documentView.frame = NSRect(x: 0, y: 0, width: max(available, (slots.last?.maxX ?? 0)), height: height)

        case .vertical:
            let top = Self.horizontalHeight
            newTabButton.frame = NSRect(
                x: bounds.width - buttonSize - 8, y: (top - buttonSize) / 2,
                width: buttonSize, height: buttonSize
            )
            downloadsButton.frame = newTabButton.frame.offsetBy(dx: -(buttonSize + 2), dy: 0)
            scrollView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
            let rowHeight: CGFloat = 30
            let width = scrollView.frame.width
            slots = itemViews.indices.map { index in
                NSRect(x: 8, y: 4 + CGFloat(index) * (rowHeight + 2), width: width - 16, height: rowHeight)
            }
            documentView.frame = NSRect(
                x: 0, y: 0, width: width,
                height: max(scrollView.contentSize.height, (slots.last?.maxY ?? 0) + 4)
            )
        }
        place(dragOrder ?? itemViews)
    }

    /// Puts tabs into their slots in the given order. The dragged tab follows the mouse instead.
    private func place(_ order: [TabItemView], animated: Bool = false) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.15 : 0
            context.allowsImplicitAnimation = animated
            for (view, slot) in zip(order, slots) where view !== draggedView {
                if animated { view.animator().frame = slot } else { view.frame = slot }
            }
        }
    }

    // MARK: - Reordering

    /// Runs a mouse-tracking loop after a tab is pressed. Moving more than a few points
    /// starts a drag: the tab follows the mouse along the strip and the others make room.
    private func trackDrag(of view: TabItemView, from mouseDown: NSEvent) {
        guard let window, let startIndex = itemViews.firstIndex(where: { $0 === view }),
              slots.indices.contains(startIndex) else { return }
        let horizontal = tabLayout == .horizontal
        let start = documentView.convert(mouseDown.locationInWindow, from: nil)
        let origin = slots[startIndex]
        var target = startIndex
        var dragging = false

        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              event.type == .leftMouseDragged {
            let point = documentView.convert(event.locationInWindow, from: nil)
            let delta = horizontal ? point.x - start.x : point.y - start.y
            if !dragging {
                guard abs(delta) > 4 else { continue }
                dragging = true
                draggedView = view
                view.isDragging = true
                documentView.addSubview(view, positioned: .above, relativeTo: nil)
            }

            var frame = origin
            if horizontal {
                frame.origin.x = min(max(origin.minX + delta, slots[0].minX), slots[slots.count - 1].minX)
            } else {
                frame.origin.y = min(max(origin.minY + delta, slots[0].minY), slots[slots.count - 1].minY)
            }
            view.frame = frame

            let center = horizontal ? frame.midX : frame.midY
            target = slots.indices.min {
                abs(center - (horizontal ? slots[$0].midX : slots[$0].midY))
                    < abs(center - (horizontal ? slots[$1].midX : slots[$1].midY))
            } ?? startIndex
            var order = itemViews.filter { $0 !== view }
            order.insert(view, at: target)
            dragOrder = order
            place(order, animated: true)
        }

        guard dragging else {
            // A plain click (no movement) selects; dragging leaves the selection alone.
            if let index = itemViews.firstIndex(where: { $0 === view }) {
                delegate?.tabStrip(self, didSelectTabAt: index)
            }
            return
        }
        draggedView = nil
        dragOrder = nil
        view.isDragging = false
        itemViews.insert(itemViews.remove(at: startIndex), at: target)
        place(itemViews, animated: true)
        if target != startIndex {
            delegate?.tabStrip(self, didMoveTabFrom: startIndex, to: target)
        }
    }

    /// Tab centres in window coordinates, for the self-test.
    var debugTabCenters: [NSPoint] {
        itemViews.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
    }

    @objc private func downloadsClicked(_ sender: Any?) {
        onDownloadsClick?()
    }

    @objc private func newTabClicked(_ sender: Any?) {
        delegate?.tabStripDidRequestNewTab(self)
    }
}

private final class TabListDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Let empty space in the tab list drag the window like the strip around it.
        superview?.superview?.superview?.mouseDown(with: event)
    }
}

private final class TabItemView: NSView {
    var onClose: (() -> Void)?
    /// Mouse-down on the tab; the strip decides whether it becomes a click or a drag.
    var onPress: ((NSEvent) -> Void)?

    var isDragging = false {
        didSet {
            alphaValue = isDragging ? 0.85 : 1
            shadow = isDragging ? {
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 8
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
                return shadow
            }() : nil
        }
    }

    // Every subview opts out of window dragging: macOS builds the title-bar drag region from
    // each view's `mouseDownCanMoveWindow`, so a plain label would make the tab drag the window.
    private let iconView = FaviconView()
    private let titleLabel = NonDraggingLabel(labelWithString: "")
    private let paneBadge = NonDraggingLabel(labelWithString: "")
    private let closeButton: NSButton
    private var isSelected = false
    private var isHovered = false { didSet { updateAppearance() } }
    private var trackingArea: NSTrackingArea?

    init() {
        let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage()
        closeButton = NSButton(image: symbol, target: nil, action: nil)
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true

        paneBadge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        paneBadge.textColor = .secondaryLabelColor
        paneBadge.toolTip = "Panes in this tab"

        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))


        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(paneBadge)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The whole tab handles clicks itself (except the close button), whatever is under the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return self
    }

    func configure(_ item: TabItem, selected: Bool) {
        titleLabel.stringValue = item.title
        if iconView.favicon !== item.favicon { iconView.favicon = item.favicon }
        toolTip = item.title
        paneBadge.stringValue = item.paneCount > 1 ? "▦ \(item.paneCount)" : ""
        paneBadge.isHidden = item.paneCount <= 1
        isSelected = selected
        updateAppearance()
        needsLayout = true
    }

    private func updateAppearance() {
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        closeButton.isHidden = !(isHovered || isSelected)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 16
        closeButton.frame = NSRect(
            x: bounds.width - closeSize - 6, y: (bounds.height - closeSize) / 2,
            width: closeSize, height: closeSize
        )
        var trailing = closeButton.frame.minX - 4
        if !paneBadge.isHidden {
            let size = paneBadge.intrinsicContentSize
            paneBadge.frame = NSRect(
                x: trailing - size.width, y: (bounds.height - size.height) / 2,
                width: size.width, height: size.height
            )
            trailing = paneBadge.frame.minX - 4
        }
        iconView.frame = NSRect(x: 10, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16)
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: 32, y: (bounds.height - titleHeight) / 2,
            width: max(0, trailing - 32), height: titleHeight
        )
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static let selectedFill = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.75)
    }

    private static let selectedBorder = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Drawn rather than glass: glass casts a shadow that the tab list's clip view cuts off.
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        if isSelected {
            Self.selectedFill.setFill()
            shape.fill()
            Self.selectedBorder.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            shape.fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPress?(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click closes, like other browsers.
        if event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeClicked(_ sender: Any?) { onClose?() }
}

private final class NonDraggingLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { false }
}
