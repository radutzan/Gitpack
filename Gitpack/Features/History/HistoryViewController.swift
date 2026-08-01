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
    private let tableView = KeyTableView()
    private let scrollView = NSScrollView()
    private let placeholder = HistoryPlaceholderView()
    private let errorBanner = ErrorBannerView()
    private let resultsBar = SearchResultsBar()
    private var rows: [Row] = []
    private var tokens: [SearchToken] = []

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
        resultsBar.onClose = { [weak self] in
            self?.appState.selectedViewModel?.cancelSearch()
        }

        for subview in [scrollView, placeholder, resultsBar, errorBanner] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // The bar floats over the list at the top of the safe area, like the
            // error banner; `additionalSafeAreaInsets` below is what stops the
            // first row from hiding underneath it.
            resultsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            resultsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resultsBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            resultsBar.heightAnchor.constraint(equalToConstant: SearchResultsBar.height),

            placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),

            errorBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            errorBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            // The scroll view insets itself below the titlebar; the banner
            // floats over it and has to be told.
            errorBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
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
            showResultsBar(false)
            return
        }
        scrollView.isHidden = false
        placeholder.isHidden = true

        showResultsBar(vm.isSearchActive)
        if vm.isSearchActive {
            resultsBar.update(
                matches: vm.searchResults.count,
                scanned: vm.searchScanned,
                searching: vm.isSearching,
                path: vm.searchPathFilter
            )
        }

        // Reload only on a real change. This runs on every activation and
        // autofetch; an unconditional reload rebuilds the table mid-click and
        // drops the selection.
        let fresh = makeRows(vm)
        if fresh != rows || tokens != vm.searchTokens {
            tokens = vm.searchTokens
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
        // While searching there is no working-copy row and no paging row: the
        // list is exactly the matches, and the search walks history by itself.
        if vm.isSearchActive {
            return vm.searchResults.map { .commit($0, marker: vm.marker(for: $0)) }
        }
        var result: [Row] = [workingCopyRow(vm.status)]
        result.append(contentsOf: vm.commits.map { .commit($0, marker: vm.marker(for: $0)) })
        if vm.hasMoreHistory && !vm.commits.isEmpty {
            result.append(.loadMore)
        }
        return result
    }

    /// The bar overlays the list, so the pane's safe area has to grow by its
    /// height — that is what the scroll view's automatic content inset follows,
    /// and without it the top row sits behind the bar at scroll position zero.
    private func showResultsBar(_ visible: Bool) {
        guard resultsBar.isHidden == visible else { return }
        resultsBar.isHidden = !visible
        view.additionalSafeAreaInsets.top = visible ? SearchResultsBar.height : 0
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
        guard let target = rows.firstIndex(where: { item(for: $0) == selection }) else {
            // The selected commit isn't in the current list — a search that
            // doesn't match it. Leaving the table's index alone would leave it
            // highlighting whatever commit inherited that row.
            if tableView.selectedRow >= 0 {
                updatingSelection = true
                tableView.deselectAll(nil)
                updatingSelection = false
            }
            return
        }
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
            cell.configure(commit: commit, marker: marker, tokens: tokens)
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

    /// Esc from anywhere else in the pane. The list itself takes Esc in
    /// `handleBareKey`, because `NSTableView` consumes `cancelOperation` for its
    /// own type-select and never forwards it up the chain.
    override func cancelOperation(_ sender: Any?) {
        guard let vm = appState.selectedViewModel, vm.isSearchActive else { return }
        vm.cancelSearch()
    }

    /// Gitbox's bare-key shortcuts, on the focused list so they can't fire
    /// while you're typing a commit message.
    private func handleBareKey(_ key: String) -> Bool {
        if movePaneFocus(for: key) { return true }
        if key == "\u{1B}", let vm = appState.selectedViewModel, vm.isSearchActive {
            vm.cancelSearch()
            return true
        }
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

/// The thin bar over the history list while a search runs: live match count,
/// a spinner until the walk reaches the end of history, and a close button.
private final class SearchResultsBar: NSVisualEffectView {
    static let height: CGFloat = 28

    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        isHidden = true

        label.font = NSFont.preferredFont(forTextStyle: .callout)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        let close = NSButton()
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear Search")
        close.isBordered = false
        close.bezelStyle = .accessoryBar
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Clear Search (Esc)"
        close.target = self
        close.action = #selector(closeClicked)
        close.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [spinner, label, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            // A separator NSBox has no intrinsic height of its own.
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SearchResultsBar is created in code")
    }

    func update(matches: Int, scanned: Int, searching: Bool, path: String?) {
        var text = matches == 1 ? "1 commit" : "\(matches) commits"
        if let path {
            text = "\((path as NSString).lastPathComponent) — \(text)"
        }
        if searching {
            text += " · searching \(scanned)…"
        } else if matches == 0 {
            text = path.map { "No commits touch \(($0 as NSString).lastPathComponent)" } ?? "No matches"
        }
        label.stringValue = text

        if searching {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    @objc private func closeClicked() {
        onClose?()
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
