import SwiftUI

struct DetailPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let vm = appState.selectedViewModel {
            content(for: vm)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(for vm: RepositoryViewModel) -> some View {
        switch vm.selection {
        case .workingCopy:
            WorkingCopyDetail(vm: vm)
        case .commit(let sha):
            if let commit = vm.commits.first(where: { $0.id == sha }) {
                CommitDetail(vm: vm, commit: commit)
            } else {
                placeholder("Commit not loaded")
            }
        case .none:
            placeholder("Select an item")
        }
    }

    private func placeholder(_ text: String) -> some View {
        ContentUnavailableView(text, systemImage: "doc.text")
    }
}
