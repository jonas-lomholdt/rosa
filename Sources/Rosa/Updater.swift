import AppKit

/// Checks GitHub Releases for a newer Rosa and installs it in place: the release zip is
/// downloaded and unpacked next to the running app, then a small helper script swaps the
/// bundles once Rosa has quit and relaunches it.
@MainActor
final class Updater {
    static let shared = Updater()
    static let didChange = Notification.Name("UpdaterDidChange")

    struct Release {
        let version: String
        let downloadURL: URL
        let notesURL: URL?
    }

    enum Status {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    private(set) var status: Status = .idle {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    var isBusy: Bool {
        switch status {
        case .checking, .installing: true
        default: false
        }
    }

    /// `BROWSER_UPDATE_URL` points the check at another releases feed (for testing).
    private let feedOverride = ProcessInfo.processInfo.environment["BROWSER_UPDATE_URL"].flatMap(URL.init(string:))
    private var feedURL: URL {
        feedOverride ?? URL(string: "https://api.github.com/repos/jonas-lomholdt/rosa/releases/latest")!
    }
    private let session = URLSession(configuration: .ephemeral)

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var statusDescription: String {
        switch status {
        case .idle: "Rosa \(currentVersion)"
        case .checking: "Checking for updates…"
        case .upToDate: "Rosa \(currentVersion) is up to date"
        case .available(let release): "Rosa \(release.version) is available"
        case .installing(let release): "Installing Rosa \(release.version)…"
        case .failed(let message): message
        }
    }

    // MARK: - Checking

    /// Runs once at launch: quiet unless there is an update. Skipped for local builds.
    func checkOnLaunch() {
        guard Settings.checkForUpdatesOnLaunch, !AppInfo.isDevelopmentBuild || feedOverride != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            await check(interactive: false)
        }
    }

    /// From the menu or Settings: always reports the outcome.
    func checkNow() {
        Task { await check(interactive: true) }
    }

    private func check(interactive: Bool) async {
        guard !isBusy else { return }
        status = .checking
        do {
            let release = try await fetchLatestRelease()
            guard Self.isVersion(release.version, newerThan: currentVersion) else {
                status = .upToDate
                if interactive { showUpToDateAlert() }
                return
            }
            status = .available(release)
            // `BROWSER_UPDATE_AUTOINSTALL` skips the prompt (for testing).
            if ProcessInfo.processInfo.environment["BROWSER_UPDATE_AUTOINSTALL"] != nil {
                install(release)
            } else {
                promptToInstall(release)
            }
        } catch {
            status = .failed("Couldn't check for updates: \(error.localizedDescription)")
            if interactive { showError(error) }
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub answered with status \(http.statusCode).")
        }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL?
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let zip = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdateError("The latest release has no download.")
        }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, downloadURL: zip.browser_download_url, notesURL: payload.html_url)
    }

    /// Compares dotted numeric versions ("0.10.0" > "0.9.2"); missing parts count as 0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    func install(_ release: Release) {
        guard !isBusy else { return }
        status = .installing(release)
        Task {
            do {
                let script = try await prepare(release)
                try launchHelper(script)
                NSApp.terminate(nil)
            } catch {
                status = .failed("Couldn't install the update: \(error.localizedDescription)")
                showError(error)
            }
        }
    }

    /// Downloads and unpacks the release into a staging folder on the same volume as the
    /// running app (so the final swap is a pair of renames) and writes the swap script.
    private func prepare(_ release: Release) async throws -> URL {
        let fileManager = FileManager.default
        let appURL = Bundle.main.bundleURL
        if appURL.path.contains("/AppTranslocation/") {
            throw UpdateError("Move Rosa to your Applications folder first, then try again.")
        }
        guard fileManager.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            throw UpdateError("Rosa can't write to \(appURL.deletingLastPathComponent().path).")
        }

        let staging = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true
        )
        let (download, response) = try await session.download(from: release.downloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("The download failed with status \(http.statusCode).")
        }
        let zip = staging.appendingPathComponent("Rosa.zip")
        try fileManager.moveItem(at: download, to: zip)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        try? fileManager.removeItem(at: zip)

        // Sanity-check the new bundle before touching the installed one.
        let newApp = staging.appendingPathComponent("Rosa.app")
        let info = Bundle(url: newApp)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download doesn't contain Rosa.")
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])

        let script = staging.appendingPathComponent("install.sh")
        try Self.swapScript.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    /// Waits for Rosa (by pid) to quit, swaps the bundles, and relaunches. If Rosa doesn't
    /// quit within a minute the update is abandoned; if the swap fails the old app is restored.
    private static let swapScript = """
        #!/bin/bash
        pid="$1"; app="$2"; staging="$3"
        for _ in $(seq 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$pid" 2>/dev/null; then rm -rf "$staging"; exit 1; fi
        xattr -dr com.apple.quarantine "$staging/Rosa.app" 2>/dev/null
        if mv "$app" "$staging/Old.app"; then
            mv "$staging/Rosa.app" "$app" || mv "$staging/Old.app" "$app"
        fi
        rm -rf "$staging"
        open -n "$app"
        """

    private func launchHelper(_ script: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
            script.deletingLastPathComponent().path,
        ]
        try process.run()
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(process.terminationStatus))."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - Alerts

    private func promptToInstall(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Rosa \(release.version) is available"
        alert.informativeText = "You have \(currentVersion). Rosa will quit, update and reopen."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        if release.notesURL != nil { alert.addButton(withTitle: "Release Notes") }
        present(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.install(release)
            case .alertThirdButtonReturn: release.notesURL.map { _ = NSWorkspace.shared.open($0) }
            default: break
            }
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "Rosa is up to date"
        alert.informativeText = "\(currentVersion) is the latest version."
        present(alert)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update failed"
        alert.informativeText = error.localizedDescription
        present(alert)
    }

    /// As a sheet on the frontmost window (Settings included), or app-modal without one.
    private func present(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: \.isVisible) {
            alert.beginSheetModal(for: window) { completion?($0) }
        } else {
            completion?(alert.runModal())
        }
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
