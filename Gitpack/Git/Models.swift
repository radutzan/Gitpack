import Foundation

struct Repository: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var displayName: String
    var url: URL
    var parentID: UUID?

    init(id: UUID = UUID(), displayName: String, url: URL, parentID: UUID? = nil) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.parentID = parentID
    }
}

struct Commit: Identifiable, Hashable, Sendable {
    let id: String
    let shortID: String
    let authorName: String
    let authorEmail: String
    let date: Date
    let parents: [String]
    let subject: String
    let body: String

    var isMerge: Bool { parents.count > 1 }
}

enum FileChangeStatus: String, Hashable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case ignored
    case unmerged

    var label: String {
        switch self {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .typeChanged: "type changed"
        case .untracked: "new"
        case .ignored: "ignored"
        case .unmerged: "conflict"
        }
    }
}

struct CommitFileChange: Identifiable, Hashable, Sendable {
    var id: String { "\(status.rawValue):\(path):\(oldPath ?? "")" }
    let status: FileChangeStatus
    let path: String
    let oldPath: String?
}

struct WorkingCopyEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let oldPath: String?
    let stagedStatus: FileChangeStatus?
    let unstagedStatus: FileChangeStatus?

    var isFullyStaged: Bool { stagedStatus != nil && unstagedStatus == nil }
    var isPartiallyStaged: Bool { stagedStatus != nil && unstagedStatus != nil }
    var isUntracked: Bool { unstagedStatus == .untracked }

    var displayStatus: FileChangeStatus {
        stagedStatus ?? unstagedStatus ?? .modified
    }
}

struct WorkingCopyStatus: Sendable {
    let branch: String?
    let upstream: String?
    let ahead: Int
    let behind: Int
    let entries: [WorkingCopyEntry]

    var isClean: Bool { entries.isEmpty }

    var modifiedFileCount: Int {
        entries.filter { $0.unstagedStatus != .untracked || $0.stagedStatus != nil }.count
    }

    var newFileCount: Int {
        entries.filter { $0.unstagedStatus == .untracked || $0.stagedStatus == .added }.count
    }
}

/// One page of a live search: the commits that matched, and how many were
/// examined. The count is what tells the search loop it has reached the end of
/// history, and what the results bar reports as progress.
struct CommitSearchPage: Sendable {
    let matches: [Commit]
    let scanned: Int
}

/// A tag and the commit it ultimately points at. An annotated tag points at a
/// tag object, so `targetSHA` is the *peeled* value — that's what history rows
/// have to match on.
struct Tag: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let targetSHA: String
}

/// One entry of `git stash list`. The ref is carried verbatim so apply and drop
/// never have to rebuild `stash@{n}` out of an index.
struct Stash: Identifiable, Hashable, Sendable {
    var id: String { ref }
    let ref: String
    let message: String
    let date: Date
}

/// A git operation left half-finished in the working copy — the only "mode"
/// Gitpack has, and the only time the stage pane grows buttons. Raw values are
/// the git subcommand itself, so abort/skip/continue is one call for all four.
enum RepositoryOperation: String, Sendable {
    case rebase
    case merge
    case cherryPick = "cherry-pick"
    case revert

    var label: String {
        switch self {
        case .rebase: "Rebase"
        case .merge: "Merge"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    /// `git merge` has no `--skip`.
    var canSkip: Bool { self != .merge }
}

enum OperationAction: String, Sendable {
    case abort
    case skip
    case `continue`
}

/// The commit-set difference between the current branch and its "other branch"
/// (Gitbox's comparison target — a remote tracking branch or another local branch).
struct Divergence: Hashable, Sendable {
    let otherRef: String
    /// SHAs on the current branch but not on the other (green dots).
    let unpushed: Set<String>
    /// SHAs on the other branch but not on the current (blue dots).
    let unmerged: Set<String>
}

struct Branch: Hashable, Sendable {
    let name: String
    let upstream: String?
    let isCurrent: Bool
}

struct Remote: Hashable, Sendable {
    let name: String
    let url: String
}
