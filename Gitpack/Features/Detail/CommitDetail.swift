import SwiftUI
import AppKit

struct CommitDetail: View {
    @Environment(AppState.self) private var appState
    @Bindable var vm: RepositoryViewModel
    let commit: Commit
    @State private var selectedFile: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                if !messageBody.isEmpty {
                    Divider()
                    Text(messageBody)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            fileList
        }
        .task(id: commit.id) {
            selectedFile = nil
            await vm.loadFilesForCommit(commit.id, using: appState.git)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                labelRow("Commit", value: commit.id, mono: true)
                if !commit.parents.isEmpty {
                    labelRow("Parent", value: commit.parents.joined(separator: " "), mono: true, accent: true)
                }
                labelRow("Date", value: commit.date.formatted(DateFormat.commitDetailTimestamp), mono: false)
                labelRow("Author", value: "\(commit.authorName) ", mono: false, trailing: AnyView(
                    Text(commit.authorEmail).foregroundStyle(Color.accentColor)
                ))
            }
            Spacer(minLength: 8)
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 56, height: 56)
                .foregroundStyle(.tertiary)
        }
    }

    private func labelRow(
        _ label: String,
        value: String,
        mono: Bool,
        accent: Bool = false,
        trailing: AnyView? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .font(.body.weight(.semibold))
                .frame(width: 60, alignment: .trailing)
            Group {
                if let trailing {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(value)
                        trailing
                    }
                } else {
                    Text(value)
                        .foregroundStyle(accent ? Color.accentColor : .primary)
                }
            }
            .font(mono ? .system(.body, design: .monospaced) : .body)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer()
        }
    }

    private var messageBody: String {
        let trimmed = commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return commit.subject }
        return commit.subject + "\n\n" + trimmed
    }

    private var files: [CommitFileChange] { vm.commitFiles[commit.id] ?? [] }

    private var fileList: some View {
        List(selection: $selectedFile) {
            ForEach(files) { file in
                FileRowView(
                    path: file.path,
                    oldPath: file.oldPath,
                    statusLabel: file.status.label,
                    stagedBinding: nil
                )
                .tag(file.id)
                .gesture(TapGesture(count: 2).onEnded { Task { await openDiff(file) } })
            }
        }
        .listStyle(.plain)
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let id = selectedIDs.first, let file = files.first(where: { $0.id == id }) {
                Button("View Diff") { Task { await openDiff(file) } }
                Divider()
                Button("Reveal in Finder") { reveal(file) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
        } primaryAction: { selectedIDs in
            if let id = selectedIDs.first, let file = files.first(where: { $0.id == id }) {
                Task { await openDiff(file) }
            }
        }
        .overlay {
            if files.isEmpty {
                Text("No file changes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reveal(_ file: CommitFileChange) {
        let fileURL = vm.repository.url.appendingPathComponent(file.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    private func openDiff(_ file: CommitFileChange) async {
        let parent = commit.parents.first
        do {
            try await appState.diffTool.diffCommit(
                repoURL: vm.repository.url,
                path: file.path,
                commitSHA: commit.id,
                parentSHA: parent
            )
        } catch let error as GitError {
            vm.lastError = error.description
        } catch {
            vm.lastError = error.localizedDescription
        }
    }
}

func iconName(for path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "md", "markdown": return "doc.text"
    case "json", "yaml", "yml", "plist", "toml": return "curlybraces"
    case "png", "jpg", "jpeg", "gif", "heic", "tiff", "svg": return "photo"
    case "pbxproj": return "hammer"
    default: return "doc"
    }
}
