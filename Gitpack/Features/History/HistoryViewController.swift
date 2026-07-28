import AppKit

/// The middle pane: working-copy pseudo-row, then commits, then a paging row.
///
/// Every row is a fixed 45pt (41pt of content + 2pt above and below). Automatic
/// row heights are what previously blanked this pane — NSTableView's estimate
/// for unmaterialized rows diverges from measured two-line rows, and any
/// selection change then scrolls to a garbage offset. A uniform height is also
/// the precondition for M3's streaming search.
final class HistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row: Equatable {
        case workingCopy(summary: String, subtitle: String, dirty: Bool)
        case commit(Commit, marker: CommitMarker)
        case loadMore
    }

    private let appState: AppState
    private let tableView = HistoryTableView()
    private let scrollView = NSScrollView()
    private let placeholder = HistoryPlaceholderView()
    private let errorBanner = ErrorBannerView()
    private var rows: [Row] = []

    /// Set while pushing the model's selection into the table, so the
    /// delegate callback doesn't write it straight back and re-trigger the
    /// observation.
    private var updatingSelection = false

    /// The last selection pushed into the table, so a reload can tell "the user
    /// picked a different row" apart from "the rows changed underneath us".
    private var lastSelection: HistoryItem?

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HistoryViewController is created in code")
    }

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 45
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked(_:))
        tableView.onBareKey = { [weak self] key in
            self?.handleBareKey(key) ?? false
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        errorBanner.onDismiss = { [weak self] in
            self?.appState.selectedViewModel?.lastError = nil
        }

        for subview in [scrollView, placeholder, errorBanner] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),

            errorBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            errorBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            errorBanner.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChanges { [weak self] in
            self?.apply()
        }
    }

    // MARK: - Model → table

    private func apply() {
        guard let vm = appState.selectedViewModel else {
            rows = []
            tableView.reloadData()
            scrollView.isHidden = true
            placeholder.isHidden = false
            errorBanner.text = nil
            return
        }
        scrollView.isHidden = false
        placeholder.isHidden = true

        // Reload only on a real change. This runs on every activation and
        // autofetch; an unconditional reload rebuilds the table mid-click and
        // drops the selection.
        let fresh = makeRows(vm)
        if fresh != rows {
            // ponytail: restores the pixel offset, not the row you were looking
            // at. Appends (paging) and edits below the fold land exactly; a new
            // commit arriving at the top shifts the view by one row. Anchor on a
            // row if that ever grates.
            let origin = scrollView.contentView.bounds.origin
            rows = fresh
            updatingSelection = true
            tableView.reloadData()
            updatingSelection = false
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        applyModelSelection(vm)
        errorBanner.text = vm.lastError
    }

    private func makeRows(_ vm: RepositoryViewModel) -> [Row] {
        var result: [Row] = [workingCopyRow(vm.status)]
        result.append(contentsOf: vm.commits.map { .commit($0, marker: vm.marker(for: $0)) })
        if vm.hasMoreHistory && !vm.commits.isEmpty {
            result.append(.loadMore)
        }
        return result
    }

    private func workingCopyRow(_ status: WorkingCopyStatus?) -> Row {
        let clean = status?.isClean ?? true
        return .workingCopy(
            summary: clean ? "Working directory clean" : summary(status),
            subtitle: subtitle(status),
            dirty: !clean
        )
    }

    private func summary(_ status: WorkingCopyStatus?) -> String {
        guard let status else { return "Working copy" }
        var parts: [String] = []
        let modified = status.modifiedFileCount
        let new = status.newFileCount
        if modified > 0 { parts.append("\(modified) modified file\(modified == 1 ? "" : "s")") }
        if new > 0 { parts.append("\(new) new file\(new == 1 ? "" : "s")") }
        return parts.isEmpty ? "\(status.entries.count) changed" : parts.joined(separator: ", ")
    }

    private func subtitle(_ status: WorkingCopyStatus?) -> String {
        guard let status else { return "" }
        var parts: [String] = []
        if let branch = status.branch { parts.append(branch) }
        if status.ahead > 0 { parts.append("↑\(status.ahead)") }
        if status.behind > 0 { parts.append("↓\(status.behind)") }
        return parts.joined(separator: " · ")
    }

    private func item(for row: Row) -> HistoryItem? {
        switch row {
        case .workingCopy: .workingCopy
        case .commit(let commit, _): .commit(commit.id)
        case .loadMore: nil
        }
    }

    private func applyModelSelection(_ vm: RepositoryViewModel) {
        // Scroll only when the *model's* selection moved. Re-selecting after a
        // reload must not scroll: paging appends 200 rows at the bottom, and
        // scrolling the still-selected row back into view would yank you to the
        // top the instant you asked for more history.
        let selectionMoved = vm.selection != lastSelection
        lastSelection = vm.selection

        guard let selection = vm.selection else {
            if tableView.selectedRow >= 0 {
                updatingSelection = true
                tableView.deselectAll(nil)
                updatingSelection = false
            }
            return
        }
        guard let target = rows.firstIndex(where: { item(for: $0) == selection }) else { return }
        if tableView.selectedRow != target {
            updatingSelection = true
            tableView.selectRowIndexes([target], byExtendingSelection: false)
            updatingSelection = false
        }
        if selectionMoved {
            tableView.scrollRowToVisible(target)
        }
    }

    // MARK: - Table → model

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .loadMore:
            let cell = tableView.makeView(withIdentifier: LoadMoreRowView.identifier, owner: self) as? LoadMoreRowView
                ?? {
                    let new = LoadMoreRowView()
                    new.identifier = LoadMoreRowView.identifier
                    return new
                }()
            return cell

        case .workingCopy(let summary, let subtitle, let dirty):
            let cell = commitCell(tableView)
            cell.configureWorkingCopy(title: summary, subtitle: subtitle, dirty: dirty)
            return cell

        case .commit(let commit, let marker):
            let cell = commitCell(tableView)
            cell.configure(commit: commit, marker: marker)
            return cell
        }
    }

    private func commitCell(_ tableView: NSTableView) -> CommitRowView {
        if let existing = tableView.makeView(withIdentifier: CommitRowView.identifier, owner: self) as? CommitRowView {
            return existing
        }
        let cell = CommitRowView()
        cell.identifier = CommitRowView.identifier
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .loadMore = rows[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, let vm = appState.selectedViewModel else { return }
        let row = tableView.selectedRow
        vm.selection = rows.indices.contains(row) ? item(for: rows[row]) : nil
    }

    @objc private func tableClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard rows.indices.contains(row), case .loadMore = rows[row],
              let vm = appState.selectedViewModel else { return }
        Task { await vm.loadMoreHistory(using: appState.git) }
    }

    /// Gitbox's bare-key shortcuts, on the focused list so they can't fire
    /// while you're typing a commit message.
    private func handleBareKey(_ key: String) -> Bool {
        guard let vm = appState.selectedViewModel, vm.otherBranch != nil, !vm.isSyncing else {
            return false
        }
        switch key {
        case "u":
            Task { await vm.performSync(vm.otherBranchIsLocal ? .merge : .pull, using: appState.git) }
            return true
        case "p":
            guard !vm.otherBranchIsLocal else { return false }
            Task { await vm.performSync(.push, using: appState.git) }
            return true
        default:
            return false
        }
    }
}

