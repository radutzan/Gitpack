import Foundation
import CoreServices

/// What kind of refresh a batch of filesystem events warrants.
enum WatchRefreshKind: Equatable {
    /// Nothing actionable changed (pure noise: loose objects, lock files, …).
    case none
    /// Working-tree or index changed — re-read `git status` only (cheap, no flicker).
    case status
    /// Refs/HEAD changed — the commit graph or branches moved; reload everything.
    case full

    func combined(with other: WatchRefreshKind) -> WatchRefreshKind {
        if self == .full || other == .full { return .full }
        if self == .status || other == .status { return .status }
        return .none
    }
}

/// Maps raw FSEvents paths to the coarsest refresh they require. Pure and
/// `nonisolated` so it's trivial to call from any context (and to unit-test).
nonisolated enum GitChangeClassifier {
    static func refreshKind(for paths: [String]) -> WatchRefreshKind {
        var needsStatus = false
        for path in paths {
            guard let gitRange = path.range(of: "/.git/") else {
                // A path in the working tree changed.
                needsStatus = true
                continue
            }
            // A path inside the repository's `.git` directory.
            let suffix = path[gitRange.upperBound...]
            // Transient lock files are noise, and must be excluded BEFORE the
            // refs test: `git fetch` touches refs/remotes/<remote>/HEAD.lock on
            // every run even when nothing changed. Real ref updates rename the
            // lock onto the final path, which fires its own event.
            if suffix.hasSuffix(".lock") {
                continue
            }
            if suffix.hasPrefix("refs/")
                || suffix.hasPrefix("logs/")
                || suffix == "HEAD"
                || suffix == "packed-refs"
                || suffix == "ORIG_HEAD"
                || suffix == "MERGE_HEAD" {
                // Branches moved / commits arrived — needs a full reload.
                return .full
            }
            if suffix == "index" {
                // Staging changed (possibly by an external git invocation).
                needsStatus = true
            }
            // Everything else under .git (objects/, *.lock, FETCH_HEAD, config) is noise.
        }
        return needsStatus ? .status : .none
    }
}

/// Thin wrapper around FSEvents that reports changed paths under a directory
/// tree. Lives off the main actor; the change handler is invoked on a private
/// serial queue, so callers must hop to their own isolation domain.
nonisolated final class FileSystemWatcher {
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "com.gitpack.fswatcher", qos: .utility)
    private var stream: FSEventStreamRef?

    init(url: URL, onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
        start(at: url)
    }

    deinit { stop() }

    private func start(at url: URL) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            guard !paths.isEmpty else { return }
            watcher.onChange(paths)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15, // coalescing latency; we debounce again before refreshing.
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Flush any callback already in flight so it can't touch a dead `self`.
        queue.sync {}
    }
}
