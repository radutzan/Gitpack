import Foundation
import Observation

enum HistoryItem: Hashable {
    case workingCopy
    case commit(String) // SHA
}

enum CommitMarker {
    case none
    case unpushed  // on current branch, not on the other branch (green)
    case unmerged  // on the other branch, not on the current one (blue)
}

enum SyncAction {
    case pull
    case fetch
    case rebase
    case merge
    case push
    case forcePush
}

/// Lightweight always-current state for every sidebar repo (the full
/// `RepositoryViewModel` is only loaded for the selected one). Fed by one
/// `git status --porcelain=v2` call per repo — `branch.ab` supplies
/// unpushed/unmerged and the entry list supplies the stage count.
@Observable
@MainActor
final class RepoBackgroundState {
    var unpushed = 0
    var unmerged = 0
    var stageChanges = 0
    var isFetching = false
    var consecutiveFailures = 0
    var lastFetchAttempt: Date?

    /// Gitbox's sidebar badge: unpushed + unmerged commits + pending stage changes.
    var badge: Int { unpushed + unmerged + stageChanges }

    var nextFetchAttempt: Date? {
        guard let lastFetchAttempt, consecutiveFailures > 0 else { return nil }
        // ponytail: exponential backoff 2min→30min cap; no jitter, no per-remote state
        let backoff = min(60.0 * pow(2, Double(consecutiveFailures)), 1800)
        return lastFetchAttempt.addingTimeInterval(backoff)
    }

    func apply(_ status: WorkingCopyStatus) {
        stageChanges = status.entries.count
        unpushed = status.ahead
        unmerged = status.behind
    }
}

/// Per-repository view state. Cached so switching back to a repo is fast.
@Observable
@MainActor
final class RepositoryViewModel {
    let repository: Repository
    var status: WorkingCopyStatus?
    var commits: [Commit] = []
    var branches: [Branch] = []
    var currentBranch: String?
    var remoteBranches: [String] = []
    var remotes: [Remote] = []
    var divergence: Divergence?
    var selection: HistoryItem?
    var commitFiles: [String: [CommitFileChange]] = [:]
    var isLoading = false
    var isSyncing = false
    /// Set by AppState; lets every status refresh also keep the sidebar
    /// badge (RepoBackgroundState) current for this repo.
    var onStatusChanged: ((WorkingCopyStatus) -> Void)?
    var lastError: String?
    var isMissing = false

    private let pageSize = 200
    /// Readable so the history list can show its "Load more" row off the real
    /// answer rather than guessing from `commits.count >= pageSize`, which stays
    /// true forever once you've paged past the first screen.
    private(set) var hasMoreHistory = true

    init(repository: Repository) {
        self.repository = repository
    }

    func reload(using git: GitService) async {
        await refreshAll(using: git)
    }

