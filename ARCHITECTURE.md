# Gitpack — Architecture

## Backend choice: pure CLI shell-out

Resolved spec open question §8.1.

The spec recommended evaluating a hybrid (libgit2 reads + CLI writes) first. v0.1 uses **pure CLI** for these reasons:

- **One mental model.** A second backend doubles the surface area for parsing bugs, version skew, and feature drift.
- **Correctness is free.** Shelling out to the user's `git` inherits hooks, signing, GPG, SSH agents, credential helpers, `~/.gitconfig`, `pull.rebase`, `commit.gpgsign`, all of it. None of those are concerns Gitpack has to learn about.
- **Performance is acceptable for v0.1.** `git log --max-count=200`, `git status --porcelain=v2 -z`, and `git diff-tree -z` are well under our 500ms budget on typical repos. The historical reason to reach for libgit2 — frequency of small calls during interactive UI — does not apply: Gitpack issues a small fixed number of calls per repo switch, then debounced refreshes on FSEvents.
- **The protocol stays open.** `GitService` (in `Git/GitService.swift`) is the seam. A libgit2 read-side can be slotted in for read-heavy operations later without touching the UI layer.

If a profiled bottleneck shows up — `log` on a 200k-commit repo, status over a network filesystem — that's the moment to reconsider.

## Authentication: nothing

Resolved spec open question §8.3.

All network operations (`fetch`, `pull`, `push`) shell out to system git. SSH agent, Keychain via `git-credential-osxkeychain`, OAuth token helpers, and signing keys all behave exactly as they do in the user's terminal. Gitpack has no Keychain UI, no "add SSH key" flow, no token storage.

## Sandbox: off

Resolved spec open question §8.5.

`ENABLE_APP_SANDBOX = NO` in the project settings. Hardened runtime stays on. This is a developer tool, not a Mac App Store submission, and sandboxing a Git client costs significant complexity (security-scoped bookmarks for every tracked repo, restrictions on spawning git, etc.) for no upside in this context.

## Comparison model: upstream config is the "other branch"

Gitbox's central toolbar concept is *current branch vs a chosen "other branch"* — a
remote branch (track/pull/push) or another local branch (compare/merge). Gitpack
stores that choice as git-native upstream config (`git branch --set-upstream-to=`),
which accepts local branches as well as remote ones. That one decision buys:

- `git status --porcelain=v2 --branch` reports `branch.ab` (ahead/behind) against
  either kind of target — one call powers both the toolbar state and sidebar badges.
- `git pull` honors it natively, and the selection survives outside Gitpack.
- No app-side persistence of the pairing.

Divergence detail (which commits, for the history dots) comes from
`git rev-list --left-right current...other`: left = unpushed (green dots),
right = unmerged (blue dots, shown italic/faded). History lists both branches'
commits (`git log current other`) so unmerged commits interleave, Gitbox-style.

Pushing uses an explicit refspec (`git push <remote> <current>:<remoteBranch>`)
derived from the upstream, so differently named local/remote branches work. The
pull/push toolbar buttons morph with held modifiers (⌥ → Fetch, ⇧⌘ → Rebase /
Force Push) and collapse to a single Merge button when the other branch is local.

## Autofetch and per-repo background state

`AppState` keeps a `RepoBackgroundState` per sidebar repo (the full
`RepositoryViewModel` still loads only for the selected one): unpushed/unmerged/
stage-change counts (the sidebar badge is their sum, as in Gitbox), a fetch
spinner flag, and failure count. It is fed by a single `git status` call per
repo — no rev-list needed for counts.

The autofetch loop runs `git fetch` across all repos on a fixed 60s cycle with a
2s stagger between repos and per-repo exponential backoff on failure (2 min
doubling to a 30 min cap). Failures are silent — the badge simply doesn't move —
and all git commands run with `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS`/`SSH_ASKPASS`
pointed at `/usr/bin/false` so auth that would need interaction fails fast instead
of hanging. Typing a commit message also triggers a fetch (rate-limited to 30s),
Gitbox's trick so you can pull before committing.

For the selected repo, the fetch's ref writes land via FSEvents (refs →
`.full` refresh), so blue dots appear without extra wiring.

## Module layout

The UI layer is AppKit throughout — no SwiftUI remains in the target. See
`docs/plans/2026-07-27-appkit-migration.md` for how it got here and what each
phase learned.

