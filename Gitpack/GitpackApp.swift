import SwiftUI
import AppKit

@main
struct GitpackApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Repository…") {
                    NotificationCenter.default.post(name: .addRepositoryRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // Gitbox's Repository menu. Bare-key equivalents (u/p) live on the
            // focused lists via .onKeyPress — bare keys in the menu bar would
            // fight text fields — so the menu carries the modifier variants.
            CommandMenu("Repository") {
                let vm = appState.selectedViewModel
                Button(vm?.otherBranchIsLocal == true ? "Merge" : "Pull") {
                    if let vm {
                        Task { await vm.performSync(vm.otherBranchIsLocal ? .merge : .pull, using: appState.git) }
                    }
                }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(vm?.otherBranch == nil || vm?.isSyncing == true)

                Button("Push") {
                    if let vm { Task { await vm.performSync(.push, using: appState.git) } }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(vm?.otherBranch == nil || vm?.otherBranchIsLocal == true || vm?.isSyncing == true)

                Button("Fetch") {
                    if let vm { Task { await vm.performSync(.fetch, using: appState.git) } }
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(vm == nil || vm?.isSyncing == true)

                Button("Rebase") {
                    if let vm { Task { await vm.performSync(.rebase, using: appState.git) } }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(vm?.otherBranch == nil || vm?.otherBranchIsLocal == true || vm?.isSyncing == true)

                Button("Force Push") {
                    if let vm { Task { await vm.performSync(.forcePush, using: appState.git) } }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(vm?.otherBranch == nil || vm?.otherBranchIsLocal == true || vm?.isSyncing == true)

                Divider()

                Button("Open in Finder") {
                    if let url = appState.selectedRepository?.url {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(appState.selectedRepository == nil)

                Button("Open in Terminal") {
                    if let url = appState.selectedRepository?.url {
                        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                .disabled(appState.selectedRepository == nil)
            }

            CommandMenu("Stage") {
                Button("Stage All") {
                    NotificationCenter.default.post(name: .stageAllRequested, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(appState.selectedViewModel?.status?.isClean ?? true)

                Button("Commit") {
                    NotificationCenter.default.post(name: .commitRequested, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appState.selectedViewModel?.status?.isClean ?? true)
            }
        }
    }
}

extension Notification.Name {
    static let addRepositoryRequested = Notification.Name("Gitpack.addRepositoryRequested")
    static let stageAllRequested = Notification.Name("Gitpack.stageAllRequested")
    static let commitRequested = Notification.Name("Gitpack.commitRequested")
}
