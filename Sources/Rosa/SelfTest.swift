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
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "quicklinks" {
            await runQuickLinks(controller, outputDir: outputDir)
            return
        }
        if ProcessInfo.processInfo.environment["BROWSER_SELFTEST_ONLY"] == "commands" {
            await runPaletteCommands(controller, outputDir: outputDir)
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
        for layout in [TabLayout.horizontal, .vertical] {
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
        // Navigation button feedback: back hovered, reload pressed.
        await pause(0.3)
        root.navigationButtons.debugSetStates(hoverBack: true, pressReload: true)
        await requestScreenCapture("nav-feedback", of: controller, in: outputDir)
        root.navigationButtons.debugSetStates(hoverBack: false, pressReload: false)
        print(failures == 0 ? "layout: all ok" : "layout: \(failures) FAILED")
    }

    /// ⌘⇧P then `>`: menu commands with shortcuts and checkmarks, run on the focused pane;
    /// deleting the `>` goes back to bookmarks.
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
        func enter() async {
            post("\r", keyCode: 36, modifiers: [], window: window)
            await pause(0.6)
        }

        controller.focusedPane?.load("data:text/html,<title>One</title><h1>One</h1>")
        await pause(1)
        controller.focusedPane?.focusWebView()
        await open()
        check("⌘⇧P: bookmarks mode", palette.isShown && !palette.debugResults.contains("Zen Mode"))
        await type(">")
        let all = palette.debugResults
        print("commands: \(zip(all, palette.debugShortcuts).map { $0.1.isEmpty ? $0.0 : "\($0.0) \($0.1)" })")
        check("'>' lists menu commands", all.contains("Zen Mode") && all.contains("Split Right") && all.contains("Find…"))
        check("no text editing or palette itself", !all.contains { ["Copy", "Paste", "Undo", "Select All", "Command Palette…"].contains($0) })
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
        await type("> zen")
        await enter()
        check("'> zen' (space) runs it again", !controller.isZenMode)

        await open()
        await type(">split r")
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
        await type(">tab")
        check("no Select Tab rows", !palette.debugResults.contains { $0.hasPrefix("Select") } && palette.debugResults.contains("Show Next Tab"))
        post("\u{1b}", keyCode: 53, modifiers: [], window: window)
        await pause(0.3)

        await open()
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
        await type(">\u{7f}")
        check("deleting '>' goes back to bookmarks", palette.isShown && !palette.debugResults.contains("Zen Mode"))
        post("\u{1b}", keyCode: 53, modifiers: [], window: window)
        await pause(0.3)
        print(failures == 0 ? "commands: all ok" : "commands: \(failures) FAILED")
    }

    /// Zen mode (⌃⌘Z): no chrome in any layout, panes fill the window, the same key brings it all
    /// back, and ⌘L leaves it with the address bar focused.
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
        check("panes not dimmed", controller.debugPanes.allSatisfy { $0.alphaValue == 1 })
        snapshot(controller, to: outputDir.appendingPathComponent("zen-split.png"))

        for (layout, mode) in [(TabLayout.vertical, AddressBarMode.perPane), (.vertical, .shared), (.horizontal, .shared)] {
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

    /// Welcome commands: only on the pane Rosa opens at launch, a click acts on that pane, hidden
    /// while the pane is too small, gone once it loads a page. Posts no key events.
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

    private static func runWelcome(_ controller: BrowserWindowController, outputDir: URL) async {
        var failures = 0
        func panes() -> [PaneView] { controller.debugContentRoot.tabContent?.paneLeaves ?? [] }
        func shown() -> String { panes().map { $0.welcome.map { $0.isHidden ? "h" : "W" } ?? "-" }.joined() }
        func check(_ label: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 40, withPad: " ", startingAt: 0)) panes=\(shown()) \(controller.debugDescriptionOfState)")
        }
        let shortcuts = WelcomeView.sections.flatMap(\.commands).map { "\($0.title)=\(WelcomeView.shortcut(for: $0.action) ?? "?")" }
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
            post("P", keyCode: 35, modifiers: [.command, .shift], window: window)
            await pause(0.5)
        }
        let down = arrow(NSDownArrowFunctionKey), arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

        controller.focusedPane?.focusWebView()
        await open()
        report("palette: ⌘⇧P")
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
        print("palette: ⌘⇧P twice                  shown=\(palette.isShown)")

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
