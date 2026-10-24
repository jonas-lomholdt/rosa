import AppKit
import WebKit

/// Scripted smoke test, enabled with `BROWSER_SELFTEST=<output dir>`. Posts real key events
/// through the app's event queue (so menu shortcuts and the priority key monitor are exercised),
/// prints the split tree after each step, and writes window snapshots to the output directory.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        guard let outputDir = ProcessInfo.processInfo.environment["BROWSER_SELFTEST"] else { return }
        Task { @MainActor in
            await run(outputDir: URL(fileURLWithPath: outputDir))
            NSApp.terminate(nil)
        }
    }

    private static func run(outputDir: URL) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        await pause()
        guard let controller = NSApp.windows.lazy.compactMap({ $0.windowController as? BrowserWindowController }).first else {
            print("FAIL: no browser window"); return
        }
        for _ in 0..<20 where NSApp.keyWindow == nil {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await pause(0.25)
        }
        print("active=\(NSApp.isActive) key=\(NSApp.keyWindow != nil)")
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "bookmarks" {
            await runBookmarks(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "layout" {
            await runLayout(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "statusbar" {
            await runStatusBar(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "quicklinks" {
            await runQuickLinks(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "commands" {
            await runPaletteCommands(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "contextmenu" {
            await runContextMenu(controller)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "zen" {
            await runZen(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "extensions" {
            await runExtensions(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "welcome" {
            await runWelcome(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "sidebar" {
            await runSidebar(controller)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "addressclick" {
            await runAddressClick(controller)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "overview" {
            await runTabOverview(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "session" {
            await runSession(controller)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "panedrop" {
            await runPaneDrop(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "history" {
            runHistorySearch()
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "semantic" {
            await runSemanticSearch(controller)
            return
        }

        func page(_ name: String, _ color: String) {
            controller.focusedPane?.load("data:text/html,<title>\(name)</title><body style='background:\(color)'><h1>\(name)</h1>")
        }

        func step(_ label: String, _ keys: [(String, UInt16, NSEvent.ModifierFlags)] = []) async {
            for (characters, keyCode, modifiers) in keys {
                await ensureActive(controller.window)
                post(characters, keyCode: keyCode, modifiers: modifiers, window: controller.window)
                await pause(0.3)
            }
            await pause(0.4)
            print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(controller.debugDescriptionOfState)")
        }

        let left = arrow(NSLeftArrowFunctionKey), right = arrow(NSRightArrowFunctionKey)
        let up = arrow(NSUpArrowFunctionKey)
        let paneNav: NSEvent.ModifierFlags = [.command, .option, .function, .numericPad]

        page("A", "#fde")
        await step("initial")
        await step("⌘D split right", [("d", 2, [.command])])
        page("B", "#def")
        await step("⌘⇧D split down", [("D", 2, [.command, .shift])])
        page("C", "#efd")
        await step("load C")
        snapshot(controller, to: outputDir.appendingPathComponent("1-splits.png"))
        func zooms(_ label: String) {
            let levels = controller.debugPanes.map { "\(Int(($0.webView.pageZoom * 100).rounded()))%" }
            print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) zoom=\(levels) indicator=\(controller.focusedPane?.zoomIndicator.text ?? "-")")
        }
        await step("⌘= zoom in", [("=", 24, [.command])])
        await step("⌘+ zoom in", [("+", 24, [.command, .shift])])
        zooms("after ⌘= ⌘+")
        snapshot(controller, to: outputDir.appendingPathComponent("1-zoomed.png"))
        await step("⌘- ⌘- ⌘- zoom out", [("-", 27, [.command]), ("-", 27, [.command]), ("-", 27, [.command])])
        zooms("after ⌘- ×3")
        await step("⌘0 actual size", [("0", 29, [.command])])
        zooms("after ⌘0")
        await step("⌘⌥← focus left", [(left, 123, paneNav)])
        await step("⌘⌥→ focus right (most recent)", [(right, 124, paneNav)])
        await step("⌘⌥↑ focus up", [(up, 126, paneNav)])
        await step("⌃J focus down", [("j", 38, [.control])])
        await step("⌃H focus left", [("h", 4, [.control])])
        await step("⌃L focus right (most recent)", [("l", 37, [.control])])
        await step("⌃K focus up", [("k", 40, [.control])])
        await step("⌘W close pane", [("w", 13, [.command])])
        await step("⌘T new tab", [("t", 17, [.command])])
        await step("⌃⇥ next tab", [("\t", 48, [.control])])
        await step("⌘⌃= equalize", [("=", 24, [.command, .control])])
        Settings.tabLayout = .vertical
        await step("vertical tabs")
        snapshot(controller, to: outputDir.appendingPathComponent("2-vertical.png"))
        Settings.addressBarMode = .shared
        await step("shared address bar")
        snapshot(controller, to: outputDir.appendingPathComponent("3-vertical-shared.png"))
        Settings.tabLayout = .horizontal
        await step("horizontal + shared")
        snapshot(controller, to: outputDir.appendingPathComponent("4-horizontal-shared.png"))
        Settings.addressBarMode = .perPane
        await runBookmarks(controller, outputDir: outputDir)
        for site in ["https://github.com", "https://www.apple.com", "https://news.ycombinator.com"] {
            controller.focusedPane?.load(site)
            // Wait for this site's page to finish and its own icon to arrive (not the previous page's).
            let host = URL(string: site)?.host()
            var icon: NSImage?
            for _ in 0..<40 where icon == nil {
                await pause(0.5)
                guard let pane = controller.focusedPane, pane.webView.url?.host() == host, !pane.webView.isLoading else { continue }
                icon = pane.favicon
            }
            print("favicon \(site): \(icon.map { "ok \($0.representations.first.map { "\($0.pixelsWide)px" } ?? "")" } ?? "MISSING")")
        }

        // History + autocomplete. Run with BROWSER_HISTORY_DB set to a scratch database.
        print("history: \(HistoryStore.shared.search("o", limit: 10).map(\.displayURL))")
        func fieldState() -> String {
            guard let field = controller.focusedPane?.addressField, let editor = field.currentEditor() else {
                return "not editing"
            }
            let selected = (editor.string as NSString).substring(with: editor.selectedRange)
            return "text=\"\(editor.string)\" selected=\"\(selected)\" suggestions=\(field.debugSuggestions)"
        }
        func type(_ label: String, _ keys: [(String, UInt16, NSEvent.ModifierFlags)]) async {
            for (characters, keyCode, modifiers) in keys {
                post(characters, keyCode: keyCode, modifiers: modifiers, window: controller.window)
                await pause(0.2)
            }
            await pause(0.3)
            print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(fieldState())")
        }
        let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]
        controller.openLocation(nil)
        await type("focus address bar", [])
        await type("type 'gi'", [("g", 5, []), ("i", 34, [])])
        await type("↓", [(arrow(NSDownArrowFunctionKey), 125, arrowFlags)])
        await type("↑", [(up, 126, arrowFlags)])
        await type("type 't'", [("t", 17, [])])
        await type("⌫ (drops completion)", [("\u{7f}", 51, [])])
        await type("type 'h'", [("h", 4, [])])
        await type("↩", [("\r", 36, [])])
        await pause(2)
        print("loaded: \(controller.focusedPane?.webView.url?.absoluteString ?? "-")")
        HistoryStore.shared.clear(since: Date().addingTimeInterval(-3600))
        print("after clearing last hour: \(HistoryStore.shared.pageCount) pages")

        // Content blocking: wait for lists, then probe a known tracker script from a page on example.com.
        for _ in 0..<240 {
            if case .ready = ContentBlocker.shared.status { break }
            if case .failed = ContentBlocker.shared.status { break }
            await pause(0.5)
        }
        print("adblock: \(ContentBlocker.shared.statusDescription)")
        func probe(_ label: String) async {
            guard let pane = controller.focusedPane else { return }
            let html = """
                <script src="https://www.google-analytics.com/analytics.js"
                    onload="document.title='tracker loaded'" onerror="document.title='tracker blocked'"></script>
                <div class="adsbygoogle-box" style="height:50px">ad</div>
                <script>setTimeout(() => document.title += ' · banner ' +
                    (getComputedStyle(document.querySelector('.adsbygoogle-box')).display === 'none' ? 'hidden' : 'visible'), 800)</script>
                """
            pane.webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
            await pause(3)
            print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(pane.webView.title ?? "-") · shield=\(pane.shieldState)")
        }
        await probe("blocking on")
        Settings.adBlockEnabled = false
        await probe("blocking off (global toggle)")
        Settings.adBlockEnabled = true
        ContentBlocker.shared.setAllowed(true, host: "example.com")
        await probe("example.com allowed")
        ContentBlocker.shared.setAllowed(false, host: "example.com")
        await probe("example.com blocked again")

        if let pane = controller.focusedPane {
            let selector = Selector(("_inspector"))
            let object = pane.webView.responds(to: selector) ? pane.webView.perform(selector)?.takeUnretainedValue() : nil
            print("inspector object: \(object.map { String(describing: Swift.type(of: $0)) } ?? "nil") responds show=\((object as? NSObject)?.responds(to: Selector(("show"))) ?? false)")
            let before = NSApp.windows.count
            pane.toggleWebInspector()
            await pause(3)
            print("direct toggle                      visible=\(pane.isWebInspectorVisible) windows \(before)->\(NSApp.windows.count) \(NSApp.windows.map { "\(Swift.type(of: $0)):\($0.title):\($0.isVisible)" })")
            pane.toggleWebInspector()
            await pause(1)
        }
        // Web Inspector via F12, twice (open, then close).
        for label in ["F12 (open inspector)", "F12 (close inspector)"] {
            await ensureActive(controller.window)
            post(arrow(NSF12FunctionKey), keyCode: 111, modifiers: [.function], window: controller.window)
            await pause(2)
            print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) visible=\(controller.focusedPane?.isWebInspectorVisible ?? false)")
        }
        // Tab reordering by dragging: horizontal strip, then vertical sidebar.
        for name in ["T1", "T2", "T3"] {
            controller.addTab().webView.loadHTMLString("<title>\(name)</title>", baseURL: nil)
        }
        await pause(1.5)
        print("tabs before drag:                  \(controller.debugTabTitles) selected=\(controller.debugTabTitles[controller.selectedTabIndex])")
        func drag(from source: Int, to destination: Int) async {
            let centers = controller.debugTabCenters
            guard let window = controller.window, centers.indices.contains(source), centers.indices.contains(destination) else {
                return print("drag: bad indices")
            }
            let start = centers[source], end = centers[destination]
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1
                )
            }
            // The tracking loop pulls drags/up from the queue, so queue them before the mouse-down.
            for step in 1...10 {
                let t = CGFloat(step) / 10
                let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                if let event = mouse(.leftMouseDragged, point) { NSApp.postEvent(event, atStart: false) }
            }
            if let up = mouse(.leftMouseUp, end) { NSApp.postEvent(up, atStart: false) }
            if let down = mouse(.leftMouseDown, start) { window.sendEvent(down) }
            await pause(0.5)
        }
        await drag(from: 2, to: 4)
        print("horizontal: drag 2 → 4             \(controller.debugTabTitles) selected=\(controller.debugTabTitles[controller.selectedTabIndex])")
        Settings.tabLayout = .vertical
        await pause(0.5)
        await drag(from: 4, to: 0)
        print("vertical: drag 4 → 0               \(controller.debugTabTitles) selected=\(controller.debugTabTitles[controller.selectedTabIndex])")
        Settings.tabLayout = .horizontal

        // Link target setting: background links and window.open, as tab vs pane.
        if let pane = controller.focusedPane {
            let request = URLRequest(url: URL(string: "https://example.com/")!)
            Settings.linkTarget = .tab
            controller.pane(pane, openLinkInBackground: request)
            await pause(1)
            print("link → tab (⌘-click)               \(controller.debugDescriptionOfState)")
            Settings.linkTarget = .pane
            controller.pane(pane, openLinkInBackground: request)
            await pause(1.5)
            print("link → pane (⌘-click)              \(controller.debugDescriptionOfState)")
            _ = controller.pane(pane, createWebViewWith: WebKitSupport.makeConfiguration())
            await pause(0.5)
            print("window.open → pane                 \(controller.debugDescriptionOfState)")
            Settings.linkTarget = .tab
        }

        // Link hints: f shows labels, typing one clicks; F opens in the background; off = nothing.
        if let pane = controller.focusedPane, let window = controller.window {
            let keyCodes: [Character: UInt16] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "c": 8, "w": 13, "e": 14,
                "p": 35, "l": 37, "j": 38, "k": 40, "m": 46,
            ]
            func press(_ text: String, shift: Bool = false) async {
                for character in text {
                    let typed = shift ? character.uppercased() : String(character)
                    post(typed, keyCode: keyCodes[character] ?? 0, modifiers: shift ? [.shift] : [], window: window)
                    await pause(0.15)
                }
                await pause(0.4)
            }
            func hintLabels() async -> [String] {
                await withCheckedContinuation { continuation in
                    pane.webView.evaluateJavaScript("window.__browserHints.debugLabels()", in: nil, in: LinkHints.contentWorld) {
                        continuation.resume(returning: (try? $0.get()) as? [String] ?? [])
                    }
                }
            }
            let html = """
                <title>hints</title>
                <a id="one" href="#" onclick="document.title='clicked one';return false">One</a><br>
                <a id="two" href="#" onclick="document.title='clicked two';return false">Two</a><br>
                <a id="three" href="https://example.com/three">Three</a><br>
                <input id="field">
                """
            pane.webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
            await pause(1.5)
            window.makeFirstResponder(pane.webView)
            await press("f")
            let labels = await hintLabels()
            print("hints after f                      \(labels)")
            if let two = labels.first(where: { $0.hasSuffix(":two") })?.split(separator: ":").first {
                await press(String(two))
                print("typed '\(two)'                       title=\(pane.webView.title ?? "-")")
            }
            let tabsBefore = controller.tabCount
            await press("f", shift: true)
            if let three = await hintLabels().first(where: { $0.hasSuffix(":three") })?.split(separator: ":").first {
                await press(String(three))
                await pause(0.5)
                print("F + '\(three)' (background)          tabs \(tabsBefore)->\(controller.tabCount), title=\(pane.webView.title ?? "-")")
            }
            _ = try? await pane.webView.evaluateJavaScript("document.getElementById('field').focus()")
            await pause(0.3)
            await press("f")
            print("f while typing in a field          hints=\(await hintLabels().count)")
            _ = try? await pane.webView.evaluateJavaScript("document.activeElement.blur()")
            Settings.linkHintsEnabled = false
            await pause(0.3)
            await press("f")
            print("f with hints disabled              hints=\(await hintLabels().count)")
            Settings.linkHintsEnabled = true

            // Vim-style scrolling.
            let tall = "<title>tall</title><div style='height:6000px'>top</div>"
            pane.webView.loadHTMLString(tall, baseURL: URL(string: "https://example.com/"))
            await pause(1.5)
            window.makeFirstResponder(pane.webView)
            func scrollY() async -> Int {
                (try? await pane.webView.evaluateJavaScript("Math.round(scrollY)")) as? Int ?? -1
            }
            await press("jj")
            await pause(0.5)
            print("vim jj                             scrollY=\(await scrollY())")
            await press("k")
            await pause(0.5)
            print("vim k                              scrollY=\(await scrollY())")
            await press("g", shift: true)
            await pause(1)
            print("vim G                              scrollY=\(await scrollY())")
            await press("gg")
            await pause(1)
            print("vim gg                             scrollY=\(await scrollY())")
            let wide = "<title>wide</title><div style='width:6000px;height:100px'>left</div>"
            pane.webView.loadHTMLString(wide, baseURL: URL(string: "https://example.com/"))
            await pause(1.5)
            window.makeFirstResponder(pane.webView)
            func scrollX() async -> Int {
                (try? await pane.webView.evaluateJavaScript("Math.round(scrollX)")) as? Int ?? -1
            }
            await press("ll")
            await pause(0.5)
            print("vim ll                             scrollX=\(await scrollX())")
            await press("h")
            await pause(0.5)
            print("vim h                              scrollX=\(await scrollX())")

            // Find in page.
            let text = "<title>find</title><p>apple banana apple</p><p>cherry APPLE</p>"
            pane.webView.loadHTMLString(text, baseURL: URL(string: "https://example.com/"))
            await pause(1.5)
            window.makeFirstResponder(pane.webView)
            await ensureActive(window)
            post("f", keyCode: 3, modifiers: [.command], window: window)
            await pause(0.5)
            let fieldFocused = (window.firstResponder as? NSTextView)?.delegate === pane.findBar.field
            print("⌘F                                 bar visible=\(!pane.findBar.isHidden) field focused=\(fieldFocused)")
            pane.findBar.field.stringValue = "apple"
            pane.findBar.onChange?("apple")
            await pause(1)
            print("find 'apple'                       \(pane.findBar.statusText)")
            pane.findNext()
            await pause(0.7)
            print("next                               \(pane.findBar.statusText)")
            pane.findPrevious()
            await pause(0.7)
            print("previous                           \(pane.findBar.statusText)")
            let painted = (try? await pane.webView.evaluateJavaScript(
                "[CSS.highlights.get('browser-find')?.size ?? 0, CSS.highlights.get('browser-find-current')?.size ?? 0].join('/')"
            )) as? String ?? "-"
            print("highlights (all/current)           \(painted)")
            pane.findBar.field.stringValue = "zzz"
            pane.findBar.onChange?("zzz")
            await pause(1)
            print("find 'zzz'                         \(pane.findBar.statusText)")
            pane.hideFindBar()

            Settings.vimKeysEnabled = false
            await pause(0.3)
            await press("j")
            await pause(0.5)
            print("vim j while disabled               scrollY=\(await scrollY())")
            Settings.vimKeysEnabled = true

            // Hints across panes: one session over a left and a right pane.
            func paneLabels(of target: PaneView) async -> [String] {
                await withCheckedContinuation { continuation in
                    target.webView.evaluateJavaScript("window.__browserHints.debugLabels()", in: nil, in: LinkHints.contentWorld) {
                        continuation.resume(returning: (try? $0.get()) as? [String] ?? [])
                    }
                }
            }
            let example = URL(string: "https://example.com/")
            let left = controller.addTab()
            left.webView.loadHTMLString(
                ##"<title>left</title><a id="l1" href="#" onclick="document.title='left clicked';return false">L1</a> "##
                    + ##"<a id="l2" href="#" onclick="return false">L2</a>"##,
                baseURL: example
            )
            controller.splitRight(nil)
            if let right = controller.focusedPane, right !== left {
                right.webView.loadHTMLString(
                    ##"<title>right</title><a id="r1" href="#" onclick="document.title='right clicked';return false">R1</a>"##,
                    baseURL: example
                )
                await pause(1.5)
                controller.focus(left)
                await pause(0.3)
                await press("f")
                await pause(0.5)
                let leftLabels = await paneLabels(of: left), rightLabels = await paneLabels(of: right)
                print("all panes: f in left               left=\(leftLabels) right=\(rightLabels)")
                if let r1 = rightLabels.first(where: { $0.hasSuffix(":r1") })?.split(separator: ":").first {
                    await press(String(r1))
                    await pause(0.5)
                    print("all panes: typed '\(r1)'              right=\(right.webView.title ?? "-") focus moved right=\(controller.focusedPane === right)")
                }
                Settings.linkHintsAllPanes = false
                controller.focus(left)
                await pause(0.3)
                await press("f")
                await pause(0.5)
                print("all panes off: f in left           left=\(await paneLabels(of: left).count) right=\(await paneLabels(of: right).count)")
                post("\u{1b}", keyCode: 53, modifiers: [], window: window)
                Settings.linkHintsAllPanes = true
            }
        }

        await runSidebar(controller)

        // Downloads (into BROWSER_DOWNLOADS_DIR): a download-attribute link twice, then a zip attachment.
        if let pane = controller.focusedPane {
            let manager = DownloadManager.shared
            func latest() -> String {
                guard let item = manager.items.first else { return "none" }
                let content = item.destination.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                return "\(item.filename) state=\(item.state) bytes=\(item.receivedBytes) text=\(content.map { $0.count < 20 ? $0 : "…" } ?? "-")"
            }
            pane.webView.loadHTMLString(
                ##"<title>dl</title><a id="d" href="data:text/plain;base64,aGVsbG8=" download="hello.txt">get</a>"##,
                baseURL: URL(string: "https://example.com/")
            )
            await pause(1.5)
            for label in ["download link", "download link again"] {
                _ = try? await pane.webView.evaluateJavaScript("document.getElementById('d').click()")
                await pause(2)
                print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(latest()) popover=\(controller.isDownloadsPopoverShown)")
            }
            pane.webView.load(URLRequest(url: URL(string: "https://github.com/github/gitignore/archive/refs/heads/main.zip")!))
            for _ in 0..<40 {
                await pause(0.5)
                if manager.items.first?.filename.hasSuffix(".zip") == true, manager.items.first?.state != .downloading { break }
            }
            print("zip attachment                     \(latest())")
            // Context menu "Download Image": right-click target reported by the page script,
            // then WebKit's menu item re-pointed by willOpenMenu.
            pane.webView.loadHTMLString(
                ##"<title>img</title><img id="i" src="https://github.com/favicon.ico" width="64" height="64">"##,
                baseURL: URL(string: "https://example.com/")
            )
            await pause(2)
            _ = try? await pane.webView.evaluateJavaScript(
                "document.getElementById('i').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true}))"
            )
            await pause(0.5)
            let menu = NSMenu()
            let item = NSMenuItem(title: "Download Image", action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadImage")
            menu.addItem(item)
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                pane.webView.willOpenMenu(menu, with: event)
            }
            if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            for _ in 0..<20 {
                await pause(0.5)
                if manager.items.first?.filename == "favicon.ico", manager.items.first?.state != .downloading { break }
            }
            print("context menu Download Image        target=\(pane.webView.contextTarget.image?.absoluteString ?? "-") \(latest())")
            print("downloads folder                   \(manager.downloadsFolder.path)")
        }

        // Settings window opens centred over the browser window.
        if let app = NSApp.delegate as? AppDelegate, let browser = controller.window {
            app.showSettings(nil)
            await pause(1)
            if let settings = NSApp.windows.first(where: { $0.title == "Settings" && $0.isVisible }) {
                let dx = Int(settings.frame.midX - browser.frame.midX), dy = Int(settings.frame.midY - browser.frame.midY)
                print("settings centre offset             dx=\(dx) dy=\(dy) size=\(Int(settings.frame.width))x\(Int(settings.frame.height))")
                settings.close()
            } else {
                print("settings centre offset             settings window not found")
            }
        }

        await step("⌘W in tab 1", [("w", 13, [.command])])
    }

    /// A real left click (down + up) at `point` in window coordinates, through `NSWindow.sendEvent`.
    private static func click(at point: NSPoint, in window: NSWindow?) async {
        guard let window else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { continue }
            window.sendEvent(event)
            await pause(0.05)
        }
    }

    /// ⌘-shortcuts only reach the app while it is active; the user may switch apps mid-run.
    private static func ensureActive(_ window: NSWindow?) async {
        guard !NSApp.isActive || NSApp.keyWindow == nil else { return }
        print("(app was not active — re-activating)")
        for _ in 0..<20 where !NSApp.isActive || NSApp.keyWindow == nil {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            await pause(0.25)
        }
    }

    private static func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(key)!)) }

    private static func pause(_ seconds: Double = 1) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func post(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow?) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return }
        if modifiers.intersection([.command, .control]).isEmpty, keyCode != 111 {
            // Plain typing goes straight to the window, so it works even when another app is active.
            window?.sendEvent(event)
        } else {
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Session restore, in two launches with the same `BROWSER_SESSION_FILE`. The first builds two
    /// tabs (a split with back history and zoom, and one in the background), checks the file and a
    /// restore into a second window, then quits, which saves the session. The second launch checks
    /// what came back. No key events.
    private static func runSession(_ controller: BrowserWindowController) async {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 44, withPad: " ", startingAt: 0)) \(detail)")
        }
        func page(_ name: String) -> URL {
            URL(string: "data:text/html,<title>\(name)</title><h1>\(name)</h1>")!
        }
        func describePanes<Panes: Sequence<PaneView>>(_ panes: Panes) -> String {
            panes.map {
                "\($0.displayTitle)[\($0.pendingRestore != nil ? "pending" : $0.webView.url == nil ? "blank" : "loaded")"
                    + " back=\($0.webView.canGoBack) zoom=\(Int(($0.webView.pageZoom * 100).rounded()))]"
            }.joined(separator: " ")
        }
        guard let fileURL = SessionStore.fileURL else {
            print("FAIL: set BROWSER_SESSION_FILE"); return
        }
        let expectedTree = "tabs=2 sel=0 | H0.60(B, *C)"
        let expectedFrame = NSRect(x: 120, y: 140, width: 1000, height: 700)

        if controller.tabCount == 2 {
            // Second launch: the session from the first came back.
            print("restored: \(controller.debugDescriptionOfState)")
            check("same tabs and split", controller.debugDescriptionOfState == expectedTree, controller.debugDescriptionOfState)
            check("window frame", controller.window?.frame == expectedFrame, "\(controller.window?.frame ?? .zero)")
            await pause(1.5)
            let panes = describePanes(controller.debugPanes)
            check("pages, history and zoom", panes == "B[loaded back=true zoom=100] C[loaded back=false zoom=110]", panes)
            check("pane C has focus", controller.focusedPane?.displayTitle == "C")
            let waiting = describePanes(controller.allPanes.suffix(1))
            check("background tab waits until shown", waiting == "D[pending back=false zoom=100]", waiting)
            controller.selectTab(at: 1)
            await pause(1)
            check("…then loads", describePanes(controller.debugPanes) == "D[loaded back=false zoom=100]", describePanes(controller.debugPanes))
            print(failures == 0 ? "session (restored): all ok" : "session (restored): \(failures) FAILED")
            return
        }

        try? FileManager.default.removeItem(at: fileURL)
        controller.window?.setFrame(expectedFrame, display: true)
        controller.focusedPane?.webView.load(URLRequest(url: page("A")))
        await pause(0.7)
        controller.focusedPane?.webView.load(URLRequest(url: page("B")))
        await pause(0.7)
        controller.splitRight(nil)
        controller.focusedPane?.webView.load(URLRequest(url: page("C")))
        controller.focusedPane?.zoomIn()
        (controller.focusedPane?.superview as? SplitView)?.ratio = 0.6
        controller.addTab(request: URLRequest(url: page("D")), select: false)
        await pause(SessionStore.saveDelay + 0.5)
        print("built:    \(controller.debugDescriptionOfState)  \(describePanes(controller.debugPanes))")
        check("tree as expected", controller.debugDescriptionOfState == expectedTree, controller.debugDescriptionOfState)

        // Written by itself (within `saveDelay` of a change).
        let saved = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(SavedSession.self, from: $0) }
        check("session file written", saved != nil, "\((try? Data(contentsOf: fileURL))?.count ?? 0) bytes")
        guard let window = saved?.windows.first else {
            print("session: \(failures) FAILED"); return
        }
        let titles = window.tabs.map { $0.panes.map(\.title).joined(separator: "+") }
        check("one window, two tabs", saved?.windows.count == 1 && titles == ["B+C", "D"], "\(titles)")
        check("panes keep their history", window.tabs[0].panes.allSatisfy { $0.state != nil })
        check("zoom and focus", window.tabs[0].panes.map(\.zoom) == [nil, 1.1] && window.tabs[0].panes.map(\.focused) == [false, true])

        // Restoring into another window gives the same tabs; the background one waits.
        let copy = BrowserWindowController()
        copy.restore(window)
        copy.showWindow(nil)
        check("restored copy matches", copy.debugDescriptionOfState == expectedTree, copy.debugDescriptionOfState)
        await pause(1.5)
        check("copy's pages, history and zoom",
              describePanes(copy.debugPanes) == "B[loaded back=true zoom=100] C[loaded back=false zoom=110]", describePanes(copy.debugPanes))
        let waiting = describePanes(copy.allPanes.suffix(1))
        check("background tab pending until selected", waiting == "D[pending back=false zoom=100]", waiting)
        copy.selectTab(at: 1)
        await pause(1)
        check("…then loaded", describePanes(copy.debugPanes) == "D[loaded back=false zoom=100]", describePanes(copy.debugPanes))
        copy.window?.close()

        // A change that leaves the session as it was doesn't touch the file.
        func modified() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        }
        await pause(SessionStore.saveDelay + 0.5)  // closing the copy's window queued a save
        let before = modified()
        controller.selectTab(at: 0)  // already selected: queues a save with nothing new
        await pause(SessionStore.saveDelay + 0.5)
        check("unchanged session isn't rewritten", before != nil && modified() == before)

        // Turning it off removes the file; turning it back on writes it again.
        Settings.restoreSession = false
        check("off removes the file", !FileManager.default.fileExists(atPath: fileURL.path))
        controller.selectTab(at: 1)
        controller.selectTab(at: 0)
        await pause(SessionStore.saveDelay + 0.5)
        check("…and nothing is written", !FileManager.default.fileExists(atPath: fileURL.path))
        Settings.restoreSession = true
        check("on writes it again", FileManager.default.fileExists(atPath: fileURL.path))
        print(failures == 0 ? "session: all ok (quitting saves it; run again to check the restore)" : "session: \(failures) FAILED")
    }

    /// The status bar layout: every size × position keeps the bar clear of the panes, clicking a
    /// number selects its tab, `statusBarItems` orders the bar, and zen mode hides it (mouse events only).
    private static func runStatusBar(_ controller: BrowserWindowController, outputDir: URL) async {
        let root = controller.debugContentRoot
        let bar = root.statusBar
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label)")
        }
        controller.focusedPane?.load("data:text/html,<title>One</title><h1>One</h1>")
        for title in ["Two", "Three"] {
            controller.addTab(request: URLRequest(url: URL(string: "data:text/html,<title>\(title)</title><h1>\(title)</h1>")!))
        }
        Settings.tabLayout = .statusBar
        Settings.addressBarMode = .perPane
        await pause(1)

        for position in StatusBarPosition.allCases {
            for size in StatusBarSize.allCases {
                Settings.statusBarPosition = position
                Settings.statusBarSize = size
                await pause(0.3)
                let name = "\(position) \(size)"
                let content = root.tabContent?.frame ?? .zero
                // The panes sit inside their container's margin.
                let panes = content.insetBy(dx: PaneContainerView.margin, dy: PaneContainerView.margin)
                check("\(name): bar shown, strip hidden", !bar.isHidden && root.tabStrip.isHidden)
                check("\(name): bar height \(Int(bar.frame.height)) inside the window",
                      bar.frame.height == size.height && root.bounds.contains(bar.frame))
                check("\(name): panes clear of the bar", !panes.intersects(bar.frame))
                check("\(name): one box per tab", bar.debugTabRects.count == 3)
                check("\(name): title after the tabs", bar.debugTitleRect.minX > (bar.debugTabRects.last?.maxX ?? .infinity)
                      && bar.debugTitleRect.width > 0)
                snapshot(controller, to: outputDir.appendingPathComponent("statusbar-\(position)-\(size).png"))
            }
        }
        Settings.statusBarPosition = .bottom
        Settings.statusBarSize = .m
        await pause(0.3)
        check("title is the selected tab's", bar.title == "Three")

        let first = bar.debugTabRects[0]
        await click(at: bar.convert(NSPoint(x: first.midX, y: first.midY), to: nil), in: controller.window)
        await pause(0.3)
        check("clicking 1 selects the first tab", controller.selectedTabIndex == 0 && bar.title == "One")

        Settings.addressBarMode = .shared
        await pause(0.3)
        let address = root.header.addressBarView.convert(root.header.addressBarView.bounds, to: root)
        check("shared address bar clears the navigation buttons", !address.intersects(root.navigationButtons.frame))
        snapshot(controller, to: outputDir.appendingPathComponent("statusbar-shared.png"))
        Settings.addressBarMode = .perPane

        Settings.statusBarItems = [.title, .spacer, .tabs]
        await pause(0.3)
        check("items reorder: title, then tabs at the right end",
              bar.debugTitleRect.maxX <= (bar.debugTabRects.first?.minX ?? 0)
              && abs((bar.debugTabRects.last?.maxX ?? 0) - (bar.bounds.width - 10)) < 1)
        snapshot(controller, to: outputDir.appendingPathComponent("statusbar-reordered.png"))
        Settings.statusBarItems = Settings.defaultStatusBarItems

        for style in StatusBarTabStyle.allCases {
            Settings.statusBarTabStyle = style
            await pause(0.3)
            check("\(style): one box per tab, title after them", bar.debugTabRects.count == 3
                  && bar.debugTitleRect.minX > (bar.debugTabRects.last?.maxX ?? .infinity))
            snapshot(controller, to: outputDir.appendingPathComponent("statusbar-style-\(style).png"))
        }
        // A split tab: its favicon gets cards stacked behind it, so its box widens (two panes behind at most).
        Settings.statusBarTabStyle = .favicons
        await pause(0.3)
        let single = bar.debugTabRects[0].width
        controller.splitRight(nil)
        await pause(0.5)
        let two = bar.debugTabRects[0].width
        controller.splitRight(nil)
        controller.splitRight(nil)
        await pause(0.5)
        let four = bar.debugTabRects[0].width
        check("split tab's box widens for its stack (\(Int(single)) → \(Int(two)) → \(Int(four)))", two > single && four > two)
        snapshot(controller, to: outputDir.appendingPathComponent("statusbar-stack.png"))
        Settings.statusBarTabStyle = .numbers

        controller.toggleZenMode(nil)
        await pause(0.3)
        check("zen mode hides the bar", bar.isHidden)
        Settings.statusBarInZen = true
        for position in StatusBarPosition.allCases {
            Settings.statusBarPosition = position
            await pause(0.3)
            let panes = (root.tabContent?.frame ?? .zero).insetBy(dx: PaneContainerView.margin, dy: PaneContainerView.margin)
            check("zen \(position): bar shown, rest of the chrome hidden",
                  !bar.isHidden && root.header.isHidden && root.navigationButtons.isHidden && root.bounds.contains(bar.frame))
            check("zen \(position): panes clear of the bar", !panes.intersects(bar.frame))
            snapshot(controller, to: outputDir.appendingPathComponent("statusbar-zen-\(position).png"))
        }
        Settings.statusBarPosition = .bottom
        Settings.statusBarInZen = false
        await pause(0.3)
        check("turning it off hides it in zen", bar.isHidden)
        controller.toggleZenMode(nil)
        await pause(0.3)
        check("leaving zen brings it back", !bar.isHidden)

        Settings.tabLayout = .horizontal
        await pause(0.3)
        check("horizontal layout hides it", bar.isHidden && !root.tabStrip.isHidden)
        print(failures == 0 ? "statusbar: all ok" : "statusbar: \(failures) FAILED")
    }

    /// Every tab layout × address bar mode (× auto-hide sidebar, collapsed and revealed): the address
    /// bar must clear the navigation buttons, and revealing the sidebar must not move it.
    private static func runLayout(_ controller: BrowserWindowController, outputDir: URL) async {
        let root = controller.debugContentRoot
        controller.focusedPane?.load("data:text/html,<title>Layout</title><h1>Layout</h1>")
        await pause(0.5)
        var failures = 0
        func addressBarFrame() -> NSRect? {
            let bar = Settings.addressBarMode == .shared ? root.header.addressBarView : controller.focusedPane?.addressBarView
            guard let bar, !bar.isHiddenOrHasHiddenAncestor else { return nil }
            return bar.convert(bar.bounds, to: root)
        }
        func check(_ label: String) -> NSRect? {
            let bar = addressBarFrame(), buttons = root.navigationButtons.frame
            let overlaps = bar.map { $0.intersects(buttons) } ?? false
            if overlaps { failures += 1 }
            print("\(overlaps ? "FAIL" : "ok  ") \(label.padding(toLength: 40, withPad: " ", startingAt: 0)) bar=\(bar.map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "-") buttons=\(Int(buttons.minX))…\(Int(buttons.maxX))")
            return bar
        }
        for layout in [TabLayout.horizontal, .vertical, .statusBar] {
            for mode in [AddressBarMode.shared, .perPane] {
                Settings.tabLayout = layout
                Settings.addressBarMode = mode
                Settings.sidebarAutoHide = false
                await pause(0.5)
                let name = "\(layout) \(mode)"
                _ = check(name)
                snapshot(controller, to: outputDir.appendingPathComponent("layout-\(layout)-\(mode).png"))
                guard layout == .vertical else { continue }
                Settings.sidebarAutoHide = true
                await pause(0.5)
                let collapsed = check("\(name) auto-hide collapsed")
                controller.toggleSidebar(nil)
                await pause(0.5)
                let revealed = check("\(name) auto-hide revealed")
                snapshot(controller, to: outputDir.appendingPathComponent("layout-\(layout)-\(mode)-revealed.png"))
                let stays = collapsed == revealed
                if !stays { failures += 1 }
                print("\(stays ? "ok  " : "FAIL") \("\(name) bar stays on reveal".padding(toLength: 40, withPad: " ", startingAt: 0))")
                controller.toggleSidebar(nil)
                await pause(0.5)
            }
        }
        Settings.sidebarAutoHide = false
        Settings.tabLayout = .horizontal
        Settings.addressBarMode = .perPane
        // Button feedback: back hovered, reload pressed, the selected tab's close button hovered.
        await pause(0.3)
        root.navigationButtons.debugSetStates(hoverBack: true, pressReload: true)
        root.tabStrip.debugSetCloseHovered(true)
        snapshot(controller, to: outputDir.appendingPathComponent("nav-feedback.png"))
        await requestScreenCapture("nav-feedback", of: controller, in: outputDir)
        root.navigationButtons.debugSetStates(hoverBack: false, pressReload: false)
        root.tabStrip.debugSetCloseHovered(false)
        print(failures == 0 ? "layout: all ok" : "layout: \(failures) FAILED")
    }

    /// ⌘⇧P: menu commands with shortcuts and checkmarks, run on the focused pane; ⌘P and
    /// deleting the `>` go back to bookmarks.
    private static func runPaletteCommands(_ controller: BrowserWindowController, outputDir: URL) async {
        let palette = controller.debugCommandPalette
        let window = controller.window
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 40, withPad: " ", startingAt: 0)) shown=\(palette.isShown) "
                  + "query=\"\(palette.debugQuery)\" results=\(palette.debugResults.prefix(6)) zen=\(controller.isZenMode) \(controller.debugDescriptionOfState)")
        }
        let keyCodes: [Character: UInt16] = [
            ">": 47, "r": 15, "v": 9, "i": 34, "z": 6, "e": 14, "n": 45, "s": 1, "l": 37, "c": 8, "t": 17, "2": 19, "o": 31, "p": 35, "y": 16, " ": 49, "\u{7f}": 51,
        ]
        func type(_ text: String) async {
            for character in text {
                post(String(character), keyCode: keyCodes[character] ?? 0, modifiers: character == ">" ? [.shift] : [], window: window)
                await pause(0.1)
            }
            await pause(0.3)
        }
        func open() async {
            await ensureActive(window)
            post("P", keyCode: 35, modifiers: [.command, .shift], window: window)
            await pause(0.5)
        }
        func openBookmarks() async {
            await ensureActive(window)
            post("p", keyCode: 35, modifiers: [.command], window: window)
            await pause(0.5)
        }
        func enter() async {
            post("\r", keyCode: 36, modifiers: [], window: window)
            await pause(0.6)
        }

        controller.focusedPane?.load("data:text/html,<title>One</title><h1>One</h1>")
        await pause(1)
        controller.focusedPane?.focusWebView()
        await openBookmarks()
        check("⌘P: bookmarks mode", palette.isShown && !palette.debugResults.contains("Zen Mode"))
        await open()
        check("⌘⇧P switches to commands", palette.isShown && palette.debugQuery == ">")
        await openBookmarks()
        check("⌘P switches back", palette.isShown && palette.debugQuery.isEmpty && !palette.debugResults.contains("Zen Mode"))
        await openBookmarks()
        check("⌘P again closes", !palette.isShown)
        await open()
        let all = palette.debugResults
        print("commands: \(zip(all, palette.debugShortcuts).map { $0.1.isEmpty ? $0.0 : "\($0.0) \($0.1)" })")
        check("'>' lists menu commands", all.contains("Zen Mode") && all.contains("Split Right") && all.contains("Find…"))
        check("no text editing or palette itself", !all.contains { ["Copy", "Paste", "Undo", "Select All", "Command Palette…", "Search Bookmarks…"].contains($0) })
        check("app menu last", all.last == "Quit Rosa")
        let zenShortcut = zip(all, palette.debugShortcuts).first { $0.0 == "Zen Mode" }?.1
        let leftShortcut = zip(all, palette.debugShortcuts).first { $0.0 == "Focus Pane Left" }?.1
        check("shortcuts shown (⌃⌘Z, ⌥⌘←)", zenShortcut == "⌃⌘Z" && leftShortcut == "⌥⌘←")
        await requestScreenCapture("palette-commands", of: controller, in: outputDir)
        await type("v")
        snapshot(controller, to: outputDir.appendingPathComponent("palette-commands-v.png"))
        await type("\u{7f}zen")
        check("'>zen' finds Zen Mode first", palette.debugSelectedTitle == "Zen Mode")
        await enter()
        check("↩ runs it, focus back on the page", !palette.isShown && controller.isZenMode
              && window?.firstResponder === controller.focusedPane?.webView)
        await open()
        await type(" zen")
        await enter()
        check("'> zen' (space) runs it again", !controller.isZenMode)

        await open()
        await type("split r")
        check("'>split r' finds Split Right", palette.debugSelectedTitle == "Split Right")
        await enter()
        check("Split Right splits", controller.debugPanes.count == 2 && controller.debugDescriptionOfState.contains("H0.50"))
        controller.focusedPane?.load("data:text/html,<title>Two</title><h1>Two</h1>")
        await pause(0.8)
        controller.focusedPane?.focusWebView()
        controller.newTab(nil)
        await pause(0.5)
        controller.focusedPane?.load("data:text/html,<title>Three</title><h1>Three</h1>")
        await pause(0.8)
        controller.focusedPane?.focusWebView()
        await open()
        await type("tab")
        check("no Select Tab rows", !palette.debugResults.contains { $0.hasPrefix("Select") } && palette.debugResults.contains("Show Next Tab"))
        post("\u{1b}", keyCode: 53, modifiers: [], window: window)
        await pause(0.3)

        await openBookmarks()
        palette.debugSetQuery("example.com")
        check("an address is the first row", palette.debugResults.first == "Open example.com")
        palette.debugSetQuery("rosa browser")
        check("other text: search row last", palette.debugResults.last?.hasPrefix("Search ") == true
              && palette.debugResults.last?.hasSuffix("for “rosa browser”") == true)
        palette.debugSetQuery("data:text/html,<title>Typed</title><h1>Typed</h1>")
        await enter()
        await pause(0.5)
        check("↩ on it loads in the focused pane", !palette.isShown && controller.focusedPane?.displayTitle == "Typed")

        await open()
        await type("\u{7f}")
        check("deleting '>' goes back to bookmarks", palette.isShown && !palette.debugResults.contains("Zen Mode"))
        post("\u{1b}", keyCode: 53, modifiers: [], window: window)
        await pause(0.3)
        print(failures == 0 ? "commands: all ok" : "commands: \(failures) FAILED")
    }

    /// Zen mode (⌃⌘Z): no chrome in any layout, panes fill the window, the same key brings it all
    /// back, and ⌘L leaves it with the address bar focused.
    /// ⌘§ tab overview: previews of tabs that aren't on screen, moving, closing, reopening, picking.
    private static func runTabOverview(_ controller: BrowserWindowController, outputDir: URL) async {
        let overview = controller.debugTabOverview
        let window = controller.window
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 44, withPad: " ", startingAt: 0)) \(controller.debugDescriptionOfState) hl=\(overview.highlightedIndex)")
        }
        func key(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) async {
            await ensureActive(window)
            post(characters, keyCode: keyCode, modifiers: modifiers, window: window)
            await pause(0.4)
        }
        func toggle() async { await key("§", 10, [.command]) }
        func page(_ name: String, _ color: String) -> String {
            // Busy pages (text and stripes over the colour) so repainting shows up in recordings.
            let lines = (1...80).map { "<p style='margin:2px;font:14px Georgia;background:linear-gradient(90deg,white,transparent)'>\(name) line \($0): the quick brown fox jumps over the lazy dog, 0123456789</p>" }.joined()
            let html = "<title>\(name)</title><body style='background:\(color)'><h1>\(name)</h1>\(lines)"
            return "data:text/html;base64,\(Data(html.utf8).base64EncodedString())"
        }
        /// The preview's colour near its right edge, past the text, where the page background shows.
        func previewColor(_ image: NSImage?) -> NSColor? {
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cg)
            return rep.colorAt(x: rep.pixelsWide * 19 / 20, y: rep.pixelsHigh * 3 / 4)?.usingColorSpace(.sRGB)
        }
        func isYellow(_ color: NSColor?) -> Bool {
            guard let color else { return false }
            return color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent < 0.3
        }
        func isRed(_ color: NSColor?) -> Bool {
            guard let color else { return false }
            return color.redComponent > 0.8 && color.greenComponent < 0.3 && color.blueComponent < 0.3
        }

        Settings.tabLayout = .horizontal
        Settings.addressBarMode = ProcessInfo.processInfo.environment["BROWSER_SELFTEST_SHARED_BAR"] != nil ? .shared : .perPane
        controller.focusedPane?.load(page("A", "red"))
        for (name, color) in [("B", "green"), ("C", "blue"), ("D", "orange"), ("E", "purple")] {
            controller.addTab(request: URLRequest(url: URL(string: page(name, color))!), select: false)
        }
        await pause(1.5)
        controller.selectTab(at: 1)
        controller.splitRight(nil)
        controller.focusedPane?.load(page("B2", "cyan"))
        await pause(1)
        controller.selectTab(at: 2)
        await pause(0.5)
        let root = controller.debugContentRoot
        let liveWebView = controller.focusedPane?.webView
        let liveSize = liveWebView?.bounds.size
        let contentFrame = root.tabContent?.frame

        await toggle()
        await pause(1.5)
        check("⌘§ opens it, highlighting the current tab", overview.isShown && overview.highlightedIndex == 2
              && window?.firstResponder === overview)
        check("one card per tab", overview.debugTitles == ["A", "B2", "C", "D", "E"])
        let previews = controller.debugTabPreviews
        check("every tab has a preview", previews.allSatisfy { $0 != nil })
        print("     preview sizes: \(previews.map { $0.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "-" })")
        for (index, preview) in previews.enumerated() {
            guard let cg = preview?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            try? png?.write(to: outputDir.appendingPathComponent("overview-preview-\(index).png"))
        }
        print("     tab A centre colour: \(previewColor(previews[0]).map { "\($0)" } ?? "-")")
        check("off-screen tab A's preview shows its page", isRed(previewColor(previews[0])))
        snapshot(controller, to: outputDir.appendingPathComponent("overview-1-open.png"))
        check("the current tab is live in its card", overview.debugLiveCard?.index == 2 && liveWebView?.window === window
              && root.tabContent?.superview !== root)
        check("its page keeps its size (no reflow)", liveWebView?.bounds.size == liveSize)
        print("     live card frame: \(overview.debugLiveCard.map { "\($0.frame)" } ?? "-")")
        await screenCapture(window, name: "overview-live-1", outputDir: outputDir)
        _ = try? await liveWebView?.evaluateJavaScript("document.body.style.background = 'yellow'; document.querySelector('h1').textContent = 'Live!'")
        await pause(0.5)
        await screenCapture(window, name: "overview-live-2", outputDir: outputDir)

        // The live card follows the highlight; the tab left behind keeps a fresh snapshot.
        let tabD = controller.allPanes[4].webView
        // With BROWSER_SELFTEST_SCREENCAPTURE, the driver records frames while burst.request exists.
        let burst = outputDir.appendingPathComponent("burst.request")
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_SCREENCAPTURE"] != nil, let window {
            // The window's rect in screen coordinates from the top left, for `screencapture -v -R`.
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let frame = window.frame
            let rect = "\(Int(frame.minX)),\(Int(screenHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
            try? rect.write(to: burst, atomically: true, encoding: .utf8)
            await pause(1.5)  // recording takes a moment to start
        }
        await key("l", 37)
        await pause(0.5)
        try? "".write(to: outputDir.appendingPathComponent("burst.stop"), atomically: true, encoding: .utf8)
        check("moving makes the highlighted tab live", overview.debugLiveCard?.index == 3 && tabD.window === window
              && liveWebView?.window == nil)
        check("the tab left behind got a fresh snapshot", isYellow(previewColor(controller.debugTabPreviews[2])))
        _ = try? await tabD.evaluateJavaScript("document.body.style.background = 'pink'; document.querySelector('h1').textContent = 'Live D!'")
        await pause(0.5)
        await screenCapture(window, name: "overview-live-3", outputDir: outputDir)
        await key("h", 4)
        await pause(0.5)
        check("and back", overview.debugLiveCard?.index == 2 && liveWebView?.window === window && tabD.window == nil)

        await key("l", 37)
        check("L moves right", overview.highlightedIndex == 3)
        await key("h", 4)
        await key("h", 4)
        check("H moves left", overview.highlightedIndex == 1)
        let columns = overview.debugColumns
        await key("j", 38)
        check("J moves down a row (\(columns) columns)", overview.highlightedIndex == min(1 + columns, 4) || columns >= 5)
        await key("k", 40)
        check("K moves back up", overview.highlightedIndex == 1)
        await key("k", 40, [.control])
        await key("l", 37, [.control])
        check("⌃L moves too", overview.highlightedIndex == 2)
        await key("G", 5, [.shift])
        check("⇧G goes to the last", overview.highlightedIndex == 4)

        await key("x", 7)
        check("X closes the highlighted tab, stays open", overview.isShown && controller.debugTabTitles == ["A", "B2", "C", "D"]
              && overview.highlightedIndex == 3 && window?.firstResponder === overview)
        await key("g", 5)
        await key("w", 13, [.command])
        check("⌘W closes the highlighted tab", controller.debugTabTitles == ["B2", "C", "D"] && overview.isShown)
        await key("u", 32)
        await pause(0.5)
        check("U reopens it and highlights it", controller.debugTabTitles.first == "A" && overview.highlightedIndex == 0
              && window?.firstResponder === overview)

        await key("r", 15, [.command])
        check("page commands are off while open", overview.isShown)

        await key("f", 3)
        let hints = overview.debugHints
        check("F labels the cards", hints.allSatisfy { $0 != nil } && Set(hints.compactMap { $0 }).count == hints.count)
        snapshot(controller, to: outputDir.appendingPathComponent("overview-2-hints.png"))
        await screenCapture(window, name: "overview-hints", outputDir: outputDir)
        if hints.count > 3, let label = hints[3] {
            for character in label { await key(String(character), keyCodeForHint(character)) }
        }
        check("typing a label switches to that tab", !overview.isShown && controller.selectedTabIndex == 3)

        await toggle()
        await key("2", 19)
        check("2 picks the second tab", !overview.isShown && controller.selectedTabIndex == 1)

        await toggle()
        await key("l", 37)
        await key("\u{1b}", 53)
        check("Esc goes back to the same tab", !overview.isShown && controller.selectedTabIndex == 1
              && window?.firstResponder === controller.focusedPane?.webView)
        check("its pages are back in place", root.tabContent?.superview === root && root.tabContent?.frame == contentFrame)

        await toggle()
        await key("l", 37)
        await key("\r", 36)
        check("↩ switches to the highlighted tab", !overview.isShown && controller.selectedTabIndex == 2)

        await toggle()
        await toggle()
        check("⌘§ again closes it", !overview.isShown && controller.selectedTabIndex == 2)

        await toggle()
        check("no search field until /", overview.debugSearchField.isHiddenOrHasHiddenAncestor)
        await key("/", 44)
        check("/ starts a search, field showing", overview.isSearching && !overview.debugSearchField.isHiddenOrHasHiddenAncestor)
        await key("b", 11)
        await key("2", 19)
        check("typing keeps the matching tabs", overview.debugVisibleTitles == ["B2"] && overview.highlightedIndex == 1)
        await screenCapture(window, name: "overview-search", outputDir: outputDir)
        await key("\r", 36)
        check("↩ switches to the match", !overview.isShown && controller.selectedTabIndex == 1)
        await toggle()
        await key("/", 44)
        await key("b", 11)
        await key("2", 19)
        await key("w", 13, [.command])
        check("⌘W in a search closes the match, keeps typing", controller.debugTabTitles == ["A", "C", "D"]
              && overview.isSearching && overview.debugVisibleTitles.isEmpty)
        await key("\u{1b}", 53)
        check("Esc drops the search and the field", overview.isShown && !overview.isSearching && overview.debugVisibleTitles.count == 3
              && overview.debugSearchField.stringValue.isEmpty && overview.debugSearchField.isHiddenOrHasHiddenAncestor)
        await key("\u{1b}", 53)
        check("Esc again closes it", !overview.isShown && root.tabContent?.superview === root)
        print(failures == 0 ? "overview: all passed" : "overview: \(failures) FAILED")
    }

    /// A real capture of the window, taken by the test driver (`screencapture -l`, which needs the
    /// screen recording permission the app doesn't have): with `BROWSER_SELFTEST_SCREENCAPTURE` set,
    /// writes `<name>.request` holding the window number and waits for the driver to write `<name>.png`.
    private static func screenCapture(_ window: NSWindow?, name: String, outputDir: URL) async {
        guard ProcessInfo.processInfo.environment["BROWSER_SELFTEST_SCREENCAPTURE"] != nil, let window else { return }
        let image = outputDir.appendingPathComponent("\(name).png")
        try? "\(window.windowNumber)".write(to: outputDir.appendingPathComponent("\(name).request"), atomically: true, encoding: .utf8)
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: image.path) { await pause(0.25) }
        await pause(0.3)  // let the driver finish writing it
    }

    private static func keyCodeForHint(_ character: Character) -> UInt16 {
        let codes: [Character: UInt16] = [
            "s": 1, "a": 0, "d": 2, "f": 3, "j": 38, "k": 40, "l": 37, "e": 14, "w": 13, "c": 8, "m": 46, "p": 35, "g": 5, "h": 4,
        ]
        return codes[character] ?? 0
    }

    /// Image context menu: "Save Image As…" lands after WebKit's "Download Image", or leads
    /// the menu when WebKit has no image group; nothing for a plain link.
    private static func runContextMenu(_ controller: BrowserWindowController) async {
        guard let pane = controller.focusedPane else { print("FAIL: no pane"); return }
        pane.webView.loadHTMLString(
            ##"<title>img</title><img id="i" src="https://github.com/favicon.ico" width="64" height="64"><a id="a" href="https://example.org/">link</a>"##,
            baseURL: URL(string: "https://example.com/")
        )
        await pause(2)
        func titles(rightClicking id: String, webKitItems: [(String, String)]) async -> String {
            _ = try? await pane.webView.evaluateJavaScript(
                "document.getElementById('\(id)').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true}))"
            )
            await pause(0.5)
            let menu = NSMenu()
            for (title, identifier) in webKitItems {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(identifier)
                menu.addItem(item)
            }
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                pane.webView.willOpenMenu(menu, with: event)
            }
            return menu.items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator: ", ")
        }
        let imageItems = [("Open Image in New Window", "WKMenuItemIdentifierOpenImageInNewWindow"),
                          ("Download Image", "WKMenuItemIdentifierDownloadImage"),
                          ("Copy Image", "WKMenuItemIdentifierCopyImage")]
        print("image menu                         \(await titles(rightClicking: "i", webKitItems: imageItems))")
        print("image menu without WebKit group    \(await titles(rightClicking: "i", webKitItems: [("Reload", "WKMenuItemIdentifierReload")]))")
        print("link menu                          \(await titles(rightClicking: "a", webKitItems: [("Open Link", "WKMenuItemIdentifierOpenLink")]))")
    }

    private static func runZen(_ controller: BrowserWindowController, outputDir: URL) async {
        let root = controller.debugContentRoot
        let window = controller.window
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 44, withPad: " ", startingAt: 0)) \(controller.debugDescriptionOfState)")
        }
        func key(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) async {
            await ensureActive(window)
            post(characters, keyCode: keyCode, modifiers: modifiers, window: window)
            await pause(0.5)
        }
        func chromeHidden() -> Bool {
            let views = [root.tabStrip, root.header, root.bookmarksBar, root.navigationButtons]
            let bars = controller.debugPanes.map(\.addressBarView)
            let lights = window?.standardWindowButton(.closeButton)?.isHidden ?? false
            return views.allSatisfy(\.isHidden) && bars.allSatisfy(\.isHiddenOrHasHiddenAncestor) && lights
        }
        func fillsWindow() -> Bool {
            guard let content = root.tabContent else { return false }
            let panes = controller.debugPanes
            let union = panes.map { $0.convert($0.bounds, to: root) }.reduce(NSRect.null) { $0.union($1) }
            let margin = PaneContainerView.margin
            return content.frame == root.bounds && union == root.bounds.insetBy(dx: margin, dy: margin)
        }
        func toggle() async { await key("z", 6, [.command, .control]) }
        func control(_ held: Bool, wait: TimeInterval = BrowserContentView.controlSettleDelay + 0.15) async {
            guard let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: held ? .control : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59
            ) else { return }
            NSApp.postEvent(event, atStart: false)
            await pause(wait)
        }
        func overlayTakesClicks() -> Bool {
            let center = NSPoint(x: root.bounds.midX, y: root.bounds.midY)
            return root.debugDragOverlayShown && root.hitTest(root.convert(center, to: root.superview)).map { "\(type(of: $0))" } == "WindowDragOverlay"
        }

        controller.focusedPane?.load("data:text/html,<title>Zen</title><body style='background:%23fde'><h1>Zen</h1>")
        Settings.tabLayout = .horizontal
        Settings.addressBarMode = .perPane
        Settings.showBookmarksBar = true
        await pause(1)
        controller.focusedPane?.focusWebView()
        check("starts with chrome", !controller.isZenMode && !root.tabStrip.isHidden && !chromeHidden())

        await toggle()
        check("⌃⌘Z: zen on, chrome hidden", controller.isZenMode && chromeHidden())
        check("page fills the window", fillsWindow())
        snapshot(controller, to: outputDir.appendingPathComponent("zen-single.png"))

        // ⌃ alone covers the page with a drag handle; a ⌃-click that doesn't drag still reaches the page.
        controller.focusedPane?.load("data:text/html,<title>Zen</title><body style='background:%23fde' "
            + "oncontextmenu='event.preventDefault();document.title=\"menu\"'><h1>Zen</h1>")
        await pause(1)
        await control(true)
        check("⌃ in zen: drag overlay over the page", overlayTakesClicks())
        if let window {
            let center = root.convert(NSPoint(x: root.bounds.midX, y: root.bounds.midY), to: nil)
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type, location: center, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1
                )
            }
            let origin = window.frame.origin
            // The overlay's tracking loop pulls the mouse-up from the queue.
            if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            if let down = mouse(.leftMouseDown) { window.sendEvent(down) }
            await pause(0.8)
            check("⌃-click without a drag goes to the page", controller.focusedPane?.displayTitle == "menu"
                  && window.frame.origin == origin && overlayTakesClicks())
        }
        await control(false)
        check("⌃ released: overlay gone", !root.debugDragOverlayShown)
        await control(true, wait: 0.05)
        check("not before ⌃ has been held a moment", !root.debugDragOverlayShown)
        await key("a", 0, [.control])
        await pause(BrowserContentView.controlSettleDelay + 0.15)
        check("a key with ⌃ (a shortcut): no overlay", !root.debugDragOverlayShown)
        await control(false)
        Settings.controlDragMovesWindow = false
        await pause(0.3)
        await control(true)
        check("setting off: ⌃ does nothing", !root.debugDragOverlayShown)
        await control(false)
        Settings.controlDragMovesWindow = true
        await pause(0.3)

        let field = root.header.addressField
        func zenBarShown() -> Bool { !root.header.isHidden && !field.isHiddenOrHasHiddenAncestor }
        await key("d", 2, [.command])
        check("⌘D in zen: shared bar to type the address", controller.isZenMode && zenBarShown()
              && field.currentEditor() != nil && controller.debugPanes.count == 2)
        snapshot(controller, to: outputDir.appendingPathComponent("zen-address.png"))
        field.currentEditor()?.string = "data:text/html,<title>Two</title><h1>Two</h1>"
        await key("\r", 36, [])
        await pause(0.5)
        check("↩ loads it, bar gone, still zen", controller.isZenMode && !zenBarShown()
              && controller.focusedPane?.displayTitle == "Two" && window?.firstResponder === controller.focusedPane?.webView)
        check("split in zen: no pane chrome", controller.isZenMode && chromeHidden() && controller.debugPanes.count == 2)
        check("split fills the window", fillsWindow())
        check("focused pane highlighted, other dimmed", controller.debugPanes.allSatisfy {
            $0.highlight == ($0 === controller.focusedPane ? .focused : .unfocused)
        })
        snapshot(controller, to: outputDir.appendingPathComponent("zen-split.png"))

        for (layout, mode) in [(TabLayout.vertical, AddressBarMode.perPane), (.vertical, .shared), (.horizontal, .shared), (.statusBar, .perPane)] {
            Settings.tabLayout = layout
            Settings.addressBarMode = mode
            await pause(0.5)
            check("\(layout) \(mode): chrome hidden", chromeHidden() && fillsWindow())
        }
        Settings.sidebarAutoHide = true
        Settings.tabLayout = .vertical
        await pause(0.5)
        controller.toggleSidebar(nil)
        await pause(0.5)
        check("auto-hide sidebar can't reveal in zen", chromeHidden() && fillsWindow())
        Settings.sidebarAutoHide = false
        Settings.tabLayout = .horizontal
        Settings.addressBarMode = .perPane
        await pause(0.5)

        await toggle()
        let restored = !controller.isZenMode && !root.tabStrip.isHidden && !root.navigationButtons.isHidden
            && !root.bookmarksBar.isHidden && window?.standardWindowButton(.closeButton)?.isHidden == false
            && controller.debugPanes.allSatisfy { !$0.addressBarView.isHidden }
        check("⌃⌘Z again: chrome back", restored)
        await control(true)
        check("⌃ outside zen: overlay too", overlayTakesClicks())
        await control(false)
        check("panes inset again", root.tabContent.map { $0.subviews.first?.frame.minX == PaneContainerView.margin } ?? false)
        snapshot(controller, to: outputDir.appendingPathComponent("zen-off.png"))

        await toggle()
        await key("l", 37, [.command])
        check("⌘L in zen: shared bar, editing", controller.isZenMode && zenBarShown() && field.currentEditor() != nil
              && controller.debugPanes.allSatisfy { $0.addressBarView.isHiddenOrHasHiddenAncestor })
        check("panes move down under the bar", (root.tabContent?.frame.minY ?? 0) > 0)
        await key("\u{1b}", 53, [])
        check("Esc hides it, still zen", controller.isZenMode && !zenBarShown() && fillsWindow()
              && window?.firstResponder === controller.focusedPane?.webView)
        await key("l", 37, [.command])
        await toggle()
        check("⌃⌘Z while typing: zen off, per-pane bars", !controller.isZenMode && !root.tabStrip.isHidden
              && controller.debugPanes.allSatisfy { !$0.addressBarView.isHidden })

        controller.focusedPane?.focusAddressField()
        await toggle()
        check("entering zen leaves the address field", controller.isZenMode && controller.focusedPane?.addressField.currentEditor() == nil)
        await toggle()
        Settings.showBookmarksBar = false
        print(failures == 0 ? "zen: all ok" : "zen: \(failures) FAILED")
    }

    /// Loads the extensions installed beside the settings file, opens a page and each
    /// extension's popup, and reports what they show. `BROWSER_SELFTEST_URL` picks the page.
    private static func runExtensions(_ controller: BrowserWindowController, outputDir: URL) async {
        // Sign a site out (cookies, storage) before testing an extension's sign-in against it.
        if let site = ProcessInfo.processInfo.environment["BROWSER_SELFTEST_CLEAR_SITE"] {
            let store = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let records = await store.dataRecords(ofTypes: types).filter { $0.displayName == site || $0.displayName.hasSuffix(".\(site)") }
            await store.removeData(ofTypes: types, for: records)
            print("cleared website data: \(records.map(\.displayName))")
        }
        let extensions = Extensions.shared
        for _ in 0..<40 where extensions.contexts.isEmpty { await pause(0.25) }
        print("extensions: \(extensions.contexts.map { Extensions.name(of: $0) })")
        for context in extensions.contexts {
            print("  \(Extensions.name(of: context)) loaded=\(context.isLoaded) base=\(context.baseURL)")
            for site in ["https://github.com/login", "https://my.1password.com/signin"] {
                let url = URL(string: site)!
                print("  \(site): access=\(context.hasAccess(to: url)) injects=\(context.hasInjectedContent(for: url))")
            }
            for error in context.webExtension.errors + context.errors { print("  error: \(error as NSError) \((error as NSError).userInfo)") }
        }
        if let page = ProcessInfo.processInfo.environment["BROWSER_SELFTEST_EXT_PAGE"], let context = extensions.contexts.first {
            let url = URL(string: page, relativeTo: context.baseURL)!.absoluteURL
            let debugPane = controller.addTab(for: url, extensionContext: context, select: true)
            await pause(Double(ProcessInfo.processInfo.environment["BROWSER_SELFTEST_EXT_WAIT"] ?? "") ?? 6)
            let dump = "(window.__log || []).splice(0).join('\\n') + '\\n---\\n' + document.documentElement.innerText.slice(0, 1500)"
            let text = try? await debugPane.webView.evaluateJavaScript(dump)
            print("extension page \(debugPane.webView.url?.absoluteString ?? "-"):\n\(text ?? "?")")
            // Clicks buttons or links by their text, in order (`Continue|Sign in`), reporting after each.
            let clicks = ProcessInfo.processInfo.environment["BROWSER_SELFTEST_EXT_CLICKS"]?.split(separator: "|").map(String.init) ?? []
            for label in clicks {
                let clicked = try? await debugPane.webView.callAsyncJavaScript(
                    """
                    const want = label.toLowerCase();
                    const all = [...document.querySelectorAll('button, a, [role=button], input[type=submit]')];
                    const target = all.find(e => (e.innerText || e.value || '').trim().toLowerCase() === want)
                        || all.find(e => (e.innerText || e.value || '').trim().toLowerCase().includes(want));
                    if (!target) return 'not found among: ' + all.map(e => (e.innerText || e.value || '').trim()).filter(Boolean).join(' / ');
                    target.click();
                    return 'clicked <' + target.tagName + '> ' + (target.href || '');
                    """, arguments: ["label": label], in: nil, contentWorld: .page)
                print("click \"\(label)\": \(clicked.map { String(describing: $0) } ?? "?")")
                await pause(5)
                let after = try? await debugPane.webView.evaluateJavaScript(dump)
                print("after: \(debugPane.webView.url?.absoluteString ?? "-") panes=\(controller.allPanes.map { $0.webView.url?.absoluteString ?? "-" })\n\(after ?? "?")")
                // The worker's console, when the extension under test records it (debugging builds of it).
                let workerLog = try? await debugPane.webView.callAsyncJavaScript(
                    "const r = await chrome.storage.local.get('__rosaLog'); return (r.__rosaLog || []).slice(-25).join('\\n')",
                    arguments: [:], in: nil, contentWorld: .page)
                if let workerLog = workerLog as? String, !workerLog.isEmpty { print("worker log:\n\(workerLog)") }
            }
            return
        }
        guard let pane = controller.focusedPane else { return print("FAIL: no pane") }
        // Hiding a button and showing it again (Settings.hiddenToolbarExtensions).
        if let context = extensions.contexts.first {
            let count = { pane.extensionToolbar.buttons.count }
            let before = count()
            extensions.setInToolbar(false, context)
            await pause(0.3)
            let hidden = count()
            extensions.setInToolbar(true, context)
            await pause(0.3)
            print("toolbar buttons: \(before) → hidden \(hidden) → shown \(count()) \(hidden == before - 1 && count() == before ? "OK" : "FAIL")")
            // From the command palette: its items outlive a menu update (AppKit asks for one on
            // every shortcut), which used to rebuild the Extensions menu under them.
            extensions.setInToolbar(false, context)
            let item = MenuCommandsPaletteSource().items().first { $0.title == "Show in Toolbar" }
            if let menu = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title == "Extensions" })?.submenu {
                menu.delegate?.menuNeedsUpdate?(menu)
            }
            item?.perform(false)
            await pause(0.3)
            print("palette Show in Toolbar: \(item == nil ? "item missing" : "") \(count() == before ? "OK" : "FAIL")")
            extensions.setInToolbar(true, context)
        }
        let site = ProcessInfo.processInfo.environment["BROWSER_SELFTEST_URL"] ?? "https://github.com/login"
        // A script for the page's own world from document start, e.g. to trace events.
        if let script = ProcessInfo.processInfo.environment["BROWSER_SELFTEST_PAGE_START_JS"] {
            pane.webView.configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        pane.load(site)
        for _ in 0..<40 { await pause(0.25); if !pane.webView.isLoading, pane.webView.url != nil { break } }
        await pause(2)
        print("page: \(pane.webView.url?.absoluteString ?? "-") panes=\(controller.allPanes.map { $0.webView.url?.absoluteString ?? "-" })")
        let injected = try? await pane.webView.evaluateJavaScript(
            "[...document.querySelectorAll('*')].map(e => e.tagName).filter(t => t.startsWith('COM-1PASSWORD')).join(',') || 'none'"
        )
        print("1Password elements in page: \(injected ?? "?")")
        // A script to run in the page after it loads, e.g. to fake an event an extension listens for.
        if let script = ProcessInfo.processInfo.environment["BROWSER_SELFTEST_PAGE_JS"] {
            let result = try? await pane.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            print("page script: \(result.map { String(describing: $0) } ?? "nil")")
            await pause(3)
        }
        snapshot(controller, to: outputDir.appendingPathComponent("ext-1-page.png"))
        for context in extensions.contexts {
            context.performAction(for: pane)
            await pause(4)
            let action = context.action(for: pane)
            let popup = action?.popupWebView
            print("popup \(Extensions.name(of: context)): shown=\(action?.popupPopover?.isShown ?? false) url=\(popup?.url?.absoluteString ?? "-")")
            print("after action: presentsPopup=\(action?.presentsPopup ?? false) panes=\(controller.allPanes.map { $0.webView.url?.absoluteString ?? "-" })")
            if let popover = action?.popupPopover {
                let frame = popover.contentViewController?.view.window?.frame ?? .zero
                print("popover: shown=\(popover.isShown) size=\(popover.contentSize) frame=\(frame) window=\(controller.window?.frame ?? .zero) screen=\(controller.window?.screen?.frame ?? .zero)")
            }
            if let opened = controller.allPanes.last, opened !== pane {
                await pause(3)
                let text = try? await opened.webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 600) : '(no body)'")
                print("opened tab text: \((text as? String)?.count ?? -1) characters")
            }
            if let popup {
                let text = try? await popup.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 600) : '(no body)'")
                // Only its size: a signed-in password manager's popup lists your items.
                print("popup text: \((text as? String)?.count ?? -1) characters")
            }
            action?.closePopup()
        }
    }

    /// Vertical sidebar: resize by dragging its edge (pinned and auto-hiding), double-click
    /// resets, auto-hide + ⌃⌘S. Sends mouse events to the window, no key events.
    private static func runSidebar(_ controller: BrowserWindowController) async {
        guard let window = controller.window else { return }
        let root = controller.debugContentRoot
        Settings.sidebarAutoHide = false
        Settings.tabLayout = .vertical
        await pause(0.5)
        func mouse(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) -> NSEvent? {
            let edge = root.debugSidebarFrame
            let point = root.convert(NSPoint(x: x, y: edge.midY), to: nil)
            return NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                pressure: type == .leftMouseUp ? 0 : 1
            )
        }
        if let pane = controller.focusedPane {
            let paneFrame = pane.convert(pane.bounds, to: root), side = root.debugSidebarFrame
            print("sidebar vs pane (top/bottom)       sidebar=\(Int(side.minY))/\(Int(side.maxY)) pane=\(Int(paneFrame.minY))/\(Int(paneFrame.maxY))")
        }
        func hit(_ x: CGFloat) -> String {
            let point = root.convert(NSPoint(x: x, y: root.debugSidebarFrame.midY), to: nil)
            return window.contentView?.hitTest(window.contentView!.convert(point, from: nil)).map { "\(type(of: $0))" } ?? "nil"
        }
        func drag(to target: CGFloat) async {
            let start = root.debugSidebarFrame.maxX + 2
            print("drag from \(Int(start)) hits                 \(hit(start))")
            for event in [mouse(.leftMouseDown, x: start), mouse(.leftMouseDragged, x: (start + target) / 2), mouse(.leftMouseDragged, x: target),
                          mouse(.leftMouseUp, x: target)].compactMap({ $0 }) {
                window.sendEvent(event)
                await pause(0.05)
            }
            await pause(0.3)
        }
        controller.focusedPane?.load("data:text/html,<title>Sidebar</title><h1>Sidebar</h1>")
        await pause(0.5)
        let handleX = root.debugSidebarFrame.maxX + 2
        print("sidebar width before               \(Int(Settings.sidebarWidth)) hits=\(hit(handleX))")
        for event in [mouse(.leftMouseDown, x: handleX), mouse(.leftMouseDragged, x: 280), mouse(.leftMouseDragged, x: 300),
                      mouse(.leftMouseUp, x: 300)].compactMap({ $0 }) {
            window.sendEvent(event)
            await pause(0.05)
        }
        await pause(0.3)
        print("sidebar dragged to 300             setting=\(Int(Settings.sidebarWidth)) frame=\(Int(root.debugSidebarFrame.maxX))")
        let resetX = root.debugSidebarFrame.maxX + 2
        for event in [mouse(.leftMouseDown, x: resetX, clicks: 2), mouse(.leftMouseUp, x: resetX, clicks: 2)].compactMap({ $0 }) {
            window.sendEvent(event)
        }
        await pause(0.3)
        print("sidebar double-click reset         setting=\(Int(Settings.sidebarWidth))")
        Settings.sidebarAutoHide = true
        await pause(0.5)
        print("auto-hide on                       sidebar width=\(Int(root.debugSidebarFrame.width))")
        controller.toggleSidebar(nil)
        await pause(0.5)
        print("⌃⌘S reveal                         sidebar width=\(Int(root.debugSidebarFrame.width)) revealed=\(root.isSidebarRevealed)")
        await drag(to: 340)
        let resized = Int(Settings.sidebarWidth) == 340 && root.isSidebarRevealed
        print("\(resized ? "ok  " : "FAIL") auto-hide dragged to 340      setting=\(Int(Settings.sidebarWidth)) frame=\(Int(root.debugSidebarFrame.maxX)) revealed=\(root.isSidebarRevealed)")
        controller.toggleSidebar(nil)
        await pause(0.5)
        print("⌃⌘S hide                           sidebar width=\(Int(root.debugSidebarFrame.width)) revealed=\(root.isSidebarRevealed)")
        Settings.sidebarAutoHide = false
        await pause(0.5)
        await runSidebarMenu(controller)
        Settings.sidebarAutoHide = false
        Settings.tabLayout = .horizontal
    }

    /// Drags background tabs out of the strip onto a pane of the selected tab (horizontal strip,
    /// then vertical sidebar), then swaps panes with ⌃⌘ arrows and ⌃⌘H/J/K/L. Mouse events sent
    /// to the window, key events posted.
    private static func runPaneDrop(_ controller: BrowserWindowController, outputDir: URL) async {
        guard let window = controller.window else { return }
        Settings.tabLayout = .horizontal
        func page(_ name: String, _ color: String) -> String {
            "data:text/html,<title>\(name)</title><body style='background:\(color)'><h1>\(name)</h1>"
        }
        controller.focusedPane?.load(page("A", "pink"))
        controller.addTab(select: false).load(page("B", "lightblue"))
        controller.addTab(select: false).load(page("C", "palegreen"))
        await pause(1.5)
        func report(_ label: String, expect: String) {
            let state = controller.debugDescriptionOfState
            print("\(state.hasSuffix(expect) ? "ok  " : "FAIL") \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(state)")
        }
        report("start", expect: "tabs=3 sel=0 | *A")

        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )
        }
        /// Drags the tab titled `tab` to `fraction` of the pane titled `title` (0...1 across, top down).
        func drop(tab: String, onto title: String, at fraction: NSPoint) async {
            guard let pane = controller.debugPanes.first(where: { $0.displayTitle == title }),
                  let index = controller.debugTabTitles.firstIndex(of: tab),
                  controller.debugTabCenters.indices.contains(index) else { return print("drop: no pane \(title) or tab \(tab)") }
            let start = controller.debugTabCenters[index]
            let local = NSPoint(x: pane.bounds.width * fraction.x, y: pane.bounds.height * fraction.y)
            let end = pane.convert(local, to: nil)
            for step in 1...12 {
                let t = CGFloat(step) / 12
                let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                if let event = mouse(.leftMouseDragged, point) { NSApp.postEvent(event, atStart: false) }
            }
            if let up = mouse(.leftMouseUp, end) { NSApp.postEvent(up, atStart: false) }
            if let down = mouse(.leftMouseDown, start) { window.sendEvent(down) }
            await pause(0.8)
        }

        // The indicator, shown the way a drag shows it, for a look.
        if let pane = controller.debugPanes.first {
            let point = pane.convert(NSPoint(x: pane.bounds.width * 0.8, y: pane.bounds.height / 2), to: nil)
            let shown = controller.tabStrip(controller.debugContentRoot.tabStrip, draggedTabAt: 1, to: point)
            await pause(0.4)
            await screenCapture(window, name: "panedrop-indicator", outputDir: outputDir)
            let own = controller.tabStrip(controller.debugContentRoot.tabStrip, draggedTabAt: 0, to: point)
            print("\(shown && !own ? "ok  " : "FAIL") indicator for B / for the tab itself  \(shown) / \(own)")
            _ = controller.tabStrip(controller.debugContentRoot.tabStrip, draggedTabAt: 1, to: nil)
        }

        // Its own tab has nowhere to go: it just follows the pointer along the strip, as before.
        await drop(tab: "A", onto: "A", at: NSPoint(x: 0.8, y: 0.5))
        report("own tab onto its pane: no drop", expect: "tabs=3 sel=2 | *A")
        await drop(tab: "B", onto: "A", at: NSPoint(x: 0.8, y: 0.5))
        report("horizontal: B onto A's right", expect: "tabs=2 sel=1 | H0.50(A, *B)")
        await screenCapture(window, name: "panedrop-1", outputDir: outputDir)

        Settings.tabLayout = .vertical
        await pause(0.5)
        await drop(tab: "C", onto: "B", at: NSPoint(x: 0.5, y: 0.85))
        report("vertical: C onto B's bottom", expect: "tabs=1 sel=0 | H0.50(A, V0.50(B, *C))")
        await screenCapture(window, name: "panedrop-2", outputDir: outputDir)
        Settings.tabLayout = .horizontal
        await pause(0.5)

        let arrows: NSEvent.ModifierFlags = [.command, .control, .function, .numericPad]
        func move(_ label: String, _ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, expect: String) async {
            await ensureActive(window)
            post(characters, keyCode: keyCode, modifiers: modifiers, window: window)
            await pause(0.5)
            report(label, expect: expect)
        }
        await move("⌃⌘← C swaps with A", arrow(NSLeftArrowFunctionKey), 123, arrows, expect: "H0.50(*C, V0.50(B, A))")
        await move("⌃⌘L C swaps with B (recent)", "l", 37, [.command, .control], expect: "H0.50(B, V0.50(*C, A))")
        await move("⌃⌘J C swaps with A", "j", 38, [.command, .control], expect: "H0.50(B, V0.50(A, *C))")
        await move("⌃⌘↑ C swaps back", arrow(NSUpArrowFunctionKey), 126, arrows, expect: "H0.50(B, V0.50(*C, A))")
        await move("⌃⌘K at the top: nothing", "k", 40, [.command, .control], expect: "H0.50(B, V0.50(*C, A))")
        await move("⌃⌘H C swaps with B", "h", 4, [.command, .control], expect: "H0.50(*C, V0.50(B, A))")
        await screenCapture(window, name: "panedrop-3", outputDir: outputDir)
    }

    /// Right-clicking the sidebar (empty space or a tab) offers Pin Sidebar, checked while
    /// auto-hide is off; choosing it flips the setting. Sends one real right-click to the window.
    private static func runSidebarMenu(_ controller: BrowserWindowController) async {
        guard let window = controller.window, let contentView = window.contentView else { return }
        let root = controller.debugContentRoot
        func rightClick(at point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        /// The menu AppKit would show: the first one up the view hierarchy from the clicked view.
        func menu(at point: NSPoint) -> NSMenu? {
            guard let event = rightClick(at: point) else { return nil }
            var view = contentView.hitTest(contentView.convert(point, from: nil))
            while let current = view {
                if let menu = current.menu(for: event) { return menu }
                view = current.superview
            }
            return nil
        }
        func describe(_ menu: NSMenu?) -> String {
            menu?.items.map { "\($0.state == .on ? "✓" : "")\($0.title)" }.joined(separator: ", ") ?? "none"
        }
        let side = root.debugSidebarFrame
        let empty = root.convert(NSPoint(x: side.midX, y: side.maxY - 60), to: nil)
        let tab = controller.debugContentRoot.tabStrip.debugTabCenters.first ?? empty

        let emptyMenu = menu(at: empty), tabMenu = menu(at: tab)
        let pinned = describe(emptyMenu) == "✓Pin Sidebar" && describe(tabMenu) == "✓Pin Sidebar"
        print("\(pinned ? "ok  " : "FAIL") menu pinned                   empty=[\(describe(emptyMenu))] tab=[\(describe(tabMenu))]")

        // A real right-click on empty sidebar space opens the menu; an Escape queued in the app
        // closes it (timers, the main queue and cancelTracking don't get through while it tracks).
        var shown = "none"
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                shown = describe(menu)
                let escape = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53
                )
                if let escape { NSApp.postEvent(escape, atStart: false) }
            }
        }
        if let event = rightClick(at: empty) { window.sendEvent(event) }
        NotificationCenter.default.removeObserver(observer)
        print("\(shown == "✓Pin Sidebar" ? "ok  " : "FAIL") right-click shows               [\(shown)]")

        if let item = emptyMenu?.items.first { emptyMenu?.performActionForItem(at: emptyMenu!.index(of: item)) }
        await pause(0.5)
        // The sidebar is now the collapsed rail; it has the menu too.
        let rail = root.convert(NSPoint(x: root.debugSidebarFrame.midX, y: root.debugSidebarFrame.maxY - 60), to: nil)
        let railMenu = menu(at: rail)
        let unpinned = Settings.sidebarAutoHide && describe(railMenu) == "Pin Sidebar" && !root.isSidebarRevealed
        print("\(unpinned ? "ok  " : "FAIL") unpin → auto-hide on            autoHide=\(Settings.sidebarAutoHide) rail=[\(describe(railMenu))]")

        railMenu?.performActionForItem(at: 0)
        await pause(0.5)
        let repinned = !Settings.sidebarAutoHide && describe(menu(at: empty)) == "✓Pin Sidebar"
        print("\(repinned ? "ok  " : "FAIL") pin from rail → auto-hide off  autoHide=\(Settings.sidebarAutoHide)")

        Settings.tabLayout = .horizontal
        await pause(0.5)
        let horizontal = describe(menu(at: controller.debugContentRoot.tabStrip.debugTabCenters.first ?? empty))
        print("\(horizontal == "none" ? "ok  " : "FAIL") no menu on horizontal tabs      [\(horizontal)]")
        Settings.tabLayout = .vertical
    }

    /// Address bar history matching and ranking: every word in any order, fuzzy matches, learned
    /// picks, typed visits, the history setting and clearing. No key events; clears history, so
    /// it needs a scratch `BROWSER_HISTORY_DB`.
    private static func runHistorySearch() {
        guard ProcessInfo.processInfo.environment["BROWSER_HISTORY_DB"] != nil else {
            print("FAIL: history needs BROWSER_HISTORY_DB (it clears history)")
            return
        }
        let store = HistoryStore.shared
        var failures = 0
        func check(_ query: String, _ expected: [String], learned: Bool = false) {
            let actual = store.search(query, limit: expected.count).map(\.displayURL)
            let isLearned = store.search(query).first.map { store.isLearnedPick($0.url, for: query) } ?? false
            let ok = actual == expected && isLearned == learned
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(query.padding(toLength: 16, withPad: " ", startingAt: 0)) \(actual)\(learned ? " learned" : "")"
                  + (ok ? "" : "  (expected \(expected)\(learned ? " learned" : ""))"))
        }
        /// What ↩ opens right after typing: `completion` is the field's completed text, `top` whether
        /// the top suggestion is selected.
        func checkDefault(_ typed: String, completion: String?, top: Bool) {
            let match = store.defaultMatch(for: typed, in: store.search(typed))
            let ok = match.completion?.text == completion && match.selectsTop == top
            if !ok { failures += 1 }
            let describe = { (text: String?, top: Bool) in "\(text ?? "-")\(top ? " +top" : "")" }
            print("\(ok ? "ok  " : "FAIL") default \(typed.padding(toLength: 13, withPad: " ", startingAt: 0)) \(describe(match.completion?.text, match.selectsTop))"
                  + (ok ? "" : "  (expected \(describe(completion, top)))"))
        }
        Settings.historyEnabled = true
        store.clear(since: nil)
        let visits = [
            ("https://rust-lang.github.io/async-book/", "Asynchronous Programming in Rust - The Async Book", 2),
            ("https://tokio.rs/tokio/tutorial", "Tutorial | Tokio - An asynchronous Rust runtime", 3),
            ("https://doc.rust-lang.org/book/", "The Rust Programming Language", 5),
            ("https://github.com/", "GitHub", 20),
            ("https://github.com/apple/swift", "GitHub - apple/swift: The Swift Programming Language", 4),
            ("https://www.postgresql.org/docs/current/indexes.html", "PostgreSQL: Documentation: 17: Chapter 11. Indexes", 1),
            ("https://news.ycombinator.com/", "Hacker News", 30),
            ("https://www.dr.dk/mad/opskrift/rugbroed", "Rugbrød – nem opskrift | DR", 1),
            ("https://www.rbc.com/", "RBC Royal Bank", 6),
        ]
        for (url, title, count) in visits {
            for _ in 0..<count { store.recordVisit(url: URL(string: url)!, title: title) }
        }
        check("gi", ["github.com", "github.com/apple/swift"])
        check("async rust", ["rust-lang.github.io/async-book", "tokio.rs/tokio/tutorial"])
        check("github swift", ["github.com/apple/swift"])
        check("rust zzz", [])
        check("gthb", ["github.com"])
        check("rlb", ["doc.rust-lang.org/book"])
        check("postgers", ["postgresql.org/docs/current/indexes.html"])
        check("RUGBRØD", ["dr.dk/mad/opskrift/rugbroed"])
        check("brod", ["dr.dk/mad/opskrift/rugbroed"])
        check("rb", ["rbc.com"])
        checkDefault("gi", completion: "github.com", top: true)
        checkDefault("github.com/a", completion: "github.com/apple/swift", top: true)
        checkDefault("hack", completion: nil, top: true)
        checkDefault("async rust", completion: nil, top: false)
        checkDefault("zzz", completion: nil, top: false)

        for _ in 0..<2 { store.recordPick(input: "rb", url: URL(string: "https://doc.rust-lang.org/book/")!) }
        check("rb", ["doc.rust-lang.org/book", "rbc.com"], learned: true)
        check("r", ["doc.rust-lang.org/book"], learned: true)
        checkDefault("rb", completion: nil, top: true)

        // A typed address that redirected to another site is recorded under what was typed too.
        store.recordVisit(url: URL(string: "https://mail.google.com/mail/u/0/")!, title: "Inbox - Gmail", typed: true)
        store.recordVisit(url: URL(string: "https://gmail.com/")!, title: "Inbox - Gmail", typed: true)
        checkDefault("gm", completion: "gmail.com", top: true)
        store.recordPick(input: "gmail", url: URL(string: "https://gmail.com/")!)
        checkDefault("gma", completion: "gmail.com", top: true)

        for _ in 0..<3 { store.recordVisit(url: URL(string: "https://tokio.rs/tokio/tutorial")!, title: "", typed: true) }
        check("rust", ["rust-lang.github.io/async-book", "tokio.rs/tokio/tutorial", "doc.rust-lang.org/book"])

        Settings.historyEnabled = false
        store.recordPick(input: "news", url: URL(string: "https://www.rbc.com/")!)
        store.recordVisit(url: URL(string: "https://example.com/")!, title: "Example")
        Settings.historyEnabled = true
        check("news", ["news.ycombinator.com"])
        check("example", [])

        store.clear(since: nil)
        check("rb", [])
        print(failures == 0 ? "history: all ok" : "history: \(failures) FAILED")
    }

    /// Welcome commands: only on the pane Rosa opens at launch, a click acts on that pane, hidden
    /// while the pane is too small, gone once it loads a page. Posts no key events.
    /// Clicking into the address bar selects the whole address; a drag selects part of it, and a
    /// click while editing places the caret.
    /// Smart search over seeded history: paraphrases find their page (by title, address or page
    /// text, across languages), a bookmark is found too, an unrelated query finds nothing, and
    /// clearing history or turning the feature off removes the vectors; ⌘P and the address bar
    /// show the matches. Needs the model already downloaded (`BROWSER_MODEL_DIR`) and scratch
    /// `BROWSER_SETTINGS_FILE`, `BROWSER_HISTORY_DB` and `BROWSER_SEMANTIC_DB`. Posts ⌘P.
    private static func runSemanticSearch(_ controller: BrowserWindowController) async {
        let environment = ProcessInfo.processInfo.environment
        guard ["BROWSER_SETTINGS_FILE", "BROWSER_HISTORY_DB", "BROWSER_SEMANTIC_DB"].allSatisfy({ environment[$0] != nil }) else {
            print("FAIL: semantic needs BROWSER_SETTINGS_FILE, BROWSER_HISTORY_DB and BROWSER_SEMANTIC_DB (it clears history)")
            return
        }
        guard SemanticModel.shared.isDownloaded else {
            print("SKIP: no model in \(SemanticModel.directory.path) (set BROWSER_MODEL_DIR to a downloaded copy)")
            return
        }
        let search = SemanticSearch.shared
        var failures = 0
        func waitForIndex(_ what: String, until done: () -> Bool) async {
            let start = Date()
            while !done(), Date().timeIntervalSince(start) < 300 { await pause(0.25) }
            let ok = done()
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(what) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(search.statusDescription)")
        }

        Settings.semanticSearch = false
        Settings.historyEnabled = true
        HistoryStore.shared.clear(since: nil)
        let pages = [
            ("https://www.kingarthurbaking.com/blog/sourdough-hydration", "Sourdough hydration explained"),
            ("https://kubernetes.io/docs/concepts/services-networking/", "Services, Load Balancing, and Networking | Kubernetes"),
            ("https://skat.dk/borger/restskat", "Restskat | Skattestyrelsen"),
            ("https://github.com/", "GitHub"),
            ("https://news.ycombinator.com/", "Hacker News"),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "Rick Astley - Never Gonna Give You Up"),
            ("https://developer.apple.com/documentation/swiftui", "SwiftUI | Apple Developer Documentation"),
            ("https://en.wikipedia.org/wiki/Photosynthesis", "Photosynthesis - Wikipedia"),
            ("https://www.seriouseats.com/the-best-chili-recipe", "The Best Chili Recipe"),
            ("https://www.dmi.dk/", "DMI - Vejret"),
            ("https://mail.google.com/mail/u/0/", "Inbox - Gmail"),
            ("https://www.booking.com/hotel/jp/tokyo-station", "Tokyo Station Hotel"),
            ("https://www.strava.com/activities/123", "Morning Run | Strava"),
            ("https://docs.python.org/3/library/asyncio.html", "asyncio — Asynchronous I/O"),
            ("https://www.ikea.com/dk/da/p/billy-reol", "BILLY Reol - IKEA"),
            ("https://www.figma.com/", "Figma"),
            ("https://react.dev/reference/react/useEffect", "useEffect – React"),
            ("https://science.nasa.gov/mars/", "Mars - NASA Science"),
            ("https://www.imdb.com/title/tt0111161/", "The Shawshank Redemption (1994) - IMDb"),
            ("https://medium.com/p/3f2a9c", "Untitled"),
            ("https://www.reddit.com/r/espresso/", "r/espresso"),
            ("https://www.postgresql.org/docs/current/indexes.html", "PostgreSQL: Documentation: Indexes"),
            ("https://www.vogue.com/fashion", "Fashion | Vogue"),
            ("https://www.coursera.org/learn/machine-learning", "Machine Learning | Coursera"),
            ("https://www.dr.dk/nyheder", "Nyheder | DR"),
            ("https://open.spotify.com/", "Spotify"),
            ("https://www.zillow.com/", "Zillow: Real Estate, Apartments, Mortgages & Home Values"),
            ("https://www.healthline.com/nutrition/intermittent-fasting-guide", "Intermittent Fasting 101 — The Ultimate Beginner's Guide"),
            ("https://www.lonelyplanet.com/iceland", "Iceland travel guide - Lonely Planet"),
            ("https://www.chess.com/openings/Sicilian-Defense", "Sicilian Defense - Chess Openings"),
        ]
        for (url, title) in pages { HistoryStore.shared.recordVisit(url: URL(string: url)!, title: title) }
        let bookmark = URL(string: "https://www.swingshoes-cph.dk/lindy-hop")!
        let bookmarkPath = Bookmarks.add(Bookmark(title: "Lindy hop for beginners – Swing Shoes Copenhagen", kind: .link(bookmark)))

        Settings.semanticSearch = true
        await waitForIndex("model ready and \(pages.count + 1) pages indexed") {
            SemanticModel.shared.state == .ready && search.pendingCount == 0 && search.indexedCount == pages.count + 1
        }
        // Page text, as `PaneView` captures it: the vague "Untitled" page is only findable by it.
        search.update(url: URL(string: "https://medium.com/p/3f2a9c")!, title: "Untitled",
                      text: "How we cut our AWS bill in half. Moving batch jobs to spot instances, rightsizing our EC2 fleet and deleting idle load balancers saved us $40k a month.")
        // A Danish page that says little in its title ("DMI - Vejret": weather) is found by its text.
        search.update(url: URL(string: "https://www.dmi.dk/")!, title: "DMI - Vejret",
                      text: "Vejrudsigt for Danmark. I morgen: skyet med regnbyger, op til 14 grader og frisk vind fra vest. Se timeprognose og radar.")
        await waitForIndex("page text indexed") { search.pendingCount == 0 }

        func check(_ query: String, _ expected: String?) async {
            let hits = await search.search(query)
            let top = hits.first?.url.absoluteString
            let ok = top == expected
            if !ok { failures += 1 }
            let shown = hits.prefix(3).map { "\($0.url.host() ?? "")\($0.url.path()) \(String(format: "%.2f z%.1f", $0.cosine, $0.z))" }
            print("\(ok ? "ok  " : "FAIL") \(query.padding(toLength: 40, withPad: " ", startingAt: 0)) \(shown)"
                  + (ok ? "" : "  (expected \(expected ?? "nothing"))"))
            if !ok {
                for score in await search.debugScores(query).prefix(4) {
                    print("       \(String(format: "%.3f z%.2f", score.cosine, score.z)) \(score.url)")
                }
            }
        }
        await check("how do I make my bread rise more", "https://www.kingarthurbaking.com/blog/sourdough-hydration")
        await check("container orchestration networking", "https://kubernetes.io/docs/concepts/services-networking/")
        await check("when do I have to pay back taxes", "https://skat.dk/borger/restskat")
        await check("cutting our cloud costs", "https://medium.com/p/3f2a9c")
        await check("coffee machine tips", "https://www.reddit.com/r/espresso/")
        await check("red planet rover", "https://science.nasa.gov/mars/")
        await check("swing dancing lessons", bookmark.absoluteString)
        await check("losing weight by skipping meals", "https://www.healthline.com/nutrition/intermittent-fasting-guide")
        await check("weather forecast tomorrow", "https://www.dmi.dk/")
        await check("quantum chromodynamics lattice gauge theory", nil)
        await check("how to change a bicycle tire", nil)

        // In the UI: ⌘P adds smart matches under its bookmarks, the address bar under its history rows.
        if let pane = controller.focusedPane, let window = controller.window {
            pane.focusWebView()
            await ensureActive(window)
            post("p", keyCode: 35, modifiers: [.command], window: window)
            await pause(0.5)
            let palette = controller.debugCommandPalette
            for (query, title) in [("swing dancing lessons", "Lindy hop for beginners – Swing Shoes Copenhagen"),
                                   ("red planet rover", "Mars - NASA Science")] {
                palette.debugSetQuery(query)
                await pause(1.5)
                let found = palette.debugResults.contains(title)
                if !found { failures += 1 }
                print("\(found ? "ok  " : "FAIL") ⌘P \(query): \(palette.debugResults)")
            }
            palette.close(restoringFocus: true)
            await pause(0.5)
            let field = [pane.addressField, controller.debugContentRoot.header.addressField].first { !$0.isHiddenOrHasHiddenAncestor }
                ?? pane.addressField
            window.makeFirstResponder(field)
            await pause(0.3)
            (field.currentEditor() as? NSTextView)?.insertText("coffee machine tips", replacementRange: NSRange(location: 0, length: (field.currentEditor()?.string as NSString?)?.length ?? 0))
            await pause(1.5)
            let suggestions = field.debugSuggestions
            let inBar = suggestions.contains("reddit.com/r/espresso")
            if !inBar { failures += 1 }
            print("\(inBar ? "ok  " : "FAIL") address bar shows smart matches: \(suggestions)")
            pane.focusWebView()
            await pause(0.8)
        }

        Bookmarks.remove(at: bookmarkPath)
        HistoryStore.shared.clear(since: nil)
        await waitForIndex("history and bookmark cleared from the index") { search.indexedCount == 0 }
        Settings.semanticSearch = false
        let deleted = !FileManager.default.fileExists(atPath: environment["BROWSER_SEMANTIC_DB"]!)
        if !deleted { failures += 1 }
        print("\(deleted ? "ok  " : "FAIL") turning it off deletes the index")
        print(failures == 0 ? "PASS semantic" : "FAIL semantic: \(failures) failed")
    }

    private static func runAddressClick(_ controller: BrowserWindowController) async {
        var failures = 0
        guard let pane = controller.focusedPane, let window = controller.window else { return print("FAIL: no pane") }
        // A lone pane's address bar is in the header.
        let field = [pane.addressField, controller.debugContentRoot.header.addressField].first { !$0.isHiddenOrHasHiddenAncestor }
            ?? pane.addressField
        func selection() -> String {
            guard let editor = field.currentEditor() else { return "not editing" }
            return (editor.string as NSString).substring(with: editor.selectedRange)
        }
        func check(_ label: String, _ expected: String) {
            let actual = selection()
            if actual != expected { failures += 1 }
            print("\(actual == expected ? "ok  " : "FAIL") \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) selected=\"\(actual)\"")
        }
        func point(atFraction x: CGFloat) -> NSPoint {
            field.convert(NSPoint(x: field.bounds.width * x, y: field.bounds.midY), to: nil)
        }
        /// The field editor tracks the mouse in its own loop, so queue the drags and up before the down.
        func press(from start: CGFloat, to end: CGFloat) async {
            func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type, location: point(atFraction: x), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1
                )
            }
            if start != end, let drag = mouse(.leftMouseDragged, end) { NSApp.postEvent(drag, atStart: false) }
            if let up = mouse(.leftMouseUp, end) { NSApp.postEvent(up, atStart: false) }
            if let down = mouse(.leftMouseDown, start) { window.sendEvent(down) }
            await pause(0.3)
        }

        pane.load("data:text/html,<title>Page</title><h1>Page</h1>")
        await pause(1)
        pane.focusWebView()
        await pause(0.3)
        let address = field.stringValue
        await press(from: 0.1, to: 0.1)
        check("click selects the whole address", address)
        await press(from: 0.1, to: 0.1)
        check("click while editing places caret", "")
        pane.focusWebView()
        await pause(0.3)
        await press(from: 0.05, to: 0.2)
        let dragged = selection()
        let partial = !dragged.isEmpty && dragged != address && dragged != "not editing"
        if !partial { failures += 1 }
        print("\(partial ? "ok  " : "FAIL") \("drag selects part of it".padding(toLength: 34, withPad: " ", startingAt: 0)) selected=\"\(dragged)\"")
        print(failures == 0 ? "addressclick: all ok" : "addressclick: \(failures) FAILED")
    }

    private static func runWelcome(_ controller: BrowserWindowController, outputDir: URL) async {
        var failures = 0
        func panes() -> [PaneView] { controller.debugContentRoot.tabContent?.paneLeaves ?? [] }
        func shown() -> String { panes().map { $0.welcome.map { $0.isHidden ? "h" : "W" } ?? "-" }.joined() }
        func check(_ label: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 40, withPad: " ", startingAt: 0)) panes=\(shown()) \(controller.debugDescriptionOfState)")
        }
        let shortcuts = WelcomeView.sections.flatMap(\.commands).map { "\($0.title)=\(WelcomeView.shortcut(for: $0) ?? "?")" }
        print("shortcuts: \(shortcuts.joined(separator: ", "))")
        check("every command has a shortcut", !shortcuts.contains { $0.hasSuffix("=?") })
        check("launch pane shows welcome", shown() == "W")
        await requestScreenCapture("welcome-launch", of: controller, in: outputDir)
        panes().first?.welcome?.debugPerform("Zen Mode")
        await pause(0.3)
        check("Zen Mode row turns zen on", controller.isZenMode && shown() == "W")
        panes().first?.welcome?.debugPerform("Zen Mode")
        await pause(0.3)
        check("and off again", !controller.isZenMode)

        if let point = panes().first?.welcome?.debugTitlePoint("Split Right") { await click(at: point, in: controller.window) }
        await pause(0.5)
        check("clicking a row's title splits", shown() == "W-")

        controller.newTab(nil)
        await pause(0.5)
        check("new tab has none", shown() == "-")
        controller.selectTab(at: 0)
        await pause(0.3)

        let size = controller.window?.contentLayoutRect.size
        controller.window?.setContentSize(NSSize(width: 900, height: 420))
        await pause(0.5)
        check("hidden in a small pane", shown() == "h-")
        // A blank web view is white: the hidden welcome page's pane gets the blank-pane background.
        check("…with the blank-pane background", panes().first?.quickLinks != nil)
        if let size { controller.window?.setContentSize(size) }
        await pause(0.5)
        check("back when large again", shown() == "W-")
        check("…without it", panes().first?.quickLinks == nil)

        panes().first?.load("data:text/html,<title>Page</title><h1>Page</h1>")
        await pause(1)
        check("gone after a page loads", shown() == "--")
        panes().first?.webView.goBack()
        await pause(0.5)
        check("not back after going back", shown() == "--")
        print(failures == 0 ? "welcome: all ok" : "welcome: \(failures) FAILED")
    }

    /// Quick links on blank panes: recent sites (one per host), pinned bookmarks taking over, the
    /// setting, and opening a tile. Writes history and bookmarks, so it needs scratch locations.
    private static func runQuickLinks(_ controller: BrowserWindowController, outputDir: URL) async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BROWSER_SETTINGS_FILE"] != nil, environment["BROWSER_HISTORY_DB"] != nil else {
            print("FAIL: quicklinks needs BROWSER_SETTINGS_FILE and BROWSER_HISTORY_DB (it writes bookmarks and history)")
            return
        }
        var failures = 0
        func pane() -> PaneView? { controller.focusedPane }
        func state() -> String {
            guard let links = pane()?.quickLinks else { return "none" }
            return links.isShowingTiles ? "\(links.debugHeading): \(links.debugTitles.joined(separator: ", "))" : "no tiles"
        }
        func check(_ label: String, _ expected: String) {
            let actual = state()
            if actual != expected { failures += 1 }
            print("\(actual == expected ? "ok  " : "FAIL") \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(actual)\(actual == expected ? "" : "  (expected \(expected))")")
        }
        Settings.historyEnabled = true
        Settings.showQuickLinks = true
        HistoryStore.shared.clear(since: nil)
        await pause(0.3)
        check("launch pane (welcome instead)", "none")

        controller.newTab(nil)
        await pause(0.5)
        check("no history, nothing pinned", "no tiles")

        let visits = [
            ("https://github.com/", "GitHub"), ("https://www.apple.com/", "Apple"), ("https://www.wikipedia.org/", "Wikipedia"),
            ("https://github.com/apple/swift", "Swift repo"), ("https://news.ycombinator.com/", "Hacker News"),
            ("https://developer.mozilla.org/", "MDN"), ("https://www.swift.org/", "Swift.org"), ("https://example.com/", ""),
        ]
        for (url, title) in visits {
            HistoryStore.shared.recordVisit(url: URL(string: url)!, title: title)
            try? await Task.sleep(for: .milliseconds(20))
        }
        await pause(0.3)
        check("recent: last 6 sites, one per host", "RECENTLY VISITED: example.com, Swift.org, MDN, Hacker News, Swift repo, Wikipedia")
        await requestScreenCapture("quicklinks-recent", of: controller, in: outputDir)

        Bookmarks.add(Bookmark(title: "Rosa", kind: .link(URL(string: "https://github.com/jonas-lomholdt/rosa")!), pinned: true))
        Bookmarks.add(Bookmark(title: "Not pinned", kind: .link(URL(string: "https://example.org/")!)))
        await pause(0.3)
        check("pinned replaces recent", "PINNED: Rosa")
        let stored = (try? String(contentsOf: Bookmarks.fileURL, encoding: .utf8)) ?? ""
        let storesPin = stored.contains("\"pinned\" : true") || stored.contains("\"pinned\":true")
        if !storesPin { failures += 1 }
        print("\(storesPin ? "ok  " : "FAIL") pinned stored in bookmarks.json")

        if let path = Bookmarks.path(of: URL(string: "https://example.org/")!) { Bookmarks.setPinned(at: path, true) }
        await pause(0.3)
        check("second pin", "PINNED: Rosa, Not pinned")
        await requestScreenCapture("quicklinks-pinned", of: controller, in: outputDir)
        for (path, _) in Bookmarks.pinned.reversed() { Bookmarks.setPinned(at: path, false) }
        await pause(0.3)
        check("unpinned all: back to recent", "RECENTLY VISITED: example.com, Swift.org, MDN, Hacker News, Swift repo, Wikipedia")

        Settings.showQuickLinks = false
        await pause(0.3)
        check("setting off: background, no tiles", "no tiles")
        Settings.showQuickLinks = true
        await pause(0.3)
        check("setting on", "RECENTLY VISITED: example.com, Swift.org, MDN, Hacker News, Swift repo, Wikipedia")

        controller.splitRight(nil)
        await pause(0.5)
        check("new split pane has them too", "RECENTLY VISITED: example.com, Swift.org, MDN, Hacker News, Swift repo, Wikipedia")
        // A visit elsewhere must not rebuild unchanged tiles (that would drop a click in progress).
        let tileBefore = pane()?.quickLinks?.subviews.last
        HistoryStore.shared.updateTitle(url: URL(string: "https://example.com/")!, title: "")
        NotificationCenter.default.post(name: HistoryStore.didChange, object: nil)
        let kept = pane()?.quickLinks?.subviews.last === tileBefore
        if !kept { failures += 1 }
        print("\(kept ? "ok  " : "FAIL") unchanged tiles survive a history change")
        if let point = pane()?.quickLinks?.debugTileCenter(0) { await click(at: point, in: controller.window) }
        await pause(0.3)
        check("clicking a tile's icon loads it", "none")
        print("pane url: \(pane()?.webView.url?.absoluteString ?? "-")")
        print(failures == 0 ? "quicklinks: all ok" : "quicklinks: \(failures) FAILED")
    }

    /// Bookmarks bar: layouts, live edits of bookmarks.json, overflow, ⌘⇧B, opening. Writes the
    /// bookmarks file, so it only runs against a scratch settings/bookmarks location.
    private static func runBookmarks(_ controller: BrowserWindowController, outputDir: URL) async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BROWSER_SETTINGS_FILE"] != nil || environment["BROWSER_BOOKMARKS_FILE"] != nil else {
            print("SKIP bookmarks: set BROWSER_SETTINGS_FILE or BROWSER_BOOKMARKS_FILE to a scratch location")
            return
        }
        let bar = controller.debugContentRoot.bookmarksBar
        func write(_ entries: [[String: Any]]) async {
            let data = try! JSONSerialization.data(withJSONObject: ["bookmarks": entries], options: .prettyPrinted)
            try? data.write(to: Bookmarks.fileURL, options: .atomic)
            await pause(0.8)
        }
        func report(_ label: String) {
            print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) shown=\(!bar.isHidden) frame=\(bar.frame.integral) "
                  + "visible=\(bar.debugVisibleTitles) overflow=\(bar.debugOverflowCount)")
        }

        Settings.showBookmarksBar = true
        await write([])
        report("bookmarks: empty file (hint)")
        snapshot(controller, to: outputDir.appendingPathComponent("bookmarks-0-empty.png"))
        await write([
            ["url": "https://example.com"],
            ["title": "GitHub", "url": "https://github.com"],
            ["title": "Work", "children": [
                ["title": "Apple", "url": "apple.com"],
                ["title": "Nested", "children": [["title": "HN", "url": "https://news.ycombinator.com"]]],
            ]],
            ["title": "Hacker News", "url": "news.ycombinator.com"],
            ["title": "no url, skipped"],
        ])
        await pause(1.5)  // favicons
        report("bookmarks: live edit")
        snapshot(controller, to: outputDir.appendingPathComponent("bookmarks-1-horizontal.png"))
        await runCommandPalette(controller, outputDir: outputDir)
        Settings.addressBarMode = .shared
        await pause(0.4)
        snapshot(controller, to: outputDir.appendingPathComponent("bookmarks-2-horizontal-shared.png"))
        for name in ["Second tab", "Third tab"] {
            controller.addTab(select: false).webView.loadHTMLString("<title>\(name)</title>", baseURL: nil)
        }
        Settings.tabLayout = .vertical
        await pause(0.6)
        report("bookmarks: vertical + shared")
        await requestScreenCapture("vertical-shared", of: controller, in: outputDir)
        snapshot(controller, to: outputDir.appendingPathComponent("bookmarks-3-vertical-shared.png"))
        Settings.addressBarMode = .perPane
        await pause(0.4)
        snapshot(controller, to: outputDir.appendingPathComponent("bookmarks-4-vertical.png"))
        await requestScreenCapture("vertical", of: controller, in: outputDir)
        Settings.tabLayout = .horizontal

        // ⌘B on a loaded page adds it and opens the editor; edits apply when it closes.
        func editorState() -> String {
            guard let model = controller.debugBookmarkEditor.debugModel else { return "editor=closed" }
            return "editor=\(model.mode) shown=\(controller.isBookmarkEditorShown) title=\"\(model.title)\" folder=\(model.folder)"
        }
        controller.focusedPane?.load("https://example.net/")
        for _ in 0..<40 {
            await pause(0.25)
            if let webView = controller.focusedPane?.webView, webView.url?.host() == "example.net", !webView.isLoading { break }
        }
        controller.focusedPane?.focusWebView()
        let countBefore = Bookmarks.items.count
        await ensureActive(controller.window)
        post("b", keyCode: 11, modifiers: [.command], window: controller.window)
        await pause(0.8)
        print("bookmarks: ⌘B                      count \(countBefore) → \(Bookmarks.items.count) \(editorState())")
        if let pane = controller.focusedPane, let popover = controller.debugBookmarkEditor.debugPopoverFrame {
            let bar = pane.addressBarView
            let anchor = bar.window?.convertToScreen(bar.convert(bar.bounds, to: nil)) ?? .zero
            let tip = controller.debugBookmarkEditor.debugArrowTip ?? .zero
            print("bookmarks: popover placement       hangsFromBar=\(popover.maxY <= anchor.minY && anchor.minY - popover.maxY < 6) "
                  + "flushRight=\(abs(anchor.maxX - popover.maxX) < 3) arrowNearRightEnd=\(anchor.maxX - tip.x < 40) "
                  + "popover=\(popover.integral) bar=\(anchor.integral) tip=\(tip)")
            await requestScreenCapture("bookmarks-popover", of: controller, in: outputDir)
        }
        if let model = controller.debugBookmarkEditor.debugModel {
            model.title = "Example"
            model.folderIndex = model.folderChoices.firstIndex { $0.label.contains("Work") } ?? 0
            model.onDone()
        }
        await pause(0.5)
        let added = URL(string: "https://example.net/")!
        print("bookmarks: rename + move to Work   path=\(Bookmarks.path(of: added) ?? []) "
              + "title=\(Bookmarks.path(of: added).flatMap(Bookmarks.bookmark(at:))?.title ?? "-") \(editorState())")
        await ensureActive(controller.window)
        controller.focusedPane?.focusWebView()
        post("b", keyCode: 11, modifiers: [.command], window: controller.window)
        await pause(0.8)
        print("bookmarks: ⌘B again (existing)     count=\(Bookmarks.items.count) \(editorState())")
        controller.debugBookmarkEditor.debugModel?.onRemove()
        await pause(0.5)
        print("bookmarks: Remove                  found=\(Bookmarks.path(of: added) != nil) \(editorState())")
        controller.focusedPane?.webView.onBookmark?(URL(string: "https://example.org/linked")!, "A link")
        await pause(0.5)
        print("bookmarks: context menu link       \(editorState()) last=\(Bookmarks.items.last?.title ?? "-")")
        controller.debugBookmarkEditor.close()
        await pause(0.4)
        bar.onNewFolder?()
        await pause(0.5)
        print("bookmarks: New Folder              \(editorState()) visible=\(bar.debugVisibleTitles)")
        controller.debugBookmarkEditor.debugModel?.title = "Reading"
        controller.debugBookmarkEditor.close()
        await pause(0.5)
        print("bookmarks: folder renamed          visible=\(bar.debugVisibleTitles)")
        // Manager window: ⌥⌘B, a nested folder named inline, moves into it, reordering.
        await ensureActive(controller.window)
        post("b", keyCode: 11, modifiers: [.command, .option], window: controller.window)
        await pause(0.8)
        if let manager = (NSApp.delegate as? AppDelegate)?.debugBookmarksManager, let managerWindow = manager.window {
            manager.debugExpandAll()
            print("manager: ⌥⌘B                       visible=\(managerWindow.isVisible) rows=\(manager.debugRows)")
            print("manager: layout                    " + (managerWindow.contentView?.subviews.map { "\(type(of: $0))\($0.frame.integral)" } ?? []).joined(separator: " "))
            manager.debugSelect("Nested")
            manager.newFolder(nil)
            await pause(0.3)
            (managerWindow.firstResponder as? NSTextView)?.string = "Deep"
            managerWindow.makeFirstResponder(nil)
            await pause(0.3)
            print("manager: new folder in Nested      rows=\(manager.debugRows)")
            if let link = Bookmarks.path(of: URL(string: "https://example.org/linked")!),
               let deep = Bookmarks.folders.first(where: { $0.title == "Deep" })?.path {
                Bookmarks.move(link, to: deep, at: 0)
            }
            Bookmarks.move([1], to: [], at: 0)
            await pause(0.3)
            manager.debugExpandAll()
            print("manager: move into Deep + reorder  rows=\(manager.debugRows)")
            print("manager: folders                   \(Bookmarks.folders.map { String(repeating: ">", count: $0.depth) + $0.title })")
            if let view = managerWindow.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: outputDir.appendingPathComponent("manager.png"))
            }
            managerWindow.close()
        } else {
            print("FAIL manager: not opened")
        }

        if let data = try? Data(contentsOf: Bookmarks.fileURL),
           let json = try? JSONSerialization.jsonObject(with: data),
           let compact = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]) {
            print("bookmarks: file                    \(String(decoding: compact, as: UTF8.self))")
        }
        snapshot(controller, to: outputDir.appendingPathComponent("bookmarks-5-edited.png"))

        await write((1...40).map { ["title": "Bookmark \($0)", "url": "https://example.com/\($0)"] })
        report("bookmarks: 40 (overflow)")
        snapshot(controller, to: outputDir.appendingPathComponent("bookmarks-6-overflow.png"))

        await ensureActive(controller.window)
        post("B", keyCode: 11, modifiers: [.command, .shift], window: controller.window)
        await pause(0.5)
        report("bookmarks: ⌘⇧B hide")
        await ensureActive(controller.window)
        post("B", keyCode: 11, modifiers: [.command, .shift], window: controller.window)
        await pause(0.5)
        report("bookmarks: ⌘⇧B show")

        // ⌘⇧T: close a tab with history and a split, reopen it with both.
        controller.focusedPane?.load("https://example.com/one")
        await pause(1.5)
        controller.focusedPane?.load("https://example.com/two")
        await pause(1.5)
        await ensureActive(controller.window)
        post("d", keyCode: 2, modifiers: [.command], window: controller.window)
        await pause(0.6)
        controller.focusedPane?.load("https://example.org/")
        await pause(1.5)
        let beforeClose = "\(controller.tabCount) tabs | \(controller.debugDescriptionOfState)"
        await ensureActive(controller.window)
        post("W", keyCode: 13, modifiers: [.command, .shift], window: controller.window)
        await pause(0.6)
        let afterClose = controller.tabCount
        post("T", keyCode: 17, modifiers: [.command, .shift], window: controller.window)
        await pause(2)
        let panes = controller.debugPaneURLs
        print("tabs: ⌘⇧W then ⌘⇧T                 before=\(beforeClose) closed→\(afterClose) reopened→\(controller.tabCount) | \(controller.debugDescriptionOfState)")
        print("tabs: reopened panes               \(panes)")

        let tabsBefore = controller.tabCount
        bar.onOpen?(URL(string: "https://example.com/opened")!, false)
        await pause(1.5)
        print("bookmarks: open in pane            url=\(controller.focusedPane?.webView.url?.absoluteString ?? "-")")
        bar.onOpen?(URL(string: "https://example.com/background")!, true)
        await pause(0.5)
        print("bookmarks: open in background      tabs \(tabsBefore) → \(controller.tabCount)")
    }

    /// ⌘⇧P over the bookmarks written by `runBookmarks` (GitHub, Work › Apple, Work › Nested › HN, …).
    private static func runCommandPalette(_ controller: BrowserWindowController, outputDir: URL) async {
        let palette = controller.debugCommandPalette
        let window = controller.window
        let keyCodes: [Character: UInt16] = [
            "a": 0, "e": 14, "g": 5, "h": 4, "i": 34, "k": 40, "l": 37, "n": 45, "o": 31, "p": 35, "r": 15, "t": 17, "u": 32, "w": 13,
        ]
        func type(_ text: String) async {
            for character in text {
                post(String(character), keyCode: keyCodes[character] ?? 0, modifiers: [], window: window)
                await pause(0.1)
            }
            await pause(0.2)
        }
        func report(_ label: String) {
            print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) shown=\(palette.isShown) query=\"\(palette.debugQuery)\" "
                  + "results=\(palette.debugResults) selected=\(palette.debugSelectedTitle ?? "-")")
        }
        func open() async {
            await ensureActive(window)
            post("p", keyCode: 35, modifiers: [.command], window: window)
            await pause(0.5)
        }
        let down = arrow(NSDownArrowFunctionKey), arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

        controller.focusedPane?.focusWebView()
        await open()
        report("palette: ⌘P")
        await requestScreenCapture("command-palette", of: controller, in: outputDir)
        await type("hn")
        report("palette: 'hn'")
        await type("\u{7f}\u{7f}gh")
        report("palette: 'gh' (letters in order)")
        await type("\u{7f}\u{7f}work")
        report("palette: 'work' (folder)")
        await requestScreenCapture("command-palette-work", of: controller, in: outputDir)
        post(down, keyCode: 125, modifiers: arrowFlags, window: window)
        await pause(0.2)
        report("palette: ↓")
        post("j", keyCode: 38, modifiers: [.control], window: window)
        await pause(0.3)
        report("palette: ⌃J")
        post("\u{1b}", keyCode: 53, modifiers: [], window: window)
        await pause(0.3)
        let webViewFocused = window?.firstResponder === controller.focusedPane?.webView
        print("palette: Esc                        shown=\(palette.isShown) focus back on page=\(webViewFocused)")

        await open()
        await type("hacker")
        report("palette: 'hacker'")
        post("\r", keyCode: 36, modifiers: [], window: window)
        for _ in 0..<20 where controller.focusedPane?.webView.url?.host() != "news.ycombinator.com" { await pause(0.25) }
        print("palette: ↩                          shown=\(palette.isShown) url=\(controller.focusedPane?.webView.url?.absoluteString ?? "-")")

        await open()
        await open()
        print("palette: ⌘P twice                   shown=\(palette.isShown)")

        // Matching speed over a large collection (it runs on every keystroke).
        let many = (0..<5000).map { index in
            CommandPaletteMatcher.Candidate(
                CommandPaletteItem(title: "Bookmark number \(index) about topic \(index % 97)",
                                   keywords: "https://example.com/section/\(index)", perform: { _ in }), order: index)
        }
        let start = Date()
        var counts: [Int] = []
        for query in ["b", "bo", "boo", "book 4", "tpc", "example 42", "zzz"] {
            counts.append(CommandPaletteMatcher.matches(query, in: many).count)
        }
        print("palette: 7 queries over 5000        \(Int(Date().timeIntervalSince(start) * 1000)) ms total, matches=\(counts)")
    }

    /// Glass and popover-style windows don't show up in `snapshot`. This leaves a marker with the
    /// window's rect (in screencapture's top-left coordinates) and holds, so a script watching the
    /// output directory can grab the real screen: `screencapture -R<rect> <name>.png`.
    private static func requestScreenCapture(_ name: String, of controller: BrowserWindowController, in outputDir: URL) async {
        guard let frame = controller.window?.frame, let mainHeight = NSScreen.screens.first?.frame.height else { return }
        let rect = "\(Int(frame.minX)),\(Int(mainHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
        try? rect.write(to: outputDir.appendingPathComponent("capture-\(name).txt"), atomically: true, encoding: .utf8)
        await pause(1.5)
    }

    private static func snapshot(_ controller: BrowserWindowController, to url: URL) {
        guard let view = controller.window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

extension BrowserWindowController {
    /// Each pane of the selected tab: URL and whether it can go back.
    var debugPaneURLs: [String] {
        guard let root = (window?.contentView as? BrowserContentView)?.tabContent else { return [] }
        return root.paneLeaves.map { "\($0.webView.url?.absoluteString ?? "-") back=\($0.webView.canGoBack)" }
    }

    /// e.g. `tabs=2 sel=0 | H(A, V(B, *C))` where `*` marks the focused pane.
    var debugDescriptionOfState: String {
        let tree = (window?.contentView as? BrowserContentView)?.tabContent.map(describe) ?? "-"
        return "tabs=\(tabCount) sel=\(selectedTabIndex) | \(tree)"
    }

    private func describe(_ view: NSView) -> String {
        if let container = view as? PaneContainerView { return describe(container.child) }
        if let split = view as? SplitView {
            let axis = split.axis == .horizontal ? "H" : "V"
            return "\(axis)\(String(format: "%.2f", split.ratio))(\(describe(split.first)), \(describe(split.second)))"
        }
        if let pane = view as? PaneView {
            return (pane === focusedPane ? "*" : "") + pane.displayTitle
        }
        return "?"
    }
}
