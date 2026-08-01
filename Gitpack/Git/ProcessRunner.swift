import Foundation

nonisolated struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    // Lossy on purpose. `String(data:encoding:)` returns nil for the whole
    // buffer on a single invalid byte, so one latin-1 line in a patch or a
    // commit message used to blank the entire page.
    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessRunner {
    /// Runs a process to completion. Captures stdout and stderr. Does not throw on
    /// non-zero exit — caller decides what's an error.
    nonisolated static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            if let environment {
                process.environment = environment
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            if stdin != nil {
                process.standardInput = Pipe()
            }

            // Read pipes concurrently so large output doesn't deadlock on the buffer.
            let stdoutBox = DataBox()
            let stderrBox = DataBox()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stdoutBox.append(chunk)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrBox.append(chunk)
                }
            }

            process.terminationHandler = { proc in
                // Drain anything still buffered.
                let remainingOut = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let remainingErr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                if !remainingOut.isEmpty { stdoutBox.append(remainingOut) }
                if !remainingErr.isEmpty { stderrBox.append(remainingErr) }

                continuation.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: stdoutBox.value,
                    stderr: stderrBox.value
                ))
            }

            do {
                try process.run()
                if let stdin, let stdinPipe = process.standardInput as? Pipe {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                    try stdinPipe.fileHandleForWriting.close()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private nonisolated final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
