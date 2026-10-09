# Changelog

User-facing changes. New entries go under **Unreleased**; when cutting a release, rename that heading
to the version (`## v0.4.0`) before tagging. The release workflow publishes that section as the
release notes (`scripts/release-notes.sh`).

## Unreleased

### 🗂️ Tabs
- **Tab overview (⌘§)**: see every tab in the window as a preview, split panes and all. Move with `h` `j` `k` `l` or the arrows and press ↩ to switch, Esc to go back. `x` closes the highlighted tab, `u` brings it back, and `f` labels the tabs so you can jump to one by typing its letter.
- The current tab plays live in the overview, videos and all.
- Press `/` in the overview to search your tabs by title or address; ↩ opens the best match.

## v0.10.2

✨ Click the address bar and the whole address is selected, ready for a new one.

### 🩹 Fixes
- Clicking the address bar selects the whole address, like ⌘L, so you can type a new one right away.

## v0.10.1

✨ Press ↩ and the address bar opens the page you meant, and the auto-hiding sidebar resizes again.

### 🧠 Address bar
- **↩ opens the page you mean**: the top suggestion is selected as you type when it's a page you opened for that input before, or when what you typed starts its address or title (`gma` → Gmail). Press ↑ to search for what you typed instead.
- **Completes addresses that redirect**: type `gmail.com` once and next time `gm` fills in the rest, even though Gmail lives at mail.google.com.

### 🩹 Fixes
- The auto-hiding sidebar can be resized again: drag its edge while it's expanded.

## v0.10.0

✨ Extensions are here: 1Password works in Rosa, with autofill and passkeys. Plus an address bar that finds what you mean.

### 🧠 Address bar
- **Search history with several words, in any order**: `rust async` now finds "Asynchronous Programming in Rust", and `github swift` finds the Swift repo on GitHub.
- **Forgiving matches**: typos (`postgers`), skipped letters (`gthb`), first letters (`rlb` for Rust Language Book) and accents (`brod` finds "Brød") all find the page.
- **Learns what you pick**: open a suggestion after typing `rb` and next time `rb` puts that page first, ready for ↩. Pages you type in rank above pages you only clicked to.
- Turning off **Remember browsing history** also stops it learning, and clearing history clears what it learned.

### 🧩 Extensions (preview)
- **1Password in Rosa**: install it from Rosa → Extensions → Import from Another Browser (if you have it in Chrome, Edge, Brave, Arc or Vivaldi), click its button and sign in. Autofill, the inline suggestion menu and the popup all work, and so do **passkeys**: save new ones to 1Password and sign in with them. Without the 1Password app connection, it asks for your account password once each time Rosa starts.
- **Other extensions**: Install Extension… takes an unpacked folder, a .crx or a .zip. Most Chrome extensions run as they are; Rosa fills in the Chrome APIs Safari's engine lacks.
- **Toolbar buttons** at the end of the address bar. Right-click one for its settings, to hide it or to remove it. Rosa → Extensions → its name brings a hidden one back (Show in Toolbar) or opens it without a button. Extension shortcuts work too (⌘⇧X opens 1Password).
- Not yet: connecting to desktop apps (1Password's Touch ID unlock), and passkeys stored in Apple Passwords or on a security key.

### 🩹 Fixes
- Splitting the first window's pane so the welcome page no longer fits no longer leaves a white pane.

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