```
Gitpack/
├── App/
│   ├── AppDelegate.swift       @main, lifecycle, menu actions + validation
│   ├── MainWindowController.swift
│   ├── MainSplitViewController.swift   3 panes, autosaved widths
│   ├── MainMenu.swift          menu bar, built in code (no nib)
│   └── AppState.swift          observable root state, per-repo view models
├── Git/
│   ├── Models.swift            value types: Repository, Commit, FileChange...
│   ├── GitService.swift        protocol (the backend seam)
│   ├── ProcessRunner.swift     async wrapper around Process
│   └── CLIGitService.swift     actor implementation, NUL-terminated parsers
├── Persistence/
│   └── RepositoryStore.swift   JSON in App Support
├── DiffTool/
│   └── DiffToolService.swift   temp-file plumbing + opendiff invocation
├── Features/
│   ├── Sidebar/SidebarViewController.swift  NSOutlineView source list
│   ├── History/{HistoryViewController,CommitRowView}.swift  NSTableView
│   ├── Detail/{Detail,WorkingCopy,Commit}ViewController.swift + FileRowView.swift
│   └── Toolbar/MainToolbar.swift         NSToolbarDelegate
├── Shared/
│   ├── Formatters.swift
│   ├── KeyTableView.swift        bare-key shortcuts before type-select
│   └── Observation+AppKit.swift  re-arming withObservationTracking
└── Assets.xcassets
```

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` — files dropped under `Gitpack/` are auto-included in the build target.

## Concurrency

- The build defaults to `default-isolation = MainActor`. View controllers, `AppState`, `RepositoryStore`, and `RepositoryViewModel` all live on the main actor by default.
- `CLIGitService` is an `actor` so all git calls run off the main thread.
- The `GitService` protocol is `nonisolated` so conformers don't accidentally inherit MainActor isolation.
- `DiffToolService` is also an `actor`.
- Parsers (`PorcelainV2Parser`, `DiffTreeParser`) are `nonisolated` enums so they're cheap to call from any context.

## Parsing strategy

All git output is requested in NUL-terminated form (`-z` flag, format strings using `%x00`/`%x1e`/`%x1f`) to sidestep the path-encoding pitfalls that affect Gitbox. Paths containing `/`, spaces, unicode, etc. round-trip cleanly.

- `git log` records use `%x1e` (RS) as commit separator and `%x1f` (US) as field separator inside.
- `git status --porcelain=v2 -z` records are NUL-terminated; type-2 (rename/copy) entries are split across two NUL records (the entry, then the original path).
- `git diff-tree -r -z` produces `<status>\0<path>\0` for plain entries and `<status>\0<oldPath>\0<newPath>\0` for renames/copies.

## File watching

The selected repository's directory tree is watched live via FSEvents (`Git/FileSystemWatcher.swift`), so the UI behaves as a reflection of the filesystem rather than a snapshot.

- **`FileSystemWatcher`** is a `nonisolated` wrapper around `FSEventStreamCreate` (recursive, file-level, `NoDefer`). Events are delivered on a private serial queue; `stop()` flushes in-flight callbacks before tearing the stream down.
- **`GitChangeClassifier`** maps a batch of changed paths to the coarsest refresh they warrant: ref/`HEAD`/reflog/`packed-refs` changes → `.full` (commit graph or branches moved); working-tree or `.git/index` changes → `.status` (cheap, no list flicker); loose objects, `*.lock`, `FETCH_HEAD` → `.none` (noise).
- **`AppState`** owns the watcher, re-targeting it whenever the selection changes (driven by `AppDelegate`'s observation of `selectedRepositoryID`). Event batches are debounced (350ms) and coalesced via `WatchRefreshKind.combined` so a burst of saves or a multi-ref git write triggers one refresh once the filesystem settles. Stale callbacks from a replaced watcher are dropped by repository-ID check.

Refresh triggers, in order of granularity:

- **FSEvents** — automatic, debounced; `.status` or `.full` per the classifier above.
- **Foreground activation** — `AppDelegate.applicationDidBecomeActive` runs `AppState.foregroundRefresh()` (a full reload), a safety net for any events coalesced or missed while inactive.
- **Mutations** — `commit`, `stage`, `push`, etc. still refresh synchronously for immediate feedback; the watcher is redundant-but-harmless here.
- **Manual** — `refreshable` pull-to-refresh on the history list.

Only the selected repo is watched (that's the only one whose state is on screen); switching repos swaps the watcher.

## Tests

Parser tests live in `Tests/ParserTests.swift`, run via `Tests/run-tests.sh` — a
`swiftc` assert-runner over `Models.swift` + `Parsers.swift` (which must stay
Foundation-only). No test target yet; add a real `GitpackTests` target when
UI/async tests appear. Covered: porcelain v2 (headers, renames, unmerged,
untracked, detached), diff-tree, log records, rev-list left/right.
