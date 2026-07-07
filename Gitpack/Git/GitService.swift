import Foundation

nonisolated protocol GitService: Sendable {
    func isRepository(at url: URL) async -> Bool
    func currentBranch(at url: URL) async throws -> String?
    func branches(at url: URL) async throws -> [Branch]
    func remotes(at url: URL) async throws -> [Remote]
    func remoteBranches(at url: URL) async throws -> [String]

    func workingCopyStatus(at url: URL) async throws -> WorkingCopyStatus
    func log(at url: URL, limit: Int, skip: Int, refs: [String]) async throws -> [Commit]
    func filesInCommit(at url: URL, sha: String) async throws -> [CommitFileChange]
    func divergence(current: String, other: String, at url: URL) async throws -> Divergence

    func stage(paths: [String], at url: URL) async throws
    func unstage(paths: [String], at url: URL) async throws
    func discard(paths: [String], at url: URL) async throws
    func commit(message: String, at url: URL) async throws

    func fetch(at url: URL) async throws
    func pull(at url: URL) async throws
    func pullRebase(at url: URL) async throws
    /// Push explicitly. `refspec` is "local:remoteBranch" with `remote` the target
    /// remote name; nil refspec/remote falls back to plain `git push`.
    func push(remote: String?, refspec: String?, force: Bool, at url: URL) async throws
    func merge(branch: String, at url: URL) async throws
    func checkout(branch: String, at url: URL) async throws

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
