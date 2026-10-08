<p align="center">
  <img src="Resources/AppIcon.png" alt="Rosa icon" width="180">
</p>

<h1 align="center">Rosa</h1>

<p align="center">
  A tiny, fast macOS browser with <b>terminal-style split panes</b>.<br>
  Built on Apple's own WebKit — no bundled engine, just a few MB.
</p>

---

## ✨ What it does

- 🪟 **Split panes** — split any tab right or down, as many times as you like
- 🧭 **Keyboard-first** — move between panes with arrow keys, like a terminal
- 🔤 **Link hints** — press `f`, type the yellow label, and the link is clicked — across all panes at once
- ⌨️ **Vim keys** — `hjkl` to scroll, `gg`/`G` for top and bottom (optional)
- 🔍 **Find in page** — with a live match count
- 🔎 **Zoom per pane** — `⌘+` / `⌘-` / `⌘0`, each pane keeps its own level
- 🧾 **JSON viewer** — JSON responses are pretty-printed and colour-coded, with a Raw / Pretty switch
- 🗂️ **Tabs** — horizontal, or a resizable vertical sidebar that can auto-hide
- 🛡️ **Ad & tracker blocking** — on by default, one click to allow a site
- 🧩 **Extensions (preview)** — run Chrome extensions like 1Password; import them from Chrome, Edge, Brave, Arc or Vivaldi
- 🧠 **Smart address bar** — autocompletes from your history as you type
- 🔖 **Bookmarks** — ⌘B or right-click to bookmark, a bar with nested folders, and a manager to organise them, and ⌘⇧P to jump to any of them by typing
- ⬇️ **Downloads** — progress, cancel, show in Finder, right from the tab bar
- 🎨 **Liquid Glass** look, light / dark / system theme
- 🐞 **Web Inspector** — the same dev tools as Safari
- 🔄 **Auto-updates** — checks GitHub on launch, installs and relaunches in one click; opt into canary builds for the newest features

## ⌨️ Shortcuts

| Keys | Does |
|---|---|
| `⌘D` | Split right |
| `⌘⇧D` | Split down |
| `⌘⌥ ← ↑ ↓ →` / `⌃H` `⌃J` `⌃K` `⌃L` | Jump to the pane in that direction |
| `⌘W` | Close pane |
| `⌘T` | New tab |
| `⌘⇧T` | Reopen closed tab (with its panes and history) |
| `⌘L` | Address bar |
| `f` / `⇧F` | Link hints / open link in background |
| `j` / `k`, `h` / `l` | Scroll down / up, left / right |
| `gg` / `G` | Jump to top / bottom |
| `⌘F`, `⌘G` / `⌘⇧G` | Find in page, next / previous match |
| `⌘+` / `⌘-` / `⌘0` | Zoom in / out / reset (focused pane) |
| `⌘B` | Bookmark this page (rename, pick a folder, or remove) |
| `⌘⇧B` | Show / hide bookmarks bar |
| `⌥⌘B` | Manage bookmarks (drag to reorder and nest folders) |
| `⌘⇧P` | Command palette: find a bookmark, enter an address or search, or `>` to run any menu command |
| `⌃⌘S` | Show sidebar (when auto-hiding) |
| `⌃⌘Z` | Zen mode: hide tabs, address bar and bookmarks bar (press again to bring them back) |
| `⌥⌘L` | Downloads |
| `⌘,` | Settings |
| `F12` / `⌘⌥I` | Web Inspector |

Settings are also stored in `~/.rosa/settings.json`. Edit the file and changes apply right away.

## 📦 Install

```bash
curl -fsSL https://raw.githubusercontent.com/jonas-lomholdt/rosa/main/scripts/install.sh | bash
```

Downloads the latest release into `/Applications` and opens it. Needs **macOS 26**.

Want every change as soon as it lands on `main`? Pick **Settings → Updates → Channel → Canary**, or install a canary build straight away with `… | bash -s -- --canary`.

## 🚀 Build it yourself

No Xcode required — the Command Line Tools are enough.

```bash
scripts/build.sh release --run
```

Or grab `Rosa-vX.Y.Z.zip` from [Releases](https://github.com/jonas-lomholdt/rosa/releases) by hand. It isn't notarised yet, so on first launch right-click **Rosa.app → Open** (the install script handles this for you).

---

## 📄 License

[MIT](LICENSE) — free to use, change and share, as long as you keep the copyright notice and credit **Jonas Lomholdt**.

---

<p align="center"><sub>Developer notes live in <a href="docs/DEVELOPMENT.md">docs/DEVELOPMENT.md</a>.</sub></p>
