import Foundation

/// One-time move of data from before the app was renamed to Rosa (identifier
/// `com.example.browser`), so history, filter lists, cookies/logins and settings carry over.
enum Migration {
    static let legacyIdentifier = "com.example.browser"

    static func run() {
        guard let identifier = Bundle.main.bundleIdentifier, identifier != legacyIdentifier else { return }
        let fileManager = FileManager.default
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]

        // Folders keyed by bundle identifier: app data (history, filter lists), WebKit website
        // data (storage, compiled content-blocker lists), cookies, and caches.
        let locations: [(folder: String, suffix: String)] = [
            ("Application Support", ""), ("WebKit", ""), ("HTTPStorages", ""),
            ("HTTPStorages", ".binarycookies"), ("Caches", ""),
        ]
        for location in locations {
            let parent = library.appendingPathComponent(location.folder, isDirectory: true)
            let old = parent.appendingPathComponent(legacyIdentifier + location.suffix)
            let new = parent.appendingPathComponent(identifier + location.suffix)
            guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else { continue }
            try? fileManager.moveItem(at: old, to: new)
        }

        // Settings: copy keys the new domain doesn't have yet, once.
        let defaults = UserDefaults.standard
        let marker = "migratedFromLegacyIdentifier"
        guard !defaults.bool(forKey: marker) else { return }
        for (key, value) in defaults.persistentDomain(forName: legacyIdentifier) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: marker)
    }
}
