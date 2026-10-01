import AppKit

@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, didSelectTabAt index: Int)
    func tabStrip(_ strip: TabStripView, didCloseTabAt index: Int)
    func tabStripDidRequestNewTab(_ strip: TabStripView)
}

struct TabItem {
    var title: String
    var paneCount: Int
}

/// The tab list. Lays out as a row in the title bar (horizontal) or as a sidebar (vertical).
final class TabStripView: ChromeView {
    static let horizontalHeight: CGFloat = 38
    static let verticalWidth: CGFloat = 220

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
    private var itemViews: [TabItemView] = []
    private var selectedIndex = 0

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(items: [TabItem], selectedIndex: Int) {
        while itemViews.count < items.count {
            let view = TabItemView()
            view.onSelect = { [weak self, weak view] in
                guard let self, let view, let index = self.itemViews.firstIndex(where: { $0 === view }) else { return }
                self.delegate?.tabStrip(self, didSelectTabAt: index)
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
            scrollView.frame = NSRect(
                x: trafficLightInset, y: 0,
                width: max(0, newTabButton.frame.minX - 4 - trafficLightInset), height: bounds.height - 1
            )
            let available = scrollView.frame.width
            let count = CGFloat(max(itemViews.count, 1))
            let width = min(240, max(110, ((available - spacing * (count - 1)) / count).rounded(.down)))
            var x: CGFloat = 0
            for view in itemViews {
                view.frame = NSRect(x: x, y: 5, width: width, height: scrollView.frame.height - 10)
                x += width + spacing
            }
            documentView.frame = NSRect(x: 0, y: 0, width: max(available, x - spacing), height: scrollView.frame.height)

        case .vertical:
            let top = Self.horizontalHeight
            newTabButton.frame = NSRect(
                x: bounds.width - buttonSize - 8, y: (top - buttonSize) / 2,
                width: buttonSize, height: buttonSize
            )
            scrollView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
            let rowHeight: CGFloat = 30
            var y: CGFloat = 4
            for view in itemViews {
                view.frame = NSRect(x: 8, y: y, width: scrollView.frame.width - 16, height: rowHeight)
                y += rowHeight + 2
            }
            documentView.frame = NSRect(
                x: 0, y: 0, width: scrollView.frame.width,
                height: max(scrollView.contentSize.height, y + 4)
            )
        }
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
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let paneBadge = NSTextField(labelWithString: "")
    private let closeButton: NSButton
    private let selectionGlass = NSGlassEffectView()
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

        selectionGlass.cornerRadius = 10
        selectionGlass.isHidden = true

        addSubview(selectionGlass)
        addSubview(titleLabel)
        addSubview(paneBadge)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(_ item: TabItem, selected: Bool) {
        titleLabel.stringValue = item.title
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
        selectionGlass.isHidden = !isSelected
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        selectionGlass.frame = bounds
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
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: 10, y: (bounds.height - titleHeight) / 2,
            width: max(0, trailing - 10), height: titleHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
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

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click closes, like other browsers.
        if event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeClicked(_ sender: Any?) { onClose?() }
}
