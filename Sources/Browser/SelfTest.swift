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
        NSApp.postEvent(event, atStart: false)
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
