import AppKit

// Before anything touches settings, history or WebKit's data store.
Migration.run()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
