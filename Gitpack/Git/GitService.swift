import Foundation

nonisolated protocol GitService: Sendable {
    func isRepository(at url: URL) async -> Bool
    func currentBranch(at url: URL) async throws -> String?
    func branches(at url: URL) async throws -> [Branch]
    func tags(at url: URL) async throws -> [Tag]
    func remotes(at url: URL) async throws -> [Remote]
    func remoteBranches(at url: URL) async throws -> [String]
    func stashes(at url: URL) async throws -> [Stash]
    /// Whatever git operation the working copy is stuck in the middle of, if any.
    func operation(at url: URL) async -> RepositoryOperation?

    func workingCopyStatus(at url: URL) async throws -> WorkingCopyStatus
    func log(at url: URL, limit: Int, skip: Int, refs: [String]) async throws -> [Commit]
    /// One page of live search. Matching happens here rather than in the caller
    /// so the patches — by far the biggest thing git hands back — never cross
    /// onto the main actor. Empty `tokens` matches everything, which is how a
    /// pure path filter (Show File History) reuses this.
    func searchLog(
        at url: URL,
        tokens: [SearchToken],
        paths: [String],
        limit: Int,
        skip: Int,
        refs: [String]
    ) async throws -> CommitSearchPage
    func filesInCommit(at url: URL, sha: String) async throws -> [CommitFileChange]
    func divergence(current: String, other: String, at url: URL) async throws -> Divergence

    func stage(paths: [String], at url: URL) async throws
    func unstage(paths: [String], at url: URL) async throws
    func discard(paths: [String], at url: URL) async throws
    func commit(message: String, at url: URL) async throws

    func stashPush(message: String?, at url: URL) async throws
    func stashApply(ref: String, at url: URL) async throws
    func stashClear(at url: URL) async throws

    func fetch(at url: URL) async throws
    func pull(at url: URL) async throws
    func pullRebase(at url: URL) async throws
    /// Push explicitly. `refspec` is "local:remoteBranch" with `remote` the target
    /// remote name; nil refspec/remote falls back to plain `git push`.
    func push(remote: String?, refspec: String?, force: Bool, at url: URL) async throws
    /// Any commit-ish: the other branch, or a commit picked out of history.
    func merge(ref: String, at url: URL) async throws
    func checkout(ref: String, at url: URL) async throws
    /// Creates the local branch that tracks `remoteBranch`, or switches to it if
    /// it already exists.
    func checkoutTracking(remoteBranch: String, at url: URL) async throws

    func createBranch(name: String, from ref: String, checkout: Bool, at url: URL) async throws
    func deleteBranch(name: String, force: Bool, at url: URL) async throws
    func deleteRemoteBranch(remote: String, branch: String, at url: URL) async throws
    func createTag(name: String, message: String?, ref: String, at url: URL) async throws
    func deleteTag(name: String, at url: URL) async throws
    /// Deletes the tag on the remote too. A no-op when the remote never had it.
    func deleteRemoteTag(name: String, remote: String, at url: URL) async throws

    /// `commit: false` is Gitbox's "Apply as Patch" — the change lands in the
    /// index and the working copy, with nothing committed.
    func cherryPick(sha: String, commit: Bool, at url: URL) async throws
    func revert(sha: String, at url: URL) async throws
    /// Hard reset. Callers stash first if the working copy is dirty.
    func reset(to ref: String, at url: URL) async throws
    func resolveOperation(_ operation: RepositoryOperation, _ action: OperationAction, at url: URL) async throws

    func addRemote(name: String, remoteURL: String, at url: URL) async throws
    func removeRemote(name: String, at url: URL) async throws

    func setUpstream(branch: String, upstream: String, at url: URL) async throws
    func showFile(at url: URL, path: String, ref: String) async throws -> Data
}

struct GitError: Error, CustomStringConvertible {
    let command: String
    let exitCode: Int32
    let stderr: String

    var description: String {
        "git \(command) failed (exit \(exitCode)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