    func refreshAll(using git: GitService) async {
        let url = repository.url
        if !FileManager.default.fileExists(atPath: url.path) {
            isMissing = true
            return
        }
        isMissing = false
        isLoading = true
        defer { isLoading = false }
        do {
            async let statusTask = git.workingCopyStatus(at: url)
            async let branchesTask = git.branches(at: url)
            async let remoteBranchesTask = git.remoteBranches(at: url)
            async let remotesTask = git.remotes(at: url)

            let status = try await statusTask
            let branches = try await branchesTask
            let remoteBranches = try await remoteBranchesTask
            let remotes = try await remotesTask

            // Only assign what actually changed. refreshAll runs on every app
            // activation and after every autofetch; unconditional assignment —
            // especially rebuilding `commits` — reloads the NSTableView mid-
            // click, blanking the panes and dropping selection.
            self.status = status
            if branches != self.branches { self.branches = branches }
            if remoteBranches != self.remoteBranches { self.remoteBranches = remoteBranches }
            if remotes != self.remotes { self.remotes = remotes }
            self.currentBranch = status.branch ?? branches.first(where: \.isCurrent)?.name
            onStatusChanged?(status)

            // Divergence vs the "other branch" (upstream config, local or remote).
            let divergence: Divergence? = if let current = currentBranch, let other = otherBranch, other != current {
                try? await git.divergence(current: current, other: other, at: url)
            } else {
                nil
            }
            if divergence != self.divergence { self.divergence = divergence }

            // Fresh history, rebuilt off-screen and swapped in only if it
            // differs. Refetches the full loaded depth so pagination survives.
            let limit = max(commits.count, pageSize)
            let fresh = try await git.log(at: url, limit: limit, skip: 0, refs: historyRefs)
            if fresh != commits {
                commits = fresh
                hasMoreHistory = fresh.count == limit
            }

            // Default selection: working copy if dirty, else first commit.
            if selection == nil {
                if !status.isClean {
                    selection = .workingCopy
                } else if let first = commits.first {
                    selection = .commit(first.id)
                }
            }
            lastError = nil
        } catch let error as GitError {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshStatusOnly(using git: GitService) async {
        let url = repository.url
        do {
            let status = try await git.workingCopyStatus(at: url)
            self.status = status
            onStatusChanged?(status)
            if let currentSelection = selection, case .workingCopy = currentSelection, status.isClean {
                // Drop to first commit if WC went clean.
                if let first = commits.first {
                    selection = .commit(first.id)
                }
            }
        } catch {
            // Quiet failure on background refresh.
        }
    }

    /// The Gitbox "other branch": what the current branch is compared/synced
    /// against. Stored as git-native upstream config, which accepts both
    /// remote-tracking and local branches.
    var otherBranch: String? {
        status?.upstream ?? branches.first(where: \.isCurrent)?.upstream
    }

    var otherBranchIsLocal: Bool {
        guard let otherBranch else { return false }
        return branches.contains { $0.name == otherBranch }
    }

    func setOtherBranch(_ ref: String, using git: GitService) async {
        guard let branch = currentBranch else { return }
        do {
            try await git.setUpstream(branch: branch, upstream: ref, at: repository.url)
            await refreshAll(using: git)
        } catch let error as GitError {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Runs a sync operation (toolbar buttons and menu items both route here)
    /// and refreshes. Errors land in `lastError`.
    func performSync(_ action: SyncAction, using git: GitService) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            switch action {
            case .pull:
                try await git.pull(at: repository.url)
            case .fetch:
                try await git.fetch(at: repository.url)
            case .rebase:
                try await git.pullRebase(at: repository.url)
            case .merge:
                guard let other = otherBranch else { return }
                try await git.merge(branch: other, at: repository.url)
            case .push, .forcePush:
                let (remote, refspec) = pushTarget
                try await git.push(
                    remote: remote, refspec: refspec,
                    force: action == .forcePush, at: repository.url
                )
            }
            await refreshAll(using: git)
        } catch let error as GitError {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Explicit push destination derived from the other branch, Gitbox-style
    /// (`git push <remote> <current>:<remoteBranch>`), so pushing works even
    /// when local and remote branch names differ. Falls back to plain `git push`.
    private var pushTarget: (remote: String?, refspec: String?) {
        guard let current = currentBranch, let other = otherBranch, !otherBranchIsLocal else {
            return (nil, nil)
        }
        let candidates = remotes.map(\.name).filter { other.hasPrefix($0 + "/") }
        guard let remote = candidates.max(by: { $0.count < $1.count }) else { return (nil, nil) }
        let branch = String(other.dropFirst(remote.count + 1))
        return (remote, "\(current):\(branch)")
    }

    func marker(for commit: Commit) -> CommitMarker {
        guard let divergence else { return .none }
        if divergence.unpushed.contains(commit.id) { return .unpushed }
        if divergence.unmerged.contains(commit.id) { return .unmerged }
        return .none
    }

    /// Refs shown in history: the current branch plus the "other branch" (so
    /// unmerged commits interleave, Gitbox-style). Empty means HEAD.
    private var historyRefs: [String] {
        var refs: [String] = []
        if let currentBranch { refs.append(currentBranch) }
        if let otherBranch, otherBranch != currentBranch { refs.append(otherBranch) }
        return refs
    }

    func loadMoreHistory(using git: GitService) async {
        guard hasMoreHistory else { return }
        let url = repository.url
        do {
            let page = try await git.log(
                at: url,
                limit: pageSize,
                skip: commits.count,
                refs: historyRefs
            )
            commits.append(contentsOf: page)
            if page.count < pageSize {
                hasMoreHistory = false
            }
        } catch {
            hasMoreHistory = false
        }
    }

    func loadFilesForCommit(_ sha: String, using git: GitService) async {
        guard commitFiles[sha] == nil else { return }
        do {
            let files = try await git.filesInCommit(at: repository.url, sha: sha)
            commitFiles[sha] = files
        } catch {
            commitFiles[sha] = []
        }
    }
}

@Observable
@MainActor
final class AppState {
    let store: RepositoryStore
    let git: GitService
    let diffTool: DiffToolService

    var selectedRepositoryID: UUID?
    private var viewModels: [UUID: RepositoryViewModel] = [:]
    private var backgroundStates: [UUID: RepoBackgroundState] = [:]
    private var autofetchTask: Task<Void, Never>?

    // Filesystem watching: keeps the selected repo's view in sync with on-disk
    // reality without manual refreshes. Only the selected repo is watched.
    private var watcher: FileSystemWatcher?
    private var watchDebounce: Task<Void, Never>?
    private var pendingKind: WatchRefreshKind = .none

    init(store: RepositoryStore? = nil, git: GitService? = nil) {
        let resolvedStore = store ?? RepositoryStore()
        let resolvedGit = git ?? CLIGitService()
        self.store = resolvedStore
        self.git = resolvedGit
        self.diffTool = DiffToolService(git: resolvedGit)
        if let first = resolvedStore.repositories.first {
            self.selectedRepositoryID = first.id
        }
    }

    var repositories: [Repository] { store.repositories }

    var selectedRepository: Repository? {
        guard let id = selectedRepositoryID else { return nil }
        return repositories.first { $0.id == id }
    }

    func viewModel(for repository: Repository) -> RepositoryViewModel {
        if let existing = viewModels[repository.id] { return existing }
        let vm = RepositoryViewModel(repository: repository)
        vm.onStatusChanged = { [weak self, id = repository.id] status in
            self?.backgroundState(for: id).apply(status)
        }
        viewModels[repository.id] = vm
        return vm
    }

    func backgroundState(for id: UUID) -> RepoBackgroundState {
        if let existing = backgroundStates[id] { return existing }
        let state = RepoBackgroundState()
        backgroundStates[id] = state
        return state
    }

    var selectedViewModel: RepositoryViewModel? {
        guard let repo = selectedRepository else { return nil }
        return viewModel(for: repo)
    }

    func addRepository(at url: URL) async -> Bool {
        guard await git.isRepository(at: url) else { return false }
        if store.contains(url: url) {
            // Already added — select it.
            if let existing = store.repositories.first(where: {
                $0.url.standardizedFileURL == url.standardizedFileURL
            }) {
                selectedRepositoryID = existing.id
            }
            return true
        }
        let name = url.lastPathComponent
        let repo = Repository(displayName: name, url: url)
        store.add(repo)
        selectedRepositoryID = repo.id
        return true
    }

    func removeRepository(_ repo: Repository) {
        store.remove(repo)
        viewModels.removeValue(forKey: repo.id)
        backgroundStates.removeValue(forKey: repo.id)
        if selectedRepositoryID == repo.id {
            selectedRepositoryID = store.repositories.first?.id
        }
    }

    // MARK: - Autofetch

    /// Background fetch across all sidebar repos, Gitbox-style: the app is a
    /// live view of every repository, not just the selected one. Errors are
    /// silent (badge just doesn't move) with per-repo exponential backoff.
    func startAutofetch() {
        guard autofetchTask == nil else { return }
        autofetchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.autofetchCycle()
                // ponytail: fixed 60s cycle + 2s stagger; make it adaptive if it's ever too chatty
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func autofetchCycle() async {
        for repo in store.repositories {
            if Task.isCancelled { return }
            guard FileManager.default.fileExists(atPath: repo.url.path) else { continue }
            let state = backgroundState(for: repo.id)
            if state.isFetching { continue }
            if let next = state.nextFetchAttempt, Date() < next {
                // Cooling down after failures — still refresh the local counts.
                await refreshBackgroundState(for: repo)
                continue
            }
            await fetchQuietly(repo, state: state)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func fetchQuietly(_ repo: Repository, state: RepoBackgroundState) async {
        state.isFetching = true
        state.lastFetchAttempt = Date()
        do {
            try await git.fetch(at: repo.url)
            state.consecutiveFailures = 0
        } catch {
            state.consecutiveFailures += 1
        }
        state.isFetching = false
        await refreshBackgroundState(for: repo)
    }

    /// One `git status` call: refreshes badge counts without loading the repo.
    func refreshBackgroundState(for repo: Repository) async {
        guard FileManager.default.fileExists(atPath: repo.url.path) else { return }
        if let status = try? await git.workingCopyStatus(at: repo.url) {
            backgroundState(for: repo.id).apply(status)
        }
    }

    /// Gitbox trick: typing a commit message triggers a fetch so you can pull
    /// before committing. Rate-limited; selected repo only.
    func opportunisticFetch() {
        guard let repo = selectedRepository else { return }
        let state = backgroundState(for: repo.id)
        guard !state.isFetching else { return }
        // ponytail: 30s rate limit, hardcoded
        if let last = state.lastFetchAttempt, Date().timeIntervalSince(last) < 30 { return }
        Task { await fetchQuietly(repo, state: state) }
    }

    // MARK: - Filesystem watching

    /// Begin watching the currently selected repository's directory tree,
    /// replacing any existing watcher. Call this whenever the selection changes.
    func startWatchingSelectedRepository() {
        stopWatching()
        guard let repo = selectedRepository,
              FileManager.default.fileExists(atPath: repo.url.path) else { return }
        let repositoryID = repo.id
        watcher = FileSystemWatcher(url: repo.url) { [weak self] paths in
            // Delivered on the watcher's private queue — hop to the main actor.
            Task { @MainActor [weak self] in
                self?.fileSystemDidChange(paths, repositoryID: repositoryID)
            }
        }
    }

    /// Tear down the active watcher and any pending debounced refresh.
    func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchDebounce?.cancel()
        watchDebounce = nil
        pendingKind = .none
    }

    /// Full reload of the selected repo, used when the app returns to the
    /// foreground (a safety net in case any FSEvents were missed while inactive).
    func foregroundRefresh() async {
        guard let vm = selectedViewModel, !vm.isLoading else { return }
        await vm.refreshAll(using: git)
    }

    private func fileSystemDidChange(_ paths: [String], repositoryID: UUID) {
        // Ignore stale callbacks from a watcher we've since replaced.
        guard repositoryID == selectedRepositoryID else { return }
        let kind = GitChangeClassifier.refreshKind(for: paths)
        guard kind != .none else { return }
        pendingKind = pendingKind.combined(with: kind)

        // Debounce: coalesce bursts (editors saving, git writing many refs) into
        // a single refresh once the filesystem settles.
        watchDebounce?.cancel()
        watchDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            let kind = self.pendingKind
            self.pendingKind = .none
            await self.applyWatchedRefresh(kind)
        }
    }

    private func applyWatchedRefresh(_ kind: WatchRefreshKind) async {
        guard let vm = selectedViewModel else { return }
        switch kind {
        case .full: await vm.refreshAll(using: git)
        case .status: await vm.refreshStatusOnly(using: git)
        case .none: break
        }
    }
}
