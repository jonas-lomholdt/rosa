import AppKit

/// ⌘§: the window's tabs as a grid of previews over the whole window. H/J/K/L or the arrows move,
/// ↩ (or a click) switches to the highlighted tab, Esc goes back. X closes the highlighted tab,
/// U reopens the last closed one, F labels the cards to pick one by typing, 1–9 pick directly,
/// / searches titles and addresses (the field shows only then). The highlighted tab is live: its
/// real pages sit in its card, scaled down. The others are snapshots (`Tab.preview`), refreshed
/// when the overview opens and when the highlight leaves a tab.
final class TabOverviewView: NSView, NSTextFieldDelegate {
    var onSelect: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onReopenTab: (() -> Void)?

    private static let topInset: CGFloat = 52
    /// With the search field showing.
    private static let searchTopInset: CGFloat = 60
    private static let sideInset: CGFloat = 40
    private static let gap: CGFloat = 28
    private static let titleHeight: CGFloat = 30
    private static let minCardWidth: CGFloat = 200
    private static let maxCardWidth: CGFloat = 420
    private static let searchWidth: CGFloat = 420
    private static let searchHeight: CGFloat = 34

    private let background = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let grid = FlippedView()
    private let searchGlass = NSGlassEffectView()
    private let searchIcon = NSImageView()
    private let searchField = NSTextField()
    private let emptyLabel = NSTextField(labelWithString: "No tabs match")
    private var cards: [TabOverviewCard] = []
    private var tabs: [Tab] = []
    private(set) var highlightedIndex = 0
    /// Indices of the tabs the search leaves, in tab order (all of them without a search).
    private var visible: [Int] = []
    private var columns = 1
    /// Height / width of the page area, so cards have the shape of the tabs.
    private var aspect: CGFloat = 0.62
    /// F: labels on the visible cards; what's been typed so far, nil when not picking.
    private var hintTyped: String?
    private var hintLabels: [String] = []
    /// The tab shown live rather than as a snapshot (the highlighted one), and its real size.
    private var liveTab: Tab?
    private var liveSize: NSSize = .zero
    /// Tabs the highlight just left: still live until their fresh snapshot is in, so their card
    /// never flashes back to an older one.
    private var retiringTabs: [Tab] = []
    private var liveSwitch: DispatchWorkItem?

    var isShown: Bool { superview != nil }
    var isSearching: Bool { searchField.currentEditor() != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.material = .fullScreenUI
        background.blendingMode = .withinWindow
        background.state = .active
        addSubview(background)

        scrollView.documentView = grid
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)

