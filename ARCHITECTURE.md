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

## Module layout

```
Gitpack/
├── App/
│   ├── GitpackApp.swift        @main, scene, command menu
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
│   ├── Sidebar/RepositorySidebar.swift
│   ├── History/HistoryList.swift
│   ├── Detail/{DetailPane,CommitDetail,WorkingCopyDetail}.swift
│   └── Toolbar/MainToolbar.swift
├── Shared/Formatters.swift
├── ContentView.swift
└── Assets.xcassets
```

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` — files dropped under `Gitpack/` are auto-included in the build target.

## Concurrency

- The build defaults to `default-isolation = MainActor`. SwiftUI views, `AppState`, `RepositoryStore`, and `RepositoryViewModel` all live on the main actor by default.
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
- **`AppState`** owns the watcher, re-targeting it whenever the selection changes (driven by `ContentView`'s `.task(id:)`). Event batches are debounced (350ms) and coalesced via `WatchRefreshKind.combined` so a burst of saves or a multi-ref git write triggers one refresh once the filesystem settles. Stale callbacks from a replaced watcher are dropped by repository-ID check.

Refresh triggers, in order of granularity:

- **FSEvents** — automatic, debounced; `.status` or `.full` per the classifier above.
- **Foreground activation** — `ContentView` awaits `NSApplication.didBecomeActiveNotification` (async `NotificationCenter` sequence, no Combine) and runs `AppState.foregroundRefresh()` (a full reload), a safety net for any events coalesced or missed while inactive.
- **Mutations** — `commit`, `stage`, `push`, etc. still refresh synchronously for immediate feedback; the watcher is redundant-but-harmless here.
- **Manual** — `refreshable` pull-to-refresh on the history list.

Only the selected repo is watched (that's the only one whose state is on screen); switching repos swaps the watcher.

## Tests

Not yet wired. The most valuable tests will be parser tests: feed known `git status --porcelain=v2 -z` and `git log` outputs to the parsers and assert the model values. Those go in a `GitpackTests` target in v0.2.
