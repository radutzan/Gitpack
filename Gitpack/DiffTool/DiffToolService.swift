import Foundation

/// Hands a pair of files off to an external diff tool. Default tool is `opendiff`
/// (FileMerge). Configurable in v0.2 via Settings.
actor DiffToolService {
    private let git: GitService
    private let command: String
    private var tempDirs: [URL] = []

    init(git: GitService, command: String = "opendiff $LEFT $RIGHT") {
        self.git = git
        self.command = command
    }

    /// Diffs a working-copy file against its HEAD version.
    func diffWorkingCopy(repoURL: URL, path: String) async throws {
        let tempDir = try makeTempDir()
        let leftURL = try await writeRefVersion(repoURL: repoURL, path: path, ref: "HEAD", into: tempDir, suffix: "head")
        let rightURL = repoURL.appendingPathComponent(path)
        try launch(left: leftURL, right: rightURL)
    }

    /// Diffs a file at `commitSHA` against its version at the parent commit.
    /// If no parent (initial commit), shows an empty file on the left.
    func diffCommit(repoURL: URL, path: String, commitSHA: String, parentSHA: String?) async throws {
        let tempDir = try makeTempDir()
        let leftURL: URL
        if let parentSHA {
            do {
                leftURL = try await writeRefVersion(
                    repoURL: repoURL, path: path, ref: parentSHA, into: tempDir, suffix: "parent"
                )
            } catch {
                leftURL = makeEmpty(in: tempDir, name: "empty-\(path.lastPathComponent)")
            }
        } else {
            leftURL = makeEmpty(in: tempDir, name: "empty-\(path.lastPathComponent)")
        }
        let rightURL = try await writeRefVersion(
            repoURL: repoURL, path: path, ref: commitSHA, into: tempDir, suffix: "current"
        )
        try launch(left: leftURL, right: rightURL)
    }

    private func writeRefVersion(repoURL: URL, path: String, ref: String, into tempDir: URL, suffix: String) async throws -> URL {
        let basename = (path as NSString).lastPathComponent
        let target = tempDir.appendingPathComponent("\(suffix)-\(basename)")
        let data = try await git.showFile(at: repoURL, path: path, ref: ref)
        try data.write(to: target, options: .atomic)
        return target
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Gitpack-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeEmpty(in dir: URL, name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func launch(left: URL, right: URL) throws {
        // Replace placeholders. `opendiff` is the default and accepts space-separated paths.
        let resolved = command
            .replacingOccurrences(of: "$LEFT", with: shellQuote(left.path))
            .replacingOccurrences(of: "$RIGHT", with: shellQuote(right.path))

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", resolved]
        try task.run()
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    nonisolated var lastPathComponent: String { (self as NSString).lastPathComponent }
}
