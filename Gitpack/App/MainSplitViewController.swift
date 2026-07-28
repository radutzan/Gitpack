import AppKit

/// The three-pane shell: sidebar | history | detail.
///
/// This replaces the hand-rolled `HStack` + drag-handle dividers that
/// `ContentView` used to carry. `NSSplitView.autosaveName` persists the widths,
/// so the `sidebarWidth`/`detailWidth` `UserDefaults` keys and the drag-end
/// write are gone with it.
final class MainSplitViewController: NSSplitViewController {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainSplitViewController is created in code")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.dividerStyle = .thin

        // Still a plain item, not `sidebarWithViewController:`. The outline view
        // draws its own `.sourceList` styling, and a sidebar item restores its
        // width through window state restoration rather than the split view's
        // autosave — which would leave this one divider behaving differently
        // from the other. Revisit only alongside `.fullSizeContentView`.
        let sidebar = NSSplitViewItem(viewController: SidebarViewController(appState: appState))
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 320
        sidebar.holdingPriority = NSLayoutConstraint.Priority(261)
        sidebar.canCollapse = false

        // History is the pane with the lowest holding priority, so it absorbs
        // window resize; the outer two keep the widths you gave them until
        // history hits its 320 floor.
        let history = NSSplitViewItem(viewController: HistoryViewController(appState: appState))
        history.minimumThickness = 320
        history.holdingPriority = NSLayoutConstraint.Priority(250)
        history.canCollapse = false

        let detail = NSSplitViewItem(viewController: DetailViewController(appState: appState))
        detail.minimumThickness = 320
        detail.holdingPriority = NSLayoutConstraint.Priority(260)
        detail.canCollapse = false

        addSplitViewItem(sidebar)
        addSplitViewItem(history)
        addSplitViewItem(detail)

        // Set last, on purpose: assigning `autosaveName` before the items exist
        // makes AppKit restore into an empty split view and then stop recording
        // divider drags — widths come back on launch but every resize is lost.
        splitView.autosaveName = "MainSplit"
    }
}
