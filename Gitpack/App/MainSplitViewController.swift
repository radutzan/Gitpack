import AppKit
import SwiftUI

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

        // A plain item, not `sidebarWithViewController:` — the SwiftUI pane
        // already draws its own sidebar chrome, and the sidebar item's width
        // restoration runs through window state restoration rather than the
        // split view's autosave, which would leave this one divider behaving
        // differently from the other. Phase D takes the sidebar item when the
        // pane becomes a real NSOutlineView.
        let sidebar = NSSplitViewItem(viewController: pane(RepositorySidebar()))
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 320
        sidebar.holdingPriority = NSLayoutConstraint.Priority(261)
        sidebar.canCollapse = false

        // History is the pane with the lowest holding priority, so it absorbs
        // window resize; the outer two keep the widths you gave them until
        // history hits its 320 floor.
        let history = NSSplitViewItem(viewController: pane(HistoryList()))
        history.minimumThickness = 320
        history.holdingPriority = NSLayoutConstraint.Priority(250)
        history.canCollapse = false

        let detail = NSSplitViewItem(viewController: pane(DetailPane()))
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

    /// ponytail: panes stay SwiftUI-in-a-hosting-controller until their phase
    /// migrates them (history → B, detail → C, sidebar → D). `sizingOptions`
    /// is emptied because a hosting controller that publishes its content size
    /// fights the split view for the width.
    private func pane(_ view: some View) -> NSViewController {
        let controller = NSHostingController(rootView: view.environment(appState))
        controller.sizingOptions = []
        return controller
    }
}
