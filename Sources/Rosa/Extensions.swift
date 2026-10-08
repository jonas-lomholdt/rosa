import AppKit
import CryptoKit
import WebKit

/// Web extensions, run by WebKit's own extension engine (`WKWebExtension`, the one Safari uses).
/// It implements the WebExtensions API, `chrome.*` included, so unpacked Chrome extensions mostly
/// load as they are. Rosa supplies the browser side: windows (`BrowserWindowController`), tabs
/// (every `PaneView`, so content scripts can message their own pane), toolbar buttons, popups,
/// keyboard commands and permissions.
///
/// Installed extensions are folders in `~/.rosa/extensions/<id>/`, loaded at launch. Native
/// messaging (talking to a desktop app) isn't supported.
@MainActor
final class Extensions: NSObject, WKWebExtensionControllerDelegate {
    static let shared = Extensions()
    /// Posted when an extension is installed, removed, or its toolbar action changes.
    static let didChange = Notification.Name("ExtensionsDidChange")

    static let directory = Settings.fileURL.deletingLastPathComponent()
        .appendingPathComponent("extensions", isDirectory: true)

    let controller: WKWebExtensionController
    /// Loaded extensions, by name.
    private(set) var contexts: [WKWebExtensionContext] = []

    override init() {
        // A fixed identifier keeps extension storage (logins, settings) across launches.
        let configuration = WKWebExtensionController.Configuration(
            identifier: UUID(uuidString: "0D5B7C3E-6A41-4F0B-9E57-52A3C1F0B6A8")!
        )
        configuration.defaultWebsiteDataStore = .default()
        // Popups, background pages and settings pages get Rosa's user agent and Web Inspector.
        configuration.webViewConfiguration = WebKitSupport.makeBaseConfiguration()
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        // Console forwarding is for watching live: a file on stdout would otherwise get it only at exit.
        if ProcessInfo.processInfo.environment["BROWSER_EXTENSION_CONSOLE"] == "1" { setvbuf(stdout, nil, _IOLBF, 0) }
    }

    // MARK: - Loading