/// Intercepts unmodified `u`/`p` before NSTableView turns them into type-select.
private final class HistoryTableView: NSTableView {
    var onBareKey: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        if bare, let key = event.charactersIgnoringModifiers, onBareKey?(key) == true {
            return
        }
        super.keyDown(with: event)
    }
}

private final class HistoryPlaceholderView: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 6

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: nil)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        image.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "No Repository")
        title.font = NSFont.preferredFont(forTextStyle: .title3)
        title.textColor = .secondaryLabelColor

        let detail = NSTextField(wrappingLabelWithString: "Select a repository in the sidebar, or add one with ⌘O.")
        detail.alignment = .center
        detail.font = NSFont.preferredFont(forTextStyle: .body)
        detail.textColor = .tertiaryLabelColor

        setViews([image, title, detail], in: .leading)
        setCustomSpacing(10, after: image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HistoryPlaceholderView is created in code")
    }
}

private final class ErrorBannerView: NSVisualEffectView {
    var onDismiss: (() -> Void)?

    var text: String? {
        didSet {
            label.stringValue = text ?? ""
            isHidden = text == nil
        }
    }

    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        isHidden = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = NSFont.preferredFont(forTextStyle: .callout)
        label.maximumNumberOfLines = 4
        label.isSelectable = true

        let dismiss = NSButton()
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismiss.isBordered = false
        dismiss.bezelStyle = .accessoryBar
        dismiss.target = self
        dismiss.action = #selector(dismissClicked)
        dismiss.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, label, dismiss])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ErrorBannerView is created in code")
    }

    @objc private func dismissClicked() {
        onDismiss?()
    }
}
