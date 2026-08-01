import AppKit

/// Commit metadata header, message body, and the files the commit touched.
final class CommitViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let appState: AppState

    private let shaField = monospacedValueField()
    private let parentField = monospacedValueField()
    private let dateField = valueField()
    private let authorField = valueField()
    private var parentRow: NSGridRow!

    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let messageScroll = NSScrollView()
    private var messageFitHeight: NSLayoutConstraint!
    private var messageZeroHeight: NSLayoutConstraint!
    private let messageDivider = NSBox()

    private let tableView = KeyTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No file changes")

    private var files: [CommitFileChange] = []
    private var loadedSHA: String?
    private var menuTargets: [CommitFileChange] = []

    private var vm: RepositoryViewModel? { appState.selectedViewModel }

    private var commit: Commit? {
        guard let vm, case .commit(let sha) = vm.selection else { return nil }
        // Not `vm.commits`: a search result can sit far deeper than the loaded
        // page, and selecting one has to fill this pane all the same.
        return vm.commit(withID: sha)
    }

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CommitViewController is created in code")
    }

    // MARK: - Layout

    override func loadView() {
        view = NSView()

        let header = buildHeader()
        buildMessage()
        buildTable()

        let headerDivider = NSBox()
        headerDivider.boxType = .separator
        messageDivider.boxType = .separator

        for subview in [header, headerDivider, messageScroll, messageDivider, scrollView, emptyLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        // The message box grows to fit its text but stops at `maxHeight` and
        // scrolls past that. The SwiftUI version used `.fixedSize(vertical:)`,
        // which refused to compress, so a long commit body pushed the file list
        // clean off the bottom of the pane.
        messageFitHeight = messageScroll.heightAnchor.constraint(equalTo: messageField.heightAnchor)
        messageFitHeight.priority = .defaultHigh
        messageZeroHeight = messageScroll.heightAnchor.constraint(equalToConstant: 0)

        let fileFloor = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        fileFloor.priority = .defaultHigh

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),

            headerDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            // A separator NSBox has no intrinsic height; unpinned it absorbs
            // the pane and squeezes everything below it to nothing.
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            messageScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            messageScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            messageScroll.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 10),
            messageScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 220),
            messageFitHeight,

            messageDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageDivider.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 10),
            messageDivider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: messageDivider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            fileFloor,

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    private func buildHeader() -> NSView {
        let grid = NSGridView(views: [
            [label("Commit"), shaField],
            [label("Parent"), parentField],
            [label("Date"), dateField],
            [label("Author"), authorField],
        ])
        grid.rowSpacing = 3
        grid.columnSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 60
        parentRow = grid.row(at: 1)

        parentField.textColor = .controlAccentColor

        let avatar = NSImageView()
        avatar.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        avatar.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        avatar.contentTintColor = .tertiaryLabelColor
        avatar.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.setViews([grid], in: .leading)
        row.setViews([avatar], in: .trailing)
        return row
    }

    private func buildMessage() {
        messageField.font = NSFont.preferredFont(forTextStyle: .body)
        messageField.isSelectable = true
        messageField.translatesAutoresizingMaskIntoConstraints = false

        messageScroll.documentView = messageField
        messageScroll.drawsBackground = false
        messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true

        NSLayoutConstraint.activate([
            messageField.topAnchor.constraint(equalTo: messageScroll.contentView.topAnchor),
            messageField.leadingAnchor.constraint(equalTo: messageScroll.contentView.leadingAnchor),
            // Pinning the width to the clip view is what makes the label wrap at
            // the pane's width, which is what gives it a real intrinsic height.
            messageField.widthAnchor.constraint(equalTo: messageScroll.contentView.widthAnchor),
        ])
    }

    private func buildTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.onBareKey = { [weak self] key in self?.movePaneFocus(for: key) ?? false }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        emptyLabel.font = NSFont.preferredFont(forTextStyle: .callout)
        emptyLabel.textColor = .secondaryLabelColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChanges { [weak self] in
            self?.apply()
        }
    }

    // MARK: - Model → views

    private func apply() {
        guard let vm, let commit else { return }

        shaField.stringValue = commit.id
        parentRow.isHidden = commit.parents.isEmpty
        parentField.stringValue = commit.parents.joined(separator: " ")
        dateField.stringValue = commit.date.formatted(DateFormat.commitDetailTimestamp)
        authorField.stringValue = "\(commit.authorName) <\(commit.authorEmail)>"

        let body = commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = body.isEmpty ? commit.subject : commit.subject + "\n\n" + body
        messageField.setText(
            message,
            tokens: vm.searchTokens,
            font: NSFont.preferredFont(forTextStyle: .body),
            color: .labelColor
        )
        let hasMessage = !message.isEmpty
        messageScroll.isHidden = !hasMessage
        messageDivider.isHidden = !hasMessage
        // Hidden views keep their constraints in AppKit, so the box has to be
        // pinned to zero as well or it still reserves its height.
        messageZeroHeight.isActive = !hasMessage

        if loadedSHA != commit.id {
            loadedSHA = commit.id
            files = []
            tableView.reloadData()
            Task { await vm.loadFilesForCommit(commit.id, using: appState.git) }
        }

        let fresh = vm.commitFiles[commit.id] ?? []
        if fresh != files {
            files = fresh
            tableView.reloadData()
        }
        emptyLabel.isHidden = !files.isEmpty
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = files[row]
        let cell = (tableView.makeView(withIdentifier: FileRowView.identifier, owner: self) as? FileRowView)
            ?? {
                let new = FileRowView()
                new.identifier = FileRowView.identifier
                return new
            }()
        cell.configure(
            path: file.path,
            oldPath: file.oldPath,
            statusLabel: file.status.label,
            staged: nil,
            tokens: vm?.searchTokens ?? []
        )
        return cell
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard files.indices.contains(row) else { return }
        Task { await openDiff(files[row]) }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clicked = tableView.clickedRow
        if files.indices.contains(clicked), !tableView.selectedRowIndexes.contains(clicked) {
            menuTargets = [files[clicked]]
            tableView.selectRowIndexes([clicked], byExtendingSelection: false)
        } else {
            menuTargets = tableView.selectedRowIndexes.compactMap {
                files.indices.contains($0) ? files[$0] : nil
            }
        }
        guard menuTargets.count == 1 else { return }
        add(menu, "View Diff", #selector(diffSelected))
        add(menu, "Show File History", #selector(showFileHistory(_:)))
        menu.addItem(.separator())
        add(menu, "Reveal in Finder", #selector(revealSelected))
        add(menu, "Copy Path", #selector(copySelectedPath))
    }

    /// ⌘D, and the context menu. Lives on this controller rather than in
    /// `AppDelegate` so it only validates while the file list has focus — the
    /// selected path is the one thing the menu bar can't reach on its own.
    @objc func showFileHistory(_ sender: Any?) {
        guard let vm, let path = selectedPath else { return }
        vm.showFileHistory(path: path, using: appState.git)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showFileHistory(_:)) { return selectedPath != nil }
        return true
    }

    /// Always the selection — `menuNeedsUpdate` pulls a right-clicked row into
    /// it first, so a context-menu target is a selected row by then too.
    private var selectedPath: String? {
        let row = tableView.selectedRow
        return files.indices.contains(row) ? files[row].path : nil
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func diffSelected() {
        guard let file = menuTargets.first else { return }
        Task { await openDiff(file) }
    }

    @objc private func revealSelected() {
        guard let vm, let file = menuTargets.first else { return }
        let fileURL = vm.repository.url.appendingPathComponent(file.path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func copySelectedPath() {
        guard let file = menuTargets.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
    }

    private func openDiff(_ file: CommitFileChange) async {
        guard let vm, let commit else { return }
        await vm.run {
            try await appState.diffTool.diffCommit(
                repoURL: vm.repository.url,
                path: file.path,
                commitSHA: commit.id,
                parentSHA: commit.parents.first
            )
        }
    }
}

// MARK: - Header field factories

private func label(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: "\(text):")
    field.font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
    return field
}

private func valueField() -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = NSFont.preferredFont(forTextStyle: .body)
    field.isSelectable = true
    field.lineBreakMode = .byTruncatingMiddle
    field.cell?.usesSingleLineMode = true
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

private func monospacedValueField() -> NSTextField {
    let field = valueField()
    field.font = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
        weight: .regular
    )
    return field
}