    func loadInstalled() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        for folder in folders where FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) {
            Task { try? await load(folder) }
        }
    }

    @discardableResult
    private func load(_ folder: URL) async throws -> WKWebExtensionContext {
        let id = folder.lastPathComponent
        do {
            try ExtensionCompatibility.apply(to: folder)
            let webExtension = try await WKWebExtension(resourceBaseURL: folder)
            let context = WKWebExtensionContext(for: webExtension)
            // Stable, so storage and the extension's own URLs survive relaunches.
            context.uniqueIdentifier = id
            context.baseURL = URL(string: "webkit-extension://\(id)/")!
            // Shows up in Safari's Develop menu under this Mac → Rosa.
            context.isInspectable = true
            context.inspectionName = webExtension.displayName
            // Installing is the consent (Rosa asks first), like Chrome.
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in webExtension.requestedPermissionMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            for error in webExtension.errors {
                NSLog("Rosa: extension %@: %@", id, error.localizedDescription)
            }
            contexts.append(context)
            contexts.sort { Self.name(of: $0).localizedCaseInsensitiveCompare(Self.name(of: $1)) == .orderedAscending }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return context
        } catch {
            NSLog("Rosa: extension %@ failed to load: %@", id, String(describing: error))
            throw error
        }
    }

    static func name(of context: WKWebExtensionContext) -> String {
        context.webExtension.displayName ?? context.uniqueIdentifier
    }

    // MARK: - Installing

    /// Asks for an unpacked extension folder, a .crx or a .zip, and installs it.
    func chooseAndInstall() {
        let panel = NSOpenPanel()
        panel.title = "Install Extension"
        panel.message = "Choose an unpacked extension folder (with a manifest.json), a .crx or a .zip."
        panel.prompt = "Install"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip, .init(filenameExtension: "crx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        install(fromUserChoice: url)
    }

    /// An extension installed in a Chromium browser on this Mac (`importable()`).
    struct Importable {
        var browser: String
        var name: String
        var folder: URL
    }

    /// Extensions in other browsers' profiles, newest version of each, to install from there.
    static func importable() -> [Importable] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let browsers = [
            ("Chrome", "Google/Chrome"), ("Edge", "Microsoft Edge"), ("Brave", "BraveSoftware/Brave-Browser"),
            ("Arc", "Arc/User Data"), ("Vivaldi", "Vivaldi"), ("Chromium", "Chromium"),
        ]
        let fileManager = FileManager.default
        var found: [Importable] = []
        for (browser, path) in browsers {
            let root = support.appendingPathComponent(path)
            let profiles = (try? fileManager.contentsOfDirectory(atPath: root.path))?
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") } ?? []
            var seen = Set<String>()
            for profile in profiles.sorted() {
                let extensions = root.appendingPathComponent(profile).appendingPathComponent("Extensions")
                for id in (try? fileManager.contentsOfDirectory(atPath: extensions.path)) ?? [] where !seen.contains(id) {
                    let versions = (try? fileManager.contentsOfDirectory(atPath: extensions.appendingPathComponent(id).path)) ?? []
                    guard let version = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else { continue }
                    let folder = extensions.appendingPathComponent(id).appendingPathComponent(version)
                    guard let name = displayName(ofManifestIn: folder) else { continue }
                    seen.insert(id)
                    found.append(Importable(browser: browser, name: name, folder: folder))
                }
            }
        }
        return found
    }

    /// The manifest's name, localized (`__MSG_key__`) from its default locale.
    private static func displayName(ofManifestIn folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = manifest["name"] as? String else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
        let key = String(name.dropFirst(6).dropLast(2))
        let locale = manifest["default_locale"] as? String ?? "en"
        let messagesURL = folder.appendingPathComponent("_locales/\(locale)/messages.json")
        guard let messagesData = try? Data(contentsOf: messagesURL),
              let messages = try? JSONSerialization.jsonObject(with: messagesData) as? [String: [String: Any]] else { return nil }
        let entry = messages.first { $0.key.lowercased() == key.lowercased() }?.value
        return entry?["message"] as? String
    }

    func install(fromUserChoice url: URL) {
        Task {
            do {
                try await install(from: url)
            } catch is CancellationError {
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn't install the extension"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    struct InstallError: LocalizedError {
        var errorDescription: String?
    }

    func install(from source: URL) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let staging = Self.directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            try fileManager.copyItem(at: source, to: staging)
        } else {
            var archive = try Data(contentsOf: source)
            if source.pathExtension.lowercased() == "crx" { archive = try Self.zipPayload(ofCRX: archive) }
            let zip = Self.directory.appendingPathComponent(".staging-\(UUID().uuidString).zip")
            defer { try? fileManager.removeItem(at: zip) }
            try archive.write(to: zip)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        }

        let root = try Self.manifestRoot(in: staging)
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw InstallError(errorDescription: "manifest.json isn't valid JSON.")
        }
        // Chrome's ID when the manifest carries its key, so it matches the Chrome install.
        let id = (manifest["key"] as? String).flatMap(Self.chromeID(fromKey:))
            ?? Self.slug(manifest["name"] as? String ?? source.deletingPathExtension().lastPathComponent)

        // Parse it before asking, so a broken extension fails here rather than after consent.
        let webExtension = try await WKWebExtension(resourceBaseURL: root)
        guard confirmInstall(webExtension) else { throw CancellationError() }

        let destination = Self.directory.appendingPathComponent(id, isDirectory: true)
        if let existing = contexts.first(where: { $0.uniqueIdentifier == id }) {
            try? controller.unload(existing)
            contexts.removeAll { $0 === existing }
        }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: root, to: destination)
        try await load(destination)
    }

    private func confirmInstall(_ webExtension: WKWebExtension) -> Bool {
        let alert = NSAlert()
        let name = webExtension.displayName ?? "this extension"
        alert.messageText = "Install “\(name)”?"
        var details: [String] = []
        if webExtension.requestedPermissionMatchPatterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            details.append("It can read and change everything on every website you visit.")
        } else if !webExtension.requestedPermissionMatchPatterns.isEmpty {
            let hosts = webExtension.requestedPermissionMatchPatterns.compactMap(\.host).sorted().prefix(5)
            details.append("It can read and change data on: \(hosts.joined(separator: ", ")).")
        }
        if let version = webExtension.displayVersion { details.append("Version \(version).") }
        alert.informativeText = details.joined(separator: "\n\n")
        alert.icon = webExtension.icon(for: NSSize(width: 64, height: 64))
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func remove(_ context: WKWebExtensionContext) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(Self.name(of: context))”?"
        alert.informativeText = "Its settings and stored data are deleted too."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.fetchDataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes, for: context) { [controller] record in
            guard let record else { return }
            controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [record]) {}
        }
        try? controller.unload(context)
        contexts.removeAll { $0 === context }
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(context.uniqueIdentifier))
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The folder holding manifest.json: the root, or a single top-level folder (zips often have one).
    private static func manifestRoot(in folder: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        let children = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        if children.count == 1, fileManager.fileExists(atPath: children[0].appendingPathComponent("manifest.json").path) {
            return children[0]
        }
        throw InstallError(errorDescription: "No manifest.json found. Choose the extension's own folder.")
    }

    /// A .crx is a zip behind a header ("Cr24", version, then signatures).
    static func zipPayload(ofCRX data: Data) throws -> Data {
        func uint32(at offset: Int) -> Int {
            data.subdata(in: offset..<offset + 4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        }
        guard data.count > 16, data.prefix(4) == Data("Cr24".utf8) else {
            throw InstallError(errorDescription: "That isn't a .crx file.")
        }
        let start = switch uint32(at: 4) {
        case 2: 16 + uint32(at: 8) + uint32(at: 12)
        case 3: 12 + uint32(at: 8)
        default: throw InstallError(errorDescription: "Unsupported .crx version.")
        }
        guard start < data.count else { throw InstallError(errorDescription: "The .crx file is damaged.") }
        return data.subdata(in: start..<data.count)
    }

    /// Chrome derives an extension's ID from its public key: the first 128 bits of its SHA-256,
    /// written with the letters a–p.
    static func chromeID(fromKey key: String) -> String? {
        guard let der = Data(base64Encoded: key) else { return nil }
        let letters = SHA256.hash(data: der).prefix(16).flatMap { [$0 >> 4, $0 & 0xF] }
        return String(letters.map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
    }

    private static func slug(_ name: String) -> String {
        let slug = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "extension" : slug
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError(errorDescription: "Couldn't unpack the archive.")
        }
    }

    // MARK: - Keyboard commands

    /// The extensions' own shortcuts (1Password: ⌘⇧X opens its popup). Called after Rosa's menus.
    func performCommand(for event: NSEvent) -> Bool {
        contexts.contains { $0.performCommand(for: event) }
    }

    // MARK: - Tabs and windows

    private var browserWindows: [BrowserWindowController] {
        NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
    }

    private var focusedBrowserWindow: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? browserWindows.first
    }

    /// Called once a pane is in a tab (so it can report its window and index).
    func didOpen(_ pane: PaneView) {
        controller.didOpenTab(pane)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        browserWindows
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focusedBrowserWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionTab)? {
        let window = (configuration.window as? BrowserWindowController) ?? focusedBrowserWindow ?? newBrowserWindow()
        return window.addTab(for: configuration.url, extensionContext: extensionContext, select: configuration.shouldBeActive)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionWindow)? {
        let window = newBrowserWindow()
        for (index, url) in configuration.tabURLs.enumerated() {
            if index == 0, let pane = window.focusedPane {
                pane.webView.load(URLRequest(url: url))
            } else {
                window.addTab(for: url, extensionContext: extensionContext, select: false)
            }
        }
        return window
    }

    private func newBrowserWindow() -> BrowserWindowController {
        (NSApp.delegate as? AppDelegate)?.newWindow(nil)
        return focusedBrowserWindow!
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext
    ) async throws {
        guard let url = extensionContext.optionsPageURL else { return }
        (focusedBrowserWindow ?? newBrowserWindow()).addTab(for: url, extensionContext: extensionContext, select: true)
    }

    // Optional permissions asked for at runtime are granted; the extension was trusted on install.

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.Permission>, Date?) {
        (permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext
    ) async -> (Set<URL>, Date?) {
        (urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        (matchPatterns, nil)
    }

    // MARK: - Toolbar action

    func webExtensionController(
        _ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext
    ) async throws {
        guard let popover = action.popupPopover else { return }
        let pane = (action.associatedTab as? PaneView) ?? focusedBrowserWindow?.focusedPane
        guard let pane, let browserWindow = pane.browserWindow else { return }
        // No toolbar (zen mode): hang it from the pane's top-right corner.
        let anchor: NSView = browserWindow.extensionButton(for: context, in: pane) ?? pane
        let anchorRect = anchor === pane
            ? NSRect(x: pane.bounds.maxX - 8, y: pane.bounds.minY, width: 0, height: 0)
            : anchor.bounds
        // Like Chrome: no arrow, right edge lined up with the button, kept inside the window.
        if popover.responds(to: Selector(("setShouldHideAnchor:"))) {
            popover.setValue(true, forKey: "shouldHideAnchor")
        }
        let edge: NSRectEdge = anchor.isFlipped ? .maxY : .minY
        popover.show(relativeTo: positioningRect(for: popover, anchor: anchor, anchorRect: anchorRect), of: anchor, preferredEdge: edge)
        // The popup page sizes itself after loading; keep the right edge where it is.
        let key = ObjectIdentifier(popover)
        let resize = popover.observe(\.contentSize) { [weak self, weak anchor] popover, _ in
            MainActor.assumeIsolated {
                guard let self, let anchor, popover.isShown else { return }
                popover.positioningRect = self.positioningRect(for: popover, anchor: anchor, anchorRect: anchorRect)
            }
        }
        let close = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let observation = self.popupObservations.removeValue(forKey: key) else { return }
                NotificationCenter.default.removeObserver(observation.close)
            }
        }
        popupObservations[key] = (resize, close)
    }

    private var popupObservations: [ObjectIdentifier: (resize: NSKeyValueObservation, close: NSObjectProtocol)] = [:]

    /// A sliver whose centre puts the popover's right edge at the anchor's right edge, or further
    /// left when the window's edge is closer. (A popover centres itself on its positioning rect.)
    private func positioningRect(for popover: NSPopover, anchor: NSView, anchorRect: NSRect) -> NSRect {
        let width = popover.contentSize.width
        var right = anchorRect.maxX
        if let content = anchor.window?.contentView {
            let windowRight = anchor.convert(NSPoint(x: content.bounds.maxX - 8, y: 0), from: content).x
            right = min(right, windowRight)
        }
        return NSRect(x: (right - width / 2).rounded(), y: anchorRect.minY, width: 1, height: anchorRect.height)
    }

    // MARK: - Native messaging (not supported)

    /// Where `BROWSER_EXTENSION_CONSOLE=1` forwards extension console output (`ExtensionCompatibility`).
    static let consoleApplicationID = "rosa.console"

    func webExtensionController(
        _ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext
    ) async throws -> Any? {
        if applicationIdentifier == Self.consoleApplicationID, let entry = message as? [String: Any] {
            print("[\(extensionContext.uniqueIdentifier) \(entry["where"] ?? "?")] \(entry["level"] ?? "log"): \(entry["text"] ?? "")")
            return nil
        }
        throw InstallError(errorDescription: "Native messaging isn't supported.")
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext
    ) async throws {
        throw InstallError(errorDescription: "Native messaging isn't supported.")
    }
}

