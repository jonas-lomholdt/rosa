import AppKit

/// A tile on a blank pane: a pinned bookmark or a recently visited site.
struct QuickLink {
    let title: String
    let url: URL
    /// Bookmark path when pinned (for Unpin in the tile's menu).
    let pinnedPath: Bookmarks.Path?

    var identity: String { "\(url.absoluteString) \(title) \(pinnedPath ?? [])" }

    /// Pinned bookmarks; when none are pinned, the last few sites visited (one page per site).
    @MainActor
    static func current() -> (heading: String, links: [QuickLink]) {
        let pinned = Bookmarks.pinned.compactMap { path, bookmark -> QuickLink? in
            guard case .link(let url) = bookmark.kind else { return nil }
            return QuickLink(title: bookmark.title.isEmpty ? displayHost(url) : bookmark.title, url: url, pinnedPath: path)
        }
        if !pinned.isEmpty { return ("Pinned", Array(pinned.prefix(QuickLinksView.maxTiles))) }
        guard Settings.historyEnabled else { return ("", []) }
        let recent = HistoryStore.shared.recentSites(limit: 6).map {
            QuickLink(title: $0.title.isEmpty ? $0.displayHost : $0.title, url: $0.url, pinnedPath: nil)
        }
        return ("Recently Visited", recent)
    }

