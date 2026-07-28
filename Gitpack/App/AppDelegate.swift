import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let appState = AppState()
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
        NSApp.mainMenu = MainMenu.build()

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

    @objc func openInFinder(_ sender: Any?) {
        guard let url = appState.selectedRepository?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInTerminal(_ sender: Any?) {
        guard let url = appState.selectedRepository?.url else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // ponytail: these two still go through NotificationCenter because the
    // detail pane is still SwiftUI. Phase E moves them onto the responder
    // chain, where the focused pane validates and handles them directly.
    @objc func stageAll(_ sender: Any?) {
        NotificationCenter.default.post(name: .stageAllRequested, object: nil)
    }

    @objc func commitChanges(_ sender: Any?) {
        NotificationCenter.default.post(name: .commitRequested, object: nil)
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
        case #selector(stageAll(_:)), #selector(commitChanges(_:)):
            return !(vm?.status?.isClean ?? true)
        default:
            return true
        }
    }
}

extension Notification.Name {
    static let stageAllRequested = Notification.Name("Gitpack.stageAllRequested")
    static let commitRequested = Notification.Name("Gitpack.commitRequested")
}
