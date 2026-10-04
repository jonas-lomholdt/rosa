import AppKit
import SwiftUI

// Note: no @State or other macro-based SwiftUI APIs (the Command Line Tools lack the plugins).

/// State of the bookmark editor: name and folder, applied when the popover closes.
final class BookmarkEditorModel: ObservableObject {
    enum Mode { case added, edit, editFolder }

    struct FolderChoice {
        var path: Bookmarks.Path
        var label: String
    }

    let mode: Mode
    let folderChoices: [FolderChoice]
    @Published var title: String
    @Published var folderIndex: Int
    var onDone: () -> Void = {}
    var onRemove: () -> Void = {}

    init(mode: Mode, title: String, folder: Bookmarks.Path) {
        self.mode = mode
        self.title = title
        let choices = [FolderChoice(path: [], label: "Bookmarks Bar")]
            + Bookmarks.folders.map { FolderChoice(path: $0.path, label: String(repeating: "    ", count: $0.depth + 1) + $0.title) }
        folderChoices = choices
        folderIndex = choices.firstIndex { $0.path == folder } ?? 0
    }

    var folder: Bookmarks.Path { folderChoices[folderIndex].path }
}

struct BookmarkEditorView: View {
    static let width: CGFloat = 300

    @ObservedObject var model: BookmarkEditorModel

    private var heading: String {
        switch model.mode {
        case .added: "Bookmark Added"
        case .edit: "Edit Bookmark"
        case .editFolder: "Edit Folder"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.headline)
            TextField("Name", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.onDone() }
            if model.mode != .editFolder {
                Picker("Folder", selection: $model.folderIndex) {
                    ForEach(model.folderChoices.indices, id: \.self) { index in
                        Text(model.folderChoices[index].label).tag(index)
                    }
                }
            }
            HStack {
                Button("Remove", role: .destructive) { model.onRemove() }
                Spacer()
                Button("Done") { model.onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: Self.width)
    }
}

/// Shows the editor for one bookmark or folder and writes the changes back when it closes
/// (Done, Return, Esc or clicking elsewhere all keep the edits; Remove deletes it).
@MainActor
final class BookmarkEditor {
    /// Where the arrow points along the anchor view's bottom edge.
    enum ArrowTarget {
        /// Near the right end (the address bar, where a star button would be); the panel sits flush right.
        case trailing
        case center
    }

    private var session: Session?

    var isShown: Bool { session?.panel.isVisible ?? false }

    func show(_ path: Bookmarks.Path, added: Bool, below view: NSView, arrow: ArrowTarget = .center) {
        close()
        guard let bookmark = Bookmarks.bookmark(at: path), let window = view.window else { return }
        let session = Session(path: path, bookmark: bookmark, added: added)
        session.onClosed = { [weak self, weak session] in
            if let session, self?.session === session { self?.session = nil }
        }
        self.session = session
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let tipX = arrow == .trailing ? rect.maxX - AnchoredPanel.arrowInset : rect.midX
        session.panel.show(tip: NSPoint(x: tipX, y: rect.minY - 2), alignRightTo: arrow == .trailing ? rect.maxX : nil,
                           parent: window)
    }

    /// Closes the editor, applying its edits right away.
    func close() {
        session?.finish()
    }

    // MARK: - Testing

    /// The editor's frame in screen coordinates (arrow included).
    var debugPopoverFrame: NSRect? { session?.panel.frame }
    /// Arrow tip in screen coordinates.
    var debugArrowTip: NSPoint? { session?.panel.arrowTip }

    var debugModel: BookmarkEditorModel? { session?.model }
}

/// One editor's lifetime. Edits are applied exactly once, when it closes (or a newer one replaces it).
@MainActor
private final class Session {
    let panel: AnchoredPanel
    let model: BookmarkEditorModel
    var onClosed: () -> Void = {}
    private let path: Bookmarks.Path
    /// What the edited entry looked like when opened, to find it again if the file changed meanwhile.
    private let original: Bookmark
    private var isFinished = false

    init(path: Bookmarks.Path, bookmark: Bookmark, added: Bool) {
        self.path = path
        original = bookmark
        let isFolder: Bool
        if case .folder = bookmark.kind { isFolder = true } else { isFolder = false }
        model = BookmarkEditorModel(
            mode: isFolder ? .editFolder : (added ? .added : .edit),
            title: bookmark.title, folder: Array(path.dropLast())
        )
        panel = AnchoredPanel(content: NSHostingView(rootView: BookmarkEditorView(model: model)))
        panel.onDismiss = { [weak self] in self?.finish() }
        model.onDone = { [weak self] in self?.finish() }
        model.onRemove = { [weak self] in self?.finish(remove: true) }
    }

    func finish(remove: Bool = false) {
        guard !isFinished else { return }
        isFinished = true
        if let current = currentPath() {
            remove ? Bookmarks.remove(at: current) : apply(at: current)
        }
        panel.dismiss()
        onClosed()
    }

    private func apply(at path: Bookmarks.Path) {
        let title = model.title.trimmingCharacters(in: .whitespaces)
        if title != Bookmarks.bookmark(at: path)?.title {
            Bookmarks.rename(at: path, to: title.isEmpty && model.mode == .editFolder ? "Folder" : title)
        }
        if model.mode != .editFolder {
            Bookmarks.move(path, to: model.folder)
        }
    }