    static func displayHost(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Shown over every blank pane (except the launch pane's welcome page): pinned bookmarks as
/// tiles, or recently visited sites when nothing is pinned. Keeps itself up to date while shown.
final class QuickLinksView: NSView {
    static let maxTiles = 12
    private static let tileSize = NSSize(width: 104, height: 92)
    private static let gap: CGFloat = 12
    private static let headerHeight: CGFloat = 24
    private static let headerGap: CGFloat = 12

    /// Opens a tile's URL in this pane, or in the background (⌘-click, menu).
    var onOpen: ((URL, Bool) -> Void)?

    private let header = WelcomeSectionHeader(title: "")
    private var tiles: [QuickLinkTile] = []
    private var heading = ""
    private var observers: [NSObjectProtocol] = []

    /// False when there's nothing to show or the pane is too small for a row of tiles.
    var isShowingTiles: Bool { !tiles.isEmpty && !header.isHidden }
    var debugTitles: [String] { tiles.map(\.link.title) }
    var debugHeading: String { header.title }
    func debugOpen(_ index: Int) { onOpen?(tiles[index].link.url, false) }
    /// Self-test: the centre of a tile (on its icon), in window coordinates.
    func debugTileCenter(_ index: Int) -> NSPoint { tiles[index].convert(NSPoint(x: tiles[index].bounds.midX, y: 34), to: nil) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(header)
        for name in [Bookmarks.didChange, HistoryStore.didChange, Settings.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var isFlipped: Bool { true }

    /// Its own background: a blank web view draws white until it has loaded something.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    /// Only the tiles take clicks; elsewhere the click reaches the (blank) web view and focuses the pane.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The tile itself, also when the point is on its icon or title.
        var view = super.hitTest(point)
        while let current = view, !(current is QuickLinkTile) { view = current === self ? nil : current.superview }
        return view
    }

    func reload() {
        let (heading, links) = QuickLink.current()
        // History changes with every page load elsewhere; rebuilding unchanged tiles would drop a click in progress.
        guard heading != self.heading || links.map(\.identity) != tiles.map(\.link.identity) else { return }
        self.heading = heading
        header.title = heading
        tiles.forEach { $0.removeFromSuperview() }
        tiles = links.map { link in
            let tile = QuickLinkTile(link: link)
            tile.onOpen = { [weak self] background in self?.onOpen?(link.url, background) }
            addSubview(tile)
            return tile
        }
        needsLayout = true
    }

    /// Height the tiles need at `width`, or nil when not even one row fits.
    func requiredHeight(forWidth width: CGFloat) -> CGFloat? {
        guard !tiles.isEmpty else { return 0 }
        let columns = columnCount(forWidth: width)
        guard columns > 0 else { return nil }
        let rows = (tiles.count + columns - 1) / columns
        return Self.headerHeight + Self.headerGap + CGFloat(rows) * Self.tileSize.height + CGFloat(rows - 1) * Self.gap
    }

    /// Up to six per row, fewer in narrow panes; rows are balanced (8 tiles → 4 + 4, not 6 + 2).
    private func columnCount(forWidth width: CGFloat) -> Int {
        let fit = Int((width - 48 + Self.gap) / (Self.tileSize.width + Self.gap))
        let maxColumns = min(6, fit, tiles.count)
        guard maxColumns > 0 else { return 0 }
        let rows = (tiles.count + maxColumns - 1) / maxColumns
        return (tiles.count + rows - 1) / rows
    }

    override func layout() {
        super.layout()
        let height = requiredHeight(forWidth: bounds.width)
        let fits = !tiles.isEmpty && height.map { $0 + 32 <= bounds.height } == true
        header.isHidden = !fits
        tiles.forEach { $0.isHidden = !fits }
        guard fits, let height else { return }
        let columns = columnCount(forWidth: bounds.width)
        let rowWidth = CGFloat(columns) * Self.tileSize.width + CGFloat(columns - 1) * Self.gap
        let x = ((bounds.width - rowWidth) / 2).rounded()
        // A little above centre, where the eye lands in an empty pane.
        var y = max(16, ((bounds.height - height) * 0.4).rounded())
        header.frame = NSRect(x: x, y: y, width: rowWidth, height: Self.headerHeight)
        y += Self.headerHeight + Self.headerGap
        for (index, tile) in tiles.enumerated() {
            let column = index % columns, row = index / columns
            // The last row is centred when it's short.
            let inRow = row == (tiles.count - 1) / columns ? tiles.count - row * columns : columns
            let rowX = x + (rowWidth - (CGFloat(inRow) * Self.tileSize.width + CGFloat(inRow - 1) * Self.gap)) / 2
            tile.frame = NSRect(
                x: (rowX + CGFloat(column) * (Self.tileSize.width + Self.gap)).rounded(),
                y: y + CGFloat(row) * (Self.tileSize.height + Self.gap),
                width: Self.tileSize.width, height: Self.tileSize.height
            )
        }
    }
}

/// Favicon in a rounded square with the title below; hover highlight, right-click menu.
private final class QuickLinkTile: NSView {
    let link: QuickLink
    var onOpen: ((Bool) -> Void)?

    private let iconBackground = NSView()
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(link: QuickLink) {
        self.link = link
        titleLabel = NSTextField(labelWithString: link.title)
        super.init(frame: .zero)
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 12
        iconBackground.layer?.cornerCurve = .continuous
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = FaviconStore.placeholder
        iconView.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        iconBackground.addSubview(iconView)
        addSubview(iconBackground)
        addSubview(titleLabel)
        toolTip = "\(link.title)\n\(link.url.absoluteString)"
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel(link.title)
        updateColors()
        Task { [weak self] in
            guard let icon = await FaviconStore.shared.icon(forSite: link.url) else { return }
            self?.iconView.image = icon
            self?.iconView.contentTintColor = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            iconBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }

    override func layout() {
        super.layout()
        let square: CGFloat = 48
        iconBackground.frame = NSRect(x: ((bounds.width - square) / 2).rounded(), y: 10, width: square, height: square)
        iconView.frame = iconBackground.bounds.insetBy(dx: 14, dy: 14)
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(x: 6, y: iconBackground.frame.maxY + 8, width: bounds.width - 12, height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isPressed else { return }
        NSColor.labelColor.withAlphaComponent(isPressed ? 0.12 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(event.modifierFlags.contains(.command))
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?(true) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(TileMenuItem("Open") { [weak self] in self?.onOpen?(false) })
        menu.addItem(TileMenuItem("Open in Background") { [weak self] in self?.onOpen?(true) })
        menu.addItem(.separator())
        if let path = link.pinnedPath {
            menu.addItem(TileMenuItem("Unpin") { Bookmarks.setPinned(at: path, false) })
        } else {
            // Pinning a recent site bookmarks it (or pins its existing bookmark).
            menu.addItem(TileMenuItem("Pin") { [link] in
                if let path = Bookmarks.path(of: link.url) {
                    Bookmarks.setPinned(at: path, true)
                } else {
                    Bookmarks.add(Bookmark(title: link.title, kind: .link(link.url), pinned: true))
                }
            })
        }
        return menu
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?(false)
        return true
    }
}

private final class TileMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
