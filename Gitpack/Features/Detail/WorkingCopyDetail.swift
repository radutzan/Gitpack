import SwiftUI
import AppKit

struct WorkingCopyDetail: View {
    @Environment(AppState.self) private var appState
    @Bindable var vm: RepositoryViewModel
    @State private var commitMessage: String = ""
    @State private var isCommitting = false
    @State private var selection: Set<String> = []
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            commitComposer
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Divider()
            fileList
        }
        .animation(.easeInOut(duration: 0.18), value: composerExpanded)
    }

    // MARK: - Composer

    private var composerExpanded: Bool {
        composerFocused || !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commitComposer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(
                "Commit message",
                text: $commitMessage,
                axis: .vertical
            )
            .focused($composerFocused)
            .lineLimit(composerExpanded ? 4...8 : 1...1)
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3))
            )
            if composerExpanded {
                HStack(spacing: 8) {
                    if isCommitting {
                        ProgressView().controlSize(.small)
                    }
                    Button("Commit") {
                        Task { await performCommit() }
                    }
                    .disabled(!canCommit)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var canCommit: Bool {
        guard let status = vm.status else { return false }
        let hasStaged = status.entries.contains { $0.stagedStatus != nil }
        return hasStaged
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCommitting
    }

    private func performCommit() async {
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await appState.git.commit(message: commitMessage, at: vm.repository.url)
            commitMessage = ""
            composerFocused = false
            await vm.refreshAll(using: appState.git)
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }

    // MARK: - File list

    private var entries: [WorkingCopyEntry] { vm.status?.entries ?? [] }

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                FileRowView(
                    path: entry.path,
                    oldPath: entry.oldPath,
                    statusLabel: statusText(for: entry),
                    stagedBinding: Binding(
                        get: { entry.isFullyStaged },
                        set: { _ in Task { await toggleStaging([entry.path]) } }
                    )
                )
                .tag(entry.path)
                .gesture(TapGesture(count: 2).onEnded { Task { await openDiff(entry.path) } })
            }
        }
        .listStyle(.plain)
        // Gitbox single-key shortcuts; scoped to list focus so text fields are safe.
        .onKeyPress(KeyEquivalent("s")) {
            guard !selection.isEmpty else { return .ignored }
            Task { await toggleStaging(Array(selection)) }
            return .handled
        }
        .onKeyPress(KeyEquivalent("d")) {
            guard selection.count == 1, let path = selection.first else { return .ignored }
            Task { await openDiff(path) }
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .stageAllRequested)) { _ in
            let unstaged = entries.filter { $0.unstagedStatus != nil }.map(\.path)
            if !unstaged.isEmpty {
                Task { await stage(unstaged) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .commitRequested)) { _ in
            if canCommit {
                Task { await performCommit() }
            } else {
                composerFocused = true
            }
        }
        .contextMenu(forSelectionType: String.self) { selectedPaths in
            menuItems(for: selectedPaths)
        } primaryAction: { selectedPaths in
            // Default action: double-click on the row already triggers diff via the
            // tap gesture above. This handler runs on Return-key activation.
            if let single = selectedPaths.first, selectedPaths.count == 1 {
                Task { await openDiff(single) }
            }
        }
        .overlay {
            if entries.isEmpty {
                Text("Working directory clean")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menuItems(for selectedPaths: Set<String>) -> some View {
        let paths = Array(selectedPaths)
        let resolved = entries.filter { selectedPaths.contains($0.path) }
        let anyHasStaged = resolved.contains { $0.stagedStatus != nil }
        let anyHasUnstaged = resolved.contains { $0.unstagedStatus != nil }
        let single = resolved.count == 1 ? resolved.first : nil

        if anyHasUnstaged {
            Button(stageLabel(count: paths.count)) {
                Task { await stage(paths) }
            }
        }
        if anyHasStaged {
            Button(unstageLabel(count: paths.count)) {
                Task { await unstage(paths) }
            }
        }
        if let single {
            Button("View Diff") { Task { await openDiff(single.path) } }
        }
        Divider()
        if let single {
            Button("Reveal in Finder") { reveal(single.path) }
            Button("Copy Path") { copyPath(single.path) }
        } else if !paths.isEmpty {
            Button("Copy Paths") { copyPath(paths.joined(separator: "\n")) }
        }
        if !paths.isEmpty {
            Divider()
            Button(discardLabel(count: paths.count), role: .destructive) {
                Task { await discard(paths) }
            }
        }
    }

    private func stageLabel(count: Int) -> String {
        count > 1 ? "Stage \(count) Files" : "Stage"
    }

    private func unstageLabel(count: Int) -> String {
        count > 1 ? "Unstage \(count) Files" : "Unstage"
    }

    private func discardLabel(count: Int) -> String {
        count > 1 ? "Discard Changes to \(count) Files…" : "Discard Changes…"
    }

    private func statusText(for entry: WorkingCopyEntry) -> String {
        entry.isPartiallyStaged ? "\(entry.displayStatus.label) (partial)" : entry.displayStatus.label
    }

    // MARK: - Mutations

    private func toggleStaging(_ paths: [String]) async {
        let resolved = entries.filter { paths.contains($0.path) }
        let allStaged = resolved.allSatisfy { $0.isFullyStaged }
        if allStaged {
            await unstage(paths)
        } else {
            await stage(paths)
        }
    }

    private func stage(_ paths: [String]) async {
        do {
            try await appState.git.stage(paths: paths, at: vm.repository.url)
            await vm.refreshStatusOnly(using: appState.git)
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }

    private func unstage(_ paths: [String]) async {
        do {
            try await appState.git.unstage(paths: paths, at: vm.repository.url)
            await vm.refreshStatusOnly(using: appState.git)
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }

    private func discard(_ paths: [String]) async {
        let alert = NSAlert()
        if paths.count == 1 {
            alert.messageText = "Discard changes to \(paths[0])?"
        } else {
            alert.messageText = "Discard changes to \(paths.count) files?"
        }
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await appState.git.discard(paths: paths, at: vm.repository.url)
            await vm.refreshStatusOnly(using: appState.git)
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }

    private func reveal(_ path: String) {
        let fileURL = vm.repository.url.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    private func copyPath(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openDiff(_ path: String) async {
        do {
            try await appState.diffTool.diffWorkingCopy(repoURL: vm.repository.url, path: path)
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }
}
