import AppKit

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

        // Vertical sidebar: resize by dragging its edge, double-click resets, auto-hide + ⌃⌘S.
        if let window = controller.window {
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
            let handleX = root.debugSidebarFrame.maxX + 2
            print("sidebar width before               \(Int(Settings.sidebarWidth))")
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
            controller.toggleSidebar(nil)
            await pause(0.5)
            print("⌃⌘S hide                           sidebar width=\(Int(root.debugSidebarFrame.width)) revealed=\(root.isSidebarRevealed)")
            Settings.sidebarAutoHide = false
            Settings.tabLayout = .horizontal
        }

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

        let tabsBefore = controller.tabCount
        bar.onOpen?(URL(string: "https://example.com/opened")!, false)
        await pause(1.5)
        print("bookmarks: open in pane            url=\(controller.focusedPane?.webView.url?.absoluteString ?? "-")")
        bar.onOpen?(URL(string: "https://example.com/background")!, true)
        await pause(0.5)
        print("bookmarks: open in background      tabs \(tabsBefore) → \(controller.tabCount)")
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
