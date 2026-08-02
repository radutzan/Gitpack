import Foundation

actor CLIGitService: GitService {
    /// Path to the git binary. On macOS, /usr/bin/git ships with the Command Line Tools
    /// shim and resolves to whichever git is selected via `xcode-select`.
    private let executable: URL

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executable = executable
    }

    // MARK: - Discovery

    func isRepository(at url: URL) async -> Bool {
        do {
            let result = try await ProcessRunner.run(
                executable: executable,
                arguments: ["-C", url.path, "rev-parse", "--git-dir"]
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func currentBranch(at url: URL) async throws -> String? {
        let result = try await runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: url, throwOnFailure: false)
        guard result.exitCode == 0 else { return nil }
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "HEAD" ? nil : value
    }

    func branches(at url: URL) async throws -> [Branch] {
        let result = try await runGit([
            "for-each-ref",
            "--format=%(HEAD)%09%(refname:short)%09%(upstream:short)",
            "refs/heads"
        ], at: url)
        return result.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> Branch? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2 else { return nil }
                let isCurrent = parts[0] == "*"
                let name = parts[1]
                let upstream = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
                return Branch(name: name, upstream: upstream, isCurrent: isCurrent)
            }
    }

    func tags(at url: URL) async throws -> [Tag] {
        // `version:refname` is git's own natural version ordering — v1.10 after
        // v1.9, not before it — reversed so the newest tag leads.
        let result = try await runGit([
            "for-each-ref", "--sort=-version:refname",
            "--format=\(TagParser.format)", "refs/tags"
        ], at: url)
        return TagParser.parse(result.stdoutString)
    }

    func remotes(at url: URL) async throws -> [Remote] {
        let result = try await runGit(["remote", "-v"], at: url)
        var seen = Set<String>()
        var remotes: [Remote] = []
        for line in result.stdoutString.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            if seen.insert(name).inserted {
                let urlPart = parts[1].split(separator: " ").first.map(String.init) ?? ""
                remotes.append(Remote(name: name, url: urlPart))
            }
        }
        return remotes
    }

    func remoteBranches(at url: URL) async throws -> [String] {
        let result = try await runGit([
            "for-each-ref",
            "--format=%(refname)",
            "refs/remotes"
        ], at: url)
        return result.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            // Filtered on the full ref: `refs/remotes/origin/HEAD` shortens to
            // plain "origin", so filtering short names for a "/HEAD" suffix let
            // that symbolic ref through and listed a bare remote as a branch.
            .filter { !$0.hasSuffix("/HEAD") }
            .map { String($0.dropFirst("refs/remotes/".count)) }
    }

    // MARK: - Status

    func workingCopyStatus(at url: URL) async throws -> WorkingCopyStatus {
        let result = try await runGit([
            "status", "--porcelain=v2", "--branch", "-z"
        ], at: url)
        return PorcelainV2Parser.parse(result.stdout)
    }

    /// Four `stat`s rather than a `git rev-parse --git-path` process: this is
    /// asked on every status refresh, and FSEvents fires a lot.
    func operation(at url: URL) async -> RepositoryOperation? {
        let gitDir = gitDirectory(for: url)
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: gitDir.appendingPathComponent(name).path)
        }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    /// `.git` is a directory in an ordinary clone and a file holding
    /// `gitdir: <path>` in a linked worktree or a submodule.
    private func gitDirectory(for url: URL) -> URL {
        let dotGit = url.appendingPathComponent(".git")
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = contents.split(separator: "\n").first,
              line.hasPrefix("gitdir: ") else { return dotGit }
        let path = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : url.appendingPathComponent(path).standardizedFileURL
    }

    // MARK: - Log

    func log(at url: URL, limit: Int, skip: Int, refs: [String]) async throws -> [Commit] {
        // %x1f = US (unit separator), %x1e = RS (record separator)
        var args: [String] = [
            "log",
            "--max-count=\(limit)",
            "--skip=\(skip)",
            "--format=\(LogParser.format)"
        ]
        args.append(contentsOf: refs)
        let result = try await runGit(args, at: url)
        return LogParser.parse(result.stdoutString)
    }

    func searchLog(
        at url: URL,
        tokens: [SearchToken],
        paths: [String],
        limit: Int,
        skip: Int,
        refs: [String]
    ) async throws -> CommitSearchPage {
        var args: [String] = [
            "log",
            "--max-count=\(limit)",
            "--skip=\(skip)",
            "--format=\(LogParser.format)"
        ]
        if !tokens.isEmpty {
            // -U0 because the spec matches added and removed lines, not the
            // context around them — which also cuts the page to a fraction of
            // its size. --no-ext-diff so a configured difftool isn't launched
            // once per commit; --no-color so a `color.diff = always` config
            // can't slip escape codes into the haystack.
            args.append(contentsOf: ["-p", "-U0", "--no-ext-diff", "--no-color"])
        }
        args.append(contentsOf: refs)
        if !paths.isEmpty {
            args.append("--")
            args.append(contentsOf: paths)
        }
        let result = try await runGit(args, at: url)
        return LogParser.parseSearch(result.stdoutString, tokens: tokens)
    }

    func divergence(current: String, other: String, at url: URL) async throws -> Divergence {
        let result = try await runGit([
            "rev-list", "--left-right", "\(current)...\(other)"
        ], at: url)
        let (left, right) = RevListParser.parseLeftRight(result.stdoutString)
        return Divergence(otherRef: other, unpushed: left, unmerged: right)
    }

    func filesInCommit(at url: URL, sha: String) async throws -> [CommitFileChange] {
        // --root so the initial commit lists the files it added; without it
        // diff-tree emits nothing for a parentless commit and the detail pane
        // reads "No file changes". Output format is unchanged for every other
        // commit.
        let result = try await runGit([
            "diff-tree", "--no-commit-id", "--name-status", "-r", "-z", "--root", sha
        ], at: url)
        return DiffTreeParser.parse(result.stdoutString)
    }

    // MARK: - Working copy mutations

    func stage(paths: [String], at url: URL) async throws {
        guard !paths.isEmpty else { return }
        // -A handles the deleted/modified/untracked cases uniformly.
        var args = ["add", "-A", "--"]
        args.append(contentsOf: paths)
        _ = try await runGit(args, at: url)
    }

    func unstage(paths: [String], at url: URL) async throws {
        guard !paths.isEmpty else { return }
        var args = ["reset", "HEAD", "--"]
        args.append(contentsOf: paths)
        _ = try await runGit(args, at: url, throwOnFailure: false)
        // `git reset HEAD --` returns non-zero in some edge cases (initial commit, etc.)
        // but we can ignore those for v0.1 since the resulting state is what we wanted.
    }

    func discard(paths: [String], at url: URL) async throws {
        guard !paths.isEmpty else { return }
        var checkoutArgs = ["checkout", "--"]
        checkoutArgs.append(contentsOf: paths)
        _ = try await runGit(checkoutArgs, at: url, throwOnFailure: false)
        // For untracked files, `git clean -f -- <path>` removes them.
        var cleanArgs = ["clean", "-f", "--"]
        cleanArgs.append(contentsOf: paths)
        _ = try await runGit(cleanArgs, at: url, throwOnFailure: false)
    }

    func commit(message: String, at url: URL) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitError(command: "commit", exitCode: -1, stderr: "Empty commit message")
        }
        _ = try await runGit(["commit", "-F", "-"], at: url, stdin: Data(trimmed.utf8))
    }

    // MARK: - Stash

    func stashes(at url: URL) async throws -> [Stash] {
        let result = try await runGit(["stash", "list", "--format=\(StashParser.format)"], at: url)
        return StashParser.parse(result.stdoutString)
    }

    func stashPush(message: String?, at url: URL) async throws {
        // -u: a stash that leaves new files behind isn't a clean slate, and
        // Gitbox's Stash Changes took untracked files too.
        var args = ["stash", "push", "-u"]
        if let message, !message.isEmpty {
            args.append(contentsOf: ["-m", message])
        }
        _ = try await runGit(args, at: url)
    }

    func stashApply(ref: String, at url: URL) async throws {
        // Apply, not pop: the stash stays until it is explicitly removed, so a
        // conflicting apply can't lose it.
        _ = try await runGit(["stash", "apply", ref], at: url)
    }

    func stashClear(at url: URL) async throws {
        _ = try await runGit(["stash", "clear"], at: url)
    }

    // MARK: - Branches, tags, remotes

    func createBranch(name: String, from ref: String, checkout: Bool, at url: URL) async throws {
        _ = try await runGit(checkout ? ["checkout", "-b", name, ref] : ["branch", name, ref], at: url)
    }

    func deleteBranch(name: String, force: Bool, at url: URL) async throws {
        _ = try await runGit(["branch", force ? "-D" : "-d", name], at: url)
    }

    func deleteRemoteBranch(remote: String, branch: String, at url: URL) async throws {
        _ = try await runGit(["push", remote, "--delete", branch], at: url)
    }

    func createTag(name: String, message: String?, ref: String, at url: URL) async throws {
        // Always annotated. `git push --follow-tags` only carries annotated tags,
        // and that is what makes "tags push with the branch" free.
        _ = try await runGit(["tag", "-a", "-m", message ?? name, name, ref], at: url)
    }

    func deleteTag(name: String, at url: URL) async throws {
        _ = try await runGit(["tag", "-d", name], at: url)
    }

    func deleteRemoteTag(name: String, remote: String, at url: URL) async throws {
        // Ask first: `push --delete` on a tag the remote never had is an error,
        // and a tag that was only ever local is the common case. If the question
        // itself fails (offline, auth), fall through to the push so the user
        // gets the real reason rather than a silent no-op.
        let listed = try await runGit(
            ["ls-remote", "--tags", remote, "refs/tags/\(name)"],
            at: url, throwOnFailure: false
        )
        let present = !listed.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard listed.exitCode != 0 || present else { return }
        _ = try await runGit(["push", remote, "--delete", "refs/tags/\(name)"], at: url)
    }

    func addRemote(name: String, remoteURL: String, at url: URL) async throws {
        _ = try await runGit(["remote", "add", name, remoteURL], at: url)
    }

    func removeRemote(name: String, at url: URL) async throws {
        _ = try await runGit(["remote", "remove", name], at: url)
    }

    // MARK: - History operations

    func cherryPick(sha: String, commit: Bool, at url: URL) async throws {
        var args = ["cherry-pick"]
        if !commit { args.append("--no-commit") }
        args.append(sha)
        _ = try await runGit(args, at: url)
    }

    func revert(sha: String, at url: URL) async throws {
        _ = try await runGit(["revert", "--no-edit", sha], at: url)
    }

    func reset(to ref: String, at url: URL) async throws {
        _ = try await runGit(["reset", "--hard", ref], at: url)
    }

    func resolveOperation(
        _ operation: RepositoryOperation,
        _ action: OperationAction,
        at url: URL
    ) async throws {
        _ = try await runGit([operation.rawValue, "--\(action.rawValue)"], at: url)
    }

    // MARK: - Network

    func fetch(at url: URL) async throws {
        _ = try await runGit(["fetch", "--prune"], at: url)
    }

    func pull(at url: URL) async throws {
        _ = try await runGit(["pull"], at: url)
    }

    func pullRebase(at url: URL) async throws {
        _ = try await runGit(["pull", "--rebase"], at: url)
    }

    func push(remote: String?, refspec: String?, force: Bool, at url: URL) async throws {
        var args = ["push"]
        if force { args.append("--force") }
        if let remote, let refspec {
            args.append(remote)
            args.append(refspec)
            // Tags by name, which is what makes Gitbox's "tags push with the
            // branch" cover lightweight ones too. `--follow-tags` only carries
            // annotated tags, and a tag made with plain `git tag` is still a tag
            // the user expects to arrive.
            args.append(contentsOf: await unpushedTagRefspecs(remote: remote, at: url))
        } else {
            // No explicit target: a bare `git push` can't carry named refspecs
            // (they would replace the default one), so git's own annotated-only
            // rule is the best available.
            args.append("--follow-tags")
        }
        _ = try await runGit(args, at: url)
    }

    /// Tags reachable from HEAD that the remote doesn't have yet.
    ///
    /// Both halves matter. `--merged HEAD` keeps a tag sitting on some unrelated
    /// local branch from dragging that branch's commits onto the remote — which
    /// is exactly what `git push --tags` does. Asking the remote what it already
    /// has keeps a locally re-pointed tag from being rejected as "already
    /// exists", which fails the *whole* push, branch included: the rejection
    /// `--follow-tags` avoids by only ever sending what's missing.
    private func unpushedTagRefspecs(remote: String, at url: URL) async -> [String] {
        guard let reachable = try? await runGit(["tag", "--merged", "HEAD"], at: url, throwOnFailure: false)
        else { return [] }
        let names = reachable.stdoutString.split(separator: "\n").map(String.init)
        guard !names.isEmpty else { return [] }

        // "<sha>\trefs/tags/<name>", plus a peeled "…^{}" line per annotated tag.
        let listed = try? await runGit(["ls-remote", "--tags", remote], at: url, throwOnFailure: false)
        let onRemote = Set(
            (listed?.stdoutString ?? "")
                .split(separator: "\n")
                .compactMap { $0.split(separator: "\t").last }
                .filter { !$0.hasSuffix("^{}") }
                .map { $0.replacingOccurrences(of: "refs/tags/", with: "") }
        )
        return names.filter { !onRemote.contains($0) }.map { "refs/tags/\($0)" }
    }

    func merge(ref: String, at url: URL) async throws {
        _ = try await runGit(["merge", ref], at: url)
    }

    func checkout(ref: String, at url: URL) async throws {
        _ = try await runGit(["checkout", ref], at: url)
    }

    func checkoutTracking(remoteBranch: String, at url: URL) async throws {
        let result = try await runGit(["checkout", "--track", remoteBranch], at: url, throwOnFailure: false)
        guard result.exitCode != 0 else { return }
        // A local branch of that name already exists — which is the common case
        // once you've checked it out before. Switch to it instead.
        let local = remoteBranch.split(separator: "/").dropFirst().joined(separator: "/")
        _ = try await runGit(["checkout", local], at: url)
    }

    func setUpstream(branch: String, upstream: String, at url: URL) async throws {
        _ = try await runGit([
            "branch", "--set-upstream-to=\(upstream)", branch
        ], at: url)
    }

    func showFile(at url: URL, path: String, ref: String) async throws -> Data {
        let result = try await runGit(["show", "\(ref):\(path)"], at: url)
        return result.stdout
    }

    // MARK: - Helpers

    @discardableResult
    private func runGit(
        _ arguments: [String],
        at url: URL,
        throwOnFailure: Bool = true,
        stdin: Data? = nil
    ) async throws -> ProcessResult {
        var args = ["-C", url.path]
        args.append(contentsOf: arguments)

        // Inherit a sane environment. Force English locale + plumbing-friendly output.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Fail fast instead of hanging when auth would need interaction
        // (background autofetch must be silent; interactive auth is out of scope).
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"
        // Same reason: `rebase --continue`, `merge` and `revert` would otherwise
        // launch $EDITOR and wait forever. `true` accepts the message git
        // already prepared, which is what a GUI wants anyway.
        env["GIT_EDITOR"] = "/usr/bin/true"

        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: args,
            environment: env,
            stdin: stdin
        )
        if throwOnFailure, result.exitCode != 0 {
            throw GitError(
                command: arguments.first ?? "",
                exitCode: result.exitCode,
                stderr: result.stderrString.isEmpty ? result.stdoutString : result.stderrString
            )
        }
        return result
    }
}
