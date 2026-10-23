import AppKit

/// The status bar tab layout: a slim, i3bar-style row that replaces the tab strip and sidebar.
/// Shows `Settings.statusBarItems` left to right: numbered tab boxes (⌘1–9, the selected one in
/// the accent colour), the focused pane's title, spacers and a downloads button. Drawn rather
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

    private func tabWidths() -> [CGFloat] {
        tabs.indices.map { index in
            let text = NSAttributedString(string: "\(index + 1)", attributes: [.font: font])
            return max((boxHeight * 1.25).rounded(), (text.size().width + size.fontSize).rounded())
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
        for (index, rect) in tabRects.enumerated() {
            let selected = index == selectedIndex
            let fill: NSColor = selected ? .controlAccentColor
                : NSColor.labelColor.withAlphaComponent(index == hoveredIndex ? 0.14 : 0.07)
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            let text = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: font,
                .foregroundColor: selected ? NSColor.white : NSColor.secondaryLabelColor,
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: (rect.midX - textSize.width / 2).rounded(),
                                  y: (rect.midY - textSize.height / 2).rounded()))
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
