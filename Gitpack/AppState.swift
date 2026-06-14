import Foundation
import Observation

enum HistoryItem: Hashable {
    case workingCopy
    case commit(String) // SHA
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
    var selection: HistoryItem?
    var commitFiles: [String: [CommitFileChange]] = [:]
    var isLoading = false
    var lastError: String?
    var isMissing = false

    private let pageSize = 200
    private var loadedPages = 0
    private var hasMoreHistory = true

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

            let status = try await statusTask
            let branches = try await branchesTask
            let remoteBranches = try await remoteBranchesTask

            self.status = status
            self.branches = branches
            self.remoteBranches = remoteBranches
            self.currentBranch = status.branch ?? branches.first(where: \.isCurrent)?.name

            // Fresh history.
            loadedPages = 0
            hasMoreHistory = true
            commits = []
            await loadMoreHistory(using: git)

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

    func loadMoreHistory(using git: GitService) async {
        guard hasMoreHistory else { return }
        let url = repository.url
        do {
            let page = try await git.log(
                at: url,
                limit: pageSize,
                skip: loadedPages * pageSize,
                branch: currentBranch
            )
            commits.append(contentsOf: page)
            loadedPages += 1
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
        viewModels[repository.id] = vm
        return vm
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
        if selectedRepositoryID == repo.id {
            selectedRepositoryID = store.repositories.first?.id
        }
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
