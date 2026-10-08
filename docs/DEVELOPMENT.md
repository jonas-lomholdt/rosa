# Development notes

A tiny macOS browser built on the system WebKit, with terminal-style split panes.

Requires macOS 26 (Liquid Glass). Builds with the Command Line Tools — full Xcode is not needed.

```bash
scripts/build.sh release --run   # builds build/Rosa.app and opens it
```

## Shortcuts

| Keys | Action |
|---|---|
| ⌘D / ⌘⇧D | Split pane right / down |
| ⌘W | Close pane (last pane closes the tab) |
| ⌘⌥ ←↑↓→, ⌃H/J/K/L | Focus neighbouring pane (⌃HJKL pass through to the page/text field when the tab has a single pane; handled in `AppDelegate.performVimPaneNavigation`) |
| ⌘⌃= | Equalize pane sizes (double-click a gap resets that split) |
| ⌘T / ⌘⇧W | New tab / close tab |
| ⌃⇥ / ⌃⇧⇥, ⌘1–9 | Switch tabs |
| ⌘L, ⌘R, ⌘[ / ⌘] | Address bar, reload, back / forward |
| ⌘+ (or ⌘=) / ⌘- / ⌘0 | Zoom the focused pane in / out / reset (`WKWebView.pageZoom`, Chrome's steps in `PageZoom`; ⌘0 also undoes pinch magnification) |
| ⌘, | Settings (tab layout, address bar, search engine) |
| f / ⇧F | Link hints: label clickable elements, type a label to click / open in background (`LinkHints.swift`). With "all panes" on, `BrowserWindowController` runs one session across every pane in the tab |
| j / k, h / l, gg / G | Vim-style scrolling (same injected script as link hints) |
| ⌘F, ⌘G / ⌘⇧G | Find in page (`FindBar.swift`), next / previous |
| ⌘B | Bookmark this page: adds it (or finds the existing one) and opens `BookmarkEditor`'s popover. Not a priority shortcut, so pages that handle ⌘B (bold in editors) keep it |
| ⌘⇧B | Show/hide the bookmarks bar (`BookmarksBarView`) |
| ⌥⌘B | Bookmarks manager window (`BookmarksManager.swift`): outline view, drag to reorder/nest, Return renames, ⌫ deletes, double-click opens in a new tab |
| ⌘⇧P | Command palette (`CommandPalette.swift`), see below |
| ⌃⌘S | Expand/collapse the auto-hiding vertical sidebar (collapsed, it is a rail of favicons; hovering it expands) |
| ⌃⌘Z | Zen mode, see below |
| ⌥⌘L | Downloads popover (`DownloadManager`, `DownloadsView`) |
| F12 / ⌘⌥I | Toggle Web Inspector (also right-click → Inspect Element) |

Settings (⌘,) and the View menu toggle **Vertical Tabs** and **Shared Address Bar** (default: slim bar per pane).

## Settings file

`Settings` reads and writes `~/.rosa/settings.json` (`SettingsStore`). On first launch it is created with every setting, carrying over values from UserDefaults. Hand edits apply live (the file and its folder are watched); invalid JSON is ignored and the previous values kept, and if Rosa later has to write over an invalid file it moves it to `settings.json.invalid` first. Unknown keys are preserved. Set `BROWSER_SETTINGS_FILE` to use a different file (e.g. for self-tests). Ad-block compile caches stay in UserDefaults.

## Bookmarks

`Bookmarks` reads and writes `bookmarks.json` beside the settings file (`BROWSER_BOOKMARKS_FILE` overrides it) through the same `SettingsStore`: it's the single source of truth, so hand edits apply live and an unparseable file keeps the last good bookmarks, but the UI never mentions it. Edits come from ⌘B, the page context menu (Add Page / Link to Bookmarks), and the bar's context menu (Edit…, Delete, Rename…, New Folder); `Bookmarks.Path` index paths address entries. The editor popover applies its changes once, when it closes. `Bookmark.id` is a runtime-only UUID so the manager keeps selection and expanded folders across edits (a hand edit re-parses and resets them). Format: `{"bookmarks": [{"title", "url"} | {"title", "children": [...]}]}`; bad entries are skipped. The bar spans the content width (not per pane) and opens links in the focused pane; ⌘/middle-click goes through `pane(_:openLinkInBackground:)`, so it honours the link-target setting. Favicons come from `FaviconStore.icon(forSite:)` (the host's last seen icon, else `/favicon.ico`). `BROWSER_SELFTEST_ONLY=bookmarks` runs just the bookmarks part of the self-test (needs `BROWSER_SETTINGS_FILE` pointing at a scratch location, since it rewrites the file).

## Command palette

`CommandPaletteView` is an overlay (Liquid Glass) added to the window's `BrowserContentView`, not a separate window, so the browser window stays key and its menu shortcuts keep working. It knows nothing about bookmarks: it shows `CommandPaletteItem`s (title, subtitle, icon, keywords, a `perform(inBackground:)` closure) collected from `CommandPaletteSource`s when it opens. Sources are grouped into `CommandPaletteMode`s: the first is the default (`BookmarksPaletteSource`: all links, folders flattened), and typing another mode's prefix switches to it, deleting it switches back. `>` is `MenuCommandsPaletteSource`: every enabled, visible main-menu item (validated with `NSMenu.update()` before the field takes focus, so state and titles match the page), with its `NSMenuItem.shortcutText` and a checkmark when on, run through `performActionForItem` after focus goes back to the page. Text editing items (they'd act on the palette's field), the window list and the palette itself are left out; the app menu comes last. A mode's `queryItem` adds a row made from the query itself: in the bookmarks mode, "Open …" first when `Settings.addressURL(fromUserInput:)` sees an address, else "Search <engine> for …" last; both load like the address bar. Open tabs or history can be added as further sources or modes. `CommandPaletteMatcher` folds case and accents once per opening, then scores each term against the title (prefix > word start > substring > letters in order, matched letters shown in bold) or the keywords (substring); ~2 ms per keystroke over 5,000 items. ↑/↓, ⌃N/⌃P and ⌃J/⌃K move (⌃J/⌃K via `handleVimPaneNavigation`), ↩ runs, ⌘↩ runs in the background, Esc closes and restores the previous first responder; the field losing focus (clicking the page) closes it. The self-test covers it in the bookmarks part; `BROWSER_SELFTEST_ONLY=commands` covers `>`.

## Zen mode

⌃⌘Z (View → Zen Mode) toggles `BrowserWindowController.isZenMode` for that window (not saved). `BrowserContentView` then hides the tab strip / sidebar, header, bookmarks bar, navigation buttons and traffic lights and gives the tab's `PaneContainerView` the whole window (it keeps its margin, so the page sits just inside the edge); panes drop their address bars and focus dimming, and split gaps stay. Focusing the address bar (⌘L, and ⌘T / ⌘D, which open blank panes) shows the header's shared address bar at the top (`showsZenAddressBar`, whatever the address bar setting) until the field ends editing (`AddressField.onEndEditing`: ↩, Esc, or a click into the page). ⌘B's editor and ⌥⌘L's downloads popover leave zen mode; downloads that start in zen mode don't pop it open. Entering zen mode while typing an address moves focus to the page. `BROWSER_SELFTEST_ONLY=zen` covers it (posts key events; use a scratch `BROWSER_SETTINGS_FILE`, it changes layouts).

## Welcome page

`WelcomeView` sits over the web view of the one pane Rosa opens at launch (`PaneView.showWelcome()`, called from `applicationDidFinishLaunching`); new tabs, splits and windows never get it. It is removed for good once that pane loads anything (`PaneView.isBlank`: no URL or `about:blank`, not loading), and hidden while the pane is smaller than its column. The commands live in `WelcomeView.sections` as menu selectors; their shortcuts are read from the main menu, so they can't drift. A click focuses that pane and sends the action up its responder chain (then the app's, for Settings). Only rows take clicks; the rest falls through to the web view. `BROWSER_SELFTEST_ONLY=welcome` checks all of this (no key events).

## Quick links

Every other blank pane gets a `QuickLinksView` (`PaneView.updateQuickLinks`, removed once the pane loads anything; `Settings.showQuickLinks` turns it off). `QuickLink.current()` returns pinned bookmarks (`"pinned": true` in bookmarks.json, depth first, up to 12), else the six most recently visited hosts (`HistoryStore.recentSites`, nothing when history is off). The view reloads itself on bookmark, history and settings changes, and hides its tiles when the pane can't fit a row. Pins are set from the ⌘B editor, the bar's and manager's context menus, and a tile's menu (Pin on a recent site adds a pinned bookmark). `BROWSER_SELFTEST_ONLY=quicklinks` covers it (needs `BROWSER_SETTINGS_FILE` and `BROWSER_HISTORY_DB` scratch locations; it clears history).

## Content blocking

On by default (Settings → Content Blocking). EasyList + EasyPrivacy (and optionally the EasyList Cookie List) are downloaded on first launch, refreshed weekly, converted by `FilterListConverter` (a subset of Adblock Plus syntax) and compiled into WebKit `WKContentRuleList`s, which WebKit caches. The shield in the address bar turns blocking off for one site.

## JSON viewer

`JSONViewer.swift` injects a script (same isolated world as link hints, installed by `LinkHints.install`) that turns WebKit's plain `<pre>` for `application/json` / `*+json` documents into an indented, colour-coded copy with a Raw / Pretty toggle. It validates with `JSON.parse` but formats by re-tokenizing the original text, so numbers beyond 2^53 and key order are kept; anti-hijacking prefixes (`)]}'`, `while(1);`) are stripped. Invalid JSON and `text/plain` are left alone. Over 3 MB it indents without colouring. Styles use a constructable stylesheet (`adoptedStyleSheets`) because CSPs like `default-src 'none'` block injected `<style>` elements. Setting: `formatJSON` (applies to the next load).

## Layout

- `Tab` owns a split tree: `PaneContainerView` → nested `SplitView`s → `PaneView` leaves (one `WKWebView` each).
- `BrowserWindowController` handles tabs, splitting/closing, and directional focus (spatial, ties go to the most recently focused pane).
- Pane/tab shortcuts are dispatched by a key monitor before the web page sees them (`AppDelegate.priorityMenus`).
- Back / forward / reload (`NavigationButtonsView`) sit beside the traffic lights: in the tab strip (horizontal), the sidebar's top row (vertical), or the start of the header (auto-hide sidebar, so revealing it doesn't move the address bar). `BROWSER_SELFTEST_ONLY=layout` checks every tab layout × address bar mode, collapsed and revealed, for overlap.

## CI & releases

- `.github/workflows/ci.yml` builds `Rosa.app` on every push/PR (macOS 26 runner) and uploads it as an artifact.
- `.github/workflows/release.yml`: push a tag `vX.Y.Z` to build, stamp the version into `Info.plist`, and publish a GitHub release with `Rosa-vX.Y.Z.zip`.

Release notes come from `CHANGELOG.md`: add user-facing changes under **Unreleased** as they land, then rename that heading to the version and commit before tagging. `scripts/release-notes.sh vX.Y.Z` prints what will be published (its section, else Unreleased, else commit subjects since the previous tag); GitHub's generated "Full Changelog" link is appended.

```bash
git tag v0.1.0 && git push origin v0.1.0
```

## Updates

`Updater.swift` checks `api.github.com/repos/jonas-lomholdt/rosa/releases/latest` a few seconds after launch (Settings → Updates, or Rosa → Check for Updates…). Installing downloads the release zip into a staging folder on the app's volume, verifies the bundle id and signature, then a helper script waits for Rosa to quit, swaps the bundles and relaunches.

- Local builds keep `CFBundleVersion` 0 from `Resources/Info.plist` ("dev" in About) and skip the launch check; release builds get the run number.
- Test against a local feed: `BROWSER_UPDATE_URL=http://127.0.0.1:8765/latest.json` (a GitHub release JSON with `tag_name` and a `.zip` asset), plus `BROWSER_UPDATE_AUTOINSTALL=1` to install without the prompt.

## App icon

`Resources/AppIcon.png` is generated from `Resources/logo-source.png` (strips the baked-in background and fits Apple's icon grid); `scripts/build.sh` turns it into `AppIcon.icns`:

```bash
swift scripts/make-icon.swift Resources/logo-source.png Resources/AppIcon.png
```

## Self-test

`BROWSER_SELFTEST=<dir>` runs a scripted sequence of real key events, prints the split tree after each step, and writes snapshots to `<dir>`. Set `BROWSER_HISTORY_DB` and `BROWSER_DOWNLOADS_DIR` to keep test visits and files out of your real history and Downloads folder:

```bash
open -W -n --env BROWSER_SELFTEST=/tmp/bt --env BROWSER_HISTORY_DB=/tmp/bt.sqlite --env BROWSER_DOWNLOADS_DIR=/tmp/bt-dl --stdout /tmp/bt.log build/Rosa.app; cat /tmp/bt.log
```
