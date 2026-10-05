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
| ⌃⌘S | Expand/collapse the auto-hiding vertical sidebar (collapsed, it is a rail of favicons; hovering it expands) |
| ⌥⌘L | Downloads popover (`DownloadManager`, `DownloadsView`) |
| F12 / ⌘⌥I | Toggle Web Inspector (also right-click → Inspect Element) |

Settings (⌘,) and the View menu toggle **Vertical Tabs** and **Shared Address Bar** (default: slim bar per pane).

## Settings file

`Settings` reads and writes `~/.rosa/settings.json` (`SettingsStore`). On first launch it is created with every setting, carrying over values from UserDefaults. Hand edits apply live (the file and its folder are watched); invalid JSON is ignored and the previous values kept, and if Rosa later has to write over an invalid file it moves it to `settings.json.invalid` first. Unknown keys are preserved. Set `BROWSER_SETTINGS_FILE` to use a different file (e.g. for self-tests). Ad-block compile caches stay in UserDefaults.

## Bookmarks

`Bookmarks` reads and writes `bookmarks.json` beside the settings file (`BROWSER_BOOKMARKS_FILE` overrides it) through the same `SettingsStore`: it's the single source of truth, so hand edits apply live and an unparseable file keeps the last good bookmarks, but the UI never mentions it. Edits come from ⌘B, the page context menu (Add Page / Link to Bookmarks), and the bar's context menu (Edit…, Delete, Rename…, New Folder); `Bookmarks.Path` index paths address entries. The editor popover applies its changes once, when it closes. `Bookmark.id` is a runtime-only UUID so the manager keeps selection and expanded folders across edits (a hand edit re-parses and resets them). Format: `{"bookmarks": [{"title", "url"} | {"title", "children": [...]}]}`; bad entries are skipped. The bar spans the content width (not per pane) and opens links in the focused pane; ⌘/middle-click goes through `pane(_:openLinkInBackground:)`, so it honours the link-target setting. Favicons come from `FaviconStore.icon(forSite:)` (the host's last seen icon, else `/favicon.ico`). `BROWSER_SELFTEST_ONLY=bookmarks` runs just the bookmarks part of the self-test (needs `BROWSER_SETTINGS_FILE` pointing at a scratch location, since it rewrites the file).

## Content blocking

On by default (Settings → Content Blocking). EasyList + EasyPrivacy (and optionally the EasyList Cookie List) are downloaded on first launch, refreshed weekly, converted by `FilterListConverter` (a subset of Adblock Plus syntax) and compiled into WebKit `WKContentRuleList`s, which WebKit caches. The shield in the address bar turns blocking off for one site.

## JSON viewer

`JSONViewer.swift` injects a script (same isolated world as link hints, installed by `LinkHints.install`) that turns WebKit's plain `<pre>` for `application/json` / `*+json` documents into an indented, colour-coded copy with a Raw / Pretty toggle. It validates with `JSON.parse` but formats by re-tokenizing the original text, so numbers beyond 2^53 and key order are kept; anti-hijacking prefixes (`)]}'`, `while(1);`) are stripped. Invalid JSON and `text/plain` are left alone. Over 3 MB it indents without colouring. Styles use a constructable stylesheet (`adoptedStyleSheets`) because CSPs like `default-src 'none'` block injected `<style>` elements. Setting: `formatJSON` (applies to the next load).

## Layout

- `Tab` owns a split tree: `PaneContainerView` → nested `SplitView`s → `PaneView` leaves (one `WKWebView` each).
- `BrowserWindowController` handles tabs, splitting/closing, and directional focus (spatial, ties go to the most recently focused pane).
- Pane/tab shortcuts are dispatched by a key monitor before the web page sees them (`AppDelegate.priorityMenus`).

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
