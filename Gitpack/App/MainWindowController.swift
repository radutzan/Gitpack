import AppKit

final class MainWindowController: NSWindowController {
    private let appState: AppState
    private let mainToolbar: MainToolbar

    init(appState: AppState) {
        self.appState = appState
        // Built before the window so the toolbar's tracking separator can bind
        // to the split view that owns the sidebar divider.
        let split = MainSplitViewController(appState: appState)
        self.mainToolbar = MainToolbar(appState: appState, splitView: split.splitView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            // `.fullSizeContentView` is what lets the sidebar item run its
            // material up behind the titlebar; without it the sidebar stops at
            // the toolbar and only the divider separator lines up.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 900, height: 500)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.contentViewController = split
        // Assigning the content view controller resizes the window to fit it,
        // and the split view fits at nothing. The autosaved frame is only
        // restored below, so without this the toolbar lays out once against a
        // collapsed window and spills every item into the overflow menu.
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.toolbar = mainToolbar.toolbar

        // Content scrolls under the titlebar now that the window is full-size
        // content, so the title needs a hard (opaque) scroll edge effect rather
        // than the default fade. A zero-height accessory is only there to carry
        // the preference — AppKit has no window- or toolbar-level setter.
        if #available(macOS 26.1, *) {
            let edge = NSTitlebarAccessoryViewController()
            edge.layoutAttribute = .bottom
            edge.automaticallyAdjustsSize = false
            edge.view = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
            edge.preferredScrollEdgeEffectStyle = .hard
            window.addTitlebarAccessoryViewController(edge)
        }

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

    /// ⌘F, routed from `AppDelegate` — the toolbar owns the search field.
    func beginSearch() {
        mainToolbar.beginSearch()
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
