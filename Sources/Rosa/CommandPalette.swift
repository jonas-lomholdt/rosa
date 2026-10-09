import AppKit

/// One row in the command palette: something to search for and what happens when it's picked.
struct CommandPaletteItem {
    var title: String
    var subtitle = ""
    var icon: NSImage?
    /// Fetches a better icon once the row is on screen (favicons).
    var loadIcon: (@MainActor () async -> NSImage?)?
    /// Matched as well as the title (a URL, a folder), but ranked below title matches.
    var keywords = ""
    /// Shown at the right edge, e.g. "⌃⌘Z".
    var shortcut = ""
    /// Hand focus back to where it was before running (menu commands act on the focused pane).
    var restoresFocus = false
    /// Runs the item; `inBackground` is ⌘↩ (e.g. open a bookmark where ⌘-clicked links go).
    var perform: (_ inBackground: Bool) -> Void
}

/// Supplies palette items: bookmarks and menu commands today; open tabs or history can
/// become further sources without touching the palette itself.
@MainActor
protocol CommandPaletteSource {
    func items() -> [CommandPaletteItem]
}

/// What the palette searches. The first mode is the default; typing another mode's prefix
/// switches to it (`>` for commands, as in VS Code), and deleting the prefix switches back.
struct CommandPaletteMode {
    /// Typed first to enter this mode; empty for the default mode.
    var prefix = ""
    var sources: [CommandPaletteSource]
    /// Shown in the empty field (only the default mode's is ever visible).
    var placeholder = ""
    var emptyText: String
    /// SF Symbol in front of the field.
    var symbol = "magnifyingglass"
    /// An extra row made from the query itself (open it as an address, search for it): first
    /// when `first`, else after the matches.
    var queryItem: ((String) -> (item: CommandPaletteItem, first: Bool)?)?
}

// MARK: - Matching

/// Ranks items against a query. Every space-separated term must match the title (prefix > word
/// start > substring > letters in order) or the keywords (substring). Case and accents are ignored.
enum CommandPaletteMatcher {
    /// An item prepared once per palette opening, so each keystroke only compares characters.
    final class Candidate {
        let item: CommandPaletteItem
        let order: Int
        let title: [Character]
        let keywords: [Character]
        var icon: NSImage?
        var isLoadingIcon = false

        init(_ item: CommandPaletteItem, order: Int) {
            self.item = item
            self.order = order
            title = CommandPaletteMatcher.fold(item.title)
            keywords = CommandPaletteMatcher.fold(item.keywords)
            icon = item.icon
        }
    }

    struct Match {
        let candidate: Candidate
        let score: Int
        /// Indices into the title's characters to highlight.
        let highlights: Set<Int>
    }

    /// Case- and accent-insensitive characters, index-aligned with the original string where possible.
    static func fold(_ text: String) -> [Character] {
        let folded = Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        if folded.count == text.count { return folded }
        return text.map { $0.lowercased().first ?? $0 }
    }

