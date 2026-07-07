# Milestones 1 & 2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give Gitpack Gitbox's comparison model (current branch vs "other branch", morphing sync controls, green/blue commit dots) and its all-repo awareness (background autofetch, sidebar badges).

**Architecture:** The "other branch" is stored as git-native upstream config (`branch.<name>.merge`/`.remote`) — git supports local branches as upstreams, so one mechanism covers both remote tracking and local comparison, and `git pull`/`status --porcelain=v2 --branch` already honor it. Divergence (unpushed/unmerged SHA sets) comes from one `git rev-list --left-right` call; history shows both branches' commits via `git log current other`. M2 adds a per-repo lightweight background state to `AppState` (today it only models the selected repo) plus a staggered autofetch loop with per-repo backoff.

**Tech Stack:** Swift 6 / SwiftUI (macOS 15.7 target, default MainActor isolation), CLI git backend via existing `GitService` protocol, `swiftc`-compiled assert tests (no test target yet — see Task 1).

**Key existing files:** `Gitpack/Git/{GitService,CLIGitService,Models}.swift`, `Gitpack/AppState.swift`, `Gitpack/Features/Toolbar/MainToolbar.swift`, `Gitpack/Features/History/HistoryList.swift`, `Gitpack/Features/Sidebar/RepositorySidebar.swift`, `Gitpack/GitpackApp.swift`.

**Verification commands:**
- Build: `xcodebuild -project Gitpack.xcodeproj -scheme Gitpack -configuration Debug build -quiet` (expect exit 0)
- Tests: `Tests/run-tests.sh` (expect `ALL TESTS PASSED`)

Commit after every task. Run the build after every task that touches app code.

---

## Milestone 1 — Comparison model & sync controls

### Task 1: Parser extraction + runnable parser tests

The parsers are `private` inside `CLIGitService.swift` and untestable. Extract them; add the promised parser tests as a swiftc script — no pbxproj surgery, no framework.

**Files:**
- Create: `Gitpack/Git/Parsers.swift` (move `PorcelainV2Parser`, `DiffTreeParser` out of `CLIGitService.swift`, drop `private`; move `parseLog` into a new `LogParser` enum with `static func parse(_ text: String) -> [Commit]`)
- Modify: `Gitpack/Git/CLIGitService.swift` (delete moved code; `log()` calls `LogParser.parse`)
- Create: `Tests/ParserTests.swift` — assert-based `@main` struct; cases: porcelain v2 with branch headers + ahead/behind, a rename (type-2) entry, untracked/unmerged entries; diff-tree plain + rename records; log records incl. empty body and multi-parent. Feed byte-exact fixtures (NUL separators as `\u{00}` etc.).
- Create: `Tests/run-tests.sh` (`chmod +x`):
  ```bash
  #!/bin/zsh
  # ponytail: swiftc assert-runner instead of a test target; add GitpackTests target when UI/async tests appear
  set -e
  cd "$(dirname "$0")"
  swiftc -parse-as-library -o /tmp/gitpack-parser-tests \
    ../Gitpack/Git/Models.swift ../Gitpack/Git/Parsers.swift ParserTests.swift
  /tmp/gitpack-parser-tests && echo "ALL TESTS PASSED"
  ```
  Note: `Models.swift`/`Parsers.swift` must stay Foundation-only for this to work (they are today; keep it that way).

**Steps:** move code → write tests → `Tests/run-tests.sh` fails if any assert trips (verify by temporarily breaking one fixture) → build the app → commit `refactor: extract git parsers, add parser tests`.

### Task 2: Divergence primitives in GitService

**Files:**
- Modify: `Gitpack/Git/Models.swift` — add:
  ```swift
  struct Divergence: Hashable, Sendable {
      let otherRef: String
      let unpushed: Set<String>   // SHAs on current, not on other (green)
      let unmerged: Set<String>   // SHAs on other, not on current (blue)
  }
  ```
