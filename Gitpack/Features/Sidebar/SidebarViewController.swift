import AppKit
import UniformTypeIdentifiers

private let repositoryDragType = NSPasteboard.PasteboardType("cl.radu.Gitpack.repository")

/// Source list of tracked repositories, with per-repo badge and fetch spinner.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    /// NSOutlineView identifies items by object identity, so the value-type
    /// `Repository` gets a node wrapper. Nodes are rebuilt only when the
    /// repository list itself changes — badges update the cells in place.
    private final class Node {
        let repository: Repository?
        var children: [Node] = []
        var isGroup: Bool { repository == nil }

        init(repository: Repository?) {
            self.repository = repository
        }
    }

    private let appState: AppState
    private let outlineView = KeyOutlineView()
    private let scrollView = NSScrollView()

    private let root = Node(repository: nil)
    private var snapshot: [Repository] = []
    private var content: [UUID: RepositoryRowView.Content] = [:]
    private var updatingSelection = false

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarViewController is created in code")
    }

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repository"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowHeight = 28
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.onBareKey = { [weak self] key in self?.movePaneFocus(for: key) ?? false }

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        outlineView.registerForDraggedTypes([repositoryDragType, .fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChanges { [weak self] in
            self?.apply()
        }
    }

    // MARK: - Model → outline

    private func apply() {
        let repositories = appState.repositories
        if repositories != snapshot {
            snapshot = repositories
            rebuildNodes(repositories)
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
        }
        applyModelSelection()
        refreshVisibleCells()
    }

    private func rebuildNodes(_ repositories: [Repository]) {
        let group = Node(repository: nil)
        group.children = repositories.filter { $0.parentID == nil }.map { repo in
            let node = Node(repository: repo)
            node.children = repositories.filter { $0.parentID == repo.id }.map { Node(repository: $0) }
            return node
        }
        root.children = [group]
    }

    private func node(for id: UUID) -> Node? {
        for group in root.children {
            for child in group.children {
                if child.repository?.id == id { return child }
                if let match = child.children.first(where: { $0.repository?.id == id }) { return match }
            }
        }
        return nil
    }

    private func applyModelSelection() {
        guard let id = appState.selectedRepositoryID, let node = node(for: id) else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0, outlineView.selectedRow != row else { return }
        updatingSelection = true
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        updatingSelection = false
    }

    /// Badges and spinners change on every autofetch cycle. Reconfiguring the
    /// materialized cells avoids a reload, which would fight the selection.
    private func refreshVisibleCells() {
        // Read every repository's state up front rather than inside the loop
        // over materialized cells. Right after `reloadData` no cell views exist
        // yet, so a loop that skips them would read no observable properties at
        // all — and the observation would never re-fire when a badge changed.
        content = snapshot.reduce(into: [:]) { result, repository in
            let background = appState.backgroundState(for: repository.id)
            result[repository.id] = RepositoryRowView.Content(
                name: repository.displayName,
                missing: appState.viewModel(for: repository).isMissing,
                badge: background.badge,
                fetching: background.isFetching
            )
        }

        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? Node,
                  let id = node.repository?.id,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? RepositoryRowView
            else { continue }
            cell.apply(content[id])
        }
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? Node) ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node) ?? root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? Node)?.isGroup ?? false)
    }

    /// The one group row is a header, not a disclosure. Without this, clicking
    /// it collapses the row and the sidebar goes blank with no obvious way back.
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        !((item as? Node)?.isGroup ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }

        guard let repository = node.repository else {
            let identifier = NSUserInterfaceItemIdentifier("GroupRow")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? {
                    let new = NSTableCellView()
                    new.identifier = identifier
                    let label = NSTextField(labelWithString: "")
                    label.translatesAutoresizingMaskIntoConstraints = false
                    new.addSubview(label)
                    new.textField = label
                    NSLayoutConstraint.activate([
                        label.leadingAnchor.constraint(equalTo: new.leadingAnchor),
                        label.centerYAnchor.constraint(equalTo: new.centerYAnchor),
                    ])
                    return new
                }()
            cell.textField?.stringValue = "Repositories"
            return cell
        }

        let cell = (outlineView.makeView(withIdentifier: RepositoryRowView.identifier, owner: self) as? RepositoryRowView)
            ?? {
                let new = RepositoryRowView()
                new.identifier = RepositoryRowView.identifier
                return new
            }()
        cell.apply(content[repository.id])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? Node,
              let repository = node.repository else { return }
        appState.selectedRepositoryID = repository.id
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node, let repository = node.repository, repository.parentID == nil else {
            return nil
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(repository.id.uuidString, forType: repositoryDragType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        if info.draggingPasteboard.availableType(from: [repositoryDragType]) != nil {
            // Reorder only, and only between top-level rows — dropping *onto* a
            // repository would mean re-parenting, which the roadmap parks with
            // submodules.
            guard index != NSOutlineViewDropOnItemIndex,
                  (item as? Node)?.isGroup ?? false else { return [] }
            return .move
        }
        if info.draggingPasteboard.availableType(from: [.fileURL]) != nil {
            // A folder dropped anywhere in the sidebar adds a repository.
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        return []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        if let raw = info.draggingPasteboard.string(forType: repositoryDragType),
           let id = UUID(uuidString: raw) {
            return moveRepository(id, toTopLevelIndex: index)
        }

        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        Task {
            for url in urls {
                _ = await appState.addRepository(at: url)
            }
        }
        return true
    }

    private func moveRepository(_ id: UUID, toTopLevelIndex index: Int) -> Bool {
        var topLevel = appState.repositories.filter { $0.parentID == nil }
        guard let from = topLevel.firstIndex(where: { $0.id == id }) else { return false }
        let moved = topLevel.remove(at: from)
        topLevel.insert(moved, at: from < index ? index - 1 : index)

        // Rebuild the flat stored array, each parent immediately followed by its
        // children, so `parentID` nesting survives the reorder.
        let all = appState.repositories
        let reordered = topLevel.flatMap { parent in
            [parent] + all.filter { $0.parentID == parent.id }
        }
        appState.store.reorder(reordered)
        return true
    }

    // MARK: - Context menu

    private var clickedRepository: Repository? {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node else { return nil }
        return node.repository
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard clickedRepository != nil else { return }
        for (title, action) in [
            ("Reveal in Finder", #selector(revealClicked)),
            ("Refresh", #selector(refreshClicked)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove from Gitpack", action: #selector(removeClicked), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
    }

    @objc private func revealClicked() {
        guard let repository = clickedRepository else { return }
        NSWorkspace.shared.activateFileViewerSelecting([repository.url])
    }

    @objc private func refreshClicked() {
        guard let repository = clickedRepository else { return }
        let vm = appState.viewModel(for: repository)
        Task { await vm.refreshAll(using: appState.git) }
    }

    @objc private func removeClicked() {
        guard let repository = clickedRepository else { return }
        appState.removeRepository(repository)
    }
}

// MARK: - Row

private final class RepositoryRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("RepositoryRow")

    struct Content: Equatable {
        let name: String
        let missing: Bool
        let badge: Int
        let fetching: Bool
    }

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let badge = BadgeView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepositoryRowView is created in code")
    }

    private func build() {
        icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor

        name.font = NSFont.preferredFont(forTextStyle: .body)
        name.lineBreakMode = .byTruncatingTail
        name.cell?.usesSingleLineMode = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        for subview in [icon, name, spinner, badge] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -4),

            spinner.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func apply(_ content: Content?) {
        guard let content else { return }
        name.stringValue = content.name
        name.textColor = content.missing ? .secondaryLabelColor : .labelColor
        badge.count = content.badge
        badge.toolTip = content.badge > 0 ? "Unpushed + unmerged commits + changed files" : nil
        if content.fetching {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}

/// Rounded count pill. `updateLayer` rather than a stored CGColor so it follows
/// light/dark switches — a CGColor snapshot would freeze at whatever appearance
/// was current when the cell was built.
private final class BadgeView: NSView {
    var count: Int = 0 {
        didSet {
            label.stringValue = String(count)
            isHidden = count == 0
            invalidateIntrinsicContentSize()
        }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true

        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BadgeView is created in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius = bounds.height / 2
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}
