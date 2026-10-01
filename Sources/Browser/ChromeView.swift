import AppKit

/// Transparent container for browser chrome (tab strip, header). Optionally acts as a
/// window drag handle, since the window uses a transparent, full-size title bar.
class ChromeView: NSView {
    var dragsWindow = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { dragsWindow }

    override func mouseDown(with event: NSEvent) {
        guard dragsWindow, let window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            window.performZoom(nil)
        } else {
            window.performDrag(with: event)
        }
    }
}

/// Borderless text field used inside a `GlassAddressBar`.
final class AddressField: NSTextField {
    var onFocus: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        placeholderString = "Search or enter address"
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 13)
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.sendsActionOnEndEditing = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// A Liquid Glass capsule holding an address field.
final class GlassAddressBar: NSView {
    static let height: CGFloat = 28

    let field = AddressField()
    private let iconView = FaviconView()
    private let glass = NSGlassEffectView()
    private let content = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = Self.height / 2
        glass.contentView = content
        content.addSubview(iconView)
        content.addSubview(field)
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var icon: NSImage? {
        get { iconView.favicon }
        set { iconView.favicon = newValue }
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let fieldHeight = field.intrinsicContentSize.height
        iconView.frame = NSRect(x: 10, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16)
        field.frame = NSRect(
            x: 32, y: ((bounds.height - fieldHeight) / 2).rounded(),
            width: max(0, bounds.width - 44), height: fieldHeight
        )
    }
}

/// 16pt image view showing a favicon, or a tinted globe placeholder.
final class FaviconView: NSImageView {
    var favicon: NSImage? {
        didSet { showFavicon() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        showFavicon()
    }

    private func showFavicon() {
        image = favicon ?? FaviconStore.placeholder
        contentTintColor = favicon == nil ? .secondaryLabelColor : nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
