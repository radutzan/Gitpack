import SwiftUI

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
        }
    }
}

extension Notification.Name {
    static let addRepositoryRequested = Notification.Name("Gitpack.addRepositoryRequested")
}
