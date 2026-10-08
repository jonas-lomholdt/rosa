import AppKit

/// A node in the split tree that can swap one of its children for another view.
@MainActor
protocol PaneParent: NSView {
    func replaceChild(_ old: NSView, with new: NSView)
}

/// Root of a tab's split tree. Holds exactly one child (a pane or a split) that fills it.
final class PaneContainerView: NSView, PaneParent {
    static let margin: CGFloat = 6

    private(set) var child: NSView
    /// Space around the split tree; zero in zen mode, so the page fills the window.
    var inset: CGFloat = PaneContainerView.margin {
        didSet { if inset != oldValue { needsLayout = true } }
    }

    init(child: NSView) {
        self.child = child
        super.init(frame: .zero)
        addSubview(child)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        child.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    func replaceChild(_ old: NSView, with new: NSView) {
        guard old === child else { return }
        if old.superview === self { old.removeFromSuperview() }
        child = new
        addSubview(new)
        needsLayout = true
    }
}

/// Two children separated by a draggable divider. Nest these to build arbitrary layouts.
final class SplitView: NSView, PaneParent {
    enum Axis {
        /// Children side by side (vertical divider). Created by ⌘D.
        case horizontal
        /// Children stacked (horizontal divider). Created by ⌘⇧D.
        case vertical
    }

    /// Gap between panes; the whole gap (plus a little) is the drag handle.
    static let dividerThickness: CGFloat = 6
    static let dividerGrabWidth: CGFloat = 10
    static let minimumPaneSize: CGFloat = 120

    let axis: Axis
    private(set) var first: NSView
    private(set) var second: NSView
    /// Fraction of the available length given to `first`.
    var ratio: CGFloat = 0.5 { didSet { needsLayout = true } }

    private let divider = DividerView()

    init(axis: Axis, first: NSView, second: NSView) {
        self.axis = axis
        self.first = first
        self.second = second
        super.init(frame: .zero)
        addSubview(first)
        addSubview(second)
        divider.axis = axis
        divider.onDrag = { [weak self] point in self?.moveDivider(toWindowPoint: point) }
        divider.onDoubleClick = { [weak self] in self?.ratio = 0.5 }
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var availableLength: CGFloat {
        let length = axis == .horizontal ? bounds.width : bounds.height
        return max(0, length - Self.dividerThickness)
    }

    override func layout() {
        super.layout()
        let available = availableLength
        let firstLength = (available * ratio).rounded()
        let thickness = Self.dividerThickness
        let grab = Self.dividerGrabWidth
        let dividerCenter = firstLength + thickness / 2

        switch axis {
        case .horizontal:
            first.frame = NSRect(x: 0, y: 0, width: firstLength, height: bounds.height)
            second.frame = NSRect(x: firstLength + thickness, y: 0, width: available - firstLength, height: bounds.height)
            divider.frame = NSRect(x: dividerCenter - grab / 2, y: 0, width: grab, height: bounds.height)
        case .vertical:
            first.frame = NSRect(x: 0, y: 0, width: bounds.width, height: firstLength)
            second.frame = NSRect(x: 0, y: firstLength + thickness, width: bounds.width, height: available - firstLength)
            divider.frame = NSRect(x: 0, y: dividerCenter - grab / 2, width: bounds.width, height: grab)
        }
        window?.invalidateCursorRects(for: divider)
    }

    func replaceChild(_ old: NSView, with new: NSView) {
        if old === first {
            first = new
        } else if old === second {
            second = new
        } else {
            return
        }
        if old.superview === self { old.removeFromSuperview() }
        addSubview(new, positioned: .below, relativeTo: divider)
        needsLayout = true
    }

    func sibling(of view: NSView) -> NSView {
        view === first ? second : first
    }

    private func moveDivider(toWindowPoint windowPoint: NSPoint) {
        let available = availableLength
        guard available > 0 else { return }
        let point = convert(windowPoint, from: nil)
        let position = axis == .horizontal ? point.x : point.y
        let minRatio = min(0.5, Self.minimumPaneSize / available)
        ratio = min(max(position / available, minRatio), 1 - minRatio)
    }
}

private final class DividerView: NSView {
    var axis: SplitView.Axis = .horizontal
    var onDrag: ((NSPoint) -> Void)?
    var onDoubleClick: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }
}

extension NSView {
    /// All panes in this subtree of the split tree, in visual order.
    var paneLeaves: [PaneView] {
        if let pane = self as? PaneView { return [pane] }
        if let split = self as? SplitView { return split.first.paneLeaves + split.second.paneLeaves }
        if let container = self as? PaneContainerView { return container.child.paneLeaves }
        return []
    }
}