// MARK: - Toolbar buttons

/// The extensions' toolbar buttons, at the end of an address bar. Acts on `pane`.
final class ExtensionToolbar: NSView {
    static let buttonSize: CGFloat = 18
    static let iconSize: CGFloat = 14
    static let spacing: CGFloat = 4

    /// The buttons came or went: the address bar makes room.
    var onWidthChange: (() -> Void)?

    weak var pane: PaneView? { didSet { if pane !== oldValue { refresh() } } }
    private(set) var buttons: [ExtensionButton] = []
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observer = NotificationCenter.default.addObserver(forName: Extensions.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var width: CGFloat {
        buttons.isEmpty ? 0 : CGFloat(buttons.count) * (Self.buttonSize + Self.spacing)
    }

    /// Keeps existing buttons (an open popup stays anchored) and only rebuilds when the set changes.
    func refresh() {
        let contexts = Extensions.shared.contexts
        if buttons.map(\.context) != contexts {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = contexts.map { ExtensionButton(context: $0) }
            buttons.forEach(addSubview)
            onWidthChange?()
        }
        for button in buttons { button.update(for: pane) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: CGFloat(index) * (Self.buttonSize + Self.spacing), y: ((bounds.height - Self.buttonSize) / 2).rounded(),
                width: Self.buttonSize, height: Self.buttonSize
            )
        }
    }
}

