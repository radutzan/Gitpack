# Gitpack — Product Spec

A minimalist, fast Git client for macOS. Spiritual successor to Gitbox.

---

## 1. Vision

Gitbox is a beloved Git GUI from the late 2000s/early 2010s era — celebrated for its clarity, density, and "Mac-like" restraint. It still has a devoted following despite being effectively unmaintained, and on modern macOS it now corrupts paths containing `/` due to URL-encoding regressions in the underlying frameworks it relies on.

Gitpack is a clean-room rewrite in modern Swift/SwiftUI that preserves what made Gitbox great:

- **A 3-pane layout** that fits the 80% case of "look at history, stage some files, commit, push."
- **Density and typography** that respect the user's screen and attention.
- **Speed and quietness** — no chrome, no nags, no telemetry.

Gitpack is **not** trying to be Tower, Fork, or GitKraken. It is deliberately scoped down. Power features (rebase, cherry-pick, merge conflict resolution, submodules, worktrees, LFS, etc.) are explicit non-goals for v0.1.

---

## 2. Target user

A developer who:

- Lives in `git` on the command line for anything non-trivial.
- Wants a GUI for the routine flow: see what changed, stage it, commit, push.
- Prefers external diff tools (FileMerge, Kaleidoscope, `opendiff`) over an in-app diff viewer.
- Values keyboard-first workflows and fast launch.

---

## 3. Scope — v0.1

### In scope

- **Repository management**: add/remove repositories from a sidebar list. Persistence across launches.
- **Commit history**: view linear-ish history for the current branch with author, date, and subject.
- **Working copy view**: list of modified, new, and deleted files for the current uncommitted state.
- **Stage / unstage**: per-file granularity. No hunk-level staging in v0.1.
- **Commit**: with a message field; respect git's commit hooks and signing config.
- **Push / pull / fetch**: against the current branch's upstream.
- **External diff handoff**: opening a file's diff invokes a configurable external diff tool (default: FileMerge via `opendiff`). No in-app diff viewer.
- **Branch switcher**: read-only display of current branch + dropdown to switch to existing local branches. No branch creation/deletion in v0.1.

### Explicitly out of scope for v0.1

- In-app diff viewer (delegated to external tools — see §6.5).
- Hunk-level / line-level staging.
- Branch creation, deletion, renaming.
- Merge, rebase, cherry-pick, revert.
- Stash management.
- Tag management.
- Submodules, worktrees, LFS.
- Conflict resolution UI.
- Remotes management UI (add/remove remote).
- History graph rendering (just a flat list for now).
- File history / blame.
- Search across commits.
- Settings sync, telemetry, crash reporting.

### Likely v0.2+ candidates (not promises)

- Branch CRUD.
- Stash.
- Tags.
- Hunk-level staging.
- Search.
- History graph.

---

## 4. UI layout

**Match Gitbox's 3-pane layout.** This is prescriptive.

```
┌─────────────────────────────────────────────────────────────────────┐
│  [Toolbar: branch picker · pull · push · upstream picker · search]  │
├──────────────┬──────────────────────────────┬───────────────────────┤
│              │                              │                       │
│  REPOSITORIES│   HISTORY / WORKING COPY     │   FILE LIST           │
│              │                              │                       │
│  • RaduKit   │   Radu Dutzan         19:57  │   path/to/file.swift  │
│  • Doppi     │   nav bar fixes              │   path/to/other.m     │
│    └ RaduKit │                              │   ...                 │
│  • radu.cl   │   Radu Dutzan   Mar 11 18:59 │                       │
│  • GitPack   │   more Mac decency           │                       │
│              │   ...                        │                       │
│              │                              │                       │
│              │                              │                       │
│              │                              │  [Commit message…]    │
│              │                              │  [Commit] button      │
└──────────────┴──────────────────────────────┴───────────────────────┘
```

### Pane behavior