    static func matches(_ query: String, in candidates: [Candidate]) -> [Match] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !terms.isEmpty else {
            return candidates.map { Match(candidate: $0, score: 0, highlights: []) }
        }
        var results: [Match] = []
        for candidate in candidates {
            var total = 0
            var highlights = Set<Int>()
            var matchedAll = true
            for term in terms {
                if let (score, indices) = titleMatch(term, in: candidate.title) {
                    total += score
                    highlights.formUnion(indices)
                } else if let start = substring(term, in: candidate.keywords) {
                    total += isWordStart(start, in: candidate.keywords) ? 350 : 300
                } else {
                    matchedAll = false
                    break
                }
            }
            if matchedAll { results.append(Match(candidate: candidate, score: total, highlights: highlights)) }
        }
        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.candidate.title.count != b.candidate.title.count { return a.candidate.title.count < b.candidate.title.count }
            return a.candidate.order < b.candidate.order
        }
        return results
    }

    private static func titleMatch(_ term: [Character], in text: [Character]) -> (Int, [Int])? {
        // Best substring occurrence: the start of the title, then the start of a word, then anywhere.
        var best: (score: Int, start: Int)?
        var searchFrom = 0
        while let start = substring(term, in: text, from: searchFrom) {
            let score = start == 0 ? 1000 : isWordStart(start, in: text) ? 900 - min(start, 50) : 700 - min(start, 50)
            if score > (best?.score ?? .min) { best = (score, start) }
            if start == 0 { break }
            searchFrom = start + 1
        }
        if let best { return (best.score, Array(best.start..<best.start + term.count)) }

        // Letters in order ("gh" → "GitHub"), preferring tight matches near the start.
        var indices: [Int] = []
        var position = 0
        for character in term {
            while position < text.count, text[position] != character { position += 1 }
            guard position < text.count else { return nil }
            indices.append(position)
            position += 1
        }
        let gaps = (indices.last ?? 0) - (indices.first ?? 0) + 1 - term.count
        let wordStarts = indices.filter { isWordStart($0, in: text) }.count
        return (max(1, 400 + wordStarts * 20 - gaps * 5 - min(indices.first ?? 0, 50)), indices)
    }

    private static func substring(_ term: [Character], in text: [Character], from: Int = 0) -> Int? {
        guard !term.isEmpty, term.count <= text.count, from <= text.count - term.count else { return nil }
        outer: for start in from...(text.count - term.count) {
            for offset in 0..<term.count where text[start + offset] != term[offset] { continue outer }
            return start
        }
        return nil
    }

    private static func isWordStart(_ index: Int, in text: [Character]) -> Bool {
        index == 0 || !(text[index - 1].isLetter || text[index - 1].isNumber)
    }
}

// MARK: - View