- Modify: `Gitpack/Git/Parsers.swift` — add `RevListParser.parseLeftRight(_ text: String) -> (left: Set<String>, right: Set<String>)` for `rev-list --left-right` output (`<sha` / `>sha` per line).
- Modify: `Gitpack/Git/GitService.swift` + `CLIGitService.swift`:
  ```swift
  func divergence(current: String, other: String, at url: URL) async throws -> Divergence
  // → git rev-list --left-right <current>...<other>
  func merge(branch: String, at url: URL) async throws          // git merge <branch>
  func pullRebase(at url: URL) async throws                     // git pull --rebase
  func push(refspec: String?, force: Bool, at url: URL) async throws
  // refspec "local:remoteBranch" when upstream names differ; plain `git push` when nil.
  // Replace the old push() — update call sites.
  ```
- Modify `log` signature: `log(at:limit:skip:refs: [String])` — pass every ref after `--format`; update the one call site in `AppState.swift`.
- Test: extend `Tests/ParserTests.swift` with rev-list fixtures (both directions, empty).

**Steps:** tests first → implement → `Tests/run-tests.sh` → build → commit `feat: divergence, merge, rebase, explicit-refspec push in GitService`.

### Task 3: ViewModel — other branch + divergence + combined history

**Files:**
- Modify: `Gitpack/AppState.swift` (`RepositoryViewModel`):
  - Add `var divergence: Divergence?`.
  - Add computed `var otherBranch: String?` → `status?.upstream ?? branches.first { $0.isCurrent }?.upstream`.
  - Add computed `var otherBranchIsLocal: Bool` → `branches.contains { $0.name == otherBranch }`.
  - In `refreshAll`: after status/branches load, if `currentBranch` and `otherBranch` both exist, load `divergence` (else nil). History call becomes `refs: [currentBranch, otherBranch].compactMap { $0 }` — deduped, detached-HEAD-safe (empty refs → `HEAD`).
  - Add `func setOtherBranch(_ ref: String, using git: GitService)` → `setUpstream` + `refreshAll`. (`git branch --set-upstream-to=` accepts local branch names; that is the whole local-comparison mechanism.)
  - Add marker helper: `func marker(for commit: Commit) -> CommitMarker` where `enum CommitMarker { case none, unpushed, unmerged }`.

**Steps:** implement → build → manual check: run app on a repo with an upstream, confirm history still loads and `status.ahead/behind` still displays → commit `feat: other-branch model, divergence, combined history in view model`.

### Task 4: Toolbar — other-branch picker + morphing sync controls

**Files:**
- Modify: `Gitpack/Features/Toolbar/MainToolbar.swift`:
  - Replace `UpstreamPicker` with `OtherBranchPicker`: menu sections — local branches except current; then remote branches (single remote → flat list; multiple remotes → one submenu per remote, split on first `/` matching `remotes()` names); ✓ on `vm.otherBranch`; selection calls `vm.setOtherBranch`.
  - Replace `PullButton`/`PushButton` with one `SyncControls` view:
    - `@State private var modifiers: EventModifiers = []` driven by `.onModifierKeysChanged { _, new in modifiers = new }` (macOS 15 API).
    - Other branch nil → both buttons disabled, labels Pull/Push.
    - Other branch local → single button `← Merge` → `git.merge(branch:)`.
    - Other branch remote → two buttons:
      - left: ⌥ held → `Fetch` (`git.fetch`); ⇧⌘ → `Rebase` (`git.pullRebase`); else `Pull` (`git.pull`)
      - right: ⇧⌘ → `Force Push` (`push(refspec:force:true)`); else `Push`
      - refspec: derive from upstream — `"\(currentBranch):\(remoteBranchName)"` where `remoteBranchName` is upstream minus `"<remote>/"` prefix; remote is the first path component.
    - All actions: set `isWorking`, run, `vm.refreshAll`, surface `GitError` into `vm.lastError` (reuse the existing pattern).
- Keep `BranchPicker` as is (it grows in M4).

