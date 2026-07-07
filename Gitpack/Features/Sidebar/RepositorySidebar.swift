import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RepositorySidebar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var bindable = appState
        List(selection: $bindable.selectedRepositoryID) {
            Section("Repositories") {
                ForEach(topLevelRepositories) { repo in
                    sidebarRow(for: repo)
                    ForEach(children(of: repo)) { child in
                        sidebarRow(for: child)
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .addRepositoryRequested)) { _ in
            promptToAddRepository()
        }
    }

    private var topLevelRepositories: [Repository] {
        appState.repositories.filter { $0.parentID == nil }
    }

    private func children(of repo: Repository) -> [Repository] {
        appState.repositories.filter { $0.parentID == repo.id }
    }

    @ViewBuilder
    private func sidebarRow(for repo: Repository) -> some View {
        let vm = appState.viewModel(for: repo)
        let background = appState.backgroundState(for: repo.id)
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
            Text(repo.displayName)
                .lineLimit(1)
                .foregroundStyle(vm.isMissing ? .secondary : .primary)
            Spacer(minLength: 4)
            if background.isFetching {
                ProgressView()
                    .controlSize(.small)
            }
            if background.badge > 0 {
                Text(String(background.badge))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.18))
                    )
                    .help("Unpushed + unmerged commits + changed files")
            }
        }
        .tag(repo.id)
        .contextMenu {
            Button("Reveal in Finder") { reveal(repo) }
            Button("Refresh") { Task { await vm.refreshAll(using: appState.git) } }
            Divider()
            Button("Remove from Gitpack", role: .destructive) {
                appState.removeRepository(repo)
            }
        }
    }

    // MARK: - Add / drop

    private func promptToAddRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more Git repositories"
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls {
                _ = await appState.addRepository(at: url)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    _ = await appState.addRepository(at: url)
                }
            }
        }
        return handled
    }

    private func reveal(_ repo: Repository) {
        NSWorkspace.shared.activateFileViewerSelecting([repo.url])
    }
}
