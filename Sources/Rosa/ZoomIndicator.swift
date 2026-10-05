import AppKit

/// Page zoom steps (Chrome's), as `WKWebView.pageZoom` factors.
enum PageZoom {
    static let levels: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    static func next(after zoom: CGFloat) -> CGFloat {
        levels.first { $0 > zoom + 0.001 } ?? levels.last!
    }

    static func previous(before zoom: CGFloat) -> CGFloat {
        levels.last { $0 < zoom - 0.001 } ?? levels.first!
    }
}

/// Glass capsule showing the zoom level briefly after it changes (top-centre of a pane).
final class ZoomIndicator: NSView {
    static let size = NSSize(width: 72, height: 28)

    private let glass = NSGlassEffectView()
    private let label = NSTextField(labelWithString: "")
    private var hideGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = Self.size.height / 2
        glass.contentView = label
        addSubview(glass)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var text: String { label.stringValue }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
    }

    func show(_ zoom: CGFloat) {
        label.stringValue = "\(Int((zoom * 100).rounded()))%"
        hideGeneration += 1
        let generation = hideGeneration
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, generation == hideGeneration else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    if generation == self.hideGeneration { self.isHidden = true }
                }
            }
        }
    }
}
