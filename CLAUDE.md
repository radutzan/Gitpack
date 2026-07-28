# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A minimalist macOS Git client, clean-room successor to Gitbox 1.6.3. SwiftUI + AppKit, no dependencies, no test target — the whole app shells out to `/usr/bin/git`.

Docs, in order of authority for scope: `docs/plans/2026-07-06-gitbox-replica-roadmap.md` (current scope, supersedes spec §3) → `ARCHITECTURE.md` (design decisions and rationale — read it before non-trivial work) → `Gitpack-Spec.md` (original v0.1 spec, largely historical).

## Commands

```bash
xcodebuild -project Gitpack.xcodeproj -scheme Gitpack -configuration Debug build
./Tests/run-tests.sh     # parser tests
```

`run-tests.sh` is a `swiftc` assert-runner over `Models.swift` + `Parsers.swift` + `FileSystemWatcher.swift` — not XCTest, no test filtering. To run one case, comment out the others in `ParserTests.main()`. It compiles those three files standalone, so **they must stay Foundation-only** (no SwiftUI/AppKit imports, no dependencies on other app files).

The Xcode target uses `PBXFileSystemSynchronizedRootGroup`: new files under `Gitpack/` are picked up automatically, never edit `project.pbxproj` to add them.

## Architecture

Layering is `Features/` (SwiftUI views) → `AppState` → `GitService` → `ProcessRunner` → `git`. Views never touch `ProcessRunner`; every git operation is a `GitService` protocol method with a `CLIGitService` implementation.

**Two kinds of per-repo state.** `RepositoryViewModel` (full model: commits, status, branches, divergence) exists only for the selected repo. `RepoBackgroundState` (badge counts, fetch flag, backoff) exists for *every* sidebar repo and is fed by one `git status --porcelain=v2 --branch` call — `branch.ab` gives ahead/behind, the entry list gives the stage count. Adding a new sidebar-visible signal should go through `RepoBackgroundState`, not by loading more view models.

**"Other branch" is upstream config.** The compare/sync target (`git branch --set-upstream-to=`, accepts local branches too) is the pivot of the whole UI: toolbar morphing, badges, history refs, green/blue dots, push refspec. There is no app-side persistence of the pairing — read it from `status.upstream`, never invent a parallel store.

**Refresh paths** (`AppState`): FSEvents → `GitChangeClassifier` → debounced `.status`/`.full`; foreground activation → full reload; mutations refresh inline; autofetch loop refreshes background states. New git mutations should call `refreshAll` after succeeding, like `performSync` does.

**Concurrency:** build default isolation is MainActor, so views/`AppState`/view models are main-actor by default. `CLIGitService` and `DiffToolService` are actors; the `GitService` protocol and the parsers are `nonisolated` — keep them that way or git work starts blocking the main thread.

**Parsing:** always request NUL-terminated output (`-z`, `%x00`/`%x1e`/`%x1f`) and parse in a `nonisolated enum` in `Parsers.swift` with a byte-exact fixture test. Splitting on newlines or spaces is how Gitbox got path corruption.

## Conventions and traps

- **Never add interactive auth.** All git runs with `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS`/`SSH_ASKPASS` at `/usr/bin/false` so background fetch fails fast instead of hanging. Credentials, signing, hooks are the user's terminal config, by design.
- **History rows need explicit fixed heights** (41pt + 2pt vertical padding). With automatic heights, the backing NSTableView's estimates for unmaterialized rows diverge from measured two-line rows and scroll-to-row blanks the pane.
- **`refreshAll` assigns conditionally** (`if fresh != commits`). It runs on every activation and autofetch; unconditional assignment rebuilds the table mid-click and drops selection.
- **Pane layout is hand-rolled.** `NavigationSplitView` and `HSplitView` both failed here (see the comment in `ContentView.swift`); widths live in `UserDefaults` and are written on drag end. Don't "simplify" it back to a framework splitter.
- **AppKit escape hatch:** SwiftUI by default; when a component fights back on layout, focus, or performance fundamentals, wrap the AppKit control rather than stacking workarounds. The history list moves to `NSTableView` at the start of M3 (search) — that's decided, not conditional.
- **Menu → view commands go through `NotificationCenter`** names in `GitpackApp.swift` (`.stageAllRequested`, `.commitRequested`, `.addRepositoryRequested`); bare-key Gitbox shortcuts (`u`/`p`/`s`/`d`) go through `.onKeyPress` on the focused list so they don't fight text fields.
- **`// ponytail:` comments mark deliberate simplifications** with their ceiling (fixed 60s fetch cycle, 30s rate limit, no jitter). Respect them as decisions; when raising one, update the comment.
