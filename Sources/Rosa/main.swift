import AppKit

// Before anything touches settings, history or WebKit's data store.
Migration.run()
Settings.load()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
