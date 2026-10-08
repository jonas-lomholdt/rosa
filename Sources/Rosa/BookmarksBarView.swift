import AppKit

/// Full-width row of bookmarks under the tab strip / address bar. Links open in the focused
/// pane (⌘- or middle-click: in the background, like links); folders open as menus, and
/// whatever doesn't fit goes into a » menu at the end. Right-click edits, deletes or adds folders.
final class BookmarksBarView: ChromeView {
    static let height: CGFloat = 30
    private static let itemHeight: CGFloat = 24
    private static let spacing: CGFloat = 2

    /// Called with the URL and whether it should open in the background.
    var onOpen: ((URL, Bool) -> Void)?
    /// Right-click → Edit…: the bookmark's path and the view to anchor the editor to.
    var onEdit: ((Bookmarks.Path, NSView) -> Void)?
    /// Right-click → New Folder.
    var onNewFolder: (() -> Void)?
    /// Left padding so items line up with the panes.
    var leadingInset: CGFloat = 0 { didSet { needsLayout = true } }

    private var itemViews: [BookmarkItemView] = []
    private var hiddenBookmarks: [Bookmark] = []
    private let overflowButton = BookmarkItemView()
    private let emptyHint = NSTextField(labelWithString: "Press ⌘B to bookmark the current page")

    var bookmarks: [Bookmark] = [] {
        didSet { rebuild() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dragsWindow = true
        overflowButton.configure(title: "", icon: Self.symbol("chevron.right.2"), tinted: true)
        overflowButton.toolTip = "More bookmarks"
        overflowButton.onClick = { [weak self] _ in self?.showOverflowMenu() }
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.lineBreakMode = .byTruncatingTail
        addSubview(overflowButton)
        addSubview(emptyHint)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rebuild() {
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = bookmarks.enumerated().map { index, bookmark in
            let view = BookmarkItemView()
            view.contextMenu = { [weak self, weak view] in
                guard let self, let view else { return nil }
                return contextMenu(for: bookmark, at: [index], anchor: view)
            }
            switch bookmark.kind {
            case .link(let url):
                view.configure(title: bookmark.title, icon: nil, tinted: false)
                view.toolTip = bookmark.title.isEmpty ? url.absoluteString : "\(bookmark.title)\n\(url.absoluteString)"
                view.onClick = { [weak self] event in self?.onOpen?(url, Self.opensInBackground(event)) }
                Task { @MainActor [weak view] in
                    if let icon = await FaviconStore.shared.icon(forSite: url) { view?.icon = icon }
                }
            case .folder(let children):
                view.configure(title: bookmark.title, icon: Self.symbol("folder"), tinted: true)
                view.onClick = { [weak self, weak view] _ in
                    guard let self, let view else { return }
                    popUp(menu(for: children), under: view)
                }
            }
            addSubview(view)
            return view
        }
        emptyHint.isHidden = !bookmarks.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let y = ((bounds.height - Self.itemHeight) / 2).rounded()
        let maxX = bounds.width - leadingInset
        let hintHeight = emptyHint.intrinsicContentSize.height
        emptyHint.frame = NSRect(x: leadingInset + 8, y: ((bounds.height - hintHeight) / 2).rounded(),
                                 width: max(0, maxX - leadingInset - 8), height: hintHeight)

        // Lay out until the bar is full, keeping room for the » button if anything is left over.
        let widths = itemViews.map(\.fittingWidth)
        let overflowWidth = overflowButton.fittingWidth
        var x = leadingInset
        var visibleCount = 0
        for (index, width) in widths.enumerated() {
            let isLast = index == widths.count - 1
            let limit = isLast ? maxX : maxX - overflowWidth - Self.spacing
            guard x + width <= limit else { break }
            itemViews[index].frame = NSRect(x: x, y: y, width: width, height: Self.itemHeight)
            x += width + Self.spacing
            visibleCount += 1
        }
        for (index, view) in itemViews.enumerated() {
            view.isHidden = index >= visibleCount
        }
        hiddenBookmarks = Array(bookmarks.dropFirst(visibleCount))
        overflowButton.isHidden = hiddenBookmarks.isEmpty
        overflowButton.frame = NSRect(x: maxX - overflowWidth, y: y, width: overflowWidth, height: Self.itemHeight)
    }

    /// The bar's item for a top-level bookmark, if it's visible (to anchor the editor to).
    func itemView(at index: Int) -> NSView? {
        itemViews.indices.contains(index) && !itemViews[index].isHidden ? itemViews[index] : nil
    }

    // MARK: - Menus

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("New Folder") { [weak self] in self?.onNewFolder?() })
        menu.addItem(Self.manageItem())
        return menu
    }