        searchGlass.cornerRadius = Self.searchHeight / 2
        let searchContent = FlippedView()
        searchGlass.contentView = searchContent
        let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.image = symbol?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        searchIcon.contentTintColor = .secondaryLabelColor
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 14)
        searchField.placeholderString = "Search tabs"
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        searchContent.addSubview(searchIcon)
        searchContent.addSubview(searchField)
        searchGlass.isHidden = true
        addSubview(searchGlass)

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    // Swallows clicks between the cards, so they never reach the page underneath.
    override func mouseDown(with event: NSEvent) {}

    /// Covers `container` (the window's content view) with `tabs`, highlighting `selected`.
    /// `liveSize` is the size of the page area, which the live tab keeps inside its card.
    func show(in container: NSView, tabs: [Tab], selected: Int, liveSize: NSSize) {
        self.liveSize = liveSize
        let aspect = liveSize.width > 0 ? liveSize.height / liveSize.width : 0.62
        self.aspect = min(max(aspect, 0.35), 1.2)
        hintTyped = nil
        searchField.stringValue = ""
        searchGlass.isHidden = true
        frame = container.bounds
        autoresizingMask = [.width, .height]
        container.addSubview(self)
        highlightedIndex = selected
        update(tabs: tabs)
        updateLive(immediately: true)
        window?.makeFirstResponder(self)
        scrollToHighlighted()
    }

    /// Hands the live tab's view back (the caller puts it where it belongs) and goes.
    func close() {
        hintTyped = nil
        liveSwitch?.cancel()
        liveTab = nil
        retiringTabs = []
        cards.forEach { $0.liveView = nil }
        if isSearching { window?.makeFirstResponder(nil) }
        removeFromSuperview()
        tabs = []
        visible = []
        cards.forEach { $0.removeFromSuperview() }
        cards = []
    }

    /// Keyboard focus back after something else took it: the search field while searching.
    func takeFocus(searching: Bool? = nil) {
        if searching ?? !searchField.stringValue.isEmpty {
            if searchGlass.isHidden {
                searchGlass.isHidden = false
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
            window?.makeFirstResponder(searchField)
            searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.utf16.count, length: 0)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    /// The tabs changed (one closed or reopened, a title or icon came in). The highlight stays on
    /// its tab; if that tab is gone, on the one now in its place.
    func update(tabs newTabs: [Tab], highlight: Int? = nil) {
        let highlightedTab = tabs.indices.contains(highlightedIndex) ? tabs[highlightedIndex] : nil
        tabs = newTabs
        if let highlight {
            highlightedIndex = highlight
        } else if let highlightedTab, let index = newTabs.firstIndex(where: { $0 === highlightedTab }) {
            highlightedIndex = index
        }

        while cards.count < newTabs.count {
            let card = TabOverviewCard()
            card.onClick = { [weak self, weak card] in
                guard let self, let card, let index = cards.firstIndex(where: { $0 === card }) else { return }
                onSelect?(index)
            }
            card.onClose = { [weak self, weak card] in
                guard let self, let card, let index = cards.firstIndex(where: { $0 === card }) else { return }
                onCloseTab?(index)
            }
            grid.addSubview(card)
            cards.append(card)
        }
        while cards.count > newTabs.count {
            let card = cards.removeLast()
            card.liveView = nil
            card.removeFromSuperview()
        }
        applyFilter(highlightBest: false)
        updateLive(immediately: highlight != nil)
    }

    /// New snapshots came in.
    func refreshPreviews() {
        for (card, tab) in zip(cards, tabs) { card.preview = tab.preview }
    }

    private func isLive(_ tab: Tab) -> Bool { tab === liveTab || retiringTabs.contains { $0 === tab } }

    private func refreshCards() {
        // Detach first, so a live view never gets pulled out of the card it just moved to.
        for (card, tab) in zip(cards, tabs) where !isLive(tab) { card.liveView = nil }
        for (index, (card, tab)) in zip(cards, tabs).enumerated() {
            card.configure(title: tab.title, favicon: tab.favicon, preview: tab.preview)
            if isLive(tab) {
                card.liveSize = liveSize
                card.liveView = tab.container
            }
            card.isHighlighted = index == highlightedIndex
            let position = visible.firstIndex(of: index)
            card.isHidden = position == nil
            if let typed = hintTyped, let position, hintLabels.indices.contains(position) {
                let label = hintLabels[position]
                let matches = label.hasPrefix(typed)
                card.hint = matches ? label : nil
                card.alphaValue = matches ? 1 : 0.35
            } else {
                card.hint = nil
                card.alphaValue = 1
            }
        }
        emptyLabel.isHidden = !visible.isEmpty || tabs.isEmpty
    }

    // MARK: Search

    /// Keeps the tabs whose title or address matches every word of the search. Typing moves the
    /// highlight to the best match; otherwise it stays on its tab while that's still shown.
    private func applyFilter(highlightBest: Bool) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        var best: Int?
        if query.isEmpty {
            visible = Array(tabs.indices)
        } else {
            let candidates = tabs.enumerated().map { index, tab in
                // A data: address is the page itself, encoded: it would match nearly anything.
                let address = tab.displayURL.hasPrefix("data:") ? "" : tab.displayURL
                return CommandPaletteMatcher.Candidate(CommandPaletteItem(title: tab.title, keywords: address, perform: { _ in }), order: index)
            }
            let matches = CommandPaletteMatcher.matches(query, in: candidates)
            best = matches.first?.candidate.order
            visible = matches.map(\.candidate.order).sorted()
        }
        if highlightBest, let best {
            highlightedIndex = best
        } else if !visible.contains(highlightedIndex) {
            // The next shown tab after it, else the last one.
            highlightedIndex = visible.first { $0 > highlightedIndex } ?? visible.last ?? min(highlightedIndex, max(tabs.count - 1, 0))
        }
        if hintTyped != nil { hintLabels = LinkHints.labels(count: visible.count) }
        refreshCards()
        needsLayout = true
        updateLive(immediately: highlightBest)
    }

    private func startSearch() {
        endHints()
        takeFocus(searching: true)
    }

    /// Esc in the search: drops it and goes back to moving around all the tabs.
    private func endSearch() {
        searchField.stringValue = ""
        searchGlass.isHidden = true
        applyFilter(highlightBest: false)
        window?.makeFirstResponder(self)
        scrollToHighlighted()
    }

    /// Clicking away from an empty search puts the field away.
    func controlTextDidEndEditing(_ notification: Notification) {
        if searchField.stringValue.isEmpty, !searchGlass.isHidden {
            searchGlass.isHidden = true
            needsLayout = true
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        applyFilter(highlightBest: true)
        scrollToHighlighted()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveVertically(down: true)
        case #selector(NSResponder.moveUp(_:)): moveVertically(down: false)
        case #selector(NSResponder.insertTab(_:)): moveWrapping(by: 1)
        case #selector(NSResponder.insertBacktab(_:)): moveWrapping(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            if visible.contains(highlightedIndex) { onSelect?(highlightedIndex) } else { NSSound.beep() }
        case #selector(NSResponder.cancelOperation(_:)): endSearch()
        default: return false
        }
        return true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        background.frame = bounds
        let searchWidth = min(Self.searchWidth, bounds.width - Self.sideInset * 2)
        searchGlass.frame = NSRect(x: ((bounds.width - searchWidth) / 2).rounded(), y: 14, width: searchWidth, height: Self.searchHeight)
        searchIcon.frame = NSRect(x: 12, y: (Self.searchHeight - 16) / 2, width: 16, height: 16)
        let fieldHeight = searchField.intrinsicContentSize.height
        searchField.frame = NSRect(x: 34, y: ((Self.searchHeight - fieldHeight) / 2).rounded(), width: searchWidth - 34 - 14, height: fieldHeight)

        let top = searchGlass.isHidden ? Self.topInset : Self.searchTopInset
        let area = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        scrollView.frame = area
        let labelHeight = emptyLabel.intrinsicContentSize.height
        emptyLabel.frame = NSRect(x: 0, y: (area.minY + area.height * 0.4).rounded(), width: bounds.width, height: labelHeight)
        let width = max(0, area.width - Self.sideInset * 2)
        let height = max(0, area.height - Self.sideInset)
        let count = max(visible.count, 1)

        // The biggest cards that fit them all; past the minimum size, scroll instead.
        var choice: (columns: Int, cardWidth: CGFloat)?
        for columns in 1...count {
            let cardWidth = min(Self.maxCardWidth, (width - CGFloat(columns - 1) * Self.gap) / CGFloat(columns))
            guard cardWidth >= Self.minCardWidth || columns == 1 else { break }
            let rows = (count + columns - 1) / columns
            if gridHeight(rows: rows, cardWidth: cardWidth) <= height {
                choice = (columns, cardWidth)
                break
            }
        }
        if choice == nil {
            let columns = max(1, Int((width + Self.gap) / (Self.minCardWidth + Self.gap)))
            choice = (columns, min(Self.maxCardWidth, (width - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)))
        }
        let (columns, cardWidth) = choice!
        self.columns = columns
        let usedColumns = min(columns, count)
        let rows = (count + columns - 1) / columns
        let contentWidth = CGFloat(usedColumns) * cardWidth + CGFloat(usedColumns - 1) * Self.gap
        let contentHeight = gridHeight(rows: rows, cardWidth: cardWidth)
        let originX = ((area.width - contentWidth) / 2).rounded()
        // Centred while it fits, a little above the middle like a dialog. A search keeps the
        // cards at the top, under the field.
        // Room above the top row for the highlight ring.
        let centred = searchField.stringValue.isEmpty ? ((height - contentHeight) * 0.45).rounded() : 0
        let originY = max(12, centred)
        grid.frame = NSRect(x: 0, y: 0, width: area.width, height: max(area.height, originY + contentHeight + Self.sideInset))
        let cardHeight = (cardWidth * aspect).rounded() + Self.titleHeight
        for (position, index) in visible.enumerated() where cards.indices.contains(index) {
            let row = position / columns, column = position % columns
            cards[index].frame = NSRect(
                x: (originX + CGFloat(column) * (cardWidth + Self.gap)).rounded(),
                y: originY + CGFloat(row) * (cardHeight + Self.gap),
                width: cardWidth.rounded(), height: cardHeight
            )
        }
    }

    private func gridHeight(rows: Int, cardWidth: CGFloat) -> CGFloat {
        CGFloat(rows) * ((cardWidth * aspect).rounded() + Self.titleHeight) + CGFloat(rows - 1) * Self.gap
    }

    private func scrollToHighlighted() {
        layoutSubtreeIfNeeded()
        guard cards.indices.contains(highlightedIndex), visible.contains(highlightedIndex) else { return }
        grid.scrollToVisible(cards[highlightedIndex].frame.insetBy(dx: 0, dy: -Self.gap))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let characters = event.charactersIgnoringModifiers ?? ""
        if hintTyped != nil, handleHintKey(event, characters: characters) { return }
        guard modifiers.isSubset(of: [.shift]) else { return super.keyDown(with: event) }

        switch event.keyCode {
        case 53:  // Esc: drops a search first
            if searchField.stringValue.isEmpty { onCancel?() } else { endSearch() }
            return
        case 36, 76:  // ↩, enter
            if visible.contains(highlightedIndex) { onSelect?(highlightedIndex) } else { NSSound.beep() }
            return
        case 123: move(by: -1); return
        case 124: move(by: 1); return
        case 125: moveVertically(down: true); return
        case 126: moveVertically(down: false); return
        case 48: moveWrapping(by: modifiers.contains(.shift) ? -1 : 1); return  // ⇥
        case 51, 117: closeHighlighted(); return  // ⌫, ⌦
        default: break
        }
        switch characters {
        case "h": move(by: -1)
        case "l": move(by: 1)
        case "j": moveVertically(down: true)
        case "k": moveVertically(down: false)
        case "g": visible.first.map(setHighlight)
        case "G": visible.last.map(setHighlight)
        case "x", "d": closeHighlighted()
        case "u": onReopenTab?()
        case "f": startHints()
        case "/": startSearch()
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            // Like ⌘1–9: 9 is the last tab.
            let number = Int(characters)!
            let index = number == 9 ? tabs.count - 1 : number - 1
            if tabs.indices.contains(index) { onSelect?(index) } else { NSSound.beep() }
        default: super.keyDown(with: event)
        }
    }

    /// ⌃J / ⌃K / ⌃H / ⌃L (they otherwise move between panes).
    func handleVimKey(_ direction: BrowserWindowController.Direction) {
        switch direction {
        case .left: move(by: -1)
        case .right: move(by: 1)
        case .up: moveVertically(down: false)
        case .down: moveVertically(down: true)
        }
    }

    private func closeHighlighted() {
        if visible.contains(highlightedIndex) { onCloseTab?(highlightedIndex) } else { NSSound.beep() }
    }

    private func setHighlight(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        highlightedIndex = index
        for (i, card) in cards.enumerated() { card.isHighlighted = i == index }
        scrollToHighlighted()
        updateLive()
    }

    // MARK: Live tab

    /// Makes the highlighted tab the live one: its container moves into its card, at its real size
    /// and scaled down, so the page doesn't reflow and keeps playing. Holding a movement key only
    /// goes live where it stops. The tab left behind is snapshotted while it's still on screen.
    private func updateLive(immediately: Bool = false) {
        liveSwitch?.cancel()
        let target = visible.contains(highlightedIndex) ? tabs[highlightedIndex] : nil
        guard target !== liveTab else { return }
        guard !immediately else { return switchLive(to: target) }
        let work = DispatchWorkItem { [weak self] in self?.switchLive(to: target) }
        liveSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func switchLive(to target: Tab?) {
        guard isShown, target !== liveTab else { return }
        if let previous = liveTab, tabs.contains(where: { $0 === previous }) {
            retiringTabs.append(previous)
            Task { [weak self] in
                await previous.capturePreview()
                guard let self else { return }
                retiringTabs.removeAll { $0 === previous }
                refreshPreviews()
                refreshCards()
            }
        }
        liveTab = target
        refreshCards()
    }

    /// Movement goes through the cards on screen, in their order.
    private var position: Int? { visible.firstIndex(of: highlightedIndex) }

    private func move(by delta: Int) {
        guard !visible.isEmpty else { return }
        let target = (position ?? 0) + delta
        setHighlight(visible[min(max(target, 0), visible.count - 1)])
    }

    private func moveWrapping(by delta: Int) {
        guard !visible.isEmpty else { return }
        setHighlight(visible[((position ?? 0) + delta + visible.count) % visible.count])
    }

    /// Down from a row above a short last row lands on the last card.
    private func moveVertically(down: Bool) {
        guard !visible.isEmpty else { return }
        let current = position ?? 0
        let target = current + (down ? columns : -columns)
        if visible.indices.contains(target) {
            setHighlight(visible[target])
        } else if down, current / columns < (visible.count - 1) / columns {
            setHighlight(visible[visible.count - 1])
        }
    }

    // MARK: Hints

    private func startHints() {
        guard visible.count > 1 else {
            if let only = visible.first { onSelect?(only) }
            return
        }
        hintTyped = ""
        hintLabels = LinkHints.labels(count: visible.count)
        refreshCards()
    }

    private func endHints() {
        guard hintTyped != nil else { return }
        hintTyped = nil
        refreshCards()
    }

    /// While picking: letters narrow the labels, a full label switches to that tab, ⌫ takes one
    /// back, Esc stops picking. Returns false for keys that keep their usual meaning (↩, arrows).
    private func handleHintKey(_ event: NSEvent, characters: String) -> Bool {
        guard var typed = hintTyped else { return false }
        switch event.keyCode {
        case 53:
            endHints()
            return true
        case 51:
            if typed.isEmpty { endHints() } else { hintTyped?.removeLast(); refreshCards() }
            return true
        default:
            break
        }
        let character = characters.lowercased()
        guard character.count == 1, character.first?.isLetter == true else { return false }
        typed += character
        guard hintLabels.contains(where: { $0.hasPrefix(typed) }) else {
            NSSound.beep()
            return true
        }
        if let position = hintLabels.firstIndex(of: typed), visible.indices.contains(position) {
            hintTyped = nil
            onSelect?(visible[position])
            return true
        }
        hintTyped = typed
        refreshCards()
        return true
    }

    // MARK: Testing

    var debugTitles: [String] { tabs.map(\.title) }
    var debugVisibleTitles: [String] { visible.map { tabs[$0].title } }
    var debugColumns: Int { columns }
    var debugHints: [String?] { cards.filter { !$0.isHidden }.map(\.hint) }
    var debugPreviewSizes: [NSSize?] { cards.map { $0.preview?.size } }
    var debugCardFrames: [NSRect] { cards.map { $0.convert($0.bounds, to: self) } }
    var debugSearchField: NSTextField { searchField }
    /// Index of the card hosting the live tab, and that card's preview area in window coordinates.
    var debugLiveCard: (index: Int, frame: NSRect)? {
        guard let index = cards.firstIndex(where: { $0.liveView != nil }) else { return nil }
        return (index, cards[index].debugPreviewFrameInWindow)
    }
}

/// One tab in the overview: its preview (or favicon, before there is one) with the favicon and
/// title underneath. The highlighted card gets an accent ring; hovering shows a close button.
private final class TabOverviewCard: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

    private static let radius: CGFloat = 12

    private let previewBox = NSView()
    /// Holds the live tab's container at its real size, drawn scaled to the card (bounds scaling,
    /// so the page keeps its layout). Clicks go to the card, not the page.
    private let liveHost = LiveHostView()
    /// The snapshot over the live page while one turns into the other. The compositor scales the
    /// live page differently from the resampled snapshot (text weight, fine lines), so swapping
    /// them outright makes the card visibly jump; a short crossfade hides it.
    private let cover = NSView()
    private static let crossfade: TimeInterval = 0.2
    private let placeholder = NSImageView()
    private let ring = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintBadge = HintBadgeView()
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { closeButton.isHidden = !isHovered } }

    var preview: NSImage? {
        didSet {
            guard preview !== oldValue else { return }
            updatePreviewContents()
        }
    }

    /// The live tab's container, or nil to show the snapshot. Either way the change crossfades.
    var liveView: NSView? {
        didSet {
            guard liveView !== oldValue else { return }
            if let liveView {
                if let oldValue, oldValue.superview === liveHost { oldValue.removeFromSuperview() }
                // The snapshot stays on top until the page has drawn here, then fades away.
                fadeCover(from: 1, to: 0, delay: 0.03)
                liveHost.addSubview(liveView)
                liveHost.isHidden = false
            } else if let oldValue {
                // The snapshot (fresh, taken from the live page) fades in over it, then the page goes.
                fadeCover(from: 0, to: 1) { [weak self, weak oldValue] in
                    guard let self, liveView == nil else { return }
                    if let oldValue, oldValue.superview === liveHost { oldValue.removeFromSuperview() }
                    liveHost.isHidden = true
                    cover.alphaValue = 0
                }
            }
            updatePreviewContents()
            needsLayout = true
        }
    }

    private var fadeGeneration = 0

    private func fadeCover(from start: CGFloat, to end: CGFloat, delay: TimeInterval = 0, completion: (() -> Void)? = nil) {
        fadeGeneration += 1
        let generation = fadeGeneration
        cover.layer?.contents = preview
        cover.alphaValue = start
        // Without a snapshot there's nothing to fade.
        guard preview != nil else {
            cover.alphaValue = 0
            completion?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == fadeGeneration else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.crossfade
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.cover.animator().alphaValue = end
            }, completionHandler: { [weak self] in
                guard let self, generation == fadeGeneration else { return }
                completion?()
            })
        }
    }

    var liveSize: NSSize = .zero { didSet { if liveSize != oldValue { needsLayout = true } } }

    private func updatePreviewContents() {
        // Also behind the live page: its margins are transparent, as they are in the snapshot.
        previewBox.layer?.contents = preview
        placeholder.isHidden = preview != nil || liveView != nil
    }

    var isHighlighted = false {
        didSet {
            ring.isHidden = !isHighlighted
            titleLabel.textColor = isHighlighted ? .labelColor : .secondaryLabelColor
        }
    }

    var hint: String? {
        didSet {
            hintBadge.text = hint?.uppercased() ?? ""
            hintBadge.isHidden = hint == nil
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ring.wantsLayer = true
        ring.layer?.cornerRadius = Self.radius + 4
        ring.layer?.borderWidth = 3
        ring.isHidden = true

        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = Self.radius
        previewBox.layer?.masksToBounds = true
        previewBox.layer?.contentsGravity = .resizeAspectFill
        previewBox.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()

        placeholder.imageScaling = .scaleProportionallyUpOrDown
        placeholder.contentTintColor = .tertiaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true

        hintBadge.isHidden = true

        let symbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab")
        closeButton.image = symbol?.withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"
        closeButton.isHidden = true

        liveHost.isHidden = true
        previewBox.addSubview(liveHost)
        cover.wantsLayer = true
        cover.layer?.contentsGravity = .resizeAspectFill
        cover.alphaValue = 0
        previewBox.addSubview(cover)
        for view in [ring, previewBox, placeholder, iconView, titleLabel, hintBadge, closeButton] { addSubview(view) }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(title: String, favicon: NSImage?, preview: NSImage?) {
        if titleLabel.stringValue != title { needsLayout = true }
        titleLabel.stringValue = title
        toolTip = title
        let icon = favicon ?? FaviconStore.placeholder
        iconView.image = icon
        placeholder.image = icon
        self.preview = preview
    }

    override func layout() {
        super.layout()
        let previewHeight = bounds.height - 30
        let previewFrame = NSRect(x: 0, y: 0, width: bounds.width, height: previewHeight)
        previewBox.frame = previewFrame
        cover.frame = previewBox.bounds
        if let liveView, liveSize.width > 0, liveSize.height > 0 {
            liveHost.frame = previewBox.bounds
            liveHost.bounds = NSRect(origin: .zero, size: liveSize)
            liveView.frame = NSRect(origin: .zero, size: liveSize)
        }
        ring.frame = previewFrame.insetBy(dx: -5, dy: -5)
        let placeholderSize = min(48, previewHeight / 3)
        placeholder.frame = NSRect(x: (previewFrame.midX - placeholderSize / 2).rounded(), y: (previewFrame.midY - placeholderSize / 2).rounded(),
                                   width: placeholderSize, height: placeholderSize)
        closeButton.frame = NSRect(x: 6, y: 6, width: 24, height: 24)

        // The cell's size, not the intrinsic one: that comes out a few points short, and the
        // label then truncates even a short title to "…".
        let titleSize = titleLabel.cell?.cellSize ?? titleLabel.intrinsicContentSize
        let titleHeight = titleSize.height
        let titleY = previewHeight + ((30 - titleHeight) / 2).rounded() + 2
        let textWidth = min(titleSize.width.rounded(.up), bounds.width - 22)
        let rowWidth = 16 + 6 + textWidth
        let rowX = ((bounds.width - rowWidth) / 2).rounded()
        iconView.frame = NSRect(x: rowX, y: previewHeight + ((30 - 16) / 2).rounded() + 2, width: 16, height: 16)
        titleLabel.frame = NSRect(x: rowX + 22, y: titleY, width: max(0, textWidth), height: titleHeight)

        let hintSize = hintBadge.fittingSize
        hintBadge.frame = NSRect(x: (previewFrame.midX - hintSize.width / 2).rounded(), y: (previewFrame.midY - hintSize.height / 2).rounded(),
                                 width: hintSize.width, height: hintSize.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
            // The same live or not, so the panes' margins don't change colour when it switches.
            previewBox.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Only a click that started on this card picks it (not the end of a click that activated the window).
    private var isPressed = false

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        guard isPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click closes, like on a tab.
        if event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeClicked() { onClose?() }

    var debugPreviewFrameInWindow: NSRect { previewBox.convert(previewBox.bounds, to: nil) }
}

/// A link-hint style label: the letters centred on their capital height (a text field centres the
/// whole line, descender included, so capitals sit high).
private final class HintBadgeView: NSView {
    private static let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .bold)
    private static let padding = NSSize(width: 9, height: 7)

    var text = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let width = (text as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: (width + Self.padding.width * 2).rounded(.up),
                      height: (Self.font.capHeight + Self.padding.height * 2).rounded(.up))
    }

    override func draw(_ dirtyRect: NSRect) {
        (NSColor(hex: Settings.linkHintColor) ?? .systemYellow).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.black]
        let width = (text as NSString).size(withAttributes: attributes).width
        // Drawing at a point puts the line's top there; the baseline is `ascender` below it.
        let baseline = bounds.midY + Self.font.capHeight / 2
        (text as NSString).draw(at: NSPoint(x: bounds.midX - width / 2, y: baseline - Self.font.ascender), withAttributes: attributes)
    }
}

/// Flipped, like the tab's usual parent, and transparent to clicks.
private final class LiveHostView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