#### Left — Repositories sidebar
- Flat list (with optional nested sub-repos for visually grouped projects, à la Gitbox's `Doppi > RaduKit`).
- Each repo shows its name and an unread/changed-file count badge (matches Gitbox).
- Selecting a repo populates the middle and right panes.
- Add via `+` button (file picker → choose folder → must contain `.git`) or drag-and-drop folders into the sidebar.
- Remove via context menu (only removes from Gitpack, never touches the filesystem).

#### Middle — History / working copy list
- Top row is always **"Uncommitted changes"** (when present), styled distinctly.
- Below that, a flat list of commits on the current branch, newest first.
- Each row: author name, relative or absolute date (right-aligned), commit subject on the second line.
- Selecting a commit shows its files in the right pane.
- Selecting "Uncommitted changes" shows the working copy file list with checkboxes for staging.
- Lazy-load / paginate older commits — don't block on loading thousands of commits.

#### Right — File list + commit area
- When a commit is selected: list of files changed in that commit, each with a status indicator (modified, new, deleted, renamed).
- When "Uncommitted changes" is selected: list of working-copy files with checkboxes for staging, plus a commit message field and Commit button at the bottom.
- Header summary like Gitbox: `"19 modified files, 1 new file"`.
- Double-click a file → open in external diff tool (see §6.5).
- Context menu per file: Stage / Unstage, Discard changes, Open in diff tool, Reveal in Finder, Copy path.

### Toolbar
- Left: `+` (add repo), gear (settings).
- Center: current branch picker (dropdown), pull button, push button, upstream picker.
- Right: search (deferred — placeholder field for now is fine, or omit entirely in v0.1).

### Visual style
- Native macOS look. Use system materials, system fonts (SF Pro / SF Mono), system accent color.
- Information density should match Gitbox — comfortable but not airy. Avoid the "iPad-ified" oversized-row look that newer macOS apps drift toward.
- Light and dark mode both supported from day one.

---

## 5. Deployment target

**Use whatever modern SwiftUI APIs require.** Prefer the newest macOS that's reasonable to ship against today. If a feature genuinely requires falling back to AppKit (e.g., `NSTableView` for the commit list if SwiftUI's `Table` proves too slow with thousands of rows), that's acceptable — wrap it cleanly.

Do not bend over backward to support older macOS versions. This is a fresh start.

---

## 6. Technical decisions

### 6.1 Language & frameworks
- Swift, latest stable.
- SwiftUI as the primary UI layer.
- AppKit interop where SwiftUI is insufficient (likely: large list performance, fine-grained text rendering for commit messages).
- Swift Concurrency (`async/await`, actors) for all git operations — never block the main thread on git work.

### 6.2 Git backend — recommendation requested

**Decision deferred to Claude Code.** Pick one of:

1. **Pure libgit2** (via SwiftGit2 or a fresh Swift wrapper).
   - Pros: in-process, fast, no shell-out overhead, structured data.
   - Cons: SwiftGit2 is sporadically maintained; libgit2 lags behind canonical git in some areas (notably anything involving credential helpers, signing, and newer protocols); auth is a perennial pain.

2. **Shell out to system `git`**.
   - Pros: always matches what the user's terminal does (config, hooks, credential helpers, signing, SSH all "just work"); zero divergence risk.
   - Cons: parsing porcelain output is fragile; performance overhead per call; need to be careful about which `git` binary is found.

3. **Hybrid**: libgit2 for read-heavy ops (history, status, diffs), CLI for write/network ops (commit, push, pull, fetch).
   - Pros: best of both — speed for reads, correctness for writes/network.
   - Cons: two code paths to maintain; two mental models.

**Strong recommendation for Claude Code to evaluate first**: the **hybrid** approach is likely the sweet spot for this app's scope. Reads (history, status, file lists) are where users feel latency, and libgit2 is fast there. Writes and network ops (commit, push, pull) are where correctness and ecosystem compatibility matter most — and where shelling out to `git` removes entire categories of bugs (auth, hooks, signing, GPG, SSH agents, credential helpers, `~/.gitconfig` quirks).

Whatever is chosen, document the rationale in the repo's `README.md` and `ARCHITECTURE.md`.

### 6.3 Authentication — recommendation requested

**Decision deferred to Claude Code**, contingent on the backend choice.

- If shelling out to `git` (for network ops): auth is essentially free — the system git already handles SSH agents, keychain, credential helpers, OAuth tokens via `git-credential-osxkeychain`, etc. Gitpack should do nothing special.
- If using libgit2 directly for network ops: auth is significantly harder. SSH agent forwarding, keychain access, and credential helpers all need explicit wiring. This is one of the strongest arguments for the hybrid approach.

**Recommendation**: regardless of backend, **delegate network operations to the system `git` binary** so authentication is the user's existing terminal setup, unchanged. No keychain prompts from Gitpack itself. No "add SSH key" UI. If `git push` works in their terminal, it works in Gitpack.

### 6.4 Repository persistence
- Store the list of tracked repositories in `~/Library/Application Support/Gitpack/repositories.json` (or equivalent via `FileManager.urls(for: .applicationSupportDirectory)`).
- Use security-scoped bookmarks if sandboxed; raw paths if not. **Recommend non-sandboxed for v0.1** — sandboxing a Git client is a battle, and this isn't a Mac App Store target.
- Detect when a tracked repo has been moved or deleted on disk; show a clear "missing" state in the sidebar rather than crashing.

