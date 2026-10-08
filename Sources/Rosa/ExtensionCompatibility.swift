import CryptoKit
import Foundation

/// Fills in the Chrome extension APIs WebKit doesn't have, so Chrome extensions that touch them
/// at startup keep running (1Password's background script dies on `chrome.notifications`).
///
/// Before an installed extension loads, Rosa writes `rosa-compat/shims-<hash>.js` into its folder and
/// makes it run first everywhere the extension has its own code: the background script goes
/// through a wrapper, and every HTML page gets a script tag. The untouched manifest is kept in
/// `rosa-compat/manifest.original.json`, and the patch is rebuilt from it on every launch, so a
/// newer Rosa brings newer shims (under a new name: WebKit caches extension files across launches).
/// Content scripts aren't touched: they only get `runtime`,
/// `storage` and `i18n`, which WebKit has.
enum ExtensionCompatibility {
    static let folder = "rosa-compat"
    private static let shimsFile: String = {
        let hash = SHA256.hash(data: Data(script.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "shims-\(hash).js"
    }()
    private static let scriptTag = "<script src=\"/\(folder)/\(shimsFile)\"></script>"
    private static let oldScriptTags = "<script src=\"/\(folder)/shims[^\"]*\"></script>"

    static func apply(to root: URL) throws {
        let fileManager = FileManager.default
        let compat = root.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: compat, withIntermediateDirectories: true)
        for old in try fileManager.contentsOfDirectory(atPath: compat.path) where old.hasPrefix("shims") && old != shimsFile {
            try? fileManager.removeItem(at: compat.appendingPathComponent(old))
        }
        try script.write(to: compat.appendingPathComponent(shimsFile), atomically: true, encoding: .utf8)

        let manifestURL = root.appendingPathComponent("manifest.json")
        let originalURL = compat.appendingPathComponent("manifest.original.json")
        if !fileManager.fileExists(atPath: originalURL.path) {
            try fileManager.copyItem(at: manifestURL, to: originalURL)
        }
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: originalURL)) as? [String: Any] else { return }

        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String {
                let wrapper = background["type"] as? String == "module"
                    ? "import \"/\(folder)/\(shimsFile)\";\nimport \"/\(worker)\";\n"
                    : "importScripts(\"/\(folder)/\(shimsFile)\", \"/\(worker)\");\n"
                try wrapper.write(to: compat.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
                background["service_worker"] = "\(folder)/background.js"
            } else if let scripts = background["scripts"] as? [String] {
                background["scripts"] = ["\(folder)/\(shimsFile)"] + scripts
            }
            manifest["background"] = background
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)

