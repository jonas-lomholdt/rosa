import AppKit

/// Bookmarks → Manage Bookmarks… (⌥⌘B): the whole tree in an outline view. Drag to reorder or
/// to move into (nested) folders, Return or right-click to rename / edit the address, ⌫ to delete,
/// double-click to open in a new tab. Every change goes straight to `Bookmarks` (and its file).
final class BookmarksManagerController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSTextFieldDelegate {

    /// Opens a URL in the front browser window: in a new tab, or in its focused pane.
    var onOpen: ((URL, _ newTab: Bool) -> Void)?

    private let outlineView = ManagerOutlineView()
    private var roots: [Node] = []
    private var expandedIDs: Set<UUID> = []
    private var observer: NSObjectProtocol?
    /// Set while we write a change ourselves, so the reload keeps the editor's state simple.
    private var editingRow: Int?

    private static let pasteboardType = NSPasteboard.PasteboardType("dev.rosa.bookmark-path")
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let addressColumn = NSUserInterfaceItemIdentifier("address")

    /// One row: a bookmark and where it sits in the tree right now.
    final class Node {
        let bookmark: Bookmark
        let path: Bookmarks.Path
        let children: [Node]?
        var icon: NSImage?

        init(_ bookmark: Bookmark, path: Bookmarks.Path) {
            self.bookmark = bookmark
            self.path = path
            if case .folder(let items) = bookmark.kind {
                children = items.enumerated().map { Node($1, path: path + [$0]) }
            } else {
                children = nil
            }
        }

