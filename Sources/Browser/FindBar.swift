import AppKit

/// Find-in-page bar: a glass capsule floating at the top-right of a pane.
final class FindBar: NSView, NSTextFieldDelegate {
    static let size = NSSize(width: 340, height: 32)

    var onChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    let field = NSTextField()
    private let glass = BrowserGlassView()
    private let content = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var previousButton = makeButton("chevron.up", "Previous match (⇧⌘G)", #selector(previousClicked))
    private lazy var nextButton = makeButton("chevron.down", "Next match (⌘G)", #selector(nextClicked))
    private lazy var closeButton = makeButton("xmark", "Close (Esc)", #selector(closeClicked))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = Self.size.height / 2
        glass.contentView = content
        addSubview(glass)

        field.placeholderString = "Find in page"
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right

        for view in [field, statusLabel, previousButton, nextButton, closeButton] {
            content.addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// nil hides the status (empty query).
    func setStatus(index: Int, count: Int, query: String) {
        if query.isEmpty {
            statusLabel.stringValue = ""
        } else if count == 0 || index == 0 {
            statusLabel.stringValue = "No matches"
        } else {
            statusLabel.stringValue = "\(index) of \(count)"
        }
        statusLabel.textColor = !query.isEmpty && count == 0 ? .systemRed : .secondaryLabelColor
        needsLayout = true
    }

    var statusText: String { statusLabel.stringValue }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let buttonSize: CGFloat = 22
        var x = bounds.width - 8 - buttonSize
        for button in [closeButton, nextButton, previousButton] {
            button.frame = NSRect(x: x, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
            x -= buttonSize + 2
        }
        let statusWidth: CGFloat = 76
        let statusHeight = statusLabel.intrinsicContentSize.height
        statusLabel.frame = NSRect(x: x - statusWidth + buttonSize - 4, y: (bounds.height - statusHeight) / 2,
                                   width: statusWidth, height: statusHeight)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: 14, y: ((bounds.height - fieldHeight) / 2).rounded(),
                             width: max(0, statusLabel.frame.minX - 18), height: fieldHeight)
    }

    // MARK: - Field

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    // MARK: - Buttons

    private func makeButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        return button
    }

    @objc private func previousClicked() { onPrevious?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func closeClicked() { onClose?() }
}
