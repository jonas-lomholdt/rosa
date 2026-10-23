import AppKit

/// The status bar tab layout: a slim, i3bar-style row that replaces the tab strip and sidebar.
/// Shows `Settings.statusBarItems` left to right: a box per tab (its number for ⌘1–9, its favicon,
/// or both; the selected one in the accent colour), the focused pane's title, spacers and a downloads button. Drawn rather
/// than built from subviews, except the downloads button (popovers anchor to it).
final class StatusBarView: ChromeView, NSViewToolTipOwner {
    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onDownloadsClick: (() -> Void)?

    var size: StatusBarSize = .m {
        didSet {
            guard size != oldValue else { return }
            updateDownloadsImage()
            superview?.needsLayout = true
            needsLayout = true
        }
    }

    var items: [StatusBarItem] = Settings.defaultStatusBarItems {
        didSet { if items != oldValue { needsLayout = true } }
    }

    var tabStyle: StatusBarTabStyle = .numbers {
        didSet { if tabStyle != oldValue { needsLayout = true } }
    }

    var title = "" {
        didSet { if title != oldValue { needsLayout = true } }
    }

    var showsDownloadsButton = false {
        didSet { if showsDownloadsButton != oldValue { needsLayout = true } }
    }

    /// Accent tint while downloads are in progress.
    var downloadsActive = false {
        didSet { if downloadsActive != oldValue { updateDownloadsImage() } }
    }

    let downloadsButton = NSButton()

    private var tabs: [TabItem] = []
    private var selectedIndex = 0
    private var tabRects: [NSRect] = []
    private var titleRect: NSRect = .zero
    private var hoveredIndex: Int? { didSet { if hoveredIndex != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    /// Room on both ends, so the outer items clear the window's rounded corners.
    private static let edgeInset: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dragsWindow = true
        downloadsButton.isBordered = false
        downloadsButton.target = self
        downloadsButton.action = #selector(downloadsClicked(_:))
        downloadsButton.toolTip = "Downloads (⌥⌘L)"
        downloadsButton.isHidden = true
        updateDownloadsImage()
        addSubview(downloadsButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(tabs: [TabItem], selectedIndex: Int) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        needsLayout = true
    }

    /// Where the downloads popover hangs from: the button, else the bar's right end.
    var downloadsAnchor: (view: NSView, rect: NSRect) {
        if !downloadsButton.isHidden { return (downloadsButton, downloadsButton.bounds) }
        return (self, NSRect(x: bounds.width - Self.edgeInset - 1, y: 0, width: 1, height: bounds.height))
    }

    // MARK: - Layout

    private var font: NSFont { .monospacedSystemFont(ofSize: size.fontSize, weight: .medium) }
    private var titleFont: NSFont { .monospacedSystemFont(ofSize: size.fontSize, weight: .regular) }
    private var gap: CGFloat { size.fontSize }
    /// Tab boxes and the downloads button are this tall, centred in the bar.
    private var boxHeight: CGFloat { bounds.height - 4 }

    private var iconSize: CGFloat { min(16, boxHeight - 4) }
    /// How far each card behind a split tab's favicon peeks out to the right.
    private var stackOffset: CGFloat { (iconSize * 0.45).rounded() }
    /// Cards drawn behind the focused pane's favicon (at most two, however many panes).
    private static let maxStackedCards = 2

    private func stackedCount(_ tab: TabItem) -> Int { min(tab.otherPaneFavicons.count, Self.maxStackedCards) }

    /// The favicon with its stack of cards.
    private func iconsWidth(_ tab: TabItem) -> CGFloat { iconSize + CGFloat(stackedCount(tab)) * stackOffset }

    private func tabWidths() -> [CGFloat] {
        tabs.indices.map { index in
            let text = NSAttributedString(string: "\(index + 1)", attributes: [.font: font])
            let content: CGFloat = switch tabStyle {
            case .numbers: text.size().width
            case .favicons: iconsWidth(tabs[index])
            case .both: iconsWidth(tabs[index]) + 4 + text.size().width
            }
            return max((boxHeight * 1.25).rounded(), (content + size.fontSize).rounded())
        }
    }

    override func layout() {
        super.layout()
        let widths = tabWidths()
        let tabsWidth = widths.reduce(0, +) + CGFloat(max(widths.count - 1, 0)) * 2
        let showsDownloads = showsDownloadsButton && items.contains(.downloads)
        let titleNatural = (NSAttributedString(string: title, attributes: [.font: titleFont]).size().width).rounded(.up)

        // Fixed widths first; the title gets what's left (up to its natural width), spacers the rest.
        func fixedWidth(_ item: StatusBarItem) -> CGFloat? {
            switch item {
            case .tabs: tabs.isEmpty ? nil : tabsWidth
            case .downloads: showsDownloads ? boxHeight : nil
            case .title: title.isEmpty ? nil : 0
            case .spacer: 0
            }
        }
        let visible = items.filter { fixedWidth($0) != nil }
        let gaps = visible.indices.dropFirst().filter { visible[$0] != .spacer && visible[$0 - 1] != .spacer }.count
        let available = bounds.width - Self.edgeInset * 2
        let fixed = visible.compactMap(fixedWidth).reduce(0, +) + CGFloat(gaps) * gap
        let titleWidth = max(0, min(titleNatural, available - fixed))
        let spacers = visible.filter { $0 == .spacer }.count
        let spacerWidth = spacers == 0 ? 0 : max(0, available - fixed - titleWidth) / CGFloat(spacers)

        tabRects = []
        titleRect = .zero
        downloadsButton.isHidden = !showsDownloads
        let boxY = ((bounds.height - boxHeight) / 2).rounded()
        var x = Self.edgeInset
        for (index, item) in visible.enumerated() {
            if index > 0, item != .spacer, visible[index - 1] != .spacer { x += gap }
            switch item {
            case .tabs:
                for width in widths {
                    tabRects.append(NSRect(x: x, y: boxY, width: width, height: boxHeight))
                    x += width + 2
                }
                x -= 2
            case .title:
                titleRect = NSRect(x: x, y: 0, width: titleWidth, height: bounds.height)
                x += titleWidth
            case .spacer:
                x += spacerWidth
            case .downloads:
                downloadsButton.frame = NSRect(x: x, y: boxY, width: boxHeight, height: boxHeight)
                x += boxHeight
            }
        }

        removeAllToolTips()
        for rect in tabRects { addToolTip(rect, owner: self, userData: nil) }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(5, boxHeight / 4)
        for (index, rect) in tabRects.enumerated() where tabs.indices.contains(index) {
            let selected = index == selectedIndex
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            // A solid accent box with white text for numbers; favicons keep their colours on a tint and an accent border.
            if selected, tabStyle == .numbers {
                NSColor.controlAccentColor.setFill()
                shape.fill()
            } else if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
                shape.fill()
                let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                border.lineWidth = 1
                NSColor.controlAccentColor.setStroke()
                border.stroke()
            } else {
                NSColor.labelColor.withAlphaComponent(index == hoveredIndex ? 0.14 : 0.07).setFill()
                shape.fill()
            }

            let text = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: font,
                .foregroundColor: selected ? (tabStyle == .numbers ? NSColor.white : NSColor.labelColor) : NSColor.secondaryLabelColor,
            ])
            let textSize = text.size()
            let contentWidth: CGFloat = switch tabStyle {
            case .numbers: textSize.width
            case .favicons: iconsWidth(tabs[index])
            case .both: iconsWidth(tabs[index]) + 4 + textSize.width
            }
            var x = (rect.midX - contentWidth / 2).rounded()
            if tabStyle != .numbers {
                drawIconStack(tabs[index], at: NSPoint(x: x, y: (rect.midY - iconSize / 2).rounded()), selected: selected)
                x += iconsWidth(tabs[index]) + 4
            }
            if tabStyle != .favicons {
                text.draw(at: NSPoint(x: x, y: (rect.midY - textSize.height / 2).rounded()))
            }
        }

