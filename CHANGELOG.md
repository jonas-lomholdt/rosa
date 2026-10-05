# Changelog

User-facing changes. New entries go under **Unreleased**; when cutting a release, rename that heading
to the version (`## v0.4.0`) before tagging. The release workflow publishes that section as the
release notes (`scripts/release-notes.sh`).

## Unreleased

### Zoom
- **⌘+ / ⌘- zoom the page in and out, ⌘0 resets it** (also in the View menu). Each pane zooms on its own, and the level shows briefly at the top of the pane.

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
