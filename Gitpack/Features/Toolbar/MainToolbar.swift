import AppKit

extension NSToolbarItem.Identifier {
    static let addRepository = NSToolbarItem.Identifier("addRepository")
    static let branchPicker = NSToolbarItem.Identifier("branchPicker")
    static let syncControls = NSToolbarItem.Identifier("syncControls")
    static let otherBranchPicker = NSToolbarItem.Identifier("otherBranchPicker")
    static let dividerSpacer = NSToolbarItem.Identifier("dividerSpacer")
    static let repositoryTitle = NSToolbarItem.Identifier("repositoryTitle")
}

/// Gitbox's toolbar: current branch, the pull/push pair, and the "other
/// branch" it syncs against, as one cluster after the window title. Add
/// Repository sits at the trailing edge.
final class MainToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "MainToolbar")

    /// Fixed so the cluster's geometry doesn't jump when a branch name changes
    /// length — which is also what keeps the divider alignment stable.
    private static let pickerWidth: CGFloat = 192

    /// Room kept clear at the trailing edge.
    private static let trailingReserve: CGFloat = 24

    /// ~2s of 50ms re-checks after any layout trigger.
    private static let alignRetryLimit = 40

    private let appState: AppState
    private let splitView: NSSplitView
    private let branchButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let otherBranchButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let syncControl = NSSegmentedControl(
        labels: ["Pull", "Push"],
        trackingMode: .momentary,
        target: nil,
        action: nil
    )
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private lazy var titleStack: NSStackView = {
        for (label, font) in [
            (titleLabel, NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)),
            (subtitleLabel, NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)),
        ] {
            label.font = font
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
        }
        subtitleLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        return stack
    }()
    private let spacer = SpacerView()
    private var modifiers: NSEvent.ModifierFlags = []
    private var flagsMonitor: Any?
    private var alignScheduled = false
    private var alignRetries = 0

    init(appState: AppState, splitView: NSSplitView) {
        self.appState = appState
        self.splitView = splitView
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false

        syncControl.segmentStyle = .texturedRounded
        syncControl.target = self
        syncControl.action = #selector(syncSegmentClicked(_:))

        configure(branchButton, toolTip: "Current Branch")
        configure(
            otherBranchButton,
            toolTip: "Other Branch — what the current branch is compared and synced with"
        )

        // A local monitor rather than a responder-chain override: the labels
        // should morph no matter which pane holds focus.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifiers = event.modifierFlags
            self?.updateSyncControl()
            return event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )

        observeChanges { [weak self] in
            self?.refresh()
        }
    }

    deinit {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
    }

    // MARK: - Toolbar delegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Add Repository lives in the sidebar's half of the toolbar, pushed to
        // its trailing edge — everything before the tracking separator is laid
        // out over the sidebar.
        [
            .flexibleSpace,
            .addRepository,
            .sidebarTrackingSeparator,
            .repositoryTitle,
            .dividerSpacer,
            .branchPicker,
            .syncControls,
            .otherBranchPicker,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .addRepository:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Add Repository"
            item.toolTip = "Add Repository"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Repository")
            item.action = #selector(AppDelegate.addRepository(_:))
            item.target = nil // responder chain → AppDelegate
            return item

        case .sidebarTrackingSeparator:
            // Carries the sidebar divider up through the toolbar, and keeps it
            // aligned as the divider is dragged.
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier,
                splitView: splitView,
                dividerIndex: 0
            )

        case .repositoryTitle:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Repository"
            item.view = titleStack
            item.isBordered = false
            return item

        case .dividerSpacer:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = spacer
            // Without this a view-based item is drawn inside the standard glass
            // capsule, and an empty spacer reads as a stray empty control.
            item.isBordered = false
            return item

        case .branchPicker:
            return pickerItem(identifier, label: "Current Branch", button: branchButton)

        case .otherBranchPicker:
            return pickerItem(identifier, label: "Other Branch", button: otherBranchButton)

        case .syncControls:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Sync"
            item.view = syncControl
            updateSyncControl()
            return item

        default:
            return nil
        }
    }

    /// `NSMenuToolbarItem` sizes itself to its title and exposes no view to
    /// constrain, so a fixed width means a pull-down button of our own.
    private func configure(_ button: NSPopUpButton, toolTip: String) {
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.pickerWidth).isActive = true

        // Built on demand in `menuNeedsUpdate`, so it can never be stale. Item 0
        // is the button's own title — a pull-down never shows it in the list.
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "No Branch", action: nil, keyEquivalent: ""))
        button.menu = menu
    }

    private func pickerItem(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        button: NSPopUpButton
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        // The label names what the control does; the branch name is the
        // button's own title.
        item.label = label
        item.toolTip = button.toolTip
        item.view = button
        return item
    }

    // MARK: - State

    private func refresh() {
        let vm = appState.selectedViewModel

        // The window's own title is hidden: AppKit reserves ~300pt for it at the
        // leading edge whatever the text says, which pins the cluster far right
        // of any divider. `window.title` is still set for the Window menu.
        let repository = appState.selectedRepository
        titleLabel.stringValue = repository?.displayName ?? "Gitpack"
        subtitleLabel.stringValue = repository?.url.deletingLastPathComponent().lastPathComponent ?? ""
        subtitleLabel.isHidden = subtitleLabel.stringValue.isEmpty

        setTitle(vm?.currentBranch ?? "No Branch", on: branchButton)
        branchButton.isEnabled = (vm?.branches.count ?? 0) > 1

        setTitle(vm?.otherBranch ?? "No Branch", on: otherBranchButton)
        otherBranchButton.isEnabled = !(vm?.remoteBranches.isEmpty ?? true) || (vm?.branches.count ?? 0) > 1

        updateSyncControl()
    }

    private func setTitle(_ title: String, on button: NSPopUpButton) {
        guard let item = button.menu?.item(at: 0), item.title != title else { return }
        item.title = title
        button.synchronizeTitleAndSelectedItem()
    }

    /// Pull/Push, morphing with held modifiers (⌥ → Fetch, ⇧⌘ → Rebase / Force
    /// Push), collapsing to a single Merge segment when the other branch is local.
    private func updateSyncControl() {
        let vm = appState.selectedViewModel
        let enabled = vm?.otherBranch != nil && vm?.isSyncing != true

        if vm?.otherBranchIsLocal == true {
            syncControl.segmentCount = 1
            configure(syncControl, segment: 0, label: "Merge", symbol: "arrow.triangle.merge", enabled: enabled)
        } else {
            syncControl.segmentCount = 2
            configure(syncControl, segment: 0, label: downLabel, symbol: downSymbol, enabled: enabled)
            configure(syncControl, segment: 1, label: upLabel, symbol: "arrow.up", enabled: enabled)
        }
        syncControl.sizeToFit()
        alignRetries = Self.alignRetryLimit
        alignSyncToDivider()
    }

    @objc private func splitViewDidResize(_ notification: Notification) {
        alignRetries = Self.alignRetryLimit
        alignSyncToDivider()
    }

    /// Widens or narrows the leading spacer until the sync control is centred on
    /// the history/detail divider. Measured rather than computed: the toolbar's
    /// own paddings aren't public, and the correction is exact in one step
    /// because the item's x moves point-for-point with the spacer.
    private func alignSyncToDivider() {
        // `arrangedSubviews`, never `subviews`: with a sidebar item the latter
        // also holds divider views, titlebar backgrounds and collapse handles,
        // in an order where index 1 is the *detail* pane.
        let panes = splitView.arrangedSubviews
        let visible = toolbar.visibleItems?.map(\.itemIdentifier) ?? []

        // Only measure once *both* sides have settled. During launch every pane
        // is still zero-wide and an unplaced toolbar item still answers with a
        // position — a meaningless one, and feeding that back once grew the
        // spacer to 63000pt and hid the whole toolbar. Same for an item sitting
        // in the overflow menu.
        let settled = panes.count > 2
            && panes.allSatisfy { $0.frame.width > 1 }
            && visible.contains(.syncControls)
            && visible.contains(.otherBranchPicker)
            && syncControl.frame.width > 0

        guard settled, let window = syncControl.window else {
            if spacer.width > 1 {
                spacer.width = 1
            }
            scheduleAlign()
            return
        }

        let centre = syncControl.convert(NSPoint(x: syncControl.bounds.midX, y: 0), to: nil).x
        let divider = panes[1].frame.maxX + splitView.dividerThickness / 2
        let target = splitView.convert(NSPoint(x: divider, y: 0), to: nil).x

        // Solve for the width outright, against the spacer's *laid-out* frame
        // rather than the width last asked for. Those two disagree for a frame
        // after every change, and a delta measured across that gap counts the
        // previous correction twice: during a drag that reads as the toolbar
        // vibrating, with an amplitude that grows with how fast you drag.
        // Measuring the pair from one layout pass makes the answer absolute, so
        // a stale reading still produces the same width.
        let placed = spacer.frame.width
        let right = otherBranchButton.convert(NSPoint(x: otherBranchButton.bounds.maxX, y: 0), to: nil).x
        // Never push the cluster past the trailing edge — whatever doesn't fit
        // drops into the overflow menu.
        let limit = window.frame.width - Self.trailingReserve - (right - placed)
        let width = max(1, min(target - (centre - placed), limit))

        guard abs(width - spacer.width) > 0.5 else { return }
        spacer.width = width
        // Verify after the toolbar re-lays out; converged passes stop here.
        scheduleAlign()
    }

    /// Re-checks after AppKit has had a chance to lay out. Bounded, because the
    /// toolbar and the split view settle at different times after launch and a
    /// layout that never settles must not turn into a permanent poll.
    private func scheduleAlign() {
        guard !alignScheduled, alignRetries > 0 else { return }
        alignScheduled = true
        alignRetries -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.alignScheduled = false
            self?.alignSyncToDivider()
        }
    }

    private func configure(
        _ control: NSSegmentedControl,
        segment: Int,
        label: String,
        symbol: String,
        enabled: Bool
    ) {
        control.setLabel(label, forSegment: segment)
        control.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: segment)
        control.setImageScaling(.scaleProportionallyDown, forSegment: segment)
        control.setEnabled(enabled, forSegment: segment)
        control.setWidth(0, forSegment: segment)
    }

    private var downAction: SyncAction {
        if modifiers.contains(.option) { return .fetch }
        if modifiers.contains(.command) && modifiers.contains(.shift) { return .rebase }
        return .pull
    }

    private var downLabel: String {
        switch downAction {
        case .fetch: "Fetch"
        case .rebase: "Rebase"
        default: "Pull"
        }
    }

    private var downSymbol: String {
        downAction == .fetch ? "arrow.down.circle.dotted" : "arrow.down"
    }

    private var upAction: SyncAction {
        modifiers.contains(.command) && modifiers.contains(.shift) ? .forcePush : .push
    }

    private var upLabel: String {
        upAction == .forcePush ? "Force Push" : "Push"
    }

    // MARK: - Actions

    @objc private func syncSegmentClicked(_ sender: NSSegmentedControl) {
        guard let vm = appState.selectedViewModel else { return }
        let action: SyncAction
        if vm.otherBranchIsLocal {
            action = .merge
        } else {
            action = sender.selectedSegment == 0 ? downAction : upAction
        }
        Task { await vm.performSync(action, using: appState.git) }
    }

    @objc private func checkoutBranch(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let vm = appState.selectedViewModel else { return }
        Task {
            do {
                try await appState.git.checkout(branch: name, at: vm.repository.url)
                await vm.refreshAll(using: appState.git)
            } catch let error as GitError {
                vm.lastError = error.description
            } catch {
                vm.lastError = error.localizedDescription
            }
        }
    }

    @objc private func selectOtherBranch(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let vm = appState.selectedViewModel else { return }
        Task { await vm.setOtherBranch(name, using: appState.git) }
    }
}

