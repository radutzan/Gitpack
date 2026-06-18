import SwiftUI
import AppKit

/// Single, shared file-row layout used by both the working-copy and commit detail
/// panes. Same row height regardless of whether the trailing checkbox is present.
/// Selection styling is provided by the enclosing `List`.
struct FileRowView: View {
    let path: String
    let oldPath: String?
    let statusLabel: String
    /// Pass `nil` for read-only contexts (commit detail). Pass a binding to render
    /// a trailing checkbox bound to the staged state.
    let stagedBinding: Binding<Bool>?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: path))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(displayPath)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(statusLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let stagedBinding {
                Toggle("", isOn: stagedBinding)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var displayPath: String {
        if let oldPath, oldPath != path {
            return "\(oldPath) → \(path)"
        }
        return path
    }
}
