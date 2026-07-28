import AppKit

extension NSToolbarItem.Identifier {
    static let addRepository = NSToolbarItem.Identifier("addRepository")
    static let branchPicker = NSToolbarItem.Identifier("branchPicker")
    static let syncControls = NSToolbarItem.Identifier("syncControls")
    static let otherBranchPicker = NSToolbarItem.Identifier("otherBranchPicker")
}

/// Gitbox's toolbar: current branch, the pull/push pair, and the "other
/// branch" it syncs against. The three centre items are one cluster —
/// `centeredItemIdentifiers` keeps them centred without spacer juggling.
final class MainToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "MainToolbar")

    private let appState: AppState
    private var branchItem: NSMenuToolbarItem?
    private var otherBranchItem: NSMenuToolbarItem?
    private var syncControl: NSSegmentedControl?
    private var modifiers: NSEvent.ModifierFlags = []
    private var flagsMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.branchPicker, .syncControls, .otherBranchPicker]

        // A local monitor rather than a responder-chain override: the labels
        // should morph no matter which pane holds focus.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifiers = event.modifierFlags
            self?.updateSyncControl()
            return event
        }

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
        [.addRepository, .branchPicker, .syncControls, .otherBranchPicker]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
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

        case .branchPicker:
            let item = makeMenuItem(
                identifier,
                symbol: "arrow.triangle.branch",
                toolTip: "Current Branch"
            )
            branchItem = item
            return item

        case .otherBranchPicker:
            let item = makeMenuItem(
                identifier,
                symbol: "point.3.connected.trianglepath.dotted",
                toolTip: "Other Branch — what the current branch is compared and synced with"
            )
            otherBranchItem = item
            return item

        case .syncControls:
            let control = NSSegmentedControl(
                labels: ["Pull", "Push"],
                trackingMode: .momentary,
                target: self,
                action: #selector(syncSegmentClicked(_:))
            )
            control.segmentStyle = .texturedRounded
            syncControl = control
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Sync"
            item.view = control
            updateSyncControl()
            return item

        default:
            return nil
        }
    }

    private func makeMenuItem(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        toolTip: String
    ) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.toolTip = toolTip
        item.showsIndicator = true
        // Built on demand in `menuNeedsUpdate`, so it can never be stale and
        // needs no observation of its own.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        return item
    }

    // MARK: - State

    private func refresh() {
        let vm = appState.selectedViewModel

        let current = vm?.currentBranch
        branchItem?.title = current ?? "No Branch"
        branchItem?.label = current ?? "No Branch"
        branchItem?.isEnabled = (vm?.branches.count ?? 0) > 1

        let other = vm?.otherBranch
        otherBranchItem?.title = other ?? "No Branch"
        otherBranchItem?.label = other ?? "No Branch"
        otherBranchItem?.isEnabled = !(vm?.remoteBranches.isEmpty ?? true) || (vm?.branches.count ?? 0) > 1

        updateSyncControl()
    }

    /// Pull/Push, morphing with held modifiers (⌥ → Fetch, ⇧⌘ → Rebase / Force
    /// Push), collapsing to a single Merge segment when the other branch is local.
    private func updateSyncControl() {
        guard let control = syncControl else { return }
        let vm = appState.selectedViewModel
        let enabled = vm?.otherBranch != nil && vm?.isSyncing != true

        if vm?.otherBranchIsLocal == true {
            control.segmentCount = 1
            configure(control, segment: 0, label: "Merge", symbol: "arrow.triangle.merge", enabled: enabled)
        } else {
            control.segmentCount = 2
            configure(control, segment: 0, label: downLabel, symbol: downSymbol, enabled: enabled)
            configure(control, segment: 1, label: upLabel, symbol: "arrow.up", enabled: enabled)
        }
        control.sizeToFit()
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

// MARK: - Menu building

extension MainToolbar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let vm = appState.selectedViewModel else { return }

        if menu === branchItem?.menu {
            for branch in vm.branches {
                menu.addItem(item(
                    branch.name,
                    action: #selector(checkoutBranch(_:)),
                    checked: branch.isCurrent
                ))
            }
        } else if menu === otherBranchItem?.menu {
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
