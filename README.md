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
- 🗂️ **Tabs** — horizontal, or a resizable vertical sidebar that can auto-hide
- 🛡️ **Ad & tracker blocking** — on by default, one click to allow a site
- 🔎 **Smart address bar** — autocompletes from your history as you type
- 🔖 **Bookmarks bar** — ⌘B or right-click to bookmark, folders, right-click to edit
- ⬇️ **Downloads** — progress, cancel, show in Finder, right from the tab bar
- 🎨 **Liquid Glass** look, light / dark / system theme
- 🐞 **Web Inspector** — the same dev tools as Safari
- 🔄 **Auto-updates** — checks GitHub on launch, installs and relaunches in one click

## ⌨️ Shortcuts

| Keys | Does |
|---|---|
| `⌘D` | Split right |
| `⌘⇧D` | Split down |
| `⌘⌥ ← ↑ ↓ →` / `⌃H` `⌃J` `⌃K` `⌃L` | Jump to the pane in that direction |
| `⌘W` | Close pane |
| `⌘T` | New tab |
| `⌘L` | Address bar |
| `f` / `⇧F` | Link hints / open link in background |
| `j` / `k`, `h` / `l` | Scroll down / up, left / right |
| `gg` / `G` | Jump to top / bottom |
| `⌘F`, `⌘G` / `⌘⇧G` | Find in page, next / previous match |
| `⌘B` | Bookmark this page (rename, pick a folder, or remove) |
| `⌘⇧B` | Show / hide bookmarks bar |
| `⌃⌘S` | Show sidebar (when auto-hiding) |
| `⌥⌘L` | Downloads |
| `⌘,` | Settings |
| `F12` / `⌘⌥I` | Web Inspector |

Settings are also stored in `~/.rosa/settings.json`. Edit the file and changes apply right away.

## 📦 Install

```bash
curl -fsSL https://raw.githubusercontent.com/jonas-lomholdt/rosa/main/scripts/install.sh | bash
```

Downloads the latest release into `/Applications` and opens it. Needs **macOS 26**.

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
