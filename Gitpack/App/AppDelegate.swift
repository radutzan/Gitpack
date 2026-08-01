import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let appState = AppState()
    private lazy var actions = RepositoryActions(appState: appState)
    private var windowController: MainWindowController?
    private var loadTask: Task<Void, Never>?

    /// Spelled out rather than inherited from `NSApplicationDelegate`: the
    /// default goes through `NSApplicationMain`, which expects the main nib to
    /// instantiate the delegate. Gitpack has no nib — the menu bar is built in
    /// `MainMenu.swift` — so the delegate would never be installed and the app
    /// would launch to a bare default menu bar and no window.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(stashDelegate: self)

        let controller = MainWindowController(appState: appState)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate()

        appState.startAutofetch()
        observeSelection()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Safety net for anything coalesced or missed while the app was inactive.
    /// Replaces `ContentView`'s `didBecomeActiveNotification` async sequence —
    /// the delegate callback is the same signal, one hop shorter.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await appState.foregroundRefresh() }
    }

    /// Replaces `ContentView`'s `.task(id: selectedRepositoryID)`: load the
    /// newly selected repo, then re-target the file watcher at it.
    private func observeSelection() {
        observeChanges { [weak self] in
            guard let self else { return }
            let id = appState.selectedRepositoryID
            loadTask?.cancel()
            guard id != nil else { return }
            loadTask = Task { [weak self] in
                guard let self else { return }
                await appState.selectedViewModel?.refreshAll(using: appState.git)
                appState.startWatchingSelectedRepository()
            }
        }
    }

    // MARK: - Actions

    @objc func addRepository(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more Git repositories"
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls {
                _ = await appState.addRepository(at: url)
            }
        }
    }

    @objc func pullOrMerge(_ sender: Any?) {
        sync(appState.selectedViewModel?.otherBranchIsLocal == true ? .merge : .pull)
    }

    @objc func push(_ sender: Any?) { sync(.push) }
    @objc func fetch(_ sender: Any?) { sync(.fetch) }
    @objc func rebase(_ sender: Any?) { sync(.rebase) }
    @objc func forcePush(_ sender: Any?) { sync(.forcePush) }

    private func sync(_ action: SyncAction) {
        guard let vm = appState.selectedViewModel else { return }
        Task { await vm.performSync(action, using: appState.git) }
    }

    /// ⌘F. The search field lives in the toolbar; the query itself lives on the
    /// view model, so this only has to move focus.
    @objc func findInHistory(_ sender: Any?) {
        windowController?.beginSearch()
    }

    /// ⌘⇧C and ⌘I: both are windows of their own, so the window controller owns
    /// them; everything else here is a model operation.
    @objc func quickCheckout(_ sender: Any?) {
        windowController?.showQuickCheckout()
    }

    @objc func showRepositorySettings(_ sender: Any?) {
        windowController?.showRepositorySettings()
    }

    @objc func newBranch(_ sender: Any?) { actions.newBranch(from: "HEAD") }
    @objc func newTag(_ sender: Any?) { actions.newTag(at: "HEAD") }
    @objc func stashChanges(_ sender: Any?) { actions.stashChanges() }
    @objc func removeStashes(_ sender: Any?) { actions.removeStashes() }

    @objc func applyStash(_ sender: NSMenuItem) {
        guard let stash = sender.representedObject as? Stash else { return }
        actions.applyStash(stash)
    }

    /// The Apply Stash submenu, rebuilt each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let stashes = appState.selectedViewModel?.stashes ?? []
        guard !stashes.isEmpty else {
            menu.addItem(withTitle: "No Stashes", action: nil, keyEquivalent: "")
            return
        }
        for stash in stashes {
            let item = NSMenuItem(title: stash.message, action: #selector(applyStash(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = stash
            item.toolTip = "\(stash.ref) — \(stash.date.formatted(DateFormat.commitTimestamp))"
            menu.addItem(item)
        }
    }

    @objc func openInFinder(_ sender: Any?) {
        guard let url = appState.selectedRepository?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInTerminal(_ sender: Any?) {
        guard let url = appState.selectedRepository?.url else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // Both are pure model operations (the draft message lives on the view
    // model), so they work from any pane rather than only when the detail
    // pane holds focus — which is what routing them through the responder
    // chain to the composer would have cost.
    @objc func stageAll(_ sender: Any?) {
        guard let vm = appState.selectedViewModel else { return }
        Task { await appState.stageAll(vm) }
    }

    @objc func commitChanges(_ sender: Any?) {
        guard let vm = appState.selectedViewModel else { return }
        Task { await appState.commit(vm) }
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let vm = appState.selectedViewModel
        let hasOther = vm?.otherBranch != nil
        let otherIsLocal = vm?.otherBranchIsLocal == true
        let busy = vm?.isSyncing == true

        switch menuItem.action {
        case #selector(pullOrMerge(_:)):
            menuItem.title = otherIsLocal ? "Merge" : "Pull"
            return hasOther && !busy
        case #selector(push(_:)), #selector(rebase(_:)), #selector(forcePush(_:)):
            return hasOther && !otherIsLocal && !busy
        case #selector(fetch(_:)):
            return vm != nil && !busy
        case #selector(openInFinder(_:)), #selector(openInTerminal(_:)):
            return appState.selectedRepository != nil
        case #selector(findInHistory(_:)), #selector(quickCheckout(_:)),
             #selector(showRepositorySettings(_:)), #selector(newBranch(_:)), #selector(newTag(_:)):
            return vm != nil
        case #selector(stashChanges(_:)):
            return vm?.status.map { !$0.isClean } ?? false
        case #selector(removeStashes(_:)):
            return !(vm?.stashes.isEmpty ?? true)
        case #selector(stageAll(_:)):
            return !(vm?.unstagedPaths.isEmpty ?? true)
        case #selector(commitChanges(_:)):
            return vm?.canCommit == true
        default:
            return true
        }
    }
}
