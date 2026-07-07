import SwiftUI
import AppKit

struct MainToolbar: ToolbarContent {
    @Environment(AppState.self) private var appState

    var body: some ToolbarContent {
        // Left: add repository, settings.
        ToolbarItem(placement: .navigation) {
            Button {
                NotificationCenter.default.post(name: .addRepositoryRequested, object: nil)
            } label: {
                Image(systemName: "plus")
            }
            .help("Add Repository")
        }
        ToolbarItem(placement: .navigation) {
            Button {
                // Settings placeholder. Wired later.
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .disabled(true)
        }

        // Center: branch picker, sync controls, other-branch picker. macOS lays
        // out a single principal item centered (and gives it precedence over the
        // window title); multiple sibling `.principal` items fragment and drop
        // out instead. Keep them as one principal item holding an HStack so the
        // whole cluster renders together, centered.
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                BranchPicker()
                SyncControls()
                OtherBranchPicker()
            }
        }
    }
}

private struct BranchPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Drive the display off the current branch (which `status` reports even
        // for a repo with no commits yet), not off the `branches` list. A repo
        // sitting on an unborn `main` has an empty `refs/heads`, but we still
        // want the toolbar to read "main" rather than "—".
        if let vm = appState.selectedViewModel, let current = vm.currentBranch {
            Menu {
                ForEach(vm.branches, id: \.name) { branch in
                    Button {
                        Task { await switchTo(branch.name, vm: vm) }
                    } label: {
                        HStack {
                            if branch.isCurrent {
                                Image(systemName: "checkmark")
                            }
                            Text(branch.name)
                        }
                    }
                }
            } label: {
                Label(current, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Nothing to switch to until there's more than the current branch.
            .disabled(vm.branches.count <= 1)
            .help("Current Branch")
        } else {
            Label("No Branch", systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        }
    }

    private func switchTo(_ branch: String, vm: RepositoryViewModel) async {
        do {
            try await appState.git.checkout(branch: branch, at: vm.repository.url)
            await vm.refreshAll(using: appState.git)
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }
}

/// Gitbox's pull/push pair. Labels morph live with held modifiers
/// (⌥ → Fetch, ⇧⌘ → Rebase / Force Push), and the pair collapses to a single
/// Merge button when the "other branch" is a local branch.
private struct SyncControls: View {
    @Environment(AppState.self) private var appState
    @State private var modifiers: NSEvent.ModifierFlags = []
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            if let vm = appState.selectedViewModel, vm.otherBranch != nil, vm.otherBranchIsLocal {
                Button {
                    run(.merge, vm: vm)
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .help("Merge \(vm.otherBranch ?? "") into \(vm.currentBranch ?? "current branch")")
                .disabled(vm.isSyncing)
            } else {
                let vm = appState.selectedViewModel
                Button {
                    if let vm { run(downAction, vm: vm) }
                } label: {
                    Label(downLabel, systemImage: downIcon)
                }
                .help("\(downLabel) from \(vm?.otherBranch ?? "the other branch")")
                .disabled(vm == nil || vm?.otherBranch == nil || vm?.isSyncing == true)

                Button {
                    if let vm { run(upAction, vm: vm) }
                } label: {
                    Label(upLabel, systemImage: "arrow.up")
                }
                .help("\(upLabel) to \(vm?.otherBranch ?? "the other branch")")
                .disabled(vm == nil || vm?.otherBranch == nil || vm?.isSyncing == true)
            }
        }
        .onAppear {
            // NSEvent monitor rather than .onModifierKeysChanged: fires regardless
            // of which pane has focus, which is what a toolbar affordance wants.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                modifiers = event.modifierFlags
                return event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
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

    private var downIcon: String {
        downAction == .fetch ? "arrow.down.circle.dotted" : "arrow.down"
    }

    private var upAction: SyncAction {
        modifiers.contains(.command) && modifiers.contains(.shift) ? .forcePush : .push
    }

    private var upLabel: String {
        upAction == .forcePush ? "Force Push" : "Push"
    }

    private func run(_ action: SyncAction, vm: RepositoryViewModel) {
        Task { await vm.performSync(action, using: appState.git) }
    }
}

/// Gitbox's "other branch" popup: the branch the current one is compared and
/// synced against. Remote branches (grouped per remote when there are several)
/// plus other local branches. Stored as upstream config.
private struct OtherBranchPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let vm = appState.selectedViewModel {
            Menu {
                let locals = vm.branches.filter { !$0.isCurrent }
                if !locals.isEmpty {
                    Section("Local Branches") {
                        ForEach(locals, id: \.name) { branch in
                            selectionButton(branch.name, vm: vm)
                        }
                    }
                }
                if vm.remotes.count > 1 {
                    ForEach(vm.remotes, id: \.name) { remote in
                        Menu(remote.name) {
                            ForEach(branches(of: remote.name, vm: vm), id: \.self) { name in
                                selectionButton(name, vm: vm)
                            }
                        }
                    }
                } else if !vm.remoteBranches.isEmpty {
                    Section("Remote Branches") {
                        ForEach(vm.remoteBranches, id: \.self) { name in
                            selectionButton(name, vm: vm)
                        }
                    }
                }
            } label: {
                Label(vm.otherBranch ?? "No Branch", systemImage: "point.3.connected.trianglepath.dotted")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(vm.remoteBranches.isEmpty && vm.branches.count <= 1)
            .help("Other Branch — what the current branch is compared and synced with")
        } else {
            Label("No Branch", systemImage: "point.3.connected.trianglepath.dotted")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        }
    }

    private func branches(of remote: String, vm: RepositoryViewModel) -> [String] {
        vm.remoteBranches.filter { $0.hasPrefix(remote + "/") }
    }

    private func selectionButton(_ name: String, vm: RepositoryViewModel) -> some View {
        Button {
            Task { await vm.setOtherBranch(name, using: appState.git) }
        } label: {
            HStack {
                if name == vm.otherBranch {
                    Image(systemName: "checkmark")
                }
                Text(name)
            }
        }
    }
}
