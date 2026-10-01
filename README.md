<p align="center">
  <img src="Resources/AppIcon.png" alt="Browser icon" width="180">
</p>

<h1 align="center">Browser</h1>

<p align="center">
  A tiny, fast macOS browser with <b>terminal-style split panes</b>.<br>
  Built on Apple's own WebKit — no bundled engine, just a few MB.
</p>

---

## ✨ What it does

- 🪟 **Split panes** — split any tab right or down, as many times as you like
- 🧭 **Keyboard-first** — move between panes with arrow keys, like a terminal
- 🔤 **Link hints** — press `f`, type the yellow label, and the link is clicked
- ⌨️ **Vim keys** — `hjkl` to scroll, `gg`/`G` for top and bottom (optional)
- 🔍 **Find in page** — with a live match count
- 🗂️ **Tabs** — horizontal, or a vertical sidebar
- 🛡️ **Ad & tracker blocking** — on by default, one click to allow a site
- 🔎 **Smart address bar** — autocompletes from your history as you type
- 🎨 **Liquid Glass** look, light / dark / system theme
- 🐞 **Web Inspector** — the same dev tools as Safari

## ⌨️ Shortcuts

| Keys | Does |
|---|---|
| `⌘D` | Split right |
| `⌘⇧D` | Split down |
| `⌘⌥ ← ↑ ↓ →` | Jump to the pane in that direction |
| `⌘W` | Close pane |
| `⌘T` | New tab |
| `⌘L` | Address bar |
| `f` / `⇧F` | Link hints / open link in background |
| `j` / `k`, `h` / `l` | Scroll down / up, left / right |
| `gg` / `G` | Jump to top / bottom |
| `⌘F`, `⌘G` / `⌘⇧G` | Find in page, next / previous match |
| `⌘,` | Settings |
| `F12` / `⌘⌥I` | Web Inspector |

## 🚀 Run it

Needs **macOS 26**. No Xcode required — the Command Line Tools are enough.

```bash
scripts/build.sh release --run
```

---

<p align="center"><sub>Developer notes live in <a href="docs/DEVELOPMENT.md">docs/DEVELOPMENT.md</a>.</sub></p>
