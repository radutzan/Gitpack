import AppKit

/// Commit composer over the staging list.
final class WorkingCopyViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSMenuDelegate {
    private let appState: AppState

    private let composerBox = NSBox()
    private let composer = ComposerTextView()
    private let composerPlaceholder = NSTextField(labelWithString: "Commit message")
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let buttonRow = NSStackView()
    private var composerHeight: NSLayoutConstraint!

    private let tableView = KeyTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Working directory clean")

    private var entries: [WorkingCopyEntry] = []
    private var isCommitting = false
    /// Targets for the currently open context menu — the clicked row when it is
    /// outside the selection, otherwise the whole selection.
    private var menuTargets: [WorkingCopyEntry] = []

    private var vm: RepositoryViewModel? { appState.selectedViewModel }

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkingCopyViewController is created in code")
    }

    // MARK: - Layout

    override func loadView() {
        view = NSView()
        buildComposer()
        buildTable()

        let divider = NSBox()
        divider.boxType = .separator

        for subview in [composerBox, buttonRow, divider, scrollView, emptyLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        composerHeight = composerBox.heightAnchor.constraint(equalToConstant: Composer.collapsedHeight)

        NSLayoutConstraint.activate([
            composerBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composerBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            composerBox.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            composerHeight,

            buttonRow.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: composerBox.trailingAnchor),
            buttonRow.topAnchor.constraint(equalTo: composerBox.bottomAnchor, constant: 6),

            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 8),
            // A separator NSBox has no intrinsic height. Without this it is free
            // to absorb the whole pane and squeeze the file list to nothing.
            divider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    private func buildComposer() {
        composerBox.boxType = .custom
        composerBox.borderWidth = 1
        composerBox.borderColor = .separatorColor
        composerBox.cornerRadius = 6
        composerBox.fillColor = .clear
        composerBox.titlePosition = .noTitle
        composerBox.contentViewMargins = .zero

        composer.delegate = self
        composer.font = NSFont.preferredFont(forTextStyle: .body)
        composer.drawsBackground = false
        composer.textContainerInset = NSSize(width: 4, height: 5)
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.autoresizingMask = [.width]
        composer.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composer.textContainer?.widthTracksTextView = true
        composer.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        composer.onFocusChange = { [weak self] _ in self?.updateComposerHeight(animated: true) }

        let composerScroll = NSScrollView()
        composerScroll.documentView = composer
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.translatesAutoresizingMaskIntoConstraints = false

        // NSTextView has no placeholder, so one rides on top and hides on input.
        composerPlaceholder.textColor = .placeholderTextColor
        composerPlaceholder.font = NSFont.preferredFont(forTextStyle: .body)
        composerPlaceholder.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(composerScroll)
        content.addSubview(composerPlaceholder)
        composerBox.contentView = content

        NSLayoutConstraint.activate([
            composerScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            composerScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            composerScroll.topAnchor.constraint(equalTo: content.topAnchor),
            composerScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            composerPlaceholder.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 9),
            composerPlaceholder.topAnchor.constraint(equalTo: content.topAnchor, constant: 5),
        ])

        commitButton.target = self
        commitButton.action = #selector(commit(_:))
        commitButton.bezelStyle = .rounded
        // Deliberately no keyEquivalent: "\r" would make this the window's
        // default button and swallow Return inside the message box. ⌘↩ lives on
        // the Stage menu, which gets key equivalents before the responder chain.

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.setViews([spinner, commitButton], in: .trailing)
        buttonRow.isHidden = true
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
        tableView.onBareKey = { [weak self] key in self?.handleBareKey(key) ?? false }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

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
        guard let vm else { return }

        let fresh = vm.status?.entries ?? []
        if fresh != entries {
            let selected = selectedPaths()
            entries = fresh
            tableView.reloadData()
            restoreSelection(selected)
        }
        emptyLabel.isHidden = !entries.isEmpty

        // Only assign when it differs — writing the text view on every keystroke
        // would collapse the insertion point back to the start.
        if composer.string != vm.commitMessage {
            composer.string = vm.commitMessage
        }
        composerPlaceholder.isHidden = !vm.commitMessage.isEmpty
        commitButton.isEnabled = vm.canCommit && !isCommitting
        updateComposerHeight(animated: false)
    }

    private func selectedPaths() -> Set<String> {
        Set(tableView.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].path : nil })
    }

    private func restoreSelection(_ paths: Set<String>) {
        let indexes = IndexSet(entries.indices.filter { paths.contains(entries[$0].path) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private var composerExpanded: Bool {
        composer.isFirstResponderInWindow || !(vm?.commitMessage ?? "").isEmpty
    }

    private func updateComposerHeight(animated: Bool) {
        let target = composerExpanded ? Composer.expandedHeight : Composer.collapsedHeight
        let shouldShowButtons = composerExpanded
        guard composerHeight.constant != target || buttonRow.isHidden == shouldShowButtons else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                composerHeight.animator().constant = target
                buttonRow.isHidden = !shouldShowButtons
                view.layoutSubtreeIfNeeded()
            }
        } else {
            composerHeight.constant = target
            buttonRow.isHidden = !shouldShowButtons
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = (tableView.makeView(withIdentifier: FileRowView.identifier, owner: self) as? FileRowView)
            ?? {
                let new = FileRowView()
                new.identifier = FileRowView.identifier
                return new
            }()
        cell.configure(
            path: entry.path,
            oldPath: entry.oldPath,
            statusLabel: entry.isPartiallyStaged ? "\(entry.displayStatus.label) (partial)" : entry.displayStatus.label,
            staged: entry.isFullyStaged
        )
        cell.onToggle = { [weak self] in
            Task { await self?.toggleStaging([entry.path]) }
        }
        return cell
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard entries.indices.contains(row) else { return }
        Task { await openDiff(entries[row].path) }
    }

    private func handleBareKey(_ key: String) -> Bool {
        if movePaneFocus(for: key) { return true }
        let paths = selectedPaths()
        switch key {
        case "s":
            guard !paths.isEmpty else { return false }
            Task { await toggleStaging(Array(paths)) }
            return true
        case "d":
            guard paths.count == 1, let path = paths.first else { return false }
            Task { await openDiff(path) }
            return true
        default:
            return false
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clicked = tableView.clickedRow
        if entries.indices.contains(clicked), !tableView.selectedRowIndexes.contains(clicked) {
            menuTargets = [entries[clicked]]
            tableView.selectRowIndexes([clicked], byExtendingSelection: false)
        } else {
            menuTargets = tableView.selectedRowIndexes.compactMap {
                entries.indices.contains($0) ? entries[$0] : nil
            }
        }
        guard !menuTargets.isEmpty else { return }

        let count = menuTargets.count
        if menuTargets.contains(where: { $0.unstagedStatus != nil }) {
            add(menu, count > 1 ? "Stage \(count) Files" : "Stage", #selector(stageSelected))
        }
        if menuTargets.contains(where: { $0.stagedStatus != nil }) {
            add(menu, count > 1 ? "Unstage \(count) Files" : "Unstage", #selector(unstageSelected))
        }
        if count == 1 {
            add(menu, "View Diff", #selector(diffSelected))
        }
        menu.addItem(.separator())
        if count == 1 {
            add(menu, "Reveal in Finder", #selector(revealSelected))
            add(menu, "Copy Path", #selector(copySelectedPaths))
        } else {
            add(menu, "Copy Paths", #selector(copySelectedPaths))
        }
        menu.addItem(.separator())
        add(menu, count > 1 ? "Discard Changes to \(count) Files…" : "Discard Changes…", #selector(discardSelected))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func stageSelected() {
        let paths = menuTargets.map(\.path)
        Task { await stage(paths) }
    }

    @objc private func unstageSelected() {
        let paths = menuTargets.map(\.path)
        Task { await unstage(paths) }
    }

    @objc private func diffSelected() {
        guard let path = menuTargets.first?.path else { return }
        Task { await openDiff(path) }
    }

    @objc private func revealSelected() {
        guard let vm, let path = menuTargets.first?.path else { return }
        let fileURL = vm.repository.url.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func copySelectedPaths() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(menuTargets.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func discardSelected() {
        let paths = menuTargets.map(\.path)
        guard !paths.isEmpty, let vm else { return }

        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? "Discard changes to \(paths[0])?"
            : "Discard changes to \(paths.count) files?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            await vm.run {
                try await appState.git.discard(paths: paths, at: vm.repository.url)
            }
            await vm.refreshStatusOnly(using: appState.git)
        }
    }

    // MARK: - Mutations

    private func toggleStaging(_ paths: [String]) async {
        let resolved = entries.filter { paths.contains($0.path) }
        if resolved.allSatisfy(\.isFullyStaged) {
            await unstage(paths)
        } else {
            await stage(paths)
        }
    }

    private func stage(_ paths: [String]) async {
        guard let vm else { return }
        await vm.run { try await appState.git.stage(paths: paths, at: vm.repository.url) }
        await vm.refreshStatusOnly(using: appState.git)
    }

    private func unstage(_ paths: [String]) async {
        guard let vm else { return }
        await vm.run { try await appState.git.unstage(paths: paths, at: vm.repository.url) }
        await vm.refreshStatusOnly(using: appState.git)
    }

    private func openDiff(_ path: String) async {
        guard let vm else { return }
        await vm.run {
            try await appState.diffTool.diffWorkingCopy(repoURL: vm.repository.url, path: path)
        }
    }

    @objc func commit(_ sender: Any?) {
        guard let vm, vm.canCommit, !isCommitting else { return }
        isCommitting = true
        commitButton.isEnabled = false
        spinner.startAnimation(nil)
        Task {
            await appState.commit(vm)
            isCommitting = false
            spinner.stopAnimation(nil)
            apply()
        }
    }

    // MARK: - Text view

    func textDidChange(_ notification: Notification) {
        guard let vm else { return }
        vm.commitMessage = composer.string
        // Gitbox trick: typing a commit message kicks off a fetch, so you can
        // pull before committing if the remote moved.
        if !composer.string.isEmpty {
            appState.opportunisticFetch()
        }
    }
}

private enum Composer {
    static let collapsedHeight: CGFloat = 26
    static let expandedHeight: CGFloat = 92
}

/// Reports first-responder changes. `textDidBeginEditing` only fires once the
/// user types, which is too late to grow the box when they click into it.
private final class ComposerTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    var isFirstResponderInWindow: Bool {
        window?.firstResponder === self
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}
