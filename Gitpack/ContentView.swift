import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            RepositorySidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            HistoryList()
                .navigationSplitViewColumnWidth(min: 320, ideal: 480)
        } detail: {
            DetailPane()
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        }
        .navigationTitle(windowTitle)
        .toolbar {
            MainToolbar()
        }
        .task(id: appState.selectedRepositoryID) {
            await loadSelected()
            // Watch the now-selected repo so on-disk changes reflect live.
            appState.startWatchingSelectedRepository()
        }
        .task {
            // Refresh when the app returns to the foreground, catching any
            // changes made while it was inactive.
            let activations = NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            )
            for await _ in activations {
                await appState.foregroundRefresh()
            }
        }
    }

    private var windowTitle: String {
        if let repo = appState.selectedRepository {
            let parent = repo.url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? repo.displayName : "\(repo.displayName) — \(parent)"
        }
        return "Gitpack"
    }

    private func loadSelected() async {
        guard let vm = appState.selectedViewModel else { return }
        await vm.refreshAll(using: appState.git)
    }
}
