import AppKit

/// Glass dropdown under an address bar listing history suggestions. It is a non-activating
/// child panel, so the address field keeps keyboard focus while it is open.
@MainActor
final class SuggestionsWindow {
    static let rowHeight: CGFloat = 32
    static let padding: CGFloat = 6

    var onPick: ((Int) -> Void)?

    var selectedIndex = -1 {
        didSet {
            for (index, row) in rows.enumerated() { row.isHighlighted = index == selectedIndex }
        }
    }

    var isVisible: Bool { panel.isVisible }

    private let panel: NSPanel
    private let glass = BrowserGlassView()
    private let content = FlippedView()
    private var rows: [SuggestionRowView] = []

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        glass.cornerRadius = 12
        glass.contentView = content
        panel.contentView = glass
    }

    func show(_ entries: [HistoryEntry], below anchor: NSView) {
        guard !entries.isEmpty, let parent = anchor.window else { return hide() }

        while rows.count < entries.count {
            let row = SuggestionRowView()
            row.onClick = { [weak self, weak row] in
                guard let self, let row, let index = self.rows.firstIndex(where: { $0 === row }) else { return }
                self.onPick?(index)
            }
            content.addSubview(row)
            rows.append(row)
        }
        while rows.count > entries.count {
            rows.removeLast().removeFromSuperview()
        }
        for (row, entry) in zip(rows, entries) { row.configure(entry) }
        selectedIndex = -1

        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = max(anchorRect.width, 360)
        let height = CGFloat(entries.count) * Self.rowHeight + Self.padding * 2
        panel.setFrame(NSRect(x: anchorRect.minX, y: anchorRect.minY - 6 - height, width: width, height: height), display: false)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: Self.padding, y: Self.padding + CGFloat(index) * Self.rowHeight,
                width: width - Self.padding * 2, height: Self.rowHeight
            )
        }

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        selectedIndex = -1
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SuggestionRowView: NSView {
    var onClick: (() -> Void)?
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            updateText()
            needsDisplay = true
        }
    }

    private let iconView = FaviconView()
    private let label = NSTextField(labelWithString: "")
    private var title = ""
    private var urlText = ""

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(iconView)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(_ entry: HistoryEntry) {
        title = entry.title.isEmpty ? entry.displayHost : entry.title
        urlText = entry.displayURL
        iconView.favicon = FaviconStore.shared.cachedIcon(forHost: entry.url.host())
        updateText()
    }

    private func updateText() {
        let primary: NSColor = isHighlighted ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = isHighlighted ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        let text = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: primary]
        )
        text.append(NSAttributedString(
            string: "  —  " + urlText,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary]
        ))
        label.attributedStringValue = text
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 10, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: 34, y: ((bounds.height - labelHeight) / 2).rounded(),
            width: max(0, bounds.width - 44), height: labelHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