        // Popups, settings and the extension's other pages (MV2 background pages too).
        let pages = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) } ?? []
        for page in pages {
            guard var html = try? String(contentsOf: page, encoding: .utf8), !html.contains(scriptTag) else { continue }
            html = html.replacingOccurrences(of: oldScriptTags, with: "", options: .regularExpression)
            let patched: String
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                patched = html.replacingCharacters(in: head.upperBound..<head.upperBound, with: scriptTag)
            } else if let doctype = html.range(of: "<!doctype[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                patched = html.replacingCharacters(in: doctype.upperBound..<doctype.upperBound, with: scriptTag)
            } else {
                patched = scriptTag + html
            }
            try? patched.write(to: page, atomically: true, encoding: .utf8)
        }
    }

    /// Stand-ins for missing namespaces. Methods take a callback or return a promise, like
    /// Chrome's; events accept listeners and never fire.
    /// The shims, plus console forwarding with `BROWSER_EXTENSION_CONSOLE=1`.
    private static let script = ProcessInfo.processInfo.environment["BROWSER_EXTENSION_CONSOLE"] == "1"
        ? shims + consoleForwarding : shims

    /// Debugging: errors and warnings from the extension's worker and pages reach Rosa's stdout
    /// through native messaging (`Extensions.consoleApplicationID`). Needs `nativeMessaging`.
    private static let consoleForwarding = #"""
    (() => {
      const api = globalThis.chrome || globalThis.browser;
      if (!api || !api.runtime || !api.runtime.sendNativeMessage) return;
      const where = globalThis.location ? location.pathname : "?";
      const text = (value) => {
        if (value instanceof Error && !value.stack) return `${value.name}: ${value.message}`;
        if (value && value.stack) return `${value}\n${value.stack.split("\n").slice(0, 4).join("\n")}`;
        if (typeof value === "object") { try { return JSON.stringify(value).slice(0, 300); } catch { return String(value); } }
        return String(value);
      };
      const send = (level, values) => {
        try { api.runtime.sendNativeMessage("rosa.console", { level, where, text: values.map(text).join(" ") }).catch(() => {}); } catch {}
      };
      for (const level of ["error", "warn", "info", "log"]) {
        const original = console[level];
        console[level] = (...values) => { send(level, values); original.apply(console, values); };
      }
      // Requests by method, host and path (no query, headers or bodies), with status or failure.
      const originalFetch = globalThis.fetch;
      if (originalFetch) {
        globalThis.fetch = async (input, init) => {
          const url = new URL(typeof input === "string" ? input : input.url ?? String(input), globalThis.location?.href);
          const label = `fetch ${(init && init.method) || (input && input.method) || "GET"} ${url.host}${url.pathname}`;
          const started = Date.now();
          try {
            const response = await originalFetch(input, init);
            if (url.protocol.startsWith("http")) send("net", [`${label} -> ${response.status} (${Date.now() - started}ms)`]);
            return response;
          } catch (error) {
            send("net", [`${label} failed after ${Date.now() - started}ms: ${error}`]);
            throw error;
          }
        };
      }
      globalThis.addEventListener?.("error", (event) => send("uncaught", [event.message, `${event.filename}:${event.lineno}`, event.error]));
      globalThis.addEventListener?.("unhandledrejection", (event) => send("rejection", [event.reason]));
    })();
    """#

    static let shims = #"""
    // Added by Rosa: Chrome extension APIs WebKit doesn't provide.
    (() => {
      const api = globalThis.chrome || globalThis.browser;
      if (!api || api.__rosaCompat) return;
      Object.defineProperty(api, "__rosaCompat", { value: true });

      const event = () => {
        const listeners = new Set();
        return {
          addListener: (listener) => { listeners.add(listener); },
          removeListener: (listener) => { listeners.delete(listener); },
          hasListener: (listener) => listeners.has(listener),
          hasListeners: () => listeners.size > 0,
        };
      };
      const method = (impl) => (...args) => {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const result = Promise.resolve().then(() => impl(...args));
        if (!callback) return result;
        result.then((value) => callback(value), () => callback());
      };
      // WebKit makes namespace objects (chrome.storage, …) on demand and may garbage-collect and
      // remake them, losing anything added. Holding on to the patched ones keeps them.
      const patched = new Set();
      Object.defineProperty(globalThis, Symbol.for("rosa.compat.patched"), { value: patched });
      const add = (target, name, value) => {
        if (target[name] !== undefined) return;
        target[name] = value;
        patched.add(target);
      };
      const define = (name, value) => add(api, name, value);
      const manifest = api.runtime && api.runtime.getManifest ? api.runtime.getManifest() : {};

      // Events Chrome has in namespaces WebKit does provide.
      const missingEvents = {
        runtime: ["onSuspend", "onSuspendCanceled", "onUpdateAvailable", "onRestartRequired"],
        tabs: ["onZoomChange"],
        windows: ["onBoundsChanged"],
        webNavigation: ["onCreatedNavigationTarget", "onHistoryStateUpdated", "onReferenceFragmentUpdated", "onTabReplaced"],
        webRequest: ["onActionIgnored"],
      };
      for (const [namespace, names] of Object.entries(missingEvents)) {
        const target = api[namespace];
        if (!target) continue;
        for (const name of names) add(target, name, event());
      }

      // Policies an administrator set; there are none.
      if (api.storage) {
        add(api.storage, "managed", {
          get: method(() => ({})),
          getBytesInUse: method(() => 0),
          onChanged: event(),
        });
      }

      let notificationCount = 0;
      define("notifications", {
        create: method((id, options) => (typeof id === "string" && id) || `rosa-${++notificationCount}`),
        update: method(() => false),
        clear: method(() => false),
        getAll: method(() => ({})),
        getPermissionLevel: method(() => "denied"),
        onClicked: event(), onClosed: event(), onButtonClicked: event(),
        onShowSettings: event(), onPermissionLevelChanged: event(),
      });

      define("idle", {
        queryState: method(() => "active"),
        setDetectionInterval: () => {},
        getAutoLockDelay: method(() => 0),
        onStateChanged: event(),
      });

      // Browser settings an extension may read or turn off (1Password turns off password saving).
      const setting = () => ({
        get: method(() => ({ value: false, levelOfControl: "not_controllable" })),
        set: method(() => {}),
        clear: method(() => {}),
        onChange: event(),
      });
      const settings = () => new Proxy({}, { get: (target, key) => (target[key] ??= setting()) });
      define("privacy", { network: settings(), services: settings(), websites: settings() });

      const info = {
        id: api.runtime && api.runtime.id, name: manifest.name, shortName: manifest.short_name,
        version: manifest.version, description: manifest.description || "", enabled: true,
        mayDisable: true, installType: "normal", type: "extension", offlineEnabled: false,
        hostPermissions: manifest.host_permissions || [], permissions: manifest.permissions || [],
      };
      define("management", {
        getSelf: method(() => info),
        get: method((id) => { if (id === info.id) return info; throw new Error(`No extension with id ${id}`); }),
        getAll: method(() => [info]),
        setEnabled: method(() => {}),
        uninstallSelf: method(() => {}),
        onInstalled: event(), onUninstalled: event(), onEnabled: event(), onDisabled: event(),
      });

      // Opens the file's URL in a background tab; Rosa downloads what it can't show.
      let downloadCount = 0;
      define("downloads", {
        download: method(async (options) => { await api.tabs.create({ url: options.url, active: false }); return ++downloadCount; }),
        search: method(() => []),
        cancel: method(() => {}),
        erase: method(() => []),
        open: method(() => {}),
        show: method(() => {}),
        onCreated: event(), onChanged: event(), onErased: event(), onDeterminingFilename: event(),
      });
    })();
    """#
}
