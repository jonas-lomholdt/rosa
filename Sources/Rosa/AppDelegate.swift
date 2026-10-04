import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [BrowserWindowController] = []
    /// Menus whose shortcuts must win over web pages (pages can otherwise swallow ⌘D, ⌘W, …).
    private var priorityMenus: [NSMenu] = []
    private var keyMonitor: Any?
    private var settingsWindow: NSWindow?
    private var bookmarksManager: BookmarksManagerController?
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        applyAppearance()
        ContentBlocker.shared.start()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        installKeyMonitor()
        newWindow(nil)
        NSApp.activate()
        SelfTest.runIfRequested()
        Updater.shared.checkOnLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    // MARK: - Windows

    @objc func newWindow(_ sender: Any?) {
        let controller = BrowserWindowController()
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)

        if let current = NSApp.keyWindow, let window = controller.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: current.frame.minX, y: current.frame.maxY)))
        } else {
            controller.window?.center()
        }
        controller.addTab()
        controller.showWindow(nil)
    }

    /// Reached only when no browser window is key (the window controller handles it otherwise).
    @objc func newTab(_ sender: Any?) { newWindow(sender) }
    @objc func openLocation(_ sender: Any?) { newWindow(sender) }

    // MARK: - Settings

    private func applyAppearance() {
        // Web views inherit this too, so pages honouring prefers-color-scheme follow along.
        NSApp.appearance = Settings.appearance.nsAppearance
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "Tiny, keyboard-first browser with split panes.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        credits.append(NSAttributedString(
            string: "github.com/jonas-lomholdt/rosa",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: AppInfo.repositoryURL]
        ))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        MainActor.assumeIsolated { Updater.shared.checkNow() }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        guard let settingsWindow else { return }
        if !settingsWindow.isVisible {
            centre(settingsWindow, over: frontmostBrowserWindow)
        }
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    @objc func showBookmarksManager(_ sender: Any?) {
        if bookmarksManager == nil {
            let manager = BookmarksManagerController()
            manager.onOpen = { [weak self] url, newTab in
                guard let self else { return }
                if frontmostBrowserWindow == nil { newWindow(nil) }
                (frontmostBrowserWindow?.windowController as? BrowserWindowController)?.open(url, newTab: newTab)
            }
            bookmarksManager = manager
        }
        guard let window = bookmarksManager?.window else { return }
        if !window.isVisible, !window.setFrameUsingName("BookmarksManager") {
            centre(window, over: frontmostBrowserWindow)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// For the self-test.
    var debugBookmarksManager: BookmarksManagerController? { bookmarksManager }

    /// The browser window the user was last in (Settings itself excluded).
    var frontmostBrowserWindow: NSWindow? {
        NSApp.orderedWindows.first { $0.windowController is BrowserWindowController && $0.isVisible }
    }

    /// Centres `window` over `parent` (or the screen), kept fully on screen. The SwiftUI content
    /// is laid out first: before that the hosting window doesn't know its final size.
    private func centre(_ window: NSWindow, over parent: NSWindow?) {
        if let content = window.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            let size = content.fittingSize
            if size.width > 0, size.height > 0 { window.setContentSize(size) }
        }
        guard let parent else { return window.center() }
        let size = window.frame.size
        var frame = NSRect(
            x: (parent.frame.midX - size.width / 2).rounded(),
            y: (parent.frame.midY - size.height / 2).rounded(),
            width: size.width, height: size.height
        )
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: false)
    }

    @objc func toggleVerticalTabs(_ sender: Any?) {
        Settings.tabLayout = Settings.tabLayout == .vertical ? .horizontal : .vertical
    }

    @objc func toggleBookmarksBar(_ sender: Any?) {
        Settings.showBookmarksBar.toggle()
    }

    @objc func toggleSharedAddressBar(_ sender: Any?) {
        Settings.addressBarMode = Settings.addressBarMode == .shared ? .perPane : .shared
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleVerticalTabs(_:)):
            menuItem.state = Settings.tabLayout == .vertical ? .on : .off
        case #selector(toggleBookmarksBar(_:)):
            menuItem.state = Settings.showBookmarksBar ? .on : .off
        case #selector(toggleSharedAddressBar(_:)):
            menuItem.state = Settings.addressBarMode == .shared ? .on : .off
        case #selector(checkForUpdates(_:)):
            return !Updater.shared.isBusy
        default:
            break
        }
        return true
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.performPriorityKeyEquivalent(event) ?? false }
            return handled ? nil : event
        }
    }

    private func performPriorityKeyEquivalent(_ event: NSEvent) -> Bool {
        let isF12 = event.keyCode == 111
        guard isF12 || !event.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
        if performVimPaneNavigation(event) { return true }
        return priorityMenus.contains { $0.performKeyEquivalent(with: event) }
    }

    /// ⌃H/J/K/L focus the neighbouring pane, like vim-tmux-navigator. Not menu items: a
    /// disabled item still swallows its key, and these must pass through in a single pane.
    private func performVimPaneNavigation(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .control,
              let controller = event.window?.windowController as? BrowserWindowController else { return false }
        let direction: BrowserWindowController.Direction
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h": direction = .left
        case "j": direction = .down
        case "k": direction = .up
        case "l": direction = .right
        default: return false
        }
        return controller.handleVimPaneNavigation(direction)
    }

    // MARK: - Menu

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = submenu("Rosa", in: main)
        appMenu.addItem(item("About Rosa", #selector(showAbout(_:))))
        appMenu.addItem(item("Check for Updates…", #selector(checkForUpdates(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings(_:)), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Rosa", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Rosa", #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu("File", in: main)
        file.addItem(item("New Window", #selector(newWindow(_:)), "n"))
        file.addItem(item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"))
        file.addItem(item("Open Location…", #selector(BrowserWindowController.openLocation(_:)), "l"))
        file.addItem(.separator())
        file.addItem(item("Close Pane", #selector(BrowserWindowController.closePane(_:)), "w"))
        file.addItem(item("Close Tab", #selector(BrowserWindowController.closeCurrentTab(_:)), "W", [.command, .shift]))

        let edit = submenu("Edit", in: main)
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "Z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        // Own submenu so it can take priority over pages without also hijacking ⌘C/⌘V.
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(BrowserWindowController.showFindBar(_:)), "f"))
        find.addItem(item("Find Next", #selector(BrowserWindowController.findNextMatch(_:)), "g"))
        find.addItem(item("Find Previous", #selector(BrowserWindowController.findPreviousMatch(_:)), "G", [.command, .shift]))
        let findHolder = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findHolder.submenu = find
        edit.addItem(findHolder)

        let view = submenu("View", in: main)
        view.addItem(item("Vertical Tabs", #selector(toggleVerticalTabs(_:))))
        view.addItem(item("Shared Address Bar", #selector(toggleSharedAddressBar(_:))))
        view.addItem(item("Bookmarks Bar", #selector(toggleBookmarksBar(_:)), "B", [.command, .shift]))
        view.addItem(item("Show Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s", [.command, .control]))
        view.addItem(item("Downloads", #selector(BrowserWindowController.toggleDownloads(_:)), "l", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"))
        view.addItem(.separator())
        view.addItem(item("Show Link Hints (F)", #selector(BrowserWindowController.showLinkHints(_:))))
        view.addItem(item("Web Inspector", #selector(BrowserWindowController.toggleWebInspector(_:)), "i", [.command, .option]))
        let f12 = item("Web Inspector", #selector(BrowserWindowController.toggleWebInspector(_:)), functionKey(NSF12FunctionKey), [])
        f12.isAlternate = false
        f12.isHidden = true
        f12.allowsKeyEquivalentWhenHidden = true
        view.addItem(f12)
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let history = submenu("History", in: main)
        history.addItem(item("Back", #selector(BrowserWindowController.navigateBack(_:)), "["))
        history.addItem(item("Forward", #selector(BrowserWindowController.navigateForward(_:)), "]"))

        // Not a priority menu: pages get ⌘B first (bold in editors), the menu gets it otherwise.
        let bookmarks = submenu("Bookmarks", in: main)
        bookmarks.addItem(item("Bookmark This Page…", #selector(BrowserWindowController.bookmarkCurrentPage(_:)), "b"))
        bookmarks.addItem(item("Manage Bookmarks…", #selector(showBookmarksManager(_:)), "b", [.command, .option]))

        let pane = submenu("Pane", in: main)
        pane.addItem(item("Split Right", #selector(BrowserWindowController.splitRight(_:)), "d"))
        pane.addItem(item("Split Down", #selector(BrowserWindowController.splitDown(_:)), "D", [.command, .shift]))
        pane.addItem(.separator())
        let arrows: [(String, Selector, Int)] = [
            ("Focus Pane Left", #selector(BrowserWindowController.focusPaneLeft(_:)), NSLeftArrowFunctionKey),
            ("Focus Pane Right", #selector(BrowserWindowController.focusPaneRight(_:)), NSRightArrowFunctionKey),
            ("Focus Pane Above", #selector(BrowserWindowController.focusPaneUp(_:)), NSUpArrowFunctionKey),
            ("Focus Pane Below", #selector(BrowserWindowController.focusPaneDown(_:)), NSDownArrowFunctionKey),
        ]
        for (title, action, key) in arrows {
            pane.addItem(item(title, action, functionKey(key), [.command, .option]))
        }
        pane.addItem(.separator())
        pane.addItem(item("Equalize Pane Sizes", #selector(BrowserWindowController.equalizePanes(_:)), "=", [.command, .control]))

        let window = submenu("Window", in: main)
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Show Next Tab", #selector(BrowserWindowController.showNextTab(_:)), "\t", [.control]))
        window.addItem(item("Show Previous Tab", #selector(BrowserWindowController.showPreviousTab(_:)),
                            functionKey(NSBackTabCharacter), [.control, .shift]))
        for number in 1...9 {
            let tabItem = item(number == 9 ? "Select Last Tab" : "Select Tab \(number)",
                               #selector(BrowserWindowController.selectTabByNumber(_:)), "\(number)")
            tabItem.tag = number
            window.addItem(tabItem)
        }
        window.addItem(.separator())
        NSApp.windowsMenu = window

        priorityMenus = [appMenu, file, find, view, history, pane, window]
        return main
    }

    private func submenu(_ title: String, in main: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func functionKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(code)!))
    }
}
