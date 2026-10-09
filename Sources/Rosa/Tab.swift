import AppKit
import WebKit

/// A tab owns one split tree of panes.
@MainActor
final class Tab {
    let container: PaneContainerView
    weak var focusedPane: PaneView?
    /// The tab's pages as last captured, for the tab overview (⌘§). Taken when the tab is left
    /// and refreshed when the overview opens; nil until the first capture.
    private(set) var preview: NSImage?
    private var previewGeneration = 0

    init(pane: PaneView) {
        container = PaneContainerView(child: pane)
        focusedPane = pane
    }

    /// A tab around an existing split tree (reopening a closed tab).
    init(root: NSView, focusedPane: PaneView?) {
        container = PaneContainerView(child: root)
        self.focusedPane = focusedPane ?? root.paneLeaves.first
    }

    var panes: [PaneView] { container.paneLeaves }

    var favicon: NSImage? { (focusedPane ?? panes.first)?.favicon }

    var title: String { (focusedPane ?? panes.first)?.displayTitle ?? "New Tab" }

    var displayURL: String { (focusedPane ?? panes.first)?.displayURL ?? "" }

    /// Snapshots every pane at about `width` points across the whole tab and lays them out as
    /// they sit in the split, without the address bars. Blank panes are left out. WebKit paints
    /// snapshots in the page's process, so this works for tabs that aren't on screen.
    func capturePreview(width: CGFloat = 480) async {
        let bounds = container.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let scale = min(1, width / bounds.width)
        let backing = container.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let inWindow = container.window != nil

        var shots: [(rect: NSRect, image: NSImage)] = []
        for pane in panes where !pane.isBlank {
            let webView = pane.webView
            guard webView.bounds.width > 1, webView.bounds.height > 1 else { continue }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            // In pixels: WebKit hands back 1x images, which look soft on a Retina screen.
            configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width * scale * backing))
            // A detached web view never gets a screen update; waiting for one would never return.
            configuration.afterScreenUpdates = inWindow
            guard let image = try? await webView.takeSnapshot(configuration: configuration) else { continue }
            shots.append((webView.convert(webView.bounds, to: container), image))
        }
        // A newer capture started meanwhile (or the tab changed): it wins.
        guard generation == previewGeneration, container.bounds == bounds else { return }
        guard !shots.isEmpty else {
            preview = nil
            return
        }

        let size = NSSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * backing), pixelsHigh: Int(size.height * backing),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size  // before making the context, so it draws in points
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let radius = PaneView.cornerRadius * scale
        for shot in shots {
            // The container is flipped; the bitmap isn't.
            let rect = NSRect(x: shot.rect.minX * scale, y: size.height - shot.rect.maxY * scale,
                              width: shot.rect.width * scale, height: shot.rect.height * scale)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            shot.image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        preview = image
    }
}