/// A search field over a list of items, floating near the top of the window (⌘⇧P). Typing
/// filters instantly; ↑/↓ (⌃P/⌃N, ⌃K/⌃J) move, ↩ runs the item, ⌘↩ runs it in the background,
/// Esc or clicking elsewhere closes it.
final class CommandPaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let width: CGFloat = 620
    private static let fieldHeight: CGFloat = 52
    private static let rowHeight: CGFloat = 44
    private static let maxVisibleRows = 8
    private static let listPadding: CGFloat = 6

    private let glass = NSGlassEffectView()
    private let searchIcon = NSImageView()
    private let field = NSTextField()
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")

    /// Each mode with its items, collected once per opening.
    private var modes: [(mode: CommandPaletteMode, candidates: [CommandPaletteMatcher.Candidate])] = []
    private var modeIndex = 0
    private var candidates: [CommandPaletteMatcher.Candidate] { modes.indices.contains(modeIndex) ? modes[modeIndex].candidates : [] }
    private var results: [CommandPaletteMatcher.Match] = []
    /// Whoever had focus before opening, to give it back on Esc.
    private weak var previousResponder: NSResponder?
    private var isClosing = false

    var isShown: Bool { superview != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            return shadow
        }()

        glass.cornerRadius = 18
        glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55)
        glass.autoresizingMask = [.width, .height]
        let content = FlippedView()
        glass.contentView = content
        addSubview(glass)

        searchIcon.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self

        separator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: Self.listPadding, left: 0, bottom: Self.listPadding, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        for view in [searchIcon, field, separator, scrollView, emptyLabel] { content.addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Showing

    /// Opens over `container` (a flipped view) with the sources' current items. `query` starts the
    /// field off, e.g. with a mode's prefix to open in that mode.
    func show(in container: NSView, modes: [CommandPaletteMode], query: String = "") {
        if isShown { close(restoringFocus: false) }
        // Collected before the field takes focus, so menu commands validate against the page.
        self.modes = modes.map { mode in
            let items = mode.sources.flatMap { $0.items() }
            return (mode, items.enumerated().map { CommandPaletteMatcher.Candidate($1, order: $0) })
        }
        modeIndex = 0
        setSymbol(modes.first?.symbol)
        field.placeholderString = modes.first?.placeholder
        field.stringValue = query

        let window = container.window
        let responder = window?.firstResponder
        // The field editor stands in for the text field being edited (e.g. the address bar).
        previousResponder = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSResponder : $0 } ?? responder

        isClosing = false
        container.addSubview(self)
        filter()
        window?.makeFirstResponder(field)
        // Focusing selects the text; put the caret after it so typing adds to the prefix.
        field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
    }

    /// The prefix of the mode the palette is in (`""` for the first), or nil when it's closed.
    var modePrefix: String? { modes.indices.contains(modeIndex) ? modes[modeIndex].mode.prefix : nil }

    /// Replaces the query, switching mode if it starts with another mode's prefix.
    func setQuery(_ query: String) {
        if let editor = field.currentEditor() {
            editor.string = query
            editor.selectedRange = NSRange(location: (query as NSString).length, length: 0)
        } else {
            field.stringValue = query
        }
        filter()
    }

    func close(restoringFocus: Bool) {
        guard isShown, !isClosing else { return }
        isClosing = true
        let window = self.window
        removeFromSuperview()
        modes = []
        results = []
        table.reloadData()
        if restoringFocus, let previous = previousResponder, let window,
           (previous as? NSView)?.window === window || previous === window {
            window.makeFirstResponder(previous)
        }
        previousResponder = nil
        isClosing = false
    }

    // MARK: Layout

    private func updateFrame() {
        guard let container = superview else { return }
        let rows = min(results.count, Self.maxVisibleRows)
        // With no results, one row's room for the empty-state hint or "No matches".
        let listHeight = results.isEmpty ? Self.rowHeight : CGFloat(rows) * Self.rowHeight + Self.listPadding * 2
        let height = Self.fieldHeight + 1 + listHeight
        let width = min(Self.width, container.bounds.width - 32)
        let top = min(max(64, (container.bounds.height * 0.16).rounded()), max(16, container.bounds.height - height - 16))
        frame = NSRect(x: ((container.bounds.width - width) / 2).rounded(), y: top, width: width, height: height)
        glass.frame = bounds
        needsLayout = true
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        glass.frame = bounds
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        updateFrame()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        searchIcon.frame = NSRect(x: 18, y: (Self.fieldHeight - 22) / 2, width: 22, height: 22)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: 48, y: ((Self.fieldHeight - fieldHeight) / 2).rounded(), width: width - 48 - 18, height: fieldHeight)
        separator.frame = NSRect(x: 0, y: Self.fieldHeight, width: width, height: 1)
        let listFrame = NSRect(x: 0, y: Self.fieldHeight + 1, width: width, height: max(0, bounds.height - Self.fieldHeight - 1))
        scrollView.frame = listFrame
        table.tableColumns.first?.width = listFrame.width
        let labelHeight = emptyLabel.intrinsicContentSize.height
        emptyLabel.frame = NSRect(x: 16, y: listFrame.minY + ((listFrame.height - labelHeight) / 2).rounded(),
                                  width: max(0, width - 32), height: labelHeight)
    }

    // MARK: Filtering & selection

    private func filter() {
        var query = field.stringValue
        let index = modes.lastIndex { !$0.mode.prefix.isEmpty && query.hasPrefix($0.mode.prefix) } ?? 0
        if index != modeIndex, modes.indices.contains(index) {
            modeIndex = index
            setSymbol(modes[index].mode.symbol)
        }
        if let prefix = modes.indices.contains(modeIndex) ? modes[modeIndex].mode.prefix : nil {
            query.removeFirst(min(prefix.count, query.count))
        }
        results = CommandPaletteMatcher.matches(query, in: candidates)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let make = modes.indices.contains(modeIndex) ? modes[modeIndex].mode.queryItem : nil,
           let (item, first) = make(trimmed) {
            let match = CommandPaletteMatcher.Match(candidate: .init(item, order: -1), score: 0, highlights: [])
            results.insert(match, at: first ? 0 : results.count)
        }
        table.reloadData()
        let hasList = !results.isEmpty
        scrollView.isHidden = !hasList
        emptyLabel.isHidden = hasList
        emptyLabel.stringValue = candidates.isEmpty ? (modes.indices.contains(modeIndex) ? modes[modeIndex].mode.emptyText : "") : "No matches"
        if hasList { select(0) }
        updateFrame()
    }

    private func setSymbol(_ name: String?) {
        let symbol = NSImage(systemSymbolName: name ?? "magnifyingglass", accessibilityDescription: nil)
        searchIcon.image = symbol?.withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
    }

    private func select(_ row: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(row, 0), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = table.selectedRow
        select(current < 0 ? 0 : (current + delta + results.count) % results.count)
    }

    /// ⌃J / ⌃K (they otherwise move between panes).
    func handleVimKey(down: Bool) { moveSelection(by: down ? 1 : -1) }

    private func performSelected(inBackground: Bool) {
        let row = table.selectedRow
        guard results.indices.contains(row) else { return NSSound.beep() }
        let item = results[row].candidate.item
        // In the background, focus goes back to where it was; otherwise the item takes it.
        close(restoringFocus: inBackground || item.restoresFocus)
        item.perform(inBackground)
    }

    @objc private func rowClicked() {
        guard results.indices.contains(table.clickedRow) else { return }
        select(table.clickedRow)
        performSelected(inBackground: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) { filter() }

    /// Clicking into the page or the chrome ends editing: close, leaving focus where the click put it.
    func controlTextDidEndEditing(_ notification: Notification) { close(restoringFocus: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let commandDown = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            moveSelection(by: Self.maxVisibleRows)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            moveSelection(by: -Self.maxVisibleRows)
        case #selector(NSResponder.insertNewline(_:)): performSelected(inBackground: commandDown)
        case #selector(NSResponder.cancelOperation(_:)): close(restoringFocus: true)
        case Selector(("noop:")):
            // ⌘↩ has no binding of its own.
            guard let event = NSApp.currentEvent, commandDown, [36, 76].contains(event.keyCode) else { return false }
            performSelected(inBackground: true)
        default:
            return false
        }
        return true
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PaletteCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? PaletteCellView ?? {
            let cell = PaletteCellView()
            cell.identifier = identifier
            return cell
        }()
        let match = results[row]
        let candidate = match.candidate
        cell.configure(item: candidate.item, highlights: match.highlights, icon: candidate.icon ?? FaviconStore.placeholder)
        if candidate.icon == nil, !candidate.isLoadingIcon, let load = candidate.item.loadIcon {
            candidate.isLoadingIcon = true
            Task { @MainActor [weak self, weak candidate] in
                guard let icon = await load(), let candidate else { return }
                candidate.icon = icon
                guard let self, let row = results.firstIndex(where: { $0.candidate === candidate }) else { return }
                table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }
        return cell
    }

    // MARK: Testing

    var debugQuery: String { field.stringValue }
    var debugResults: [String] { results.map(\.candidate.item.title) }
    var debugShortcuts: [String] { results.map(\.candidate.item.shortcut) }
    func debugSetQuery(_ query: String) { setQuery(query) }
    var debugSelectedTitle: String? {
        results.indices.contains(table.selectedRow) ? results[table.selectedRow].candidate.item.title : nil
    }
}

/// Selected rows get an accent-coloured rounded highlight, like Spotlight.
private final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

/// Icon, title (matched letters in bold) and a dimmer subtitle.
private final class PaletteCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var title = ""
    private var highlights = Set<Int>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
        }
        subtitleLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.font = .systemFont(ofSize: 13)
        shortcutLabel.alignment = .right
        for view in [iconView, titleLabel, subtitleLabel, shortcutLabel] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(item: CommandPaletteItem, highlights: Set<Int>, icon: NSImage) {
        title = item.title
        self.highlights = highlights
        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.isHidden = item.subtitle.isEmpty
        shortcutLabel.stringValue = item.shortcut
        shortcutLabel.isHidden = item.shortcut.isEmpty
        iconView.image = icon
        applyColors()
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        let color: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let attributed = NSMutableAttributedString()
        for (index, character) in title.enumerated() {
            let bold = highlights.contains(index)
            attributed.append(NSAttributedString(string: String(character), attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: bold ? .bold : .regular),
                .foregroundColor: color,
            ]))
        }
        titleLabel.attributedStringValue = attributed
        subtitleLabel.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        shortcutLabel.textColor = subtitleLabel.textColor
        iconView.contentTintColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let insetX: CGFloat = 18
        iconView.frame = NSRect(x: insetX, y: ((bounds.height - 18) / 2).rounded(), width: 18, height: 18)
        let textX = insetX + 18 + 12
        var textWidth = max(0, bounds.width - textX - insetX)
        if !shortcutLabel.isHidden {
            let size = shortcutLabel.intrinsicContentSize
            shortcutLabel.frame = NSRect(x: bounds.width - insetX - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                                         width: size.width, height: size.height)
            textWidth = max(0, shortcutLabel.frame.minX - 12 - textX)
        }
        let titleHeight = titleLabel.intrinsicContentSize.height
        if subtitleLabel.isHidden {
            titleLabel.frame = NSRect(x: textX, y: ((bounds.height - titleHeight) / 2).rounded(), width: textWidth, height: titleHeight)
        } else {
            let subtitleHeight = subtitleLabel.intrinsicContentSize.height
            let top = ((bounds.height - titleHeight - subtitleHeight) / 2).rounded()
            titleLabel.frame = NSRect(x: textX, y: top, width: textWidth, height: titleHeight)
            subtitleLabel.frame = NSRect(x: textX, y: top + titleHeight, width: textWidth, height: subtitleHeight)
        }
    }
}