### 6.5 External diff tool integration
- Default tool: FileMerge via `opendiff <file_in_HEAD> <file_in_working_copy>`.
- Settings: a single text field in preferences for "Diff tool command" with `$LEFT` and `$RIGHT` placeholders. Default value: `opendiff $LEFT $RIGHT`.
- For diffing a working-copy file: write the HEAD version of the file to a temp file, pass both paths to the diff tool.
- For diffing a file inside a historical commit: write both that commit's version and its parent's version to temp files.
- Clean up temp files when the diff tool exits (or on app quit, whichever is more reliable).

### 6.6 File watching
- Watch the working directory of the currently selected repo using `FSEvents` (or `DispatchSource` file monitors) to refresh status without polling.
- Debounce updates — git operations cause bursts of filesystem events.
- Watch `.git/HEAD` and `.git/refs/` to detect branch switches and ref updates that happen outside Gitpack.

### 6.7 Performance targets
- Cold launch to usable UI: under 1 second on an M-series Mac.
- Switching between repos in the sidebar: under 200ms to populated panes.
- Loading the first 200 commits of history: under 500ms.
- No spinners for routine operations on reasonably sized repos (< 50k commits).

### 6.8 Error handling
- Git errors surface as a non-modal banner or inline message in the relevant pane. Never use a modal alert for routine git errors (e.g., "nothing to commit").
- Truly unexpected errors (libgit2 crashes, missing binary) surface as a dismissible alert with the underlying error text — these are bugs and should be debuggable.

---

## 7. Architecture suggestions (non-prescriptive)

A loose suggestion — Claude Code can deviate if there's a better idea:

```
Gitpack/
├── App/                  # @main, app lifecycle, settings
├── Features/
│   ├── RepositoryList/   # left pane
│   ├── History/          # middle pane
│   ├── FileList/         # right pane
│   └── CommitComposer/   # commit message + button
├── Git/
│   ├── GitService.swift  # protocol; hides backend choice
│   ├── LibGit2Backend/   # if used
│   └── CLIBackend/       # shells out to `git`
├── Persistence/          # repo list, settings
├── DiffTool/             # external diff handoff
└── Shared/               # models, formatters, extensions
```

`GitService` should be a protocol — this lets the backend choice be revisited without rewriting the UI layer, and makes testing trivial.

Models should be value types (`struct Commit`, `struct FileChange`, `struct Repository`) and decoupled from the backend.

---

## 8. Open questions for Claude Code to answer in implementation

1. **Backend choice**: pure libgit2, pure CLI, or hybrid? Justify in `ARCHITECTURE.md`.
2. **SwiftGit2 vs. fresh wrapper**: if libgit2 is used, is SwiftGit2 healthy enough to depend on, or should we vendor libgit2 directly with a minimal Swift wrapper?
3. **Authentication wiring**: confirm that delegating to system `git` for network ops is sufficient and document any edge cases.
4. **Commit list virtualization**: does SwiftUI's `Table` / `List` handle 10k+ rows acceptably, or do we need `NSTableView` interop from day one?
5. **Sandbox**: stay un-sandboxed for v0.1 — confirm or push back.

---

## 9. Deliverables for v0.1

- A buildable Xcode project (or Swift Package + Xcode wrapper) that produces a `.app`.
- A working app that satisfies §3 ("In scope").
- `README.md` with build instructions and architecture overview.
- `ARCHITECTURE.md` documenting backend decisions and rationale.
- Basic unit tests for the `GitService` layer.
- No installer, no DMG, no notarization concerns yet — just a working dev build.

---

## 10. Non-goals (worth restating)

- **Not a Tower competitor.** Gitpack is intentionally narrow.
- **Not a teaching tool.** Assumes the user knows git.
- **Not a cross-platform app.** macOS only, and proudly native.
- **Not free of the command line.** Users are expected to drop to the terminal for anything Gitpack doesn't do.

---

## Appendix A — Reference: what Gitbox got right

For Claude Code to internalize before designing screens:

- **The 3-pane layout is the entire app.** Everything else (toolbar, dialogs) is deliberately minimal.
- **Repository sidebar groups visually nested repos** without making them functionally different from top-level repos.
- **Commit list rows are two-line**: name + date on top, subject below. Compact but legible.
- **The "Uncommitted changes" pseudo-row** at the top of the commit list is the entry point to staging — no separate "Working Copy" tab or screen.
- **Commit happens in the same pane as the file list** — no modal, no separate window. You check files, type a message, hit Commit, done.
- **Push/pull are toolbar buttons**, not buried in menus.
- **No graph rendering** — just a chronological list. This is a feature, not a limitation.