/// Sized by intrinsic content rather than a constraint: a toolbar item view
/// that measures zero in either axis makes the whole toolbar spill into the
/// overflow menu.
private final class SpacerView: NSView {
    var width: CGFloat = 1 {
        didSet {
            width = max(width, 1)
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: 24) }
}

// MARK: - Menu building

extension MainToolbar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Item 0 is the pull-down's title, and stays.
        while menu.numberOfItems > 1 {
            menu.removeItem(at: 1)
        }
        guard let vm = appState.selectedViewModel else { return }

        if menu === branchButton.menu {
            for branch in vm.branches {
                menu.addItem(item(
                    branch.name,
                    action: #selector(checkoutBranch(_:)),
                    checked: branch.isCurrent
                ))
            }
        } else if menu === otherBranchButton.menu {
            buildOtherBranchMenu(menu, vm: vm)
        }
    }

    private func buildOtherBranchMenu(_ menu: NSMenu, vm: RepositoryViewModel) {
        let locals = vm.branches.filter { !$0.isCurrent }
        if !locals.isEmpty {
            menu.addItem(.sectionHeader(title: "Local Branches"))
            for branch in locals {
                menu.addItem(otherBranchMenuItem(branch.name, vm: vm))
            }
        }

        if vm.remotes.count > 1 {
            for remote in vm.remotes {
                let names = vm.remoteBranches.filter { $0.hasPrefix(remote.name + "/") }
                guard !names.isEmpty else { continue }
                let submenu = NSMenu(title: remote.name)
                for name in names {
                    submenu.addItem(otherBranchMenuItem(name, vm: vm))
                }
                let parent = NSMenuItem(title: remote.name, action: nil, keyEquivalent: "")
                parent.submenu = submenu
                menu.addItem(parent)
            }
        } else if !vm.remoteBranches.isEmpty {
            menu.addItem(.sectionHeader(title: "Remote Branches"))
            for name in vm.remoteBranches {
                menu.addItem(otherBranchMenuItem(name, vm: vm))
            }
        }
    }

    private func otherBranchMenuItem(_ name: String, vm: RepositoryViewModel) -> NSMenuItem {
        item(name, action: #selector(selectOtherBranch(_:)), checked: name == vm.otherBranch)
    }

    private func item(_ title: String, action: Selector, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = title
        item.state = checked ? .on : .off
        return item
    }
}