    private static func manageItem() -> NSMenuItem {
        ClosureMenuItem("Manage Bookmarks…") {
            NSApp.sendAction(#selector(AppDelegate.showBookmarksManager(_:)), to: nil, from: nil)
        }
    }

    private func contextMenu(for bookmark: Bookmark, at path: Bookmarks.Path, anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        switch bookmark.kind {
        case .link(let url):
            menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.onOpen?(url, false) })
            menu.addItem(ClosureMenuItem("Open in Background") { [weak self] in self?.onOpen?(url, true) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Edit…") { [weak self, weak anchor] in
                if let anchor { self?.onEdit?(path, anchor) }
            })
            menu.addItem(ClosureMenuItem(bookmark.pinned ? "Unpin from Quick Links" : "Pin to Quick Links") {
                Bookmarks.setPinned(at: path, !bookmark.pinned)
            })
            menu.addItem(ClosureMenuItem("Delete") { Bookmarks.remove(at: path) })
        case .folder(let children):
            menu.addItem(ClosureMenuItem("Rename…") { [weak self, weak anchor] in
                if let anchor { self?.onEdit?(path, anchor) }
            })
            menu.addItem(ClosureMenuItem("Delete") { [weak self] in
                guard children.isEmpty || self?.confirmDeleting(bookmark.title, count: children.count) == true else { return }
                Bookmarks.remove(at: path)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Folder") { [weak self] in self?.onNewFolder?() })
        menu.addItem(Self.manageItem())
        return menu
    }

    private func confirmDeleting(_ folder: String, count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete “\(folder)”?"
        alert.informativeText = "It contains \(count) \(count == 1 ? "item" : "items"), which will be deleted too."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showOverflowMenu() {
        popUp(menu(for: hiddenBookmarks), under: overflowButton)
    }

    private func popUp(_ menu: NSMenu, under view: BookmarkItemView) {
        view.isPressed = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        view.isPressed = false
    }

    private func menu(for bookmarks: [Bookmark]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if bookmarks.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for bookmark in bookmarks {
            switch bookmark.kind {
            case .link(let url):
                let item = NSMenuItem(title: bookmark.title.isEmpty ? (url.host() ?? url.absoluteString) : bookmark.title,
                                      action: #selector(menuItemClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.toolTip = url.absoluteString
                item.image = FaviconStore.placeholder
                Task { @MainActor [weak item] in
                    if let icon = await FaviconStore.shared.icon(forSite: url) { item?.image = icon }
                }
                menu.addItem(item)
            case .folder(let children):
                let item = NSMenuItem(title: bookmark.title, action: nil, keyEquivalent: "")
                item.image = Self.symbol("folder")
                item.submenu = self.menu(for: children)
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpen?(url, NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
    }

    private static func opensInBackground(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) || event.buttonNumber == 2
    }

    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? image
    }

    // MARK: - Testing

    var debugVisibleTitles: [String] {
        zip(bookmarks, itemViews).filter { !$0.1.isHidden }.map(\.0.title)
    }

    var debugOverflowCount: Int { hiddenBookmarks.count }
}

/// One bookmark (or folder) in the bar: favicon and title, with a hover highlight.
private final class BookmarkItemView: NSView {
    var onClick: ((NSEvent) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var isPressed = false { didSet { needsDisplay = true } }

    var icon: NSImage? {
        get { iconView.favicon }
        set { iconView.favicon = newValue }
    }

    private let iconView = FaviconView()
    private let titleLabel = NonDraggingLabel(labelWithString: "")
    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(iconView)
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, icon: NSImage?, tinted: Bool) {
        titleLabel.stringValue = title
        titleLabel.isHidden = title.isEmpty
        iconView.favicon = icon
        // Symbols (folder, ») follow the text colour; favicons keep their own.
        if tinted { iconView.contentTintColor = .secondaryLabelColor }
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        guard !titleLabel.isHidden else { return 28 }
        // The label's cell insets its text by 2pt per side on top of the intrinsic width.
        let titleWidth = min(ceil(titleLabel.intrinsicContentSize.width), 160) + 4
        return Self.titleX + titleWidth + 8
    }

    private static let titleX: CGFloat = 28

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let iconX = titleLabel.isHidden ? ((bounds.width - 16) / 2).rounded() : 8
        iconView.frame = NSRect(x: iconX, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16)
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(x: Self.titleX, y: ((bounds.height - titleHeight) / 2).rounded(),
                                  width: max(0, bounds.width - Self.titleX - 8), height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isPressed else { return }
        NSColor.labelColor.withAlphaComponent(isPressed ? 0.14 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?() ?? super.menu(for: event)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(event) }
    }
}

/// Menu item that runs a closure (keeps context menus free of selector plumbing).
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
