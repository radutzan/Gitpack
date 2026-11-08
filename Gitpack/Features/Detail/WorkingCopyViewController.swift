import AppKit

/// Commit composer over the staging list.
final class WorkingCopyViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let appState: AppState
    private lazy var actions = RepositoryActions(appState: appState)

    private let operationBar = OperationBarView()
    private var operationBarHeight: NSLayoutConstraint!
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

        operationBar.onAction = { [weak self] action in
            guard let operation = self?.vm?.operation else { return }
            self?.actions.resolve(operation, action)
        }

        for subview in [operationBar, composerBox, buttonRow, divider, scrollView, emptyLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        composerHeight = composerBox.heightAnchor.constraint(equalToConstant: Composer.collapsedHeight)
        // Zero-height rather than a second set of constraints: with the bar
        // collapsed the composer sits exactly where it did before it existed.
        operationBarHeight = operationBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            operationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            operationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            operationBar.topAnchor.constraint(equalTo: view.topAnchor),
            operationBarHeight,

            composerBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composerBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            composerBox.topAnchor.constraint(equalTo: operationBar.bottomAnchor, constant: 10),
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
        // Tab cycles between the two halves of this pane. `handleBareKey` sends
        // it back the other way.
        composer.onTabOut = { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(tableView)
        }

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
        tableView.quickLookURLs = { [weak self] in self?.quickLookURLs(Array(self?.selectedPaths() ?? [])) ?? [] }

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

        // The one "mode" this app has: a rebase, merge, cherry-pick or revert
        // that stopped half-way and needs a decision.
        operationBar.update(
            operation: vm.operation,
            conflicts: entries.filter { $0.displayStatus == .unmerged }.count
        )
        operationBar.isHidden = vm.operation == nil
        operationBarHeight.constant = vm.operation == nil ? 0 : OperationBarView.height

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

    /// Deleted files have nothing on disk to preview, so they drop out.
    private func quickLookURLs(_ paths: [String]) -> [URL] {
        guard let vm else { return [] }
        return entries.map(\.path).filter(paths.contains)
            .map { vm.repository.url.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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
        // A conflict sets both halves of the status, which is not the same
        // thing as a partially staged file — saying "(partial)" about it reads
        // as though half the conflict were resolved.
        let conflicted = entry.displayStatus == .unmerged
        let partial = entry.isPartiallyStaged && !conflicted
        cell.configure(
            path: entry.path,
            oldPath: entry.oldPath,
            statusLabel: partial ? "\(entry.displayStatus.label) (partial)" : entry.displayStatus.label,
            staged: entry.isFullyStaged,
            conflicted: conflicted
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
        case "\t":
            view.window?.makeFirstResponder(composer)
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
            add(menu, "Show File History", #selector(showFileHistory(_:)))
        }
        menu.addItem(.separator())
        if count == 1 {
            add(menu, "Reveal in Finder", #selector(revealSelected))
            add(menu, "Copy Path", #selector(copySelectedPaths))
        } else {
            add(menu, "Copy Paths", #selector(copySelectedPaths))
        }
        menu.addItem(.separator())
        if count == 1 {
            add(menu, "Ignore File…", #selector(ignoreSelected))
        }
        // Gitbox called this Revert File…; Discard Changes is the same operation
        // under the name the rest of this UI uses.
        add(menu, count > 1 ? "Discard Changes to \(count) Files…" : "Discard Changes…", #selector(discardSelected))
        add(menu, count > 1 ? "Delete \(count) Files…" : "Delete File…", #selector(deleteSelected))
    }

    @objc private func ignoreSelected() {
        guard let path = menuTargets.first?.path else { return }
        actions.ignore(path: path)
    }

    @objc private func deleteSelected() {
        actions.delete(paths: menuTargets.map(\.path))
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

    /// ⌘D and the context menu. On this controller rather than in `AppDelegate`
    /// so it validates against the focused list's own selection.
    @objc func showFileHistory(_ sender: Any?) {
        guard let vm, let path = selectedPath else { return }
        vm.showFileHistory(path: path, using: appState.git)
    }

    private var selectedPath: String? {
        let row = tableView.selectedRow
        return entries.indices.contains(row) ? entries[row].path : nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showFileHistory(_:)):
            return selectedPath != nil
        case #selector(commitChanges(_:)):
            let staging = !stageableSelection.isEmpty
            menuItem.title = staging ? "Stage Selected" : "Commit"
            return staging || vm?.canCommit == true
        default:
            return true
        }
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

    /// ⌘↩. Stages the selection while the file list itself has focus, and
    /// commits everywhere else — one menu item, because a second item with the
    /// same key equivalent swallows the press whenever it validates as disabled
    /// instead of falling through to the next one.
    @objc func commitChanges(_ sender: Any?) {
        let paths = stageableSelection
        guard paths.isEmpty else {
            Task { await stage(paths) }
            return
        }
        guard let vm else { return }
        Task { await appState.commit(vm) }
    }

    /// Empty unless the file list is first responder, so ⌘↩ from the composer
    /// still commits, and empty when everything selected is already staged, so
    /// the shortcut falls back to committing rather than doing nothing.
    private var stageableSelection: [String] {
        guard view.window?.firstResponder === tableView else { return [] }
        return tableView.selectedRowIndexes.compactMap {
            guard entries.indices.contains($0), entries[$0].unstagedStatus != nil else { return nil }
            return entries[$0].path
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

/// The stage pane's only mode: a stopped rebase/merge/cherry-pick/revert, with
/// the three ways out of it.
private final class OperationBarView: NSView {
    static let height: CGFloat = 38

    var onAction: ((OperationAction) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true

        label.font = NSFont.preferredFont(forTextStyle: .callout)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true

        let abort = NSButton(title: "Abort", target: self, action: #selector(abortClicked))
        abort.hasDestructiveAction = true
        skipButton.target = self
        skipButton.action = #selector(skipClicked)
        let cont = NSButton(title: "Continue", target: self, action: #selector(continueClicked))
        cont.keyEquivalent = ""
        for button in [abort, skipButton, cont] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
        }

        let stack = NSStackView(views: [label, abort, skipButton, cont])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OperationBarView is created in code")
    }

    /// Drawn here rather than assigned once: `updateLayer` is what AppKit calls
    /// again when the appearance flips, so the colour follows dark mode.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
    }

    func update(operation: RepositoryOperation?, conflicts: Int) {
        guard let operation else { return }
        var text = "\(operation.label) in progress"
        if conflicts > 0 {
            text += " — \(conflicts) conflicted file\(conflicts == 1 ? "" : "s")"
        }
        label.stringValue = text
        skipButton.isHidden = !operation.canSkip
    }

    @objc private func abortClicked() { onAction?(.abort) }
    @objc private func skipClicked() { onAction?(.skip) }
    @objc private func continueClicked() { onAction?(.continue) }
}

private enum Composer {
    static let collapsedHeight: CGFloat = 26
    static let expandedHeight: CGFloat = 92
}

/// Reports first-responder changes. `textDidBeginEditing` only fires once the
/// user types, which is too late to grow the box when they click into it.
private final class ComposerTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    /// An `NSTextView` that is not a field editor types a tab character instead
    /// of moving focus, so Tab has to be intercepted to leave the composer.
    var onTabOut: (() -> Void)?

    override func insertTab(_ sender: Any?) { onTabOut?() }
    override func insertBacktab(_ sender: Any?) { onTabOut?() }

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
