# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A minimalist macOS Git client, clean-room successor to Gitbox 1.6.3. Pure AppKit, no dependencies, no test target — the whole app shells out to `/usr/bin/git`.

Docs, in order of authority for scope: `docs/plans/2026-07-06-gitbox-replica-roadmap.md` (current scope) → `ARCHITECTURE.md` (design decisions and rationale — read it before non-trivial work).

## Commands

```bash
xcodebuild -project Gitpack.xcodeproj -scheme Gitpack -configuration Debug build
./Tests/run-tests.sh     # parser tests
```

`run-tests.sh` is a `swiftc` assert-runner over `Models.swift` + `Parsers.swift` + `FileSystemWatcher.swift` — not XCTest, no test filtering. To run one case, comment out the others in `ParserTests.main()`. It compiles those three files standalone, so **they must stay Foundation-only** (no SwiftUI/AppKit imports, no dependencies on other app files).

The Xcode target uses `PBXFileSystemSynchronizedRootGroup`: new files under `Gitpack/` are picked up automatically, never edit `project.pbxproj` to add them.

## Architecture

Layering is `App/` (shell) + `Features/` (panes) → `AppState` → `GitService` → `ProcessRunner` → `git`. Views never touch `ProcessRunner`; every git operation is a `GitService` protocol method with a `CLIGitService` implementation.

**Two kinds of per-repo state.** `RepositoryViewModel` (full model: commits, status, branches, divergence) exists only for the selected repo. `RepoBackgroundState` (badge counts, fetch flag, backoff) exists for *every* sidebar repo and is fed by one `git status --porcelain=v2 --branch` call — `branch.ab` gives ahead/behind, the entry list gives the stage count. Adding a new sidebar-visible signal should go through `RepoBackgroundState`, not by loading more view models.

**"Other branch" is upstream config.** The compare/sync target (`git branch --set-upstream-to=`, accepts local branches too) is the pivot of the whole UI: toolbar morphing, badges, history refs, green/blue dots, push refspec. There is no app-side persistence of the pairing — read it from `status.upstream`, never invent a parallel store.

**Refresh paths** (`AppState`): FSEvents → `GitChangeClassifier` → debounced `.status`/`.full`; foreground activation → full reload; mutations refresh inline; autofetch loop refreshes background states. New git mutations should call `refreshAll` after succeeding, like `performSync` does.

**Concurrency:** build default isolation is MainActor, so views/`AppState`/view models are main-actor by default. `CLIGitService` and `DiffToolService` are actors; the `GitService` protocol and the parsers are `nonisolated` — keep them that way or git work starts blocking the main thread.

**Parsing:** always request NUL-terminated output (`-z`, `%x00`/`%x1e`/`%x1f`) and parse in a `nonisolated enum` in `Parsers.swift` with a byte-exact fixture test. Splitting on newlines or spaces is how Gitbox got path corruption.

## Conventions and traps

- **Never add interactive auth.** All git runs with `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS`/`SSH_ASKPASS` at `/usr/bin/false` so background fetch fails fast instead of hanging. Credentials, signing, hooks are the user's terminal config, by design.
- **History rows need explicit fixed heights** — `tableView.rowHeight = 45` (41pt of content + 2pt above and below), never `usesAutomaticRowHeights`. With automatic heights, NSTableView's estimates for unmaterialized rows diverge from measured two-line rows and scroll-to-row blanks the pane. A uniform height is also what makes M3's streaming search viable.
- **`refreshAll` assigns conditionally** (`if fresh != commits`). It runs on every activation and autofetch; unconditional assignment rebuilds the table mid-click and drops selection.
- **The UI is AppKit.** There is no SwiftUI left in the target — `grep -r "import SwiftUI" Gitpack/` returns nothing, and it should stay that way. `docs/plans/2026-07-27-appkit-migration.md` records how it got here and what each phase cost. Do not reintroduce SwiftUI, and especially not as a wrapper around an AppKit control — that bridge direction is what failed.
- **Inside an `observeChanges` body, read the observable state up front** — never only inside a loop over materialized table cells. Right after `reloadData` no cell views exist yet, so such a loop reads nothing, registers no dependency, and that state never updates again. `SidebarViewController.refreshVisibleCells` reads every repository's badge into a dictionary first, then applies it to whatever cells happen to exist; the badges silently never appeared until it did.
- **A separator `NSBox` has no intrinsic height.** Pin it to 1pt. Left unpinned it is free to absorb the whole pane, and the views below it get squeezed to nothing — that is what pushed the detail pane's file list off the bottom of the window the first time it ran.
- **The history table reloads only when its rows actually differ,** and restores the scroll offset and selection afterwards without scrolling. `HistoryViewController` scrolls to the selection only when the *model's* selection moved — restoring it after a reload would yank you to the top the moment you page in 200 more commits.
- **`AppDelegate` declares its own `static func main()`.** Inheriting the `NSApplicationDelegate` default routes through `NSApplicationMain`, which expects a main nib to instantiate the delegate. There is no nib, so the app would launch to a default menu bar and no window.
- **`splitView.autosaveName` is assigned after the split view items are added.** Set before, AppKit restores widths on launch but silently stops recording drags.
- **Menu actions use `target: nil`** so validation flows through the responder chain into `AppDelegate.validateMenuItem` (that is what replaces SwiftUI's `.disabled(…)`). There is no `NotificationCenter` plumbing left: Commit and Stage All are model operations on `AppState`, which is why they work from any pane rather than only when the detail pane holds focus. Bare-key Gitbox shortcuts (`u`/`p` in history, `s`/`d` in the file list) go through `KeyTableView` so they don't fight text fields.
- **The commit draft lives on `RepositoryViewModel.commitMessage`,** not in the composer. That is what lets ⌘↩ commit without reaching into the view hierarchy, and it keeps a draft alive when you click away to a commit and back. The composer only assigns the text view when it actually differs — writing it every keystroke collapses the insertion point.
- **AppKit invalidation goes through `observeChanges`** (`Shared/Observation+AppKit.swift`), a re-arming `withObservationTracking`. `AppState`, `RepositoryViewModel`, `RepoBackgroundState` and `RepositoryStore` are all `@Observable` — don't reach for Combine or KVO. `RepositoryStore` in particular *must* stay `@Observable`: `AppState.repositories` is a computed passthrough to its array, so without it, adding or removing a repository is invisible to every observer.
- **`// ponytail:` comments mark deliberate simplifications** with their ceiling (fixed 60s fetch cycle, 30s rate limit, no jitter). Respect them as decisions; when raising one, update the comment.
