import AppKit

/// A tab owns one split tree of panes.
@MainActor
final class Tab {
    let container: PaneContainerView
    weak var focusedPane: PaneView?

    init(pane: PaneView) {
        container = PaneContainerView(child: pane)
        focusedPane = pane
    }

    var panes: [PaneView] { container.paneLeaves }

    var favicon: NSImage? { (focusedPane ?? panes.first)?.favicon }

    var title: String { (focusedPane ?? panes.first)?.displayTitle ?? "New Tab" }
}