        var url: URL? {
            if case .link(let url) = bookmark.kind { return url }
            return nil
        }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Bookmarks"
        window.minSize = NSSize(width: 420, height: 260)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BookmarksManager")
        super.init(window: window)
        buildContent()
        observer = NotificationCenter.default.addObserver(
            forName: Bookmarks.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let nameColumn = NSTableColumn(identifier: Self.nameColumn)
        nameColumn.title = "Name"
        nameColumn.width = 280
        let addressColumn = NSTableColumn(identifier: Self.addressColumn)
        addressColumn.title = "Address"
        addressColumn.width = 380
        outlineView.addTableColumn(nameColumn)
        outlineView.addTableColumn(addressColumn)
        outlineView.outlineTableColumn = nameColumn
        outlineView.style = .inset
        outlineView.rowHeight = 24
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(openInNewTab(_:))
        outlineView.registerForDraggedTypes([Self.pasteboardType, .URL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.onReturn = { [weak self] in self?.rename(nil) }
        outlineView.onDelete = { [weak self] in self?.delete(nil) }

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let newFolder = NSButton(title: "New Folder", target: self, action: #selector(newFolder(_:)))
        let hint = NSTextField(labelWithString: "Drag to reorder or move into folders · Return to rename · Double-click to open")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        for view in [scroll, newFolder, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: newFolder.topAnchor, constant: -10),
            newFolder.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            newFolder.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            hint.leadingAnchor.constraint(equalTo: newFolder.trailingAnchor, constant: 12),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            hint.centerYAnchor.constraint(equalTo: newFolder.centerYAnchor),
        ])
    }

    // MARK: - Data

    /// Rebuilds the rows from `Bookmarks`, keeping expanded folders and the selection (by id).
    private func reload() {
        let selectedID = selectedNode?.bookmark.id
        roots = Bookmarks.items.enumerated().map { Node($1, path: [$0]) }
        outlineView.reloadData()
        func restore(_ nodes: [Node]) {
            for node in nodes where node.children != nil && expandedIDs.contains(node.bookmark.id) {
                outlineView.expandItem(node)
                restore(node.children ?? [])
            }
        }
        restore(roots)
        if let selectedID, let node = find(selectedID, in: roots) {
            let row = outlineView.row(forItem: node)
            if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    private func find(_ id: UUID, in nodes: [Node]) -> Node? {
        for node in nodes {
            if node.bookmark.id == id { return node }
            if let found = find(id, in: node.children ?? []) { return found }
        }
        return nil
    }

    private var selectedNode: Node? {
        outlineView.item(atRow: outlineView.selectedRow) as? Node
    }

    /// The right-clicked row if there is one, else the selection.
    private var targetNode: Node? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return outlineView.item(atRow: row) as? Node
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children?[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.children != nil
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? Node { expandedIDs.insert(node.bookmark.id) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? Node { expandedIDs.remove(node.bookmark.id) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let column = tableColumn else { return nil }
        let isName = column.identifier == Self.nameColumn
        let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? ManagerCell
            ?? ManagerCell(identifier: column.identifier, showsIcon: isName)
        cell.textField?.delegate = self
        if isName {
            cell.textField?.stringValue = node.bookmark.title
            cell.textField?.placeholderString = node.url?.host() ?? "Untitled"
            if node.children != nil {
                cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
                cell.imageView?.contentTintColor = .secondaryLabelColor
            } else {
                cell.imageView?.image = node.icon ?? FaviconStore.placeholder
                cell.imageView?.contentTintColor = node.icon == nil ? .secondaryLabelColor : nil
                if node.icon == nil, let url = node.url { loadIcon(for: node, url: url) }
            }
        } else if let url = node.url {
            cell.textField?.stringValue = url.absoluteString
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.placeholderString = nil
        } else {
            let count = node.children?.count ?? 0
            cell.textField?.stringValue = count == 1 ? "1 item" : "\(count) items"
            cell.textField?.textColor = .tertiaryLabelColor
        }
        return cell
    }

    private func loadIcon(for node: Node, url: URL) {
        Task { @MainActor [weak self] in
            guard let icon = await FaviconStore.shared.icon(forSite: url), let self else { return }
            node.icon = icon
            let row = outlineView.row(forItem: node)
            let column = outlineView.column(withIdentifier: Self.nameColumn)
            if row >= 0, column >= 0 {
                outlineView.reloadData(forRowIndexes: [row], columnIndexes: [column])
            }
        }
    }

    // MARK: - Editing

    /// Starts inline editing of the name (or, with the address column, the URL) of a row.
    private func beginEditing(_ node: Node, column identifier: NSUserInterfaceItemIdentifier) {
        let row = outlineView.row(forItem: node)
        let column = outlineView.column(withIdentifier: identifier)
        guard row >= 0, column >= 0,
              let cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? ManagerCell,
              let field = cell.textField else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        field.isEditable = true
        field.textColor = .labelColor
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        field.isEditable = false
        let row = outlineView.row(for: field)
        let column = outlineView.column(for: field)
        guard row >= 0, column >= 0, let node = outlineView.item(atRow: row) as? Node else { return }
        window?.makeFirstResponder(outlineView)
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let isEscape = (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        if outlineView.tableColumns[column].identifier == Self.nameColumn {
            if !isEscape, text != node.bookmark.title {
                Bookmarks.rename(at: node.path, to: text.isEmpty && node.children != nil ? "Folder" : text)
                return
            }
        } else if !isEscape, let url = node.url, let newURL = Bookmarks.linkURL(text), newURL != url {
            Bookmarks.setURL(at: node.path, to: newURL)
            return
        }
        // Unchanged or cancelled: put the original text back.
        outlineView.reloadData(forRowIndexes: [row], columnIndexes: [column])
    }

    // MARK: - Actions

    @objc func newFolder(_ sender: Any?) {
        // Inside the selected folder, or next to the selected bookmark.
        var parent: Bookmarks.Path = []
        if let node = selectedNode {
            parent = node.children != nil ? node.path : Array(node.path.dropLast())
        }
        if !parent.isEmpty, let node = nodeAt(parent) { expandedIDs.insert(node.bookmark.id) }
        let path = Bookmarks.add(Bookmark(title: "New Folder", kind: .folder([])), to: parent)
        reload()
        guard let node = nodeAt(path) else { return }
        beginEditing(node, column: Self.nameColumn)
    }

    private func nodeAt(_ path: Bookmarks.Path) -> Node? {
        var nodes = roots
        var node: Node?
        for index in path {
            guard nodes.indices.contains(index) else { return nil }
            node = nodes[index]
            nodes = node?.children ?? []
        }
        return node
    }

    @objc func rename(_ sender: Any?) {
        if let node = targetNode { beginEditing(node, column: Self.nameColumn) }
    }

    @objc func editAddress(_ sender: Any?) {
        if let node = targetNode, node.url != nil { beginEditing(node, column: Self.addressColumn) }
    }

    @objc func open(_ sender: Any?) {
        if let url = targetNode?.url { onOpen?(url, false) }
    }

    @objc func openInNewTab(_ sender: Any?) {
        guard let node = targetNode else { return }
        if let url = node.url {
            onOpen?(url, true)
        } else if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    @objc func togglePinned(_ sender: Any?) {
        guard let node = targetNode, node.url != nil else { return }
        Bookmarks.setPinned(at: node.path, !node.bookmark.pinned)
    }

    @objc func delete(_ sender: Any?) {
        guard let node = targetNode else { return }
        let count = node.children?.count ?? 0
        if count > 0 {
            let alert = NSAlert()
            alert.messageText = "Delete “\(node.bookmark.title)”?"
            alert.informativeText = "It contains \(count) \(count == 1 ? "item" : "items"), which will be deleted too."
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Bookmarks.remove(at: node.path)
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(node.path.map(String.init).joined(separator: ","), forType: Self.pasteboardType)
        if let url = node.url { pasteboardItem.setString(url.absoluteString, forType: .string) }
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        var target = item as? Node
        // Dropping onto a bookmark means "next to it".
        if let link = target, link.children == nil, let position = link.path.last {
            target = outlineView.parent(forItem: link) as? Node
            outlineView.setDropItem(target, dropChildIndex: position)
        }
        if let source = draggedPath(info) {
            // Not into itself or one of its own subfolders.
            if let target, target.path.starts(with: source) { return [] }
            return .move
        }
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self]) ? .copy : []
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        let folder = (item as? Node)?.path ?? []
        let position = index == NSOutlineViewDropOnItemIndex ? nil : index
        if let node = item as? Node { expandedIDs.insert(node.bookmark.id) }
        if let source = draggedPath(info) {
            Bookmarks.move(source, to: folder, at: position)
            return true
        }
        // A link dragged in from a page or another app.
        guard let url = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return false }
        let path = Bookmarks.add(Bookmark(title: url.host() ?? "", kind: .link(url)), to: folder)
        if let position, let last = path.last, position < last { Bookmarks.move(path, to: folder, at: position) }
        return true
    }

    private func draggedPath(_ info: NSDraggingInfo) -> Bookmarks.Path? {
        guard info.draggingSource as? NSOutlineView === outlineView,
              let text = info.draggingPasteboard.string(forType: Self.pasteboardType) else { return nil }
        let path = text.split(separator: ",").compactMap { Int($0) }
        return path.isEmpty ? nil : path
    }

    // MARK: - Testing

    var debugRows: [String] {
        (0..<outlineView.numberOfRows).compactMap { row in
            guard let node = outlineView.item(atRow: row) as? Node else { return nil }
            return String(repeating: "  ", count: outlineView.level(forRow: row)) + (node.bookmark.title.isEmpty ? "(icon)" : node.bookmark.title)
        }
    }

    func debugSelect(_ title: String) {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? Node, node.bookmark.title == title {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
    }

    func debugExpandAll() {
        outlineView.expandItem(nil, expandChildren: true)
    }
}

extension BookmarksManagerController: NSMenuDelegate {
    /// Context menu for the right-clicked row (or the empty area).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        guard let node = targetNode, outlineView.clickedRow >= 0 else {
            add("New Folder", #selector(newFolder(_:)))
            return
        }
        if node.url != nil {
            add("Open", #selector(open(_:)))
            add("Open in New Tab", #selector(openInNewTab(_:)))
            menu.addItem(.separator())
            add("Rename", #selector(rename(_:)))
            add("Edit Address", #selector(editAddress(_:)))
            add(node.bookmark.pinned ? "Unpin from Quick Links" : "Pin to Quick Links", #selector(togglePinned(_:)))
        } else {
            add("Rename", #selector(rename(_:)))
        }
        add("Delete", #selector(delete(_:)))
        menu.addItem(.separator())
        // New Folder goes inside a right-clicked folder, or next to a right-clicked bookmark.
        outlineView.selectRowIndexes([outlineView.clickedRow], byExtendingSelection: false)
        add(node.children != nil ? "New Folder Inside" : "New Folder", #selector(newFolder(_:)))
    }
}

/// Return renames and ⌫ deletes, like Finder.
private final class ManagerOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()  // Return, Enter
        case 51, 117: onDelete?()  // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }
}

/// Text cell (with an icon in the name column); the text only becomes editable on request.
private final class ManagerCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.isEditable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        var constraints = [
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ]
        if showsIcon {
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
