import AppKit

/// The right pane. Swaps between the working-copy and commit children as the
/// history selection moves. Both children read their own state from
/// `AppState`, so a repository switch needs no rebuilding here — only a change
/// of *kind* swaps a child.
final class DetailViewController: NSViewController {
    private enum Pane: Equatable {
        case blank
        case prompt
        case workingCopy
        case commit
    }

    private let appState: AppState
    private lazy var workingCopy = WorkingCopyViewController(appState: appState)
    private lazy var commit = CommitViewController(appState: appState)
    private lazy var promptView = placeholder("Select an item")
    private lazy var blankView = NSView()

    private var pane: Pane?
    private var child: NSViewController?

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DetailViewController is created in code")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChanges { [weak self] in
            self?.apply()
        }
    }

    private func apply() {
        let target: Pane
        if let vm = appState.selectedViewModel {
            switch vm.selection {
            case .workingCopy: target = .workingCopy
            case .commit: target = .commit
            case nil: target = .prompt
            }
        } else {
            target = .blank
        }
        guard target != pane else { return }
        pane = target
        show(target)
    }

    private func show(_ target: Pane) {
        if let child {
            child.view.removeFromSuperview()
            child.removeFromParent()
            self.child = nil
        }
        view.subviews.forEach { $0.removeFromSuperview() }

        let content: NSView
        switch target {
        case .workingCopy:
            addChild(workingCopy)
            child = workingCopy
            content = workingCopy.view
        case .commit:
            addChild(self.commit)
            child = self.commit
            content = self.commit.view
        case .prompt:
            content = promptView
        case .blank:
            content = blankView
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Safe area, not the view's top: the window is full-size-content so
            // the sidebar can run behind the titlebar, and this pane's header
            // would slide under the toolbar with it.
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func placeholder(_ text: String) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}
