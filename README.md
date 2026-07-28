# Gitpack

A minimalist macOS Git client. Spiritual successor to Gitbox.

This is **v0.1**, scoped tightly per [`Gitpack-Spec.md`](Gitpack-Spec.md). Power features (rebase, cherry-pick, hunk staging, merge resolution) are explicit non-goals.

## Build

```bash
open Gitpack.xcodeproj
```

Then ⌘R. Requires Xcode 26.3+ and macOS 15.7+.

Or from CLI:

```bash
xcodebuild -project Gitpack.xcodeproj -scheme Gitpack -configuration Debug build
```

## Runtime requirements

- `/usr/bin/git` must resolve to a working git (Apple's git via Command Line Tools / Xcode is fine).
- Auth (SSH, credential helpers, signing, hooks, `~/.gitconfig`) is whatever your terminal already uses — Gitpack does not manage credentials.

## What works

- Add/remove repositories (file picker, drag-and-drop folders, persistence in `~/Library/Application Support/Gitpack/repositories.json`)
- Linear commit history with author / date / subject; merge commits styled distinctly
- Working copy: per-file stage / unstage via checkbox, context menu, or `s`; discard changes, reveal in Finder, copy path
- Three resizable panes whose widths persist across launches
- Commit (respects hooks and signing — they run as your terminal would run them)
- **"Other branch" comparison model** (Gitbox-style): pick a remote or local branch to compare/sync against; stored as upstream config
- Pull / push / fetch / rebase / force-push / merge — toolbar buttons morph with held modifiers (⌥ → Fetch, ⇧⌘ → Rebase / Force Push; local target → Merge)
- **Green/blue divergence dots** in history: green = unpushed, blue = fetched-but-unmerged (shown italic)
- **Background autofetch** of all repos (60s cycle, silent failures with backoff) + fetch on commit-message typing
- **Sidebar badges** = unpushed + unmerged + changed files, live for every repo, with fetch spinners
- Repository / Stage menus; single-key shortcuts on the lists (`u` pull/merge, `p` push, `s` stage, `d` diff)
- Branch switcher, external diff via `opendiff` (FileMerge), light/dark mode

## Not here yet (see roadmap)

Search, branch/tag/stash CRUD, cherry-pick/revert/reset, rebase-conflict UI, submodules, undo. Excluded from the project entirely: in-app diff viewer, hunk staging, history graph.

Background fetch never prompts for credentials — if auth needs interaction it fails silently, so make sure fetch works non-interactively in your terminal.

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md).