final class ExtensionButton: NSButton {
    let context: WKWebExtensionContext
    private weak var pane: PaneView?

    init(context: WKWebExtensionContext) {
        self.context = context
        super.init(frame: .zero)
        isBordered = false
        imageScaling = .scaleProportionallyDown
        target = self
        action = #selector(clicked(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(for pane: PaneView?) {
        self.pane = pane
        let action = context.action(for: pane)
        let size = NSSize(width: ExtensionToolbar.iconSize, height: ExtensionToolbar.iconSize)
        let icon = (action?.icon(for: size) ?? context.webExtension.actionIcon(for: size))?.copy() as? NSImage
        icon?.size = size
        image = icon
        let label = action?.label ?? ""
        toolTip = label.isEmpty ? Extensions.name(of: context) : label
        isEnabled = action?.isEnabled ?? true
        let badge = action?.badgeText ?? ""
        setAccessibilityLabel(badge.isEmpty ? toolTip : "\(toolTip ?? "") (\(badge))")
    }

    @objc private func clicked(_ sender: Any?) {
        if let pane { context.userGesturePerformed(in: pane) }
        context.performAction(for: pane)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if let pane { menu.items = context.menuItems(for: pane) }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if context.optionsPageURL != nil {
            let options = NSMenuItem(title: "Settings…", action: #selector(openOptions(_:)), keyEquivalent: "")
            options.target = self
            menu.addItem(options)
        }
        let remove = NSMenuItem(title: "Remove “\(Extensions.name(of: context))”…", action: #selector(removeExtension(_:)), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openOptions(_ sender: Any?) {
        guard let url = context.optionsPageURL else { return }
        pane?.browserWindow?.addTab(for: url, extensionContext: context, select: true)
    }

    @objc private func removeExtension(_ sender: Any?) {
        Extensions.shared.remove(context)
    }
}

// MARK: - Extensions menu

/// Rosa → Extensions: install, and each extension's settings / removal. Rebuilt when opened.
final class ExtensionsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ExtensionsMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            let install = NSMenuItem(title: "Install Extension…", action: #selector(install(_:)), keyEquivalent: "")
            install.target = self
            menu.addItem(install)
            let importItem = NSMenuItem(title: "Import from Another Browser", action: nil, keyEquivalent: "")
            let importMenu = NSMenu()
            let importable = Extensions.importable()
            for found in importable.sorted(by: { ($0.browser, $0.name) < ($1.browser, $1.name) }) {
                let item = NSMenuItem(title: "\(found.name) (\(found.browser))", action: #selector(importExtension(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = found.folder
                importMenu.addItem(item)
            }
            if importable.isEmpty {
                importMenu.addItem(NSMenuItem(title: "No Chrome, Edge, Brave, Arc or Vivaldi extensions found", action: nil, keyEquivalent: ""))
            }
            importItem.submenu = importMenu
            menu.addItem(importItem)
            let reveal = NSMenuItem(title: "Show Extensions Folder", action: #selector(revealFolder(_:)), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
            let contexts = Extensions.shared.contexts
            if !contexts.isEmpty { menu.addItem(.separator()) }
            for context in contexts {
                let item = NSMenuItem(title: Extensions.name(of: context), action: nil, keyEquivalent: "")
                item.image = context.webExtension.icon(for: NSSize(width: 16, height: 16))
                let submenu = NSMenu()
                if context.optionsPageURL != nil {
                    let options = NSMenuItem(title: "Settings…", action: #selector(openOptions(_:)), keyEquivalent: "")
                    options.target = self
                    options.representedObject = context
                    submenu.addItem(options)
                }
                let remove = NSMenuItem(title: "Remove…", action: #selector(remove(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = context
                submenu.addItem(remove)
                item.submenu = submenu
                menu.addItem(item)
            }
        }
    }

    @objc private func install(_ sender: Any?) {
        MainActor.assumeIsolated { Extensions.shared.chooseAndInstall() }
    }

    @objc private func importExtension(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard let folder = sender.representedObject as? URL else { return }
            Extensions.shared.install(fromUserChoice: folder)
        }
    }

    @objc private func revealFolder(_ sender: Any?) {
        let directory = MainActor.assumeIsolated { Extensions.directory }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func openOptions(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard let context = sender.representedObject as? WKWebExtensionContext, let url = context.optionsPageURL,
                  let window = NSApp.orderedWindows.lazy.compactMap({ $0.windowController as? BrowserWindowController }).first
            else { return }
            window.addTab(for: url, extensionContext: context, select: true)
        }
    }

    @objc private func remove(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard let context = sender.representedObject as? WKWebExtensionContext else { return }
            Extensions.shared.remove(context)
        }
    }
}

// MARK: - Panes as extension tabs

/// Every pane is a tab to extensions: each has its own page, and content scripts message it.
extension PaneView: WKWebExtensionTab {
    var browserWindow: BrowserWindowController? { delegate as? BrowserWindowController }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { browserWindow }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browserWindow?.allPanes.firstIndex(of: self) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }
    func size(for context: WKWebExtensionContext) -> CGSize { webView.bounds.size }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { webView.pageZoom }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        browserWindow?.focusedPane === self
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        webView.pageZoom = zoomFactor
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        webView.load(URLRequest(url: url))
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
    }

