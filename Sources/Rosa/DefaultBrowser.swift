import AppKit

/// Whether Rosa opens links from other apps, and asking macOS to make it so.
enum DefaultBrowser {
    /// Any copy of Rosa counts (a release and a local build share the bundle identifier).
    static var isRosa: Bool {
        guard let id = Bundle.main.bundleIdentifier,
              let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: app)?.bundleIdentifier == id
    }

    /// False when run outside an app bundle (`swift run`), which macOS can't register.
    static var canBecomeDefault: Bool { Bundle.main.bundleIdentifier != nil }

    /// macOS asks the user to confirm. Choosing the http handler sets https and web pages too.
    static func makeRosaDefault() async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
    }
}
