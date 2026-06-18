import SwiftUI

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

        // Center: branch picker, pull, push, upstream picker. macOS lays out a
        // single principal item centered (and gives it precedence over the
        // window title); multiple sibling `.principal` items fragment and drop
        // out instead. Keep them as one principal item holding an HStack so the
        // whole cluster renders together, centered.
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                BranchPicker()
                PullButton()
                PushButton()
                UpstreamPicker()
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

private struct PullButton: View {
    @Environment(AppState.self) private var appState
    @State private var isWorking = false

    var body: some View {
        Button {
            Task { await pull() }
        } label: {
            Label("Pull", systemImage: "arrow.down")
        }
        .help("Pull from upstream")
        .disabled(appState.selectedViewModel == nil || isWorking)
    }

    private func pull() async {
        guard let vm = appState.selectedViewModel else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await appState.git.pull(at: vm.repository.url)
            await vm.refreshAll(using: appState.git)
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }
}

private struct PushButton: View {
    @Environment(AppState.self) private var appState
    @State private var isWorking = false

    var body: some View {
        Button {
            Task { await push() }
        } label: {
            Label("Push", systemImage: "arrow.up")
        }
        .help("Push to upstream")
        .disabled(appState.selectedViewModel == nil || isWorking)
    }

    private func push() async {
        guard let vm = appState.selectedViewModel else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await appState.git.push(at: vm.repository.url)
            await vm.refreshAll(using: appState.git)
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }
}

private struct UpstreamPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let vm = appState.selectedViewModel {
            let current = currentUpstream(vm: vm)
            Menu {
                ForEach(vm.remoteBranches, id: \.self) { remote in
                    Button {
                        Task { await setUpstream(remote, vm: vm) }
                    } label: {
                        HStack {
                            if remote == current {
                                Image(systemName: "checkmark")
                            }
                            Text(remote)
                        }
                    }
                }
            } label: {
                Label(current ?? "No Upstream", systemImage: "point.3.connected.trianglepath.dotted")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // No remotes means there's nothing to set an upstream to.
            .disabled(vm.remoteBranches.isEmpty)
            .help("Upstream Branch")
        } else {
            Label("No Upstream", systemImage: "point.3.connected.trianglepath.dotted")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        }
    }

    private func currentUpstream(vm: RepositoryViewModel) -> String? {
        if let value = vm.status?.upstream { return value }
        return vm.branches.first(where: { $0.name == vm.currentBranch })?.upstream
    }

    private func setUpstream(_ upstream: String, vm: RepositoryViewModel) async {
        guard let branch = vm.currentBranch else { return }
        do {
            try await appState.git.setUpstream(branch: branch, upstream: upstream, at: vm.repository.url)
            await vm.refreshAll(using: appState.git)
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }
}
