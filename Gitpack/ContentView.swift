import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Plain HSplitView, not NavigationSplitView: the NavigationSplitView
        // NSSplitView bridge intermittently laid out its columns to the full
        // List content height (observed 13k–23k pt tall columns, autosaved and
        // restored), pushing all pane content off-viewport — the window looked
        // empty except for toolbar and dividers. Gitbox's layout is a fixed
        // 3-pane; HSplitView models it without that machinery.
        HSplitView {
            RepositorySidebar()
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320, maxHeight: .infinity)
            HistoryList()
                .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            DetailPane()
                .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
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
            appState.startAutofetch()
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
