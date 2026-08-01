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

        // A real sidebar item: vibrant material, and full-height layout so it
        // runs up behind the titlebar with the toolbar's tracking separator
        // sitting on the divider.
        let sidebar = NSSplitViewItem(sidebarWithViewController: SidebarViewController(appState: appState))
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

    /// Moves keyboard focus one pane left or right. The target is the pane's
    /// first table view, found by search rather than by a protocol every pane
    /// would have to conform to — and it lands on the file list rather than the
    /// commit composer, which is what you want when arrowing between panes.
    func focusPane(adjacentTo pane: NSViewController, offset: Int) {
        guard let index = splitViewItems.firstIndex(where: { $0.viewController === pane }) else { return }
        let target = index + offset
        guard splitViewItems.indices.contains(target),
              let responder = firstTableView(in: splitViewItems[target].viewController.view)
        else { return }
        view.window?.makeFirstResponder(responder)
    }

    private func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }
}
