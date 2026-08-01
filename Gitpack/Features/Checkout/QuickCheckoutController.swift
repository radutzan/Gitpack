import AppKit

/// ⌘⇧C: type-to-find over every local branch, remote branch and tag, with the
/// keyboard alone. Arrow keys move the list while the field keeps focus, Return
/// checks out, Esc closes.
final class QuickCheckoutController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private enum Kind: String {
        case branch, remote, tag

        var label: String {
            switch self {
            case .branch: "branch"
            case .remote: "remote branch"
            case .tag: "tag"
            }
        }
    }

    private struct Ref {
        let name: String
        let kind: Kind
    }

    private let appState: AppState
    private lazy var actions = RepositoryActions(appState: appState)
    private let field = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// A snapshot: the sheet is up for a few seconds and a ref list that
    /// reshuffles under an arrow key is worse than a slightly stale one.
    private var all: [Ref] = []
    private var filtered: [Ref] = []

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("QuickCheckoutController is created in code")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 340))

        field.placeholderString = "Branch or tag"
        field.delegate = self
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(queryChanged)

        for identifier in ["name", "kind"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.resizingMask = identifier == "name" ? .autoresizingMask : []
            if identifier == "kind" { column.width = 96 }
            tableView.addTableColumn(column)
        }
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activate)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        for subview in [field, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),

            scrollView.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let vm = appState.selectedViewModel else { return }
        all = vm.branches.map { Ref(name: $0.name, kind: .branch) }
            + vm.tags.map { Ref(name: $0.name, kind: .tag) }
            + vm.remoteBranches.map { Ref(name: $0, kind: .remote) }
        applyFilter()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    // MARK: - Filtering

    @objc private func queryChanged() {
        applyFilter()
    }

    private func applyFilter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        filtered = query.isEmpty
            ? all
            : all.filter { $0.name.range(of: query, options: .caseInsensitive) != nil }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    // MARK: - Keyboard

    /// The field keeps focus while ↑/↓ drive the list — the whole point of a
    /// type-to-find switcher is never having to tab into the results.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            activate()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(nil)
        default:
            return false
        }
        return true
    }

    private func move(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let row = min(max(tableView.selectedRow + delta, 0), filtered.count - 1)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss(nil)
    }

    @objc private func activate() {
        let row = tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        let ref = filtered[row]
        dismiss(nil)
        switch ref.kind {
        case .branch: actions.checkout(ref.name)
        case .remote: actions.checkoutTracking(ref.name)
        case .tag: actions.checkoutDetached(ref.name)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? labelCell(identifier)
        let ref = filtered[row]
        if identifier.rawValue == "kind" {
            cell.textField?.stringValue = ref.kind.label
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .right
        } else {
            cell.textField?.stringValue = ref.name
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    private func labelCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
