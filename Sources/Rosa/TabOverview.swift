import AppKit

/// ⌘§: the window's tabs as a grid of previews over the whole window. H/J/K/L or the arrows move,
/// ↩ (or a click) switches to the highlighted tab, Esc goes back. X closes the highlighted tab,
/// U reopens the last closed one, F labels the cards to pick one by typing, 1–9 pick directly.
/// Previews are snapshots (`Tab.preview`), not live pages: the controller refreshes them on opening.
final class TabOverviewView: NSView {
    var onSelect: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onReopenTab: (() -> Void)?

    private static let topInset: CGFloat = 52
    private static let sideInset: CGFloat = 40
    private static let gap: CGFloat = 28
    private static let titleHeight: CGFloat = 30
    private static let minCardWidth: CGFloat = 200
    private static let maxCardWidth: CGFloat = 420

    private let background = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let grid = FlippedView()
    private var cards: [TabOverviewCard] = []
    private var tabs: [Tab] = []
    private(set) var highlightedIndex = 0
    private var columns = 1
    /// Height / width of the page area, so cards have the shape of the tabs.
    private var aspect: CGFloat = 0.62
    /// F: labels on the cards; what's been typed so far, nil when not picking.
    private var hintTyped: String?
    private var hintLabels: [String] = []

    var isShown: Bool { superview != nil }

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    // Swallows clicks between the cards, so they never reach the page underneath.
    override func mouseDown(with event: NSEvent) {}

    /// Covers `container` (the window's content view) with `tabs`, highlighting `selected`.
    func show(in container: NSView, tabs: [Tab], selected: Int, aspect: CGFloat) {
        self.aspect = min(max(aspect, 0.35), 1.2)
        hintTyped = nil
        frame = container.bounds
        autoresizingMask = [.width, .height]
        container.addSubview(self)
        highlightedIndex = selected
        update(tabs: tabs)
        window?.makeFirstResponder(self)
        scrollToHighlighted()
    }

    func close() {
        hintTyped = nil
        removeFromSuperview()
        tabs = []
        cards.forEach { $0.removeFromSuperview() }
        cards = []
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
        highlightedIndex = min(max(highlightedIndex, 0), max(newTabs.count - 1, 0))

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
        while cards.count > newTabs.count { cards.removeLast().removeFromSuperview() }
        if hintTyped != nil { hintLabels = LinkHints.labels(count: newTabs.count) }
        refreshCards()
        needsLayout = true
    }

    /// New snapshots came in.
    func refreshPreviews() {
        for (card, tab) in zip(cards, tabs) { card.preview = tab.preview }
    }