**Steps:** implement → build → manual: with a repo tracking `origin/main`, hold ⌥ and ⇧⌘ over the toolbar and watch labels morph; select a local branch as other → single Merge button → commit `feat: other-branch picker and modifier-morphing sync controls`.

### Task 5: History dots + other-branch row styling

**Files:**
- Modify: `Gitpack/Features/History/HistoryList.swift`:
  - `CommitRow` gains `let marker: CommitMarker`; leading 7pt `Circle()` — `.green` for unpushed, `.blue` for unmerged, `Color.clear` for none (keeps alignment).
  - Unmerged rows: italic + `.secondary` text (extend the existing `isMerge` styling ternaries into a computed style based on `marker`/`isMerge`).
  - `HistoryListContent` passes `vm.marker(for: commit)`.

**Steps:** implement → build → manual: fetch a repo that's behind (`git fetch` in Terminal on a stale clone), confirm blue-dotted italic rows appear above/interleaved and green dots on local-only commits → commit `feat: green/blue divergence dots in history`.

### Task 6: Menu bar + key shortcuts

**Files:**
- Modify: `Gitpack/GitpackApp.swift` — `.commands` gains (capture `appState` directly; `Commands` can't read `@Environment`):
  - **Repository** `CommandMenu`: Pull, Push, Fetch (⌥U), Rebase (⇧⌘U), Force Push (⇧⌘P), divider, Open in Finder, Open in Terminal. Route through a small `SyncActions` helper (shared with the toolbar — extract the toolbar's action funcs into `AppState` or a `SyncActions` struct so menu and toolbar call the same code; pick `AppState` methods, simplest).
  - **Stage** `CommandMenu`: Stage All (⇧⌘↩), Commit (⌘↩) — post the existing NotificationCenter pattern (`.stageAllRequested`, `.commitRequested`) consumed by `WorkingCopyDetail`.
  - Disable items when `selectedViewModel == nil` (and sync items when `otherBranch == nil`).
- Modify: `Gitpack/Features/History/HistoryList.swift` — `.onKeyPress` on the `List` for bare keys (fires only when the list has focus, so text fields are safe): `u` → pull/merge, `p` → push, `d` → open diff for selection.
- Modify: `Gitpack/Features/Detail/WorkingCopyDetail.swift` — `.onKeyPress("s")` on its file list → toggle stage for selected rows; wire the two new notifications.
- Note: Gitbox put bare `u`/`p` in the menu bar; bare-key menu equivalents fight text input in SwiftUI, so bare keys live on the focused lists and the menu carries the modifier variants. `// ponytail:` comment at the shortcut site.

**Steps:** implement → build → manual: `u`/`p`/`s`/`d` with list focus, menu items + shortcuts, disabled states → commit `feat: Repository/Stage menus and single-key shortcuts`.

**Milestone 1 exit criteria:** other-branch picker persists per branch via git config; pull/push/fetch/rebase/force-push/merge all reachable from toolbar (with modifiers) and menu; green/blue dots correct against `git rev-list --left-right` run by hand; parser tests pass.

---

## Milestone 2 — Autofetch, badges, all-repo awareness

### Task 7: Per-repo background state + badge computation

**Files:**
- Modify: `Gitpack/AppState.swift`:
  ```swift
  @Observable @MainActor
  final class RepoBackgroundState {
      var unpushed = 0
      var unmerged = 0
      var stageChanges = 0
      var isFetching = false
      var consecutiveFailures = 0
      var badge: Int { unpushed + unmerged + stageChanges }
  }
  ```
  - `AppState.backgroundStates: [UUID: RepoBackgroundState]`, accessor `backgroundState(for:)` (create-on-demand, like `viewModel(for:)`).
  - `func refreshBackgroundState(for repo: Repository) async` — no fetch: `workingCopyStatus` (stage count = `entries.count`) + `branches` + `divergence` when upstream exists → update counts. Cheap (3 git calls). Skip if repo missing on disk.
  - Call it for the selected repo at the end of `refreshAll`-triggered paths (`applyWatchedRefresh`, mutations) so the selected repo's badge is always current without waiting for the timer.
- Modify: `Gitpack/Features/Sidebar/RepositorySidebar.swift` — `badgeCount(for:)` reads `appState.backgroundState(for: repo).badge` (nil→hide when 0); add `ProgressView().controlSize(.small)` in the row when `isFetching`.

**Steps:** implement → build → manual: two repos in sidebar, one dirty + one ahead — both show correct badges without being selected (after Task 8's loop, or by triggering refresh manually) → commit `feat: per-repo background state drives sidebar badges`.

### Task 8: Autofetch engine

**Files:**
- Create: `Gitpack/Git/AutofetchEngine.swift`:
  - `@MainActor final class AutofetchEngine` owned by `AppState`; `start()` spawns one `Task` loop:
    ```
    while true:
      for repo in store.repositories (snapshot):
        state = backgroundState(for: repo)
        if state.consecutiveFailures > 0 and now < nextAllowedAttempt(state): continue
        state.isFetching = true
        try? await git.fetch(at: repo.url)   // errors: failures += 1 (backoff = 60s · 2^n, cap 30 min); success: failures = 0
        state.isFetching = false
        await appState.refreshBackgroundState(for: repo)
        await Task.sleep(2s)                 // stagger between repos
      await Task.sleep(60s)                  // base cycle, per Gitbox Refresh.txt spirit
    ```
  - `stop()` cancels. Honor cancellation in both sleeps.
- Modify: `Gitpack/Git/CLIGitService.swift` — background-safe fetch env: add `GIT_ASKPASS=/usr/bin/false` and `SSH_ASKPASS=/usr/bin/false` alongside the existing `GIT_TERMINAL_PROMPT=0` (applies to all commands; interactive auth is out of scope by decision). One place: `runGit`.
- Modify: `Gitpack/GitpackApp.swift` or `ContentView.task` — start the engine once at launch.
- Selected-repo propagation needs no work: fetch writes `refs/remotes/*`, FSEvents classifies refs → `.full` refresh → blue dots appear live.

**Steps:** implement → build → manual: stale clone in sidebar, not selected; push to it from elsewhere (or `git commit` in its origin + wait) → badge rises within ~1 min; select it → blue dots present. Unreachable remote (bogus URL repo) → no error UI, spinner stops, backoff (verify via log print or Activity in M5) → commit `feat: background autofetch with per-repo backoff`.

### Task 9: Fetch on commit-message typing

**Files:**
- Modify: `Gitpack/Features/Detail/WorkingCopyDetail.swift` — `.onChange(of: message)`: if non-empty, call `appState.opportunisticFetch()`.
- Modify: `Gitpack/AppState.swift` — `opportunisticFetch()`: for the selected repo only; rate-limited (skip if last fetch < 30s ago, tracked on `RepoBackgroundState.lastFetch: Date?`); silent; refreshes background state after. `// ponytail:` 30s constant, no config.

**Steps:** implement → build → manual: type in message field on a behind repo → blue dots/badge update without touching Pull → commit `feat: typing a commit message triggers an opportunistic fetch`.

### Task 10: Docs + final verification

**Files:**
- Modify: `ARCHITECTURE.md` — new sections: comparison model (upstream-as-other-branch rationale), autofetch policy (cycle/stagger/backoff numbers), background-state layer; update the Tests section (swiftc runner, not a target — with the upgrade note).
- Modify: `README.md` — "What works" gains M1/M2 bullets; runtime note that background fetch never prompts (auth must be non-interactive).

**Steps:** update docs → full build → `Tests/run-tests.sh` → manual smoke of the M1 exit criteria + autofetch on ≥2 real repos → commit `docs: architecture and README for comparison model + autofetch`.

**Milestone 2 exit criteria:** all sidebar repos show live badges and fetch spinners without being selected; a push from another machine (or another clone) surfaces as blue dots + badge within one cycle; failures are silent with backoff; no main-thread stalls (repo switching stays <200ms while a fetch runs).