// MARK: - Sources

/// Every bookmark (folders flattened), opened like a click on the bookmarks bar.
struct BookmarksPaletteSource: CommandPaletteSource {
    /// The URL and whether to open it in the background.
    let open: (URL, Bool) -> Void

    func items() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        func collect(_ list: [Bookmark], folders: [String]) {
            for bookmark in list {
                switch bookmark.kind {
                case .link(let url):
                    let address = Self.displayAddress(url)
                    let folderPath = folders.joined(separator: " › ")
                    items.append(CommandPaletteItem(
                        title: bookmark.title.isEmpty ? (url.host() ?? address) : bookmark.title,
                        subtitle: folderPath.isEmpty ? address : "\(folderPath)  ·  \(address)",
                        icon: FaviconStore.shared.cachedIcon(forHost: url.host()),
                        loadIcon: { await FaviconStore.shared.icon(forSite: url) },
                        keywords: "\(folderPath) \(url.absoluteString)",
                        perform: { [open] background in open(url, background) }
                    ))
                case .folder(let children):
                    collect(children, folders: folders + [bookmark.title])
                }
            }
        }
        collect(Bookmarks.items, folders: [])
        return items
    }

    /// Typed text as a row: "Open example.com" first when it's an address, else "Search Google
    /// for …" after the bookmarks. Loads like the address bar does.
    static func queryItem(_ text: String, open: @escaping (URL, Bool) -> Void) -> (item: CommandPaletteItem, first: Bool)? {
        if let url = Settings.addressURL(fromUserInput: text) {
            var item = CommandPaletteItem(
                title: "Open \(text)", subtitle: url.absoluteString,
                icon: FaviconStore.shared.cachedIcon(forHost: url.host()),
                perform: { background in open(url, background) }
            )
            if url.host() != nil {
                item.loadIcon = { await FaviconStore.shared.icon(forSite: url) }
            }
            return (item, true)
        }
        guard let url = Settings.url(fromUserInput: text) else { return nil }
        let item = CommandPaletteItem(
            title: "Search \(Settings.searchEngine.name) for “\(text)”",
            icon: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil),
            perform: { background in open(url, background) }
        )
        return (item, false)
    }

    /// `https://www.example.com/path/` → `example.com/path`.
    private static func displayAddress(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// Every enabled main menu command, with its shortcut and a checkmark when it's on, run as if
/// picked from the menu (so new menu items show up here by themselves).
struct MenuCommandsPaletteSource: CommandPaletteSource {
    /// Text editing would act on the palette's own field, the palette shouldn't list itself, and
    /// ⌘1–9 are quicker than nine "Select Tab" rows.
    private static let excluded: Set<Selector> = [
        Selector(("undo:")), Selector(("redo:")), #selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
        #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)), Selector(("startDictation:")),
        #selector(NSApplication.orderFrontCharacterPalette(_:)), #selector(BrowserWindowController.showCommandPalette(_:)),
        #selector(BrowserWindowController.searchBookmarks(_:)),
        #selector(BrowserWindowController.selectTabByNumber(_:)),
    ]
    private static let checkmark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "On")
    /// Keeps titles aligned when there's no checkmark.
    private static let noIcon = NSImage(size: NSSize(width: 18, height: 18))

    func items() -> [CommandPaletteItem] {
        guard let main = NSApp.mainMenu else { return [] }
        var items: [CommandPaletteItem] = []
        func collect(_ menu: NSMenu, path: [String]) {
            menu.delegate?.menuNeedsUpdate?(menu)  // menus filled when opened (Rosa → Extensions)
            menu.update()  // validates: enabled state, checkmarks, titles like "Exit Full Screen"
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let submenu = item.submenu {
                    collect(submenu, path: path + [item.title])
                    continue
                }
                // Window list entries target their window; private actions come from AppKit's own items.
                guard let action = item.action, item.isEnabled, !Self.excluded.contains(action),
                      !NSStringFromSelector(action).hasPrefix("_"), !(item.target is NSWindow) else { continue }
                let folder = path.joined(separator: " › ")
                items.append(CommandPaletteItem(
                    title: item.title,
                    subtitle: folder,
                    icon: item.state == .on ? Self.checkmark : Self.noIcon,
                    keywords: folder,
                    shortcut: item.shortcutText ?? "",
                    restoresFocus: true,
                    perform: { [weak item] _ in
                        guard let item, let menu = item.menu else { return }
                        menu.performActionForItem(at: menu.index(of: item))
                    }
                ))
            }
        }
        // The app menu (About, Quit) last: it's the least useful.
        let holders = main.items.dropFirst() + main.items.prefix(1)
        for holder in holders {
            if let submenu = holder.submenu { collect(submenu, path: [holder.title]) }
        }
        return items
    }
}

extension NSMenuItem {
    /// Menu-style shortcut text, e.g. "⌃⌘Z" or "⌥⌘←"; nil without a key equivalent.
    var shortcutText: String? {
        guard !keyEquivalent.isEmpty else { return nil }
        var modifiers = keyEquivalentModifierMask
        var key = keyEquivalent
        // An uppercase key equivalent implies Shift.
        if key != key.lowercased() { modifiers.insert(.shift) }
        let names: [Int: String] = [
            NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→", NSUpArrowFunctionKey: "↑",
            NSDownArrowFunctionKey: "↓", NSF12FunctionKey: "F12", NSBackTabCharacter: "⇥", 0x09: "⇥", 0x0d: "↩",
        ]
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, let name = names[Int(scalar.value)] {
            key = name
        } else {
            key = key.uppercased()
        }
        // macOS moves some shortcuts to the Globe key (Enter Full Screen becomes 🌐F).
        var text = modifiers.contains(.function) ? "🌐" : ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }
}