    private func refreshCards() {
        for (index, (card, tab)) in zip(cards, tabs).enumerated() {
            card.configure(title: tab.title, favicon: tab.favicon, preview: tab.preview)
            card.isHighlighted = index == highlightedIndex
            if let typed = hintTyped, hintLabels.indices.contains(index) {
                let label = hintLabels[index]
                let matches = label.hasPrefix(typed)
                card.hint = matches ? label : nil
                card.alphaValue = matches ? 1 : 0.35
            } else {
                card.hint = nil
                card.alphaValue = 1
            }
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        background.frame = bounds
        let area = NSRect(x: 0, y: Self.topInset, width: bounds.width, height: max(0, bounds.height - Self.topInset))
        scrollView.frame = area
        let width = max(0, area.width - Self.sideInset * 2)
        let height = max(0, area.height - Self.sideInset)
        let count = max(tabs.count, 1)

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
        // Centred while it fits, a little above the middle like a dialog.
        let originY = max(0, ((height - contentHeight) * 0.45).rounded())
        grid.frame = NSRect(x: 0, y: 0, width: area.width, height: max(area.height, originY + contentHeight + Self.sideInset))
        let cardHeight = (cardWidth * aspect).rounded() + Self.titleHeight
        for (index, card) in cards.enumerated() {
            let row = index / columns, column = index % columns
            card.frame = NSRect(
                x: originX + CGFloat(column) * (cardWidth + Self.gap),
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
        guard cards.indices.contains(highlightedIndex) else { return }
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
        case 53: onCancel?(); return  // Esc
        case 36, 76: onSelect?(highlightedIndex); return  // ↩, enter
        case 123: move(by: -1); return
        case 124: move(by: 1); return
        case 125: moveVertically(down: true); return
        case 126: moveVertically(down: false); return
        case 48: moveWrapping(by: modifiers.contains(.shift) ? -1 : 1); return  // ⇥
        case 51, 117: onCloseTab?(highlightedIndex); return  // ⌫, ⌦
        default: break
        }
        switch characters {
        case "h": move(by: -1)
        case "l": move(by: 1)
        case "j": moveVertically(down: true)
        case "k": moveVertically(down: false)
        case "g": setHighlight(0)
        case "G": setHighlight(tabs.count - 1)
        case "x", "d": onCloseTab?(highlightedIndex)
        case "u": onReopenTab?()
        case "f": startHints()
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

    private func setHighlight(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        highlightedIndex = index
        for (i, card) in cards.enumerated() { card.isHighlighted = i == index }
        scrollToHighlighted()
    }

    private func move(by delta: Int) { setHighlight(min(max(highlightedIndex + delta, 0), tabs.count - 1)) }

    private func moveWrapping(by delta: Int) {
        guard !tabs.isEmpty else { return }
        setHighlight((highlightedIndex + delta + tabs.count) % tabs.count)
    }

    /// Down from a row above a short last row lands on the last card.
    private func moveVertically(down: Bool) {
        let target = highlightedIndex + (down ? columns : -columns)
        if tabs.indices.contains(target) {
            setHighlight(target)
        } else if down, highlightedIndex / columns < (tabs.count - 1) / columns {
            setHighlight(tabs.count - 1)
        }
    }

    // MARK: Hints

    private func startHints() {
        guard tabs.count > 1 else { onSelect?(highlightedIndex); return }
        hintTyped = ""
        hintLabels = LinkHints.labels(count: tabs.count)
        refreshCards()
    }

    private func endHints() {
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
        if let index = hintLabels.firstIndex(of: typed) {
            hintTyped = nil
            onSelect?(index)
            return true
        }
        hintTyped = typed
        refreshCards()
        return true
    }

    // MARK: Testing

    var debugTitles: [String] { tabs.map(\.title) }
    var debugColumns: Int { columns }
    var debugHints: [String?] { cards.map(\.hint) }
    var debugPreviewSizes: [NSSize?] { cards.map { $0.preview?.size } }
    var debugCardFrames: [NSRect] { cards.map { $0.convert($0.bounds, to: self) } }
}

/// One tab in the overview: its preview (or favicon, before there is one) with the favicon and
/// title underneath. The highlighted card gets an accent ring; hovering shows a close button.
private final class TabOverviewCard: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

    private static let radius: CGFloat = 12

    private let previewBox = NSView()
    private let placeholder = NSImageView()
    private let ring = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { closeButton.isHidden = !isHovered } }

    var preview: NSImage? {
        didSet {
            guard preview !== oldValue else { return }
            previewBox.layer?.contents = preview
            placeholder.isHidden = preview != nil
        }
    }

    var isHighlighted = false {
        didSet {
            ring.isHidden = !isHighlighted
            titleLabel.textColor = isHighlighted ? .labelColor : .secondaryLabelColor
        }
    }

    var hint: String? {
        didSet {
            hintLabel.stringValue = hint?.uppercased() ?? ""
            hintLabel.isHidden = hint == nil
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
        titleLabel.cell?.truncatesLastVisibleLine = true

        hintLabel.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        hintLabel.alignment = .center
        hintLabel.textColor = .black
        hintLabel.drawsBackground = true
        hintLabel.backgroundColor = NSColor(hex: Settings.linkHintColor) ?? .systemYellow
        hintLabel.wantsLayer = true
        hintLabel.layer?.cornerRadius = 6
        hintLabel.layer?.masksToBounds = true
        hintLabel.isHidden = true

        let symbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab")
        closeButton.image = symbol?.withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"
        closeButton.isHidden = true

        for view in [ring, previewBox, placeholder, iconView, titleLabel, hintLabel, closeButton] { addSubview(view) }
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
        ring.frame = previewFrame.insetBy(dx: -5, dy: -5)
        let placeholderSize = min(48, previewHeight / 3)
        placeholder.frame = NSRect(x: (previewFrame.midX - placeholderSize / 2).rounded(), y: (previewFrame.midY - placeholderSize / 2).rounded(),
                                   width: placeholderSize, height: placeholderSize)
        closeButton.frame = NSRect(x: 6, y: 6, width: 24, height: 24)

        let titleHeight = titleLabel.intrinsicContentSize.height
        let titleY = previewHeight + ((30 - titleHeight) / 2).rounded() + 2
        let textWidth = min(titleLabel.intrinsicContentSize.width, bounds.width - 22)
        let rowWidth = 16 + 6 + textWidth
        let rowX = ((bounds.width - rowWidth) / 2).rounded()
        iconView.frame = NSRect(x: rowX, y: previewHeight + ((30 - 16) / 2).rounded() + 2, width: 16, height: 16)
        titleLabel.frame = NSRect(x: rowX + 22, y: titleY, width: max(0, textWidth), height: titleHeight)

        let hintSize = hintLabel.intrinsicContentSize
        let hintWidth = hintSize.width + 16, hintHeight = hintSize.height + 6
        hintLabel.frame = NSRect(x: (previewFrame.midX - hintWidth / 2).rounded(), y: (previewFrame.midY - hintHeight / 2).rounded(),
                                 width: hintWidth, height: hintHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
            previewBox.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
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
}