    func goBack(for context: WKWebExtensionContext) async throws { webView.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { webView.goForward() }

    func activate(for context: WKWebExtensionContext) async throws {
        browserWindow?.reveal(self)
    }

    func close(for context: WKWebExtensionContext) async throws {
        browserWindow?.closeFromExtension(self)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

// MARK: - Browser windows as extension windows

extension BrowserWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { allPanes }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { focusedPane }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext) async throws {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(for context: WKWebExtensionContext) async throws {
        window?.close()
    }
}

// MARK: - Debugging

/// With `BROWSER_EXTENSION_CONSOLE=1`, pages report the names of custom events they and extension
/// scripts exchange (`B5…` for 1Password; never their contents), to see where a handshake stops.
@MainActor
final class ExtensionEventTrace: NSObject, WKScriptMessageHandler {
    private static let shared = ExtensionEventTrace()
    private static let enabled = ProcessInfo.processInfo.environment["BROWSER_EXTENSION_CONSOLE"] == "1"
    private static let script = """
    (() => {
      const send = (what) => { try { window.webkit.messageHandlers.rosaEventTrace.postMessage(what); } catch {} };
      const original = EventTarget.prototype.dispatchEvent;
      EventTarget.prototype.dispatchEvent = function (event) {
        if (/^B5/.test(String(event.type))) send(`page dispatched ${event.type}`);
        return original.call(this, event);
      };
      for (const type of ["B5OPXReady", "B5InitializeSession", "B5InitializeDevice", "B5TrustedDeviceUpgradeRequest", "B5RequestDelegatedSession"]) {
        document.addEventListener(type, () => send(`page heard ${type}`), true);
      }
    })();
    """

    /// Re-added by `LinkHints.install`, which clears every user script.
    static let userScript: WKUserScript? = enabled
        ? WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page) : nil

    static func install(on controller: WKUserContentController) {
        guard enabled else { return }
        controller.add(shared, contentWorld: .page, name: "rosaEventTrace")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        print("[event \(message.frameInfo.request.url?.host() ?? "?")\(message.frameInfo.request.url?.path() ?? "")] \(message.body)")
    }
}
