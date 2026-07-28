# AppKit UI Migration Plan

> **For Claude:** Phases are independent and each ships a working app. Do not start a
> later phase until the previous one builds, launches, and has been verified with the
> `axprobe` skill (accessibility-tree inspection — no screen recording permission needed).

**Goal:** Replace the SwiftUI UI layer with AppKit, keeping `Git/`, `Persistence/`,
`DiffTool/`, `Shared/`, and the `AppState`/`RepositoryViewModel` logic untouched.

**Architecture:** AppKit owns the shell (`NSApplicationDelegate` → `NSWindowController` →
`NSSplitViewController` → `NSToolbar` → `NSMenu`). Panes migrate one at a time; until a
pane is migrated it stays as SwiftUI inside an `NSHostingController`. The inverse
(SwiftUI shell hosting `NSViewRepresentable` leaves) is explicitly rejected — that bridge
direction produced both recorded layout failures (`NavigationSplitView`, `HSplitView`).

**Tech stack:** AppKit, Swift 6 `@Observable` (kept — bridged to AppKit via a re-arming
`withObservationTracking` helper), no dependencies, no test target.

**Why:** The remaining roadmap (M3 search, M4 menus, M5 Quick Look / drag-out / focus
navigation) is concentrated in exactly the areas where SwiftUI-on-macOS is weakest:
table streaming, menu validation, responder chain, focus, drag & drop. The history list
was already committed to `NSTableView` at the start of M3. See `ARCHITECTURE.md`.

**Verification model:** There is no UI test target and none is being added. Each phase
ends with: `xcodebuild … build` succeeds, app launches, and an `axprobe` pass confirming
the pane tree, row counts, and that a representative action still works. Parser tests
(`./Tests/run-tests.sh`) must keep passing — they never touch UI.

---

## Phase A — AppKit shell (panes still SwiftUI)

**Outcome:** `NSWindow` + `NSSplitViewController` + `NSToolbar` + `NSMenu`, with the three
existing SwiftUI panes hosted unchanged. Deletes the hand-rolled splitter and its manual
width persistence.