    /// The edited entry's path now; it moves if the file was edited while the popover was open.
    private func currentPath() -> Bookmarks.Path? {
        switch original.kind {
        case .link(let url):
            if let at = Bookmarks.bookmark(at: path), case .link(let current) = at.kind, current == url { return path }
            return Bookmarks.path(of: url)
        case .folder:
            if let at = Bookmarks.bookmark(at: path), case .folder = at.kind, at.title == original.title { return path }
            return nil
        }
    }
}

/// A popover-style panel whose arrow can sit anywhere along its top edge (NSPopover always
/// centres it). Child of the browser window; closes on Esc, a click in another window, or
/// switching apps.
@MainActor
final class AnchoredPanel: NSPanel {
    static let arrowHeight: CGFloat = 10
    static let arrowWidth: CGFloat = 22
    /// Arrow centre from the panel's right edge in `.trailing` placement.
    static let arrowInset: CGFloat = 22
    private static let cornerRadius: CGFloat = 14

    var onDismiss: (() -> Void)?
    private let background = NSVisualEffectView()
    private let border = PanelBorderView()
    private let content: NSView
    private var arrowX: CGFloat = 0
    private var resignObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    /// Arrow tip in screen coordinates.
    var arrowTip: NSPoint { NSPoint(x: frame.minX + arrowX, y: frame.maxY) }

    init(content: NSView) {
        self.content = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        let root = NSView()
        root.addSubview(background)
        root.addSubview(border)
        root.addSubview(content)
        contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    /// Places the arrow tip at `tip`; with `alignRightTo`, the panel's right edge lines up with that x,
    /// otherwise it's centred on the tip. Either way it's kept inside the parent window.
    func show(tip: NSPoint, alignRightTo right: CGFloat?, parent: NSWindow) {
        let size = content.fittingSize
        let width = size.width, height = size.height + Self.arrowHeight
        var x = right.map { $0 - width } ?? (tip.x - width / 2)
        x = min(max(x, parent.frame.minX + 8), parent.frame.maxX - width - 8)
        let minArrow = Self.cornerRadius + Self.arrowWidth / 2
        arrowX = min(max(tip.x - x, minArrow), width - minArrow)
        setFrame(NSRect(x: x, y: tip.y - height, width: width, height: height), display: false)

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        background.frame = bounds
        border.frame = bounds
        content.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
        let path = Self.shape(in: bounds, arrowX: arrowX)
        border.path = path
        background.maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            NSColor.black.setFill()
            path.fill()
            return true
        }

        parent.addChildWindow(self, ordered: .above)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        // Dismiss on a click in any other window, or when the app goes to the background.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self { MainActor.assumeIsolated { self.onDismiss?() } }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss?() }
        }
    }

    func dismiss() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        resignObserver = nil
        clickMonitor = nil
        let parent = self.parent
        parent?.removeChildWindow(self)
        orderOut(nil)
        // Give the browser window its keyboard focus back (if the click wasn't elsewhere).
        if NSApp.keyWindow == nil || NSApp.keyWindow === self { parent?.makeKey() }
    }

    /// Rounded rectangle with the arrow rising from its top edge at `arrowX`.
    private static func shape(in bounds: NSRect, arrowX: CGFloat) -> NSBezierPath {
        let body = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - arrowHeight - 1)
        let radius = cornerRadius
        let half = arrowWidth / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: body.minX + radius, y: body.minY))
        path.line(to: NSPoint(x: body.maxX - radius, y: body.minY))
        path.appendArc(withCenter: NSPoint(x: body.maxX - radius, y: body.minY + radius), radius: radius, startAngle: 270, endAngle: 0)
        path.line(to: NSPoint(x: body.maxX, y: body.maxY - radius))
        path.appendArc(withCenter: NSPoint(x: body.maxX - radius, y: body.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
        // Arrow, with softened corners at its base and tip.
        path.line(to: NSPoint(x: arrowX + half, y: body.maxY))
        path.curve(to: NSPoint(x: arrowX, y: body.maxY + arrowHeight - 0.5),
                   controlPoint1: NSPoint(x: arrowX + half * 0.45, y: body.maxY),
                   controlPoint2: NSPoint(x: arrowX + 2, y: body.maxY + arrowHeight - 0.5))
        path.curve(to: NSPoint(x: arrowX - half, y: body.maxY),
                   controlPoint1: NSPoint(x: arrowX - 2, y: body.maxY + arrowHeight - 0.5),
                   controlPoint2: NSPoint(x: arrowX - half * 0.45, y: body.maxY))
        path.line(to: NSPoint(x: body.minX + radius, y: body.maxY))
        path.appendArc(withCenter: NSPoint(x: body.minX + radius, y: body.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: body.minX, y: body.minY + radius))
        path.appendArc(withCenter: NSPoint(x: body.minX + radius, y: body.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }
}

/// Hairline outline of the panel's shape.
private final class PanelBorderView: NSView {
    var path: NSBezierPath? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let path else { return }
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
