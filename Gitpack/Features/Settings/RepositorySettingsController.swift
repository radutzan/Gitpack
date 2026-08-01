import AppKit

/// ⌘I / "Edit Branches and Tags…": a three-tab sheet over the selected repo.
///
/// An `NSTabView` rather than an `NSTabViewController` because the sheet needs a
/// Done button of its own — a tab view controller's view *is* the tab view, with
/// nowhere to put one.
final class RepositorySettingsController: NSViewController {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepositorySettingsController is created in code")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 400))

        let tabView = NSTabView()
        for (title, controller) in tabs() {
            addChild(controller)
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = controller.view
            tabView.addTabViewItem(item)
        }

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        for subview in [tabView, done] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            tabView.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),

            done.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 12),
            done.trailingAnchor.constraint(equalTo: tabView.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
    }

    private func tabs() -> [(String, NSViewController)] {
        let actions = RepositoryActions(appState: appState)

        let summary = SettingsListViewController { [weak self] in
            guard let vm = self?.appState.selectedViewModel else { return [] }
            return [
                .value("Name", vm.repository.displayName),
                .value("Location", vm.repository.url.path),
                .value("Current Branch", vm.currentBranch ?? "detached HEAD"),
                .value("Other Branch", vm.otherBranch ?? "—"),
                .value("Local Branches", "\(vm.branches.count)"),
                .value("Tags", "\(vm.tags.count)"),
                .value("Remotes", "\(vm.remotes.count)"),
                .value("Stashes", "\(vm.stashes.count)"),
            ]
        }

        let refs = SettingsListViewController { [weak self] in
            guard let vm = self?.appState.selectedViewModel else { return [] }
            typealias Row = SettingsListViewController.Row
            var rows: [Row] = []
            if !vm.branches.isEmpty {
                rows.append(.header("Local Branches"))
                rows += vm.branches.map { branch -> Row in
                    // The branch you're on can't be deleted, so it offers no button.
                    .value(branch.name, branch.upstream ?? "", delete: branch.isCurrent ? nil : {
                        actions.deleteBranch(branch.name)
                    })
                }
            }
            if !vm.remoteBranches.isEmpty {
                rows.append(.header("Remote Branches"))
                rows += vm.remoteBranches.map { name -> Row in
                    .value(name, "", delete: { actions.deleteRemoteBranch(name) })
                }
            }
            if !vm.tags.isEmpty {
                rows.append(.header("Tags"))
                rows += vm.tags.map { tag -> Row in
                    .value(tag.name, String(tag.targetSHA.prefix(7)), delete: { actions.deleteTag(tag.name) })
                }
            }
            return rows
        }

        let remotes = SettingsListViewController { [weak self] in
            guard let vm = self?.appState.selectedViewModel else { return [] }
            return vm.remotes.map { remote -> SettingsListViewController.Row in
                .value(remote.name, remote.url, delete: { actions.removeRemote(remote.name) })
            }
        }
        remotes.add = { actions.addRemote() }

        return [
            ("Summary", summary),
            ("Branches and Tags", refs),
            ("Remotes", remotes),
        ]
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    @objc private func close() {
        dismiss(nil)
    }
}

/// One list, three configurations: a label/value summary, the ref list, and the
/// remotes. Rows come from a closure re-run on every model change, so a delete
/// made here shows up without the sheet knowing what changed.
final class SettingsListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        let title: String
        let detail: String
        let isHeader: Bool
        let delete: (@MainActor () -> Void)?

        static func header(_ title: String) -> Row {
            Row(title: title, detail: "", isHeader: true, delete: nil)
        }

        static func value(_ title: String, _ detail: String, delete: (@MainActor () -> Void)? = nil) -> Row {
            Row(title: title, detail: detail, isHeader: false, delete: delete)
        }
    }

    /// Set to give the list a "+" button.
    var add: (@MainActor () -> Void)?

    private let rowsProvider: @MainActor () -> [Row]
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private var rows: [Row] = []

    init(rows: @escaping @MainActor () -> [Row]) {
        self.rowsProvider = rows
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsListViewController is created in code")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))

        for identifier in ["title", "detail"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.resizingMask = .autoresizingMask
            column.width = identifier == "title" ? 200 : 260
            tableView.addTableColumn(column)
        }
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        configure(addButton, symbol: "plus", action: #selector(addClicked))
        configure(removeButton, symbol: "minus", action: #selector(removeClicked))

        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        for subview in [scrollView, buttons] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),

            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChanges { [weak self] in
            self?.apply()
        }
    }

    private func apply() {
        // Re-selected by title afterwards: this runs on *any* model change,
        // including a background fetch landing, and a bare `reloadData` drops
        // the selection — which silently disables the − button under the cursor.
        let selected = rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow].title : nil
        rows = rowsProvider()
        tableView.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.title == selected }) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        }
        addButton.isHidden = add == nil
        updateButtons()
    }

    private func updateButtons() {
        let row = tableView.selectedRow
        removeButton.isEnabled = rows.indices.contains(row) && rows[row].delete != nil
    }

    @objc private func addClicked() {
        add?()
    }

    @objc private func removeClicked() {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        rows[row].delete?()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !rows[row].isHeader
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? labelCell(identifier)
        let entry = rows[row]
        let isDetail = identifier.rawValue == "detail"
        cell.textField?.stringValue = isDetail ? entry.detail : entry.title
        cell.textField?.font = entry.isHeader
            ? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            : NSFont.preferredFont(forTextStyle: .body)
        cell.textField?.textColor = isDetail || entry.isHeader ? .secondaryLabelColor : .labelColor
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