**Files:**
- Create: `Gitpack/App/AppDelegate.swift`
- Create: `Gitpack/App/MainMenu.swift`
- Create: `Gitpack/App/MainWindowController.swift`
- Create: `Gitpack/App/MainSplitViewController.swift`
- Create: `Gitpack/Shared/Observation+AppKit.swift`
- Rewrite: `Gitpack/Features/Toolbar/MainToolbar.swift` (SwiftUI `ToolbarContent` → `NSToolbarDelegate`)
- Move: `Gitpack/AppState.swift` → `Gitpack/App/AppState.swift` (matches `ARCHITECTURE.md`'s documented layout)
- Delete: `Gitpack/GitpackApp.swift`, `Gitpack/ContentView.swift`
- Modify: `Gitpack/Features/Sidebar/RepositorySidebar.swift` (drop the `.addRepositoryRequested` receiver and its `NSOpenPanel`; that moves to `AppDelegate`)

**Tasks:**

1. **Observation bridge.** `Shared/Observation+AppKit.swift`: a `@MainActor` free function
   `observeChanges(_ body:)` that runs `body` inside `withObservationTracking` and re-arms
   itself on `onChange` via `Task { @MainActor in … }` (the change callback fires *before*
   the mutation lands, so re-reading must be deferred a turn). App-lifetime observers only
   — mark the missing cancellation with a `// ponytail:` comment naming the ceiling.

2. **Split view.** `MainSplitViewController` builds three `NSSplitViewItem`s wrapping
   `NSHostingController`s for `RepositorySidebar`, `HistoryList`, `DetailPane`, each with
   `.environment(appState)` and `sizingOptions = []` (a hosting controller that publishes
   its content size fights the split view's layout).
   - sidebar: `NSSplitViewItem(sidebarWithViewController:)`, min 180 / max 320, holding priority 261
   - history: min 320, holding priority 250 — this is the pane that absorbs window resize
   - detail: min 320, holding priority 260
   - `splitView.autosaveName = "MainSplit"` replaces the `sidebarWidth`/`detailWidth`
     `UserDefaults` keys entirely.

3. **Toolbar.** `MainToolbar` becomes an `NSObject & NSToolbarDelegate`:
   - `.addRepository` — plain item, `target: nil` + `action: #selector(AppDelegate.addRepository(_:))` so it routes through the responder chain
   - `.branchPicker`, `.otherBranchPicker` — `NSMenuToolbarItem`, menus built lazily in
     `menuNeedsUpdate(_:)` (no observation needed: the menu can't be stale, it's built on click)
   - `.syncControls` — `NSSegmentedControl`, two segments (pull/push) collapsing to one
     (merge) when the other branch is local; labels morph from a
     `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)` monitor
   - `toolbar.centeredItemIdentifiers` centers the three-control cluster
   - Titles/enablement refresh through `observeChanges`.
   - **Dropped:** the disabled `gearshape` "Settings" placeholder — it has no action.

4. **Menus.** `MainMenu.swift` builds the full menu bar programmatically. All actions use
   `target: nil` so `AppDelegate`'s `validateMenuItem(_:)` drives enablement off the
   responder chain — this is what replaces SwiftUI's `.disabled(…)` recomputation.
   - App menu, **Edit menu** (undo/redo/cut/copy/paste/select-all — SwiftUI supplied these
     for free; omitting them breaks ⌘C/⌘V in the commit composer)
   - File: Add Repository… ⌘O
   - Repository: Pull/Merge ⌘U (title swaps in `validateMenuItem`), Push ⌘P, Fetch ⌥⌘U,
     Rebase ⇧⌘U, Force Push ⇧⌘P, Open in Finder, Open in Terminal
   - Stage: Stage All ⇧⌘↩, Commit ⌘↩ (still posts `NotificationCenter` — the SwiftUI detail
     pane is the receiver until Phase C)
   - Window, Help

5. **App lifecycle.** `AppDelegate` is `@main`. It owns `AppState`, installs the menu,
   shows the window, starts autofetch, implements `applicationDidBecomeActive(_:)` →
   `foregroundRefresh()` (replacing `ContentView`'s `NotificationCenter` async sequence),
   and observes `selectedRepositoryID` to run `refreshAll` + re-target the file watcher
   (replacing `ContentView`'s `.task(id:)`). Owns the `NSOpenPanel` for Add Repository.

6. **Verify:** build; launch; `axprobe` the window — three panes present, sidebar rows
   equal to repo count, toolbar shows branch/sync/other-branch, ⌘O opens the panel,
   dragging a divider and relaunching restores widths.

7. **Commit:** `refactor: AppKit shell — NSSplitViewController, NSToolbar, NSMenu`

**Two things this phase learned the hard way (both now `CLAUDE.md` entries):**
`@main` on the delegate alone launches to a default menu bar and no window — the
`NSApplicationDelegate` default `main()` goes through `NSApplicationMain`, which expects a
nib to instantiate the delegate, so `AppDelegate` declares its own `static func main()`.
And `splitView.autosaveName` must be assigned *after* the split view items are added:
set before, widths restore on launch but drags are never recorded.

---

## Phase B — History pane → `NSTableView`

**Outcome:** The history list is a real `NSTableView`. This is M3's already-decided first
task, done early so search is built once on the real control.

**Files:**
- Rewrite: `Gitpack/Features/History/HistoryList.swift` → `HistoryViewController.swift`
- Create: `Gitpack/Features/History/CommitRowView.swift` (`NSTableCellView` subclass)
- Modify: `Gitpack/App/MainSplitViewController.swift` (swap the hosting controller)

**Tasks:**

1. View-based `NSTableView`, single column, `rowHeight = 45` (41pt content + 2pt vertical
   padding, matching today). **Keep it a fixed `rowHeight`, not
   `usesAutomaticRowHeights`** — the divergence between estimated and measured heights is
   what blanked the pane before, and a uniform-height table is also the precondition for
   M3's 10k-row streaming.
2. `CommitRowView`: marker dot (`NSView` with a layer background), author `NSTextField`,
   right-aligned date, subject line. Italic/faded via `NSFont` traits and `alphaValue`
   for merge + unmerged commits. Port the colors and `markerHelp` tooltips verbatim.
3. Row 0 is the working-copy pseudo-row (`HistoryItem.workingCopy`); reuse the same cell
   with the summary/subtitle strings — those functions port unchanged from
   `HistoryListContent`.
4. Selection: `tableViewSelectionDidChange` → `vm.selection`. The `refreshAll` conditional
   assignment (`if fresh != commits`) stays load-bearing — assigning unconditionally
   rebuilds the table mid-click.
5. `keyDown(with:)` on the table view for the bare-key `u`/`p` shortcuts (replaces
   `.onKeyPress`), falling through to `super` for everything else so type-select still works.
6. "Load more commits" stays as a trailing row.
7. Error banner → a small `NSView` overlay pinned to the top, or fold it into Phase E.
8. **Verify:** build, launch, `axprobe` row count matches `vm.commits.count + 1`; arrow-key
   navigation changes the detail pane; scroll to the bottom of a long history without blanking.
9. **Commit:** `refactor: history list on NSTableView`

**What this phase actually needed beyond the sketch above.** Two behaviours fall out of
reloading an `NSTableView` that SwiftUI's `List` handled implicitly, and both are now
`CLAUDE.md` entries: the scroll offset must be captured and restored around `reloadData()`,
and the selection must be re-applied *without* scrolling — otherwise clicking "Load more"
appends 200 rows and throws you back to the top. `RepositoryViewModel.hasMoreHistory`
became `private(set)` so the paging row keys off the real answer instead of
`commits.count >= 200`, which never goes false once you've paged past the first screen.
Dropped: `.refreshable` pull-to-refresh (not a Mac idiom; ⌘R can land in M5 if wanted).

---

## Phase C — Detail pane → `NSViewController`

**Outcome:** The largest chunk. Working-copy and commit detail become AppKit view
controllers; the commit composer becomes an `NSTextView`.

**Files:**
- Rewrite: `Gitpack/Features/Detail/DetailPane.swift` → `DetailViewController.swift` (child-VC swapping)
- Rewrite: `Gitpack/Features/Detail/WorkingCopyDetail.swift` → `WorkingCopyViewController.swift`
- Rewrite: `Gitpack/Features/Detail/CommitDetail.swift` → `CommitViewController.swift`
- Rewrite: `Gitpack/Features/Detail/FileRowView.swift` → `NSTableCellView` subclass
- Modify: `Gitpack/App/MainSplitViewController.swift`

**Tasks:**

1. `DetailViewController` swaps child view controllers on `vm.selection` via
   `observeChanges`. No cross-fade; `addChild` + `view` swap.
2. **Commit composer:** `NSTextView` in an `NSScrollView`, with a `Commit` button row.
   Grow-on-focus behaviour reproduced by animating a height constraint in
   `NSAnimationContext` (this is the one place AppKit costs more than SwiftUI).
   `NSTextViewDelegate.textDidChange` drives `appState.opportunisticFetch()`.
   This also unblocks M5's ⌘↑/⌘↓ message history, which the SwiftUI `TextField` could not do.
3. **File lists:** `NSTableView` with a checkbox column (`NSButton` checkbox in the cell)
   for the working copy, no checkbox for commit detail. Double-click → `openDiff`
   (`doubleAction`), `keyDown` for `s`/`d`.
4. **Context menus:** one `NSMenu` per table with `menuNeedsUpdate(_:)` building items from
   `tableView.clickedRow` + selection. This replaces
   `.contextMenu(forSelectionType:)` and finally makes right-click-on-unselected-row behave
   natively. `stage`/`unstage`/`discard`/`reveal`/`copyPath`/`openDiff` port verbatim —
   they are already plain Swift calling `NSAlert`/`NSWorkspace`/`NSPasteboard`.
5. **Commit header:** `NSGridView` for the label/value rows (`Commit:`, `Parent:`, `Date:`,
   `Author:`), selectable `NSTextField`s. Message body in a non-editable `NSTextView`.
   **This fixes a live bug:** today's `CommitDetail` puts `.fixedSize(horizontal: false,
   vertical: true)` on the header+message block, so a commit with a long body pushes the
   file list clean off the bottom of the pane — measured during Phase A verification, a
   23-file commit's list landed ~200pt below the window edge, while a one-line commit's fit
   exactly. Pre-dates the migration (it is a property of the view, not its container).
   The `NSTextView` must scroll its own body rather than grow the pane.
6. **Verify:** build, launch, `axprobe` — stage/unstage toggles a checkbox and the row's
   status text, ⌘↩ commits, selecting a commit lists its files.
7. **Commit:** `refactor: detail pane on AppKit view controllers`

**Done differently from the sketch, and why.** The `NotificationCenter` shims (Phase E's
task 1) went away here instead: moving the commit draft onto
`RepositoryViewModel.commitMessage` turns Commit and Stage All into pure model operations
on `AppState`, so they need no view at all. That is *better* than routing them through the
responder chain, which would have made ⌘↩ work only while the detail pane held focus. The
message body is a wrapping `NSTextField` in a scroll view rather than an `NSTextView` —
the label has a real intrinsic height, which is what lets it grow to fit and cap at 220pt.
Two traps banked in `CLAUDE.md`: a separator `NSBox` needs an explicit 1pt height or it
absorbs the pane, and hidden views keep their constraints in AppKit (so the message box
also needs pinning to zero when empty). Dropped: the ⌘↩-focuses-the-composer fallback
(the menu item is simply disabled until a commit is possible) and the accent-coloured
author email (now plain `Name <email>`).

---

## Phase D — Sidebar → `NSOutlineView`

**Outcome:** Source-list sidebar; M2's outstanding drag-reorder falls out of the API.

**Files:**
- Rewrite: `Gitpack/Features/Sidebar/RepositorySidebar.swift` → `SidebarViewController.swift`
- Modify: `Gitpack/App/MainSplitViewController.swift`

**Tasks:**

1. `NSOutlineView`, `.sourceList` style, one root group row ("Repositories"), children from
   `appState.repositories` with the existing `parentID` nesting.
2. Cell: folder icon, name, fetch `NSProgressIndicator` (spinner), badge `NSTextField` in a
   rounded background. Badge and spinner update through `observeChanges` on the repo's
   `RepoBackgroundState`.
3. Selection → `appState.selectedRepositoryID`.
4. Folder drop: `registerForDraggedTypes([.fileURL])` + `validateDrop`/`acceptDrop` →
   `appState.addRepository(at:)`.
5. **Drag-reorder** (closes an M2 item): `pasteboardWriterForItem` + `acceptDrop` reordering
   `store.repositories`. Persist through `RepositoryStore`.
6. Context menu: Reveal in Finder / Refresh / Remove.
7. **Verify:** build, launch, `axprobe` — row count, selection drives the other two panes,
   dropping a folder adds a repo, reorder survives relaunch.
8. **Commit:** `feat: sidebar on NSOutlineView with drag-reorder`

**The prerequisite the sketch missed.** `RepositoryStore` was not `@Observable`, and
`AppState.repositories` is a computed passthrough to its array — so the repository list was
invisible to observation. The SwiftUI sidebar only ever refreshed because add/remove also
assigned `selectedRepositoryID`; removing a repository that wasn't selected left a stale
row on screen. Making the store `@Observable` is what lets `observeChanges` drive this
pane at all. Two more findings, both in `CLAUDE.md`: observable state has to be read up
front in the observation body rather than inside a loop over materialized cells (right
after `reloadData` there are none, so no dependency is registered and badges never
appear), and the single group row needs `shouldCollapseItem` → `false` or clicking it
blanks the sidebar. The split view keeps a plain item rather than
`sidebarWithViewController:` — the outline draws its own `.sourceList` styling, and a
sidebar item restores its width through window state restoration instead of the split
view's autosave.

---

## Phase E — Remove the shims

**Outcome:** No SwiftUI left in the target; the responder chain does what
`NotificationCenter` was doing.

**Files:**
- Modify: `Gitpack/App/MainMenu.swift`, `Gitpack/App/AppDelegate.swift`,
  `Gitpack/Features/Detail/WorkingCopyViewController.swift`
- Delete: the `Notification.Name` extension (`.stageAllRequested`, `.commitRequested`,
  `.addRepositoryRequested`)
- Modify: `ARCHITECTURE.md`, `CLAUDE.md`, `docs/plans/2026-07-06-gitbox-replica-roadmap.md`

**Tasks:**

1. ~~Stage All / Commit off `NotificationCenter`~~ — **done in phase C**, as model
   operations on `AppState` rather than responder-chain actions, so they work from any pane.
2. ~~Delete the notification names~~ — **done in phase C**.
3. ~~Grep for `import SwiftUI` across `Gitpack/`~~ — **done in phase D**; zero hits, and
   `MainSplitViewController`'s hosting-controller helper is gone with it.
4. Add ←/→ pane focus navigation (`makeFirstResponder` across the three panes) — an M5
   item that is now nearly free. Both key views route arrows through
   `NSViewController.movePaneFocus(for:)`; the target pane's first `NSTableView` is found
   by search, so no pane has to conform to anything. **Trap:** "unmodified keypress" cannot
   mean `deviceIndependentFlagsMask.isEmpty` — the arrow keys always carry `.function` and
   `.numericPad`, so that test silently swallowed every one of them. Check only for the
   modifiers a user actually holds, which also leaves ⇧← extending a selection.
5. Update the docs: `ARCHITECTURE.md`'s module layout and concurrency section, `CLAUDE.md`'s
   "AppKit escape hatch" convention (now "AppKit, full stop") and the SwiftUI-specific traps
   (fixed row heights and the conditional `refreshAll` assignment both still apply and must
   stay documented — they are `NSTableView` facts, not SwiftUI ones). Mark M3's first task done.
6. **Verify:** build, `./Tests/run-tests.sh`, launch, full `axprobe` pass over all three panes.
7. **Commit:** `refactor: drop NotificationCenter shims and the last SwiftUI imports`

---

## Standing notes

- `Git/`, `Persistence/`, `DiffTool/`, `Shared/Formatters.swift` and `Tests/` are not
  touched by any phase. `Models.swift`/`Parsers.swift`/`FileSystemWatcher.swift` must stay
  Foundation-only — `run-tests.sh` compiles them standalone.
- `AppState` and `RepositoryViewModel` keep `@Observable`. No Combine, no KVO, no rewrite of
  the state layer — only the read side changes, via `observeChanges`.
- The Xcode target uses `PBXFileSystemSynchronizedRootGroup`: new and moved files under
  `Gitpack/` are picked up automatically. Never edit `project.pbxproj`.
- Two traps survive the migration verbatim and must not be "cleaned up": fixed history row
  heights, and `refreshAll`'s conditional assignment.
</content>
</invoke>