        if titleRect.width > 0 {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: title, attributes: [
                .font: titleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ])
            let height = text.size().height
            text.draw(with: NSRect(x: titleRect.minX, y: (titleRect.midY - height / 2).rounded(),
                                   width: titleRect.width, height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// A split tab's favicons as a stack of cards: the focused pane's in front, the others behind it,
    /// each smaller, fainter and further right, showing only where they peek out past the cards in front.
    private func drawIconStack(_ tab: TabItem, at origin: NSPoint, selected: Bool) {
        var cards = [NSRect(origin: origin, size: NSSize(width: iconSize, height: iconSize))]
        for depth in stride(from: 1, through: stackedCount(tab), by: 1) {
            let side = (iconSize * (1 - 0.15 * CGFloat(depth))).rounded()
            cards.append(NSRect(x: origin.x + CGFloat(depth) * stackOffset + iconSize - side,
                                y: (origin.y + (iconSize - side) / 2).rounded(), width: side, height: side))
        }
        let favicons = [tab.favicon] + tab.otherPaneFavicons
        // Back to front, each clipped to stay out of the cards in front of it (with a hairline gap).
        for depth in cards.indices.reversed() {
            NSGraphicsContext.saveGraphicsState()
            // One clip per card in front: they overlap, so a single even-odd path would let the overlap through.
            for front in cards[..<depth] {
                let clip = NSBezierPath(rect: bounds)
                clip.append(NSBezierPath(roundedRect: front.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3))
                clip.windingRule = .evenOdd
                clip.addClip()
            }
            let fraction: CGFloat = depth > 0 ? (depth == 1 ? 0.7 : 0.45) : (selected || tab.favicon == nil ? 1 : 0.85)
            Self.icon(favicons[depth]).draw(in: cards[depth], from: .zero, operation: .sourceOver,
                                            fraction: fraction, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The favicon, else the placeholder globe tinted like secondary text (it's a template image).
    private static func icon(_ favicon: NSImage?) -> NSImage {
        if let favicon { return favicon }
        let placeholder = FaviconStore.placeholder
        return NSImage(size: placeholder.size, flipped: false) { rect in
            placeholder.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private func updateDownloadsImage() {
        let symbol = downloadsActive ? "arrow.down.circle.fill" : "arrow.down.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Downloads")
        downloadsButton.image = image?.withSymbolConfiguration(.init(pointSize: size.fontSize + 1, weight: .regular))
        downloadsButton.contentTintColor = downloadsActive ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func downloadsClicked(_ sender: Any?) { onDownloadsClick?() }

    // MARK: - Mouse

    private func tabIndex(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return tabRects.firstIndex { $0.contains(point) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Empty space drags the window (`ChromeView`).
        guard let index = tabIndex(at: event) else { return super.mouseDown(with: event) }
        onSelectTab?(index)
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click closes, like the tab strip.
        if event.buttonNumber == 2, let index = tabIndex(at: event) { onCloseTab?(index) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { hoveredIndex = tabIndex(at: event) }
    override func mouseExited(with event: NSEvent) { hoveredIndex = nil }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = tabRects.firstIndex(where: { $0.contains(point) }), tabs.indices.contains(index) else { return "" }
        let shortcut = index < 9 ? "  ⌘\(index + 1)" : ""
        return tabs[index].title + shortcut
    }

    // MARK: - Testing

    var debugTabRects: [NSRect] { tabRects }
    var debugTitleRect: NSRect { titleRect }
}
