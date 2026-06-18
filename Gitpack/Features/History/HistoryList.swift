import SwiftUI

struct HistoryList: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let vm = appState.selectedViewModel {
            HistoryListContent(vm: vm)
        } else {
            ContentUnavailableView(
                "No Repository",
                systemImage: "folder.badge.questionmark",
                description: Text("Select a repository in the sidebar, or add one with ⌘O.")
            )
        }
    }
}

private struct HistoryListContent: View {
    @Environment(AppState.self) private var appState
    @Bindable var vm: RepositoryViewModel

    var body: some View {
        List(selection: $vm.selection) {
            workingCopyRow
                .tag(HistoryItem.workingCopy)
            ForEach(vm.commits) { commit in
                CommitRow(commit: commit)
                    .tag(HistoryItem.commit(commit.id))
            }
            if vm.commits.count >= 200 {
                loadMoreRow
            }
        }
        .listStyle(.inset)
        .refreshable {
            await vm.refreshAll(using: appState.git)
        }
        .overlay {
            if let error = vm.lastError {
                VStack {
                    ErrorBanner(text: error) { vm.lastError = nil }
                    Spacer()
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var workingCopyRow: some View {
        let status = vm.status
        let isClean = status?.isClean ?? true
        // Two-line VStack mirroring CommitRow so the pseudo-row matches the
        // commit-row height. Second line shows branch/ahead-behind context, or
        // a non-breaking space placeholder if there's nothing useful to say.
        VStack(alignment: .leading, spacing: 1) {
            Text(isClean ? "Working directory clean" : workingCopySummary(status))
                .font(.body)
                .fontWeight(isClean ? .regular : .semibold)
                .foregroundStyle(isClean ? .secondary : .primary)
                .lineLimit(1)
            Text(workingCopySubtitle(status))
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func workingCopySubtitle(_ status: WorkingCopyStatus?) -> String {
        guard let status else { return "\u{00A0}" }
        var parts: [String] = []
        if let branch = status.branch { parts.append(branch) }
        if status.ahead > 0 { parts.append("↑\(status.ahead)") }
        if status.behind > 0 { parts.append("↓\(status.behind)") }
        return parts.isEmpty ? "\u{00A0}" : parts.joined(separator: " · ")
    }

    private func workingCopySummary(_ status: WorkingCopyStatus?) -> String {
        guard let status else { return "Working copy" }
        let modified = status.modifiedFileCount
        let new = status.newFileCount
        var parts: [String] = []
        if modified > 0 { parts.append("\(modified) modified file\(modified == 1 ? "" : "s")") }
        if new > 0 { parts.append("\(new) new file\(new == 1 ? "" : "s")") }
        return parts.isEmpty ? "\(status.entries.count) changed" : parts.joined(separator: ", ")
    }

    private var loadMoreRow: some View {
        Button {
            Task { await vm.loadMoreHistory(using: appState.git) }
        } label: {
            HStack {
                Spacer()
                Text("Load more commits")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }
}

private struct CommitRow: View {
    let commit: Commit

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(commit.authorName)
                    .font(.body)
                    .fontWeight(commit.isMerge ? .regular : .semibold)
                    .italic(commit.isMerge)
                    .foregroundStyle(commit.isMerge ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Text(commit.date, format: DateFormat.commitTimestamp)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .italic(commit.isMerge)
                    .opacity(commit.isMerge ? 0.7 : 1)
            }
            Text(commit.subject.isEmpty ? " " : commit.subject)
                .font(.body)
                .italic(commit.isMerge)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(radius: 2, y: 1)
    }
}
