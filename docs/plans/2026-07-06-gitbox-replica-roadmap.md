# Gitpack — Gitbox Replica Roadmap

Supersedes the scope section of `Gitpack-Spec.md` (§3), which described only the v0.1 baseline. The target is now the functionality of **Gitbox 1.6.3** (Oleg Andreev, 2010–2012) — same structure, density, interactions, and shortcuts, rendered with modern native macOS styling. Not a pixel recreation of the 2011 look.

Primary reference: the open-sourced original at [github.com/oleganza/gitbox](https://github.com/oleganza/gitbox) (Apache-2.0, ObjC). Especially worth mining verbatim: `Documents/Search.txt` (full search spec), `Documents/Refresh.txt` (FSEvents/timer refresh policy), `Documents/UI.txt`, and `Classes/GBRepositoryController.m` (the action/undo/badge logic). Archived marketing site + screenshots: `web.archive.org/web/2012/http://gitboxapp.com/`.

## Decisions (2026-07-06)

- **Fidelity**: same structure/interactions, modern skin.
- **In roadmap**: autofetch + dot markers + sidebar badges; live full-history search; full branch/history/stash/tag operations.
- **Sidebar**: drag-reorder only for now. Groups: maybe later. Submodules: later.
- **Auth**: keep delegating 100% to system git; background fetches that need interaction fail silently (matches Gitbox's suppressed background prompts). No askpass/Keychain UI.
- **Parked** (not scheduled): undo/redo of git operations (⌘Z commit/pull/push), submodules, sidebar groups, auth prompt UI.
- **Out of scope for this project** (not parked — excluded): 2011 visual skin, in-app diff / hunk staging (never in Gitbox 1.x either), history graph.

## Baseline (done, v0.1)

3-pane window; repo add/remove/persist; linear history; stage/unstage via checkbox + context menu; commit (hooks/signing respected); push/pull/fetch vs upstream; local-branch switcher; external diff via temp files + `opendiff`; FSEvents live refresh + foreground refresh; light/dark.

## Milestone 1 — The comparison model & sync controls

Gitbox's toolbar is not "pull/push vs upstream"; it is **current branch vs a chosen "other branch"** (local or remote), and every sync affordance derives from that pair. This is the interaction core and everything later (dots, badges, merge) hangs off it.

- "Other branch" toolbar popup: remote branches (submenus per remote when >1), other local branches, persisted per repo (Gitbox stored this as the branch's tracking config where possible).
- Pull/Push segmented control that morphs:
  - other branch is remote → `← pull | push →`
  - other branch is local → single `← merge` button
  - held Option → `← fetch`; held ⌘⇧ → `← rebase` / `force →`, labels update live with modifier state.
- Ahead/behind computation for the branch pair (`git rev-list --left-right --count`), plus the commit-set queries behind it.
- History dot markers: **green = unpushed** (on current, not on other), **blue = unmerged** (fetched, on other, not on current); other-branch-only commits listed in faded/italic style.
- Single-key shortcuts: `u` pull/merge, `p` push, ⌥u fetch, ⌘⇧U rebase, ⌘⇧P force push, `s` stage/unstage, `d` diff.
- Menu bar buildout to match (Repository / Stage / Changes menus), so every toolbar action has a menu + shortcut home.

## Milestone 2 — Autofetch, badges, all-repo awareness

Gitbox's identity: "see all your repositories at a glance." Requires an architectural change — today `AppState` only loads/watches the **selected** repo. Introduce a lightweight per-repo background state (ahead/behind counts, stage count, fetch status) maintained for *every* sidebar repo, with the full model still loaded only for the selected one.

- Background autofetch timer across all repos (staggered; Gitbox's `Refresh.txt` documents debounce + backoff — copy that policy). Errors and auth prompts suppressed for background fetches.
- Fetch triggered on typing a commit message (Gitbox's trick so you can pull before committing).
- Sidebar numeric badges = unpushed + unmerged + stage-change count; inline spinner during fetch/pull.
- New remote commits appear live with blue dots when the repo is selected.
- Sidebar drag-reorder.

## Milestone 3 — Live history search

Gitbox's signature feature. ⌘F / toolbar field streams `git log -p` and filters live — no index.

- **First task: migrate the history list to `NSTableView` (`NSViewRepresentable`).** Search stresses exactly what SwiftUI's List bridge is weakest at: streaming mutations, per-row substring highlighting, 10k+ rows, stable selection through constant filtering. Decided 2026-07-13 after the NavigationSplitView/HSplitView layout failures showed the SwiftUI↔AppKit bridge layer is where this app breaks; build the search UI once, on the real control. Keep the row design (two-line, dots, fixed height) and the manual width-persistence pattern from ContentView.
- Matches commit metadata (author, SHA, date), file paths, and **added/removed diff lines**; space-separated tokens AND together; quoted phrases match exact case.
- Yellow highlight of matched substrings in history rows, file lists, and message text.
- Thin results bar atop the history list: live count ("152 commits") + progress spinner; Esc cancels the stream.
- Show File History (⌘D): filter history to commits touching the selected file (same pipeline, path filter).
- Implementation: incremental `git log -p -z`-style streaming parse off-main-actor, batched UI updates; cancellation via process kill. `Documents/Search.txt` in the Gitbox repo is the spec — follow it.

## Milestone 4 — Full branch, tag, stash, and history operations

Breadth. Toolbar branch popup grows Gitbox's full menu; the commit context menu becomes the power-user surface. Advanced/destructive stays in menus and modifiers — the toolbar keeps its four controls.

- Branch popup: local branches ✓, Checkout Tag ▸, Checkout Remote Branch ▸ (creates local tracking branch), Checkout Commit… (detached), New Branch…, New Tag…, Edit Branches and Tags…
- Quick Checkout (⌘⇧C): type-to-find branch/tag switcher.
- Commit context menu: New Tag…, New Branch…, Merge, Cherry-pick, Apply as Patch, Checkout…, Revert Commit…, Reset Branch… (auto-stash dirty state first), Delete Tag.
- Tags: create/delete/push-with-branch; shown as badges on history rows and in commit detail; natural version sort.
- Stash: Stash Changes… (auto message from file names, includes untracked), Apply Stash ▸ list, Remove old stashes.
- Rebase conflict state: stage pane shows status + **Cancel / Skip / Continue Rebase** buttons (Gitbox's only "mode"). Merge conflicts stay minimal: conflicted files marked, resolve via external mergetool.
- Repo Settings sheet: Summary, Branches and Tags, Remotes tabs (add/remove remotes; delete local/remote branches).
- File ops on stage rows: Ignore File…, Revert File…, Delete File….

## Milestone 5 — Detail pane & app-shell polish

- Commit detail header: Commit SHA, clickable Parent SHA(s), Date, Author name/email + avatar (Gravatar, cached; graceful offline fallback), auto-linked URLs in messages.
- Commit message field: ⌘↑/⌘↓ browse previous messages from history; ⌘↩ commit; ⌘⇧↩ Stage All.
- Color labels: 7-color right-click picker on commits, colored corner marker on rows, persisted locally per repo (Gitbox's "visual bisect").
- Quick Look (space) on any file in any commit; drag files out; Extract File… (save a historical version).
- Keyboard pane navigation: ←/→ move focus across the three panes.
- File menu: Clone Repository… (URL, progress, remembers last URL), New Repository… (`git init` offer on non-repo folders), Open Repository…, Open Recent; drop folder on Dock icon.
- Repository menu: Open in Finder / Open in Terminal / Open Xcode Project; Optimize Repository (`git gc`).
- Activity window (⌘0): live list of git commands Gitpack runs + their output.
- Welcome window on first launch (Clone… / Open…).
- Window title: `folderName — parentFolderName`.

## Ordering rationale

M1 before M2 because badges/dots are defined by the comparison model. M3 (search) is self-contained and touches only history + a streaming parser. M4 is wide but each op is shallow (one `GitService` method + one menu item each, mostly). M5 is independent garnish and can be interleaved anywhere after M1. Each milestone ships a usable app; nothing blocks on a later milestone.

## Standing technical notes

- Every new operation goes through the `GitService` protocol (CLI backend, NUL-terminated parsing — see `ARCHITECTURE.md`).
- Parser tests (promised since v0.1) should land with M1 — the rev-list/ref parsing added there is exactly the fragile kind.
- History list moves to `NSTableView` at the start of M3 (see M3 first task) — no longer conditional. Elsewhere the rule is: SwiftUI by default; when a component fights back on layout, focus, or performance fundamentals, wrap the AppKit original instead of stacking workarounds (see ContentView's custom split dividers for the pattern).
