import AppKit
import SwiftUI

// Note: no @State or other macro-based SwiftUI APIs (the Command Line Tools lack the plugins).

/// State of the bookmark popover: name and folder, applied when the popover closes.
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
/// (Done, Return, Esc or clicking outside all keep the edits; Remove deletes it).
@MainActor
final class BookmarkEditor {
    private var session: Session?

    var isShown: Bool { session?.popover.isShown ?? false }

    func show(_ path: Bookmarks.Path, added: Bool, relativeTo rect: NSRect, of view: NSView) {
        close()
        guard let bookmark = Bookmarks.bookmark(at: path) else { return }
        let session = Session(path: path, bookmark: bookmark, added: added)
        session.onClosed = { [weak self, weak session] in
            if let session, self?.session === session { self?.session = nil }
        }
        self.session = session
        // Always hang below the anchor: the bottom edge is maxY only in flipped views.
        session.popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    /// Closes the popover, applying its edits right away.
    func close() {
        session?.finish()
    }

    // MARK: - Testing

    /// The popover's window frame in screen coordinates.
    var debugPopoverFrame: NSRect? {
        guard let view = session?.popover.contentViewController?.view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    var debugModel: BookmarkEditorModel? { session?.model }
}

/// One popover's lifetime. Edits are applied exactly once, when it closes (or a newer one replaces it).
@MainActor
private final class Session: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
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
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: BookmarkEditorView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        // Final size up front: if the popover first opens at the hosting view's provisional size and
        // then shrinks, AppKit keeps its bottom edge, so the arrow ends up far below the anchor.
        popover.contentSize = host.view.fittingSize
        model.onDone = { [weak self] in self?.finish() }
        model.onRemove = { [weak self] in self?.finish(remove: true) }
    }

    func finish(remove: Bool = false) {
        guard !isFinished else { return }
        isFinished = true
        if let current = currentPath() {
            remove ? Bookmarks.remove(at: current) : apply(at: current)
        }
        popover.close()
        onClosed()
    }

    func popoverDidClose(_ notification: Notification) {
        finish()
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
