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
            "--format=%(refname:short)",
            "refs/remotes"
        ], at: url)
        return result.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasSuffix("/HEAD") }
    }

    // MARK: - Status

    func workingCopyStatus(at url: URL) async throws -> WorkingCopyStatus {
        let result = try await runGit([
            "status", "--porcelain=v2", "--branch", "-z"
        ], at: url)
        return PorcelainV2Parser.parse(result.stdout)
    }

    // MARK: - Log

    func log(at url: URL, limit: Int, skip: Int, refs: [String]) async throws -> [Commit] {
        // %x1f = US (unit separator), %x1e = RS (record separator)
        let format = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%s%x1f%b%x1e"
        var args: [String] = [
            "log",
            "--max-count=\(limit)",
            "--skip=\(skip)",
            "--format=\(format)"
        ]
        args.append(contentsOf: refs)
        let result = try await runGit(args, at: url)
        return LogParser.parse(result.stdoutString)
    }

    func divergence(current: String, other: String, at url: URL) async throws -> Divergence {
        let result = try await runGit([
            "rev-list", "--left-right", "\(current)...\(other)"
        ], at: url)
        let (left, right) = RevListParser.parseLeftRight(result.stdoutString)
        return Divergence(otherRef: other, unpushed: left, unmerged: right)
    }

    func filesInCommit(at url: URL, sha: String) async throws -> [CommitFileChange] {
        let result = try await runGit([
            "diff-tree", "--no-commit-id", "--name-status", "-r", "-z", sha
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
        }
        _ = try await runGit(args, at: url)
    }

    func merge(branch: String, at url: URL) async throws {
        _ = try await runGit(["merge", branch], at: url)
    }

    func checkout(branch: String, at url: URL) async throws {
        _ = try await runGit(["checkout", branch], at: url)
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
