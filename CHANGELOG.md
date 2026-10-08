# Changelog

User-facing changes. New entries go under **Unreleased**; when cutting a release, rename that heading
to the version (`## v0.4.0`) before tagging. The release workflow publishes that section as the
release notes (`scripts/release-notes.sh`).

## Unreleased

### 🧩 Extensions
- **Browser extensions (preview)**: Rosa can run Chrome-style extensions, 1Password included. Rosa → Extensions → Import from Another Browser installs one you already have in Chrome, Edge, Brave, Arc or Vivaldi; Install Extension… takes a folder, .crx or .zip. Extension buttons sit at the end of the address bar; right-click one for its settings, to hide it from the toolbar or to remove it (Rosa → Extensions → its name → Show in Toolbar brings it back, Open opens it without a button), and their shortcuts work (⌘⇧X opens 1Password). Extensions sign in on their own; connecting to desktop apps (like 1Password's Touch ID unlock) isn't supported yet.

## v0.9.0

✨ Canary builds: opt in to get every new feature as soon as it lands.

### 🔄 Updates
- **Canary builds**: pick Settings → Updates → Channel → Canary to get every new feature as soon as it lands, before it's in a stable release. Switch back to Stable any time; you'll move over with the next stable release.

## v0.8.1

🩹 Zen mode is on the welcome page.

### 👋 Welcome
- **The welcome page lists Zen Mode (⌃⌘Z)**: click it to hide everything but the page.

## v0.8.0

✨ Zen mode for presenting (⌃⌘Z), and a command palette that runs any command (⌘⇧P, then `>`).

### ⌨️ Command palette
- **Type `>` in the ⌘⇧P palette to run any menu command**: Zen Mode, Split Right, Reopen Closed Tab, Vertical Tabs… Each shows its shortcut, and settings that are on get a checkmark. Delete the `>` to go back to bookmarks.
- **Type an address or a search in ⌘⇧P too**: `github.com` gets an "Open github.com" row at the top, anything else a "Search Google for …" row below your bookmarks.

### 🧘 Zen mode
- **⌃⌘Z hides everything but the page**: tabs, address bar, bookmarks bar and the window buttons disappear, and the page fills the window, with a slim margin around it. Handy for presenting. Press ⌃⌘Z again to bring it all back (also in View → Zen Mode).
- **⌘L still works in zen mode**: the address bar appears at the top while you type and goes away again on Return or Esc. Same for ⌘T and ⌘D.
- Split panes stay side by side in zen mode. ⌘B brings the browser back.

### 🪟 Windows
- **New Window from the Dock**: right-click Rosa's Dock icon → New Window.

### 🐛 Fixes
- **New tabs and panes are no longer plain white** when quick links are turned off: they get the same themed background as the welcome page.

## v0.7.1

🩹 Back, forward and reload now light up when you hover them.

### 🐛 Fixes
- **Back, forward and reload now react to the mouse**: a rounded highlight on hover, a stronger one while pressed, so they no longer look dead.

## v0.7.0

✨ A friendly start: a welcome page on launch, and your pinned or recent sites on every blank pane.

### 👋 Welcome
- **Rosa opens with a welcome page** listing handy commands and their shortcuts: search or enter an address, the command palette, settings, splitting panes, new tab and reopening a closed tab. Click one to run it. It goes away as soon as you open a page, and new tabs and panes stay blank.

### 📌 Quick links
- **Blank panes show your pinned sites** as tiles. Pin a bookmark from the ⌘B panel, by right-clicking it in the bookmarks bar or the bookmarks manager, or right-click a tile → Pin.
- **Nothing pinned? You get your 6 most recently visited sites** instead, one per site.
- Click a tile to open it in that pane, ⌘-click to open it in the background. Turn quick links off in Settings → Appearance.

## v0.6.0

✨ Jump to any bookmark by typing its name: ⌘⇧P.

### ⌨️ Command palette
- **⌘⇧P opens a command palette** to jump to any bookmark, including ones inside folders. Results filter instantly as you type: by name, folder or address, and letters in order work too (`gh` finds GitHub). ↑ / ↓ (or ⌃J / ⌃K) to pick, Return opens it in the current pane, ⌘Return opens it in the background, Esc closes.

## v0.5.1

🩹 The address bar stays put when the sidebar slides out.

### 🐛 Fixes
- With an auto-hiding vertical sidebar and the shared address bar, expanding the sidebar no longer stretches the address bar over the back / forward / reload buttons. The address bar now stays put.

## v0.5.0

✨ Zoom in on any pane, and JSON that finally looks good.

### 🔍 Zoom
- **⌘+ / ⌘- zoom the page in and out, ⌘0 resets it** (also in the View menu). Each pane zooms on its own, and the level shows briefly at the top of the pane.

### 🎨 JSON viewer
- **JSON responses are formatted and colour-coded**, in light and dark mode. A Raw / Pretty switch in the corner shows the original text. Turn it off in Settings → Appearance → Format JSON responses.

## v0.4.0

### Bookmarks
- **Bookmarks bar** across the top of the window (⌘⇧B to show or hide), with folders that open as menus and a » menu for what doesn't fit.
- **⌘B bookmarks the current page**: rename it, pick a folder or remove it in the little panel that pops up. ⌘B on a bookmarked page edits it.
- **Right-click a page or link → Add to Bookmarks.** Right-click the bar to edit, delete, rename or add folders.
- **Bookmarks manager** (⌥⌘B): every bookmark in a tree, with nested folders. Drag to reorder or move into folders, Return to rename, ⌫ to delete, double-click to open.
- Bookmarks are stored in `~/.rosa/bookmarks.json`, so they're easy to back up or edit by hand.

### Navigation
- **Back, forward and reload buttons** next to the traffic lights (reload turns into stop while a page loads).
- **⌘⇧T reopens the last closed tab**, with its split panes and back/forward history.
- **⌃H / ⌃J / ⌃K / ⌃L** move between panes, vim-style (they keep their usual meaning when a tab has only one pane).

### Vertical tabs
- **New Tab** now sits right after the last tab (just a + when the sidebar is collapsed), and the downloads button moved to the bottom of the sidebar.

## Earlier versions

See [GitHub releases](https://github.com/jonas-lomholdt/rosa/releases) for v0.3.0 and before.
