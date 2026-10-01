# Browser

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

Settings (⌘,) and the View menu toggle **Vertical Tabs** and **Shared Address Bar** (default: slim bar per pane).

## Layout

- `Tab` owns a split tree: `PaneContainerView` → nested `SplitView`s → `PaneView` leaves (one `WKWebView` each).
- `BrowserWindowController` handles tabs, splitting/closing, and directional focus (spatial, ties go to the most recently focused pane).
- Pane/tab shortcuts are dispatched by a key monitor before the web page sees them (`AppDelegate.priorityMenus`).

## Self-test

`BROWSER_SELFTEST=<dir>` runs a scripted sequence of real key events, prints the split tree after each step, and writes snapshots to `<dir>`:

```bash
open -W -n --env BROWSER_SELFTEST=/tmp/bt --stdout /tmp/bt.log build/Browser.app; cat /tmp/bt.log
```
