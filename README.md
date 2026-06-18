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

## What works in v0.1

- Add/remove repositories (file picker, drag-and-drop folders, persistence in `~/Library/Application Support/Gitpack/repositories.json`)
- Linear commit history with author / date / subject; merge commits styled distinctly
- Working copy: per-file stage / unstage via checkbox or context menu
- Commit (respects hooks and signing — they run as your terminal would run them)
- Push, pull, fetch against the current branch's upstream
- Branch switcher (read-only list, switch only)
- External diff via `opendiff` (FileMerge), with HEAD/parent versions written to temp files
- Light/dark mode

## Explicit non-goals for v0.1

See spec §3. Notably absent on purpose: in-app diff viewer, hunk staging, branch CRUD, merge/rebase/cherry-pick, stash, tags, conflict UI, history graph, search.

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md).
