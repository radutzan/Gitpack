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

    func log(at url: URL, limit: Int, skip: Int, branch: String?) async throws -> [Commit] {
        // %x1f = US (unit separator), %x1e = RS (record separator)
        let format = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%s%x1f%b%x1e"
        var args: [String] = [
            "log",
            "--max-count=\(limit)",
            "--skip=\(skip)",
            "--format=\(format)"
        ]
        if let branch {
            args.append(branch)
        }
        let result = try await runGit(args, at: url)
        return parseLog(result.stdoutString)
    }

    private nonisolated func parseLog(_ text: String) -> [Commit] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFraction = ISO8601DateFormatter()
        isoFormatterNoFraction.formatOptions = [.withInternetDateTime]

        return text
            .split(separator: "\u{1E}", omittingEmptySubsequences: true)
            .compactMap { record -> Commit? in
                let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let fields = trimmed.components(separatedBy: "\u{1F}")
                guard fields.count >= 8 else { return nil }
                let date = isoFormatter.date(from: fields[4])
                    ?? isoFormatterNoFraction.date(from: fields[4])
                    ?? Date()
                let parents = fields[5].split(separator: " ").map(String.init)
                return Commit(
                    id: fields[0],
                    shortID: fields[1],
                    authorName: fields[2],
                    authorEmail: fields[3],
                    date: date,
                    parents: parents,
                    subject: fields[6],
                    body: fields[7].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
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

    func push(at url: URL) async throws {
        _ = try await runGit(["push"], at: url)
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

// MARK: - Porcelain v2 parser

private nonisolated enum PorcelainV2Parser {
    static func parse(_ data: Data) -> WorkingCopyStatus {
        // Records are NUL-terminated. Type-2 (rename/copy) entries have an extra
        // NUL-terminated original path that follows the main entry.
        let records = data.split(separator: 0x00, omittingEmptySubsequences: false).map { Data($0) }
        var iterator = records.makeIterator()

        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var entries: [WorkingCopyEntry] = []

        while let record = iterator.next() {
            if record.isEmpty { continue }
            guard let line = String(data: record, encoding: .utf8) else { continue }

            if line.hasPrefix("# ") {
                let header = line.dropFirst(2)
                if header.hasPrefix("branch.head ") {
                    let value = String(header.dropFirst("branch.head ".count))
                    branch = value == "(detached)" ? nil : value
                } else if header.hasPrefix("branch.upstream ") {
                    upstream = String(header.dropFirst("branch.upstream ".count))
                } else if header.hasPrefix("branch.ab ") {
                    let value = header.dropFirst("branch.ab ".count)
                    let parts = value.split(separator: " ")
                    if parts.count == 2 {
                        ahead = Int(parts[0].dropFirst()) ?? 0
                        behind = Int(parts[1].dropFirst()) ?? 0
                    }
                }
                continue
            }

            if line.hasPrefix("1 ") {
                if let entry = parseEntry1(line) {
                    entries.append(entry)
                }
            } else if line.hasPrefix("2 ") {
                // Type-2 entry: path is in the entry, origPath is the next NUL-terminated record.
                let origPathData = iterator.next() ?? Data()
                let origPath = String(data: origPathData, encoding: .utf8) ?? ""
                if let entry = parseEntry2(line, origPath: origPath) {
                    entries.append(entry)
                }
            } else if line.hasPrefix("u ") {
                if let entry = parseEntryU(line) {
                    entries.append(entry)
                }
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst(2))
                entries.append(WorkingCopyEntry(
                    path: path, oldPath: nil,
                    stagedStatus: nil, unstagedStatus: .untracked
                ))
            } else if line.hasPrefix("! ") {
                let path = String(line.dropFirst(2))
                entries.append(WorkingCopyEntry(
                    path: path, oldPath: nil,
                    stagedStatus: nil, unstagedStatus: .ignored
                ))
            }
        }

        return WorkingCopyStatus(
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            entries: entries
        )
    }

    /// "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>"
    private static func parseEntry1(_ line: String) -> WorkingCopyEntry? {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9 else { return nil }
        let xy = fields[1]
        let path = fields[8]
        let (staged, unstaged) = parseXY(xy)
        return WorkingCopyEntry(
            path: path, oldPath: nil,
            stagedStatus: staged, unstagedStatus: unstaged
        )
    }

    /// "2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>"  + origPath in next record
    private static func parseEntry2(_ line: String, origPath: String) -> WorkingCopyEntry? {
        let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 10 else { return nil }
        let xy = fields[1]
        let path = fields[9]
        let (staged, unstaged) = parseXY(xy)
        return WorkingCopyEntry(
            path: path, oldPath: origPath,
            stagedStatus: staged, unstagedStatus: unstaged
        )
    }

    /// "u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>"
    private static func parseEntryU(_ line: String) -> WorkingCopyEntry? {
        let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 11 else { return nil }
        let path = fields[10]
        return WorkingCopyEntry(
            path: path, oldPath: nil,
            stagedStatus: .unmerged, unstagedStatus: .unmerged
        )
    }

    private static func parseXY(_ xy: String) -> (FileChangeStatus?, FileChangeStatus?) {
        let chars = Array(xy)
        guard chars.count == 2 else { return (nil, nil) }
        return (statusFor(chars[0]), statusFor(chars[1]))
    }

    private static func statusFor(_ c: Character) -> FileChangeStatus? {
        switch c {
        case ".": return nil
        case "M": return .modified
        case "T": return .typeChanged
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "U": return .unmerged
        default: return nil
        }
    }
}

// MARK: - diff-tree parser

private nonisolated enum DiffTreeParser {
    /// Output for `git diff-tree --no-commit-id --name-status -r -z <sha>`:
    /// status\0path\0  for non-rename/copy entries
    /// status\0oldPath\0newPath\0  for renames/copies
    static func parse(_ text: String) -> [CommitFileChange] {
        let parts = text.split(separator: "\u{00}", omittingEmptySubsequences: false).map(String.init)
        var changes: [CommitFileChange] = []
        var i = 0
        while i < parts.count {
            let token = parts[i]
            if token.isEmpty { i += 1; continue }
            // Status code: single letter for plain ops, R/C followed by similarity score.
            let firstChar = token.first!
            let isRenameOrCopy = (firstChar == "R" || firstChar == "C")
            let status = mapStatus(firstChar)
            if isRenameOrCopy {
                guard i + 2 < parts.count else { break }
                let oldPath = parts[i + 1]
                let newPath = parts[i + 2]
                changes.append(CommitFileChange(status: status, path: newPath, oldPath: oldPath))
                i += 3
            } else {
                guard i + 1 < parts.count else { break }
                let path = parts[i + 1]
                changes.append(CommitFileChange(status: status, path: path, oldPath: nil))
                i += 2
            }
        }
        return changes
    }

    private static func mapStatus(_ c: Character) -> FileChangeStatus {
        switch c {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .unmerged
        default: return .modified
        }
    }
}
