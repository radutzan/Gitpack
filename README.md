# Gitpack

A minimalist macOS Git client, in the spirit of [Gitbox](https://github.com/oleganza/gitbox) — see every repository you have at a glance, pull, commit, push, get on with your day.

Pure AppKit, no dependencies, no embedded Git library. Every operation shells out to your `/usr/bin/git`, so hooks, signing, SSH agents, credential helpers and your `~/.gitconfig` all behave exactly as they do in your terminal.

## What it does

**All your repos at once.** The sidebar lists every repository with a live badge (unpushed + unmerged + changed files) and fetches all of them in the background, so you can tell which ones need attention without clicking through.

**One comparison, everywhere.** Gitbox's central idea: your current branch versus one chosen *other* branch — a remote branch, or another local one. That pair drives the whole window. Toolbar buttons morph to match it (⌥ → Fetch, ⇧⌘ → Rebase / Force Push, single Merge button when the other branch is local), history rows get green dots for unpushed commits and blue for fetched-but-unmerged, and the badge counts come from the same place. It is stored as plain upstream config, so the choice survives outside the app.

**The basics, quickly.** Three resizable panes; linear history with merge commits styled distinctly; per-file staging by checkbox, context menu or `s`; discard, reveal in Finder, copy path; commit; branch switcher; external diff via FileMerge. Bare-key shortcuts from Gitbox are intact — `u` pull/merge, `p` push, `s` stage, `d` diff — plus ⌘↩ to commit from anywhere. Pane widths, repo list and window state persist.

## Not in it

**Yet:** history search, branch/tag/stash management, cherry-pick, revert, reset, rebase-conflict UI, clone, submodules, undo. See [the roadmap](docs/plans/2026-07-06-gitbox-replica-roadmap.md).

**By choice:** an in-app diff viewer, hunk staging, and a history graph. Diffs open in your external diff tool.

**Never:** credential management. Background fetch runs with `GIT_TERMINAL_PROMPT=0` and askpass disabled, so anything needing interactive auth fails silently rather than hanging. If `git fetch` works non-interactively in your terminal, it works here.

## Build

```bash
xcodebuild -project Gitpack.xcodeproj -scheme Gitpack -configuration Debug build
```

Or `open Gitpack.xcodeproj` and hit ⌘R. Needs Xcode 26.3+, runs on macOS 15.7+.

Parser tests (a `swiftc` assert-runner, not XCTest):

```bash
./Tests/run-tests.sh
```

## Design notes

[`ARCHITECTURE.md`](ARCHITECTURE.md) covers the decisions worth arguing about: why CLI shell-out instead of libgit2, why upstream config is the comparison model, the autofetch and per-repo background state design, NUL-terminated parsing, and the FSEvents refresh policy.

## Credit

Gitbox was made by Oleg Andreev, 2010–2012, and [open-sourced](https://github.com/oleganza/gitbox) under Apache-2.0. Gitpack is a clean-room successor — no Gitbox code, just its ideas about what a Git client should be.

## License

MIT — see [`LICENSE`](LICENSE).
