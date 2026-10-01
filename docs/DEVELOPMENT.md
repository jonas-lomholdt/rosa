# Development notes

A tiny macOS browser built on the system WebKit, with terminal-style split panes.

Requires macOS 26 (Liquid Glass). Builds with the Command Line Tools — full Xcode is not needed.

```bash
scripts/build.sh release --run   # builds build/Browser.app and opens it
```

## Shortcuts

| Keys | Action |
|---|---|
| ⌘D / ⌘⇧D | Split pane right / down |
| ⌘W | Close pane (last pane closes the tab) |
| ⌘⌥ ←↑↓→ | Focus neighbouring pane |
| ⌘⌃= | Equalize pane sizes (double-click a gap resets that split) |
| ⌘T / ⌘⇧W | New tab / close tab |
| ⌃⇥ / ⌃⇧⇥, ⌘1–9 | Switch tabs |
| ⌘L, ⌘R, ⌘[ / ⌘] | Address bar, reload, back / forward |
| ⌘, | Settings (tab layout, address bar, search engine) |
| f / ⇧F | Link hints: label clickable elements, type a label to click / open in background (`LinkHints.swift`). With "all panes" on, `BrowserWindowController` runs one session across every pane in the tab |
| j / k, h / l, gg / G | Vim-style scrolling (same injected script as link hints) |
| ⌘F, ⌘G / ⌘⇧G | Find in page (`FindBar.swift`), next / previous |
| ⌃⌘S | Show/hide the auto-hiding vertical sidebar |
| F12 / ⌘⌥I | Toggle Web Inspector (also right-click → Inspect Element) |

Settings (⌘,) and the View menu toggle **Vertical Tabs** and **Shared Address Bar** (default: slim bar per pane).

## Content blocking

On by default (Settings → Content Blocking). EasyList + EasyPrivacy (and optionally the EasyList Cookie List) are downloaded on first launch, refreshed weekly, converted by `FilterListConverter` (a subset of Adblock Plus syntax) and compiled into WebKit `WKContentRuleList`s, which WebKit caches. The shield in the address bar turns blocking off for one site.

## Layout

- `Tab` owns a split tree: `PaneContainerView` → nested `SplitView`s → `PaneView` leaves (one `WKWebView` each).
- `BrowserWindowController` handles tabs, splitting/closing, and directional focus (spatial, ties go to the most recently focused pane).
- Pane/tab shortcuts are dispatched by a key monitor before the web page sees them (`AppDelegate.priorityMenus`).

## App icon

`Resources/AppIcon.png` is generated from `Resources/logo-source.png` (strips the baked-in background and fits Apple's icon grid); `scripts/build.sh` turns it into `AppIcon.icns`:

```bash
swift scripts/make-icon.swift Resources/logo-source.png Resources/AppIcon.png
```

## Self-test

`BROWSER_SELFTEST=<dir>` runs a scripted sequence of real key events, prints the split tree after each step, and writes snapshots to `<dir>`. Set `BROWSER_HISTORY_DB` to keep test visits out of your real history:

```bash
open -W -n --env BROWSER_SELFTEST=/tmp/bt --env BROWSER_HISTORY_DB=/tmp/bt.sqlite --stdout /tmp/bt.log build/Browser.app; cat /tmp/bt.log
```
