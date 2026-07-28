import AppKit

final class MainWindowController: NSWindowController {
    private let appState: AppState
    private let mainToolbar: MainToolbar

    init(appState: AppState) {
        self.appState = appState
        self.mainToolbar = MainToolbar(appState: appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 900, height: 500)
        // The centred toolbar cluster occupies the title row, exactly as the
        // SwiftUI principal item did. The title is still set below — the Window
        // menu and Mission Control read it.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.contentViewController = MainSplitViewController(appState: appState)
        window.toolbar = mainToolbar.toolbar

        super.init(window: window)

        _ = window.setFrameAutosaveName("MainWindow")
        observeChanges { [weak self] in
            self?.updateTitle()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code")
    }

    private func updateTitle() {
        guard let window else { return }
        guard let repo = appState.selectedRepository else {
            window.title = "Gitpack"
            window.subtitle = ""
            return
        }
        window.title = repo.displayName
        window.subtitle = repo.url.deletingLastPathComponent().lastPathComponent
    }
}
