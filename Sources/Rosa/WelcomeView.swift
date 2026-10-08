import AppKit

/// Shown over a blank pane (new window, tab or split): a few clickable commands with their
/// shortcuts, like an editor's welcome page. Shortcuts are read from the main menu so they
/// can't drift from the real key equivalents.
final class WelcomeView: NSView {
    struct Command {
        let title: String
        let symbol: String
        let action: Selector
    }

    struct Section {
        let title: String
        let commands: [Command]
    }

    static let sections: [Section] = [
        Section(title: "Get Started", commands: [
            Command(title: "Search or Enter Address", symbol: "magnifyingglass", action: #selector(BrowserWindowController.openLocation(_:))),
            Command(title: "Open Command Palette", symbol: "command", action: #selector(BrowserWindowController.showCommandPalette(_:))),
            Command(title: "Zen Mode", symbol: "eye.slash", action: #selector(BrowserWindowController.toggleZenMode(_:))),
            Command(title: "Settings", symbol: "gearshape", action: #selector(AppDelegate.showSettings(_:))),
        ]),
        Section(title: "Panes & Tabs", commands: [
            Command(title: "Split Right", symbol: "rectangle.split.2x1", action: #selector(BrowserWindowController.splitRight(_:))),
            Command(title: "Split Down", symbol: "rectangle.split.1x2", action: #selector(BrowserWindowController.splitDown(_:))),
            Command(title: "New Tab", symbol: "plus", action: #selector(BrowserWindowController.newTab(_:))),
            Command(title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", action: #selector(BrowserWindowController.reopenClosedTab(_:))),
        ]),
    ]

    private static let width: CGFloat = 440
    private static let headerHeight: CGFloat = 56
    private static let headerGap: CGFloat = 32
    private static let sectionTitleHeight: CGFloat = 24
    private static let sectionGap: CGFloat = 20
    private static let rowHeight: CGFloat = 28

    /// Height of the whole column; the view hides itself when the pane is smaller.
    static let contentHeight: CGFloat = headerHeight + headerGap
        + sections.map { sectionTitleHeight + CGFloat($0.commands.count) * rowHeight }.reduce(0, +)
        + sectionGap * CGFloat(sections.count - 1)

    /// Called with a row's action; the pane focuses itself and sends it up the responder chain.
    var onCommand: ((Selector) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Welcome to Rosa")
    private let subtitleLabel = NSTextField(labelWithString: "A tiny browser with split panes")
    private var sectionHeaders: [WelcomeSectionHeader] = []
    private var rows: [[WelcomeRow]] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 20, weight: .medium)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        subtitleLabel.textColor = .secondaryLabelColor
        for view in [iconView, titleLabel, subtitleLabel] { addSubview(view) }

        for section in Self.sections {
            let header = WelcomeSectionHeader(title: section.title)
            addSubview(header)
            sectionHeaders.append(header)
            rows.append(section.commands.map { command in
                let row = WelcomeRow(command: command)
                row.onClick = { [weak self] in self?.onCommand?(command.action) }
                addSubview(row)
                return row
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Its own background: a blank web view draws white until it has loaded something.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    /// Only the rows take clicks; elsewhere the click reaches the (blank) web view and focuses the pane.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The row itself, also when the point is on its icon or title.
        var view = super.hitTest(point)
        while let current = view, !(current is WelcomeRow) { view = current === self ? nil : current.superview }
        return view
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        // Menu shortcuts can change (rebuilt menu), so refresh them whenever the view is shown.
        rows.joined().forEach { $0.refreshShortcut() }
    }

    override func layout() {
        super.layout()
        let width = min(Self.width, bounds.width - 48)
        let x = ((bounds.width - width) / 2).rounded()
        var y = max(24, ((bounds.height - Self.contentHeight) / 2 - 16).rounded())

        let iconSize: CGFloat = 48
        let titleHeight = titleLabel.intrinsicContentSize.height
        let subtitleHeight = subtitleLabel.intrinsicContentSize.height
        let textWidth = ceil(max(titleLabel.intrinsicContentSize.width, subtitleLabel.intrinsicContentSize.width)) + 4
        let headerX = ((bounds.width - (iconSize + 12 + textWidth)) / 2).rounded()
        iconView.frame = NSRect(x: headerX, y: y + (Self.headerHeight - iconSize) / 2, width: iconSize, height: iconSize)
        let textTop = y + ((Self.headerHeight - titleHeight - subtitleHeight) / 2).rounded()
        titleLabel.frame = NSRect(x: headerX + iconSize + 12, y: textTop, width: textWidth, height: titleHeight)
        subtitleLabel.frame = NSRect(x: headerX + iconSize + 12, y: textTop + titleHeight, width: textWidth, height: subtitleHeight)
        y += Self.headerHeight + Self.headerGap

        for (index, header) in sectionHeaders.enumerated() {
            if index > 0 { y += Self.sectionGap }
            header.frame = NSRect(x: x, y: y, width: width, height: Self.sectionTitleHeight)
            y += Self.sectionTitleHeight
            for row in rows[index] {
                // Rows overhang the column a little so their hover highlight has padding.
                row.frame = NSRect(x: x - 8, y: y, width: width + 16, height: Self.rowHeight)
                y += Self.rowHeight
            }
        }
    }

    /// Self-test: a point (window coordinates) on the title of the row titled `title`.
    func debugTitlePoint(_ title: String) -> NSPoint? {
        guard let row = rows.joined().first(where: { $0.accessibilityLabel() == title }) else { return nil }
        return row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
    }

    /// Self-test: clicks the row titled `title`.
    func debugPerform(_ title: String) {
        guard let command = Self.sections.flatMap(\.commands).first(where: { $0.title == title }) else { return }
        onCommand?(command.action)
    }

    /// Menu-style shortcut text (⌃⌥⇧⌘ + key) for the main menu item with `action`.
    static func shortcut(for action: Selector) -> String? {
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action, !item.keyEquivalent.isEmpty, !item.isHidden { return item }
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
            }
            return nil
        }
        guard let menu = NSApp.mainMenu, let item = find(in: menu) else { return nil }
        return item.shortcutText
    }
}

/// "GET STARTED ———" small caps title with a hairline running to the right edge.
final class WelcomeSectionHeader: NSView {
    private let label: NSTextField
    private let line = NSBox()

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue.uppercased(); needsLayout = true }
    }

    init(title: String) {
        label = NSTextField(labelWithString: title.uppercased())
        super.init(frame: .zero)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        line.boxType = .separator
        addSubview(label)
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var size = label.intrinsicContentSize
        // Labels sized exactly to their intrinsic width clip the last glyph.
        size.width = ceil(size.width) + 4
        let labelY = ((bounds.height - size.height) / 2).rounded()
        label.frame = NSRect(x: 0, y: labelY, width: size.width, height: size.height)
        let lineX = size.width + 10
        line.frame = NSRect(x: lineX, y: (bounds.height / 2).rounded(), width: max(0, bounds.width - lineX), height: 1)
    }
}

/// One clickable command: icon, title, and the shortcut right-aligned.
private final class WelcomeRow: NSView {
    var onClick: (() -> Void)?

    private let command: WelcomeView.Command
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(command: WelcomeView.Command) {
        self.command = command
        titleLabel = NSTextField(labelWithString: command.title)
        super.init(frame: .zero)
        let symbol = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
        iconView.image = symbol?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        iconView.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        for view in [iconView, titleLabel, shortcutLabel] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(command.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func refreshShortcut() {
        let shortcut = WelcomeView.shortcut(for: command.action) ?? ""
        guard shortcutLabel.stringValue != shortcut else { return }
        shortcutLabel.stringValue = shortcut
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        iconView.frame = NSRect(x: 8, y: (height - 16) / 2, width: 16, height: 16)
        var shortcutSize = shortcutLabel.intrinsicContentSize
        shortcutSize.width = ceil(shortcutSize.width) + 4
        shortcutLabel.frame = NSRect(x: bounds.width - 8 - shortcutSize.width, y: ((height - shortcutSize.height) / 2).rounded(),
                                     width: shortcutSize.width, height: shortcutSize.height)
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(x: 34, y: ((height - titleHeight) / 2).rounded(),
                                  width: max(0, shortcutLabel.frame.minX - 8 - 34), height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isPressed else { return }
        NSColor.labelColor.withAlphaComponent(isPressed ? 0.12 : 0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
