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

        func page(_ name: String, _ color: String) {
            controller.focusedPane?.load("data:text/html,<title>\(name)</title><body style='background:\(color)'><h1>\(name)</h1>")
        }

        func step(_ label: String, _ keys: [(String, UInt16, NSEvent.ModifierFlags)] = []) async {
            for (characters, keyCode, modifiers) in keys {
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
            Settings.vimKeysEnabled = false
            await pause(0.3)
            await press("j")
            await pause(0.5)
            print("vim j while disabled               scrollY=\(await scrollY())")
            Settings.vimKeysEnabled = true
        }

        await step("⌘W in tab 1", [("w", 13, [.command])])
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
