import AppKit

/// Which half of a pane a tab dragged out of the tab strip lands in: the pane splits there.
enum PaneDropEdge {
    case left, right, top, bottom

    /// The edge nearest `point` (in `bounds`, flipped), measured relative to the pane's size,
    /// so every point of the pane picks a half.
    init(point: NSPoint, in bounds: NSRect) {
        let x = (point.x - bounds.minX) / max(bounds.width, 1)
        let y = (point.y - bounds.minY) / max(bounds.height, 1)
        let distances: [(PaneDropEdge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        self = distances.min { $0.1 < $1.1 }!.0
    }

    var axis: SplitView.Axis { self == .left || self == .right ? .horizontal : .vertical }
    /// Whether the dropped tab becomes the split's first child.
    var isLeading: Bool { self == .left || self == .top }

    /// The half of `bounds` the dropped tab will take.
    func rect(in bounds: NSRect) -> NSRect {
        let gap = SplitView.dividerThickness / 2
        switch self {
        case .left: return NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2 - gap, height: bounds.height)
        case .right: return NSRect(x: bounds.midX + gap, y: bounds.minY, width: bounds.width / 2 - gap, height: bounds.height)
        case .top: return NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2 - gap)
        case .bottom: return NSRect(x: bounds.minX, y: bounds.midY + gap, width: bounds.width, height: bounds.height / 2 - gap)
        }
    }
}

/// Shows where a dragged tab will land: a tinted half of the pane under the pointer, with the
/// tab's favicon and title. Lives in the tab's `PaneContainerView`, above the panes; takes no clicks.
final class PaneDropIndicator: NSView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = FaviconView()
    /// Keeps the title readable over whatever page is underneath.
    private let pill = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PaneView.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        pill.material = .popover
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerCurve = .continuous
        addSubview(pill)
        pill.addSubview(iconView)
        pill.addSubview(label)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    /// Shows the indicator at `rect` (container coordinates), sliding there if it was already showing.
    func show(_ rect: NSRect, title: String, favicon: NSImage?) {
        label.stringValue = title
        if iconView.favicon !== favicon { iconView.favicon = favicon }
        let appearing = alphaValue == 0
        if appearing { frame = rect }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearing ? 0.12 : 0.15
            context.allowsImplicitAnimation = true
            animator().alphaValue = 1
            animator().frame = rect
            layoutSubtreeIfNeeded()
        }
    }

    /// Fades out and leaves the container.
    func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        }
    }

    override func layout() {
        super.layout()
        let icon: CGFloat = 16, padding: CGFloat = 12, pillHeight: CGFloat = 32
        let width = max(0, min(bounds.width - 2 * padding - icon - 6 - 24, label.intrinsicContentSize.width))
        let pillWidth = padding + icon + 6 + width + padding
        pill.frame = NSRect(x: ((bounds.width - pillWidth) / 2).rounded(), y: ((bounds.height - pillHeight) / 2).rounded(),
                            width: pillWidth, height: pillHeight)
        pill.layer?.cornerRadius = pillHeight / 2
        iconView.frame = NSRect(x: padding, y: ((pillHeight - icon) / 2).rounded(), width: icon, height: icon)
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: padding + icon + 6, y: ((pillHeight - height) / 2).rounded(), width: width, height: height)
    }
}
