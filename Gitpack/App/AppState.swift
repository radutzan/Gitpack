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
    var stashes: [Stash] = []
    /// The half-finished rebase/merge/cherry-pick/revert the working copy is in,
    /// if any — what the stage pane's Abort/Skip/Continue row hangs off.
    var operation: RepositoryOperation?
    var tags: [Tag] = [] {
        // Indexed once per change rather than searched per row: history rows ask
        // for a commit's tags on every cell that scrolls past.
        didSet {
            tagNames = Dictionary(grouping: tags, by: \.targetSHA)
                .mapValues { $0.map(\.name) }
        }
    }
    private(set) var tagNames: [String: [String]] = [:]

    func tags(for sha: String) -> [String] { tagNames[sha] ?? [] }

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

    /// The commit message lives here rather than in the composer so ⌘↩ from the
    /// menu bar can commit without reaching into the view hierarchy, and so a
    /// draft survives clicking away to a commit and back.
    var commitMessage = ""

    var unstagedPaths: [String] {
        status?.entries.filter { $0.unstagedStatus != nil }.map(\.path) ?? []
    }

    var canCommit: Bool {
        let hasStaged = status?.entries.contains { $0.stagedStatus != nil } ?? false
        return hasStaged && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Runs a git call and funnels either flavour of failure into `lastError`.
    /// Every call site used to repeat the same two-clause catch.
    @discardableResult
    func run(_ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            return true
        } catch let error as GitError {
            lastError = error.description
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Run a mutation, then reload. The refresh runs even when the call failed:
    /// a conflicted merge or cherry-pick exits non-zero and *still* leaves the
    /// working copy in a state the panes have to show.
    func perform(using git: GitService, _ body: () async throws -> Void) async {
        let succeeded = await run(body)
        // `refreshAll` clears `lastError` when it succeeds — which it will,
        // because reading the repository is not what failed. Put the failure
        // back afterwards or the banner never appears and the operation looks
        // like it simply did nothing.
        let failure = lastError
        await refreshAll(using: git)
        if !succeeded { lastError = failure }
    }

    private let pageSize = 200
    /// Readable so the history list can show its "Load more" row off the real
    /// answer rather than guessing from `commits.count >= pageSize`, which stays
    /// true forever once you've paged past the first screen.
    private(set) var hasMoreHistory = true

    // MARK: - Live search

    /// The query as typed. Owned here rather than by the search field for the
    /// same reason `commitMessage` is: ⌘F and Esc reach it without going
    /// through the view hierarchy, and it survives switching repos and back.
    var searchQuery = ""
    /// Show File History: restricts the same pipeline to one path.
    private(set) var searchPathFilter: String?
    private(set) var searchResults: [Commit] = []
    /// The tokens the visible results were produced with — what the rows
    /// highlight. Kept separate from `searchQuery` so highlighting can't run
    /// ahead of the results while you are still typing.
    private(set) var searchTokens: [SearchToken] = []
    private(set) var searchScanned = 0
    private(set) var isSearching = false
    private var searchTask: Task<Void, Never>?
    /// Bumped on every restart so a page that lands from a superseded search
    /// can't append its results or clear the spinner.
    private var searchGeneration = 0
    private let searchPageSize = 200

    var isSearchActive: Bool {
        searchPathFilter != nil || !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the history list shows: results while a search is on, the real
    /// history otherwise.
    var displayedCommits: [Commit] {
        isSearchActive ? searchResults : commits
    }

    /// A commit by SHA from either list — a search result can be far deeper in
    /// history than the loaded page, and the detail pane still has to find it.
    func commit(withID id: String) -> Commit? {
        commits.first { $0.id == id } ?? searchResults.first { $0.id == id }
    }

    /// (Re)starts the search for the current query and path filter. Safe to call
    /// on every keystroke: the previous run is cancelled and the incremental
    /// delay restarts with it, which is Gitbox's "restart the timer" rule.
    func updateSearch(using git: GitService) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let tokens = SearchQuery.parse(searchQuery)
        let paths = searchPathFilter.map { [$0] } ?? []

        searchTokens = tokens
        searchResults = []
        searchScanned = 0

        guard !tokens.isEmpty || !paths.isEmpty else {
            isSearching = false
            searchTask = nil
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
            await self.runSearch(generation: generation, tokens: tokens, paths: paths, using: git)
        }
    }

    func showFileHistory(path: String, using git: GitService) {
        searchPathFilter = path
        searchQuery = ""
        updateSearch(using: git)
    }

    /// Esc, and the results bar's close button: drop the query, the filter and
    /// the running stream, and fall back to normal history.
    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        searchQuery = ""
        searchPathFilter = nil
        searchTokens = []
        searchResults = []
        searchScanned = 0
        isSearching = false
    }

    /// Walks history a page at a time, appending matches as they arrive, until
    /// it runs out or is superseded. No index, by design — Gitbox searched live
    /// too, and an index would have to be invalidated on every fetch.
    ///
    /// ponytail: pages rather than one streamed `git log -p`. Cancellation
    /// therefore lands at page granularity (an in-flight page finishes and is
    /// dropped), and `--skip` re-walks the graph from the tips each page, which
    /// is quadratic in the deep tail of a very large repo. Upgrade path is a
    /// single streamed process, split on the 0x1E byte, killed on cancel.
    private func runSearch(
        generation: Int,
        tokens: [SearchToken],
        paths: [String],
        using git: GitService
    ) async {
        let url = repository.url
        let refs = historyRefs
        var skip = 0
        while !Task.isCancelled, generation == searchGeneration {
            do {
                let page = try await git.searchLog(
                    at: url, tokens: tokens, paths: paths,
                    limit: searchPageSize, skip: skip, refs: refs
                )
                guard !Task.isCancelled, generation == searchGeneration else { return }
                skip += page.scanned
                searchScanned = skip
                if !page.matches.isEmpty {
                    searchResults.append(contentsOf: page.matches)
                }
                if page.scanned < searchPageSize { break }
            } catch {
                break
            }
        }
        if generation == searchGeneration {
            isSearching = false
        }
    }

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
            async let tagsTask = git.tags(at: url)
            async let stashesTask = git.stashes(at: url)
            async let operationTask = git.operation(at: url)

            let status = try await statusTask
            let branches = try await branchesTask
            let remoteBranches = try await remoteBranchesTask
            let remotes = try await remotesTask
            let tags = try await tagsTask
            let stashes = try await stashesTask
            let previousOperation = operation
            self.operation = await operationTask

            // Only assign what actually changed. refreshAll runs on every app
            // activation and after every autofetch; unconditional assignment —
            // especially rebuilding `commits` — reloads the NSTableView mid-
            // click, blanking the panes and dropping selection.
            self.status = status
            if branches != self.branches { self.branches = branches }
            if remoteBranches != self.remoteBranches { self.remoteBranches = remoteBranches }
            if remotes != self.remotes { self.remotes = remotes }
            if tags != self.tags { self.tags = tags }
            if stashes != self.stashes { self.stashes = stashes }
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
            // An operation that just stopped half-way puts its Abort/Skip/
            // Continue row in the stage pane, so move there — otherwise the way
            // out of the mode is behind a click you don't know to make.
            if operation != nil, previousOperation == nil {
                selection = .workingCopy
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
            // Cheap (four `stat`s) and it has to be here as well as in
            // refreshAll: a conflict resolved by editing files on disk only ever
            // produces a `.status` refresh.
            self.operation = await git.operation(at: url)
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
                try await git.merge(ref: other, at: repository.url)
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

    /// The remote the other branch lives on, when the other branch is a remote one.
    private var upstreamRemote: String? {
        guard let other = otherBranch, !otherBranchIsLocal else { return nil }
        let candidates = remotes.map(\.name).filter { other.hasPrefix($0 + "/") }
        return candidates.max(by: { $0.count < $1.count })
    }

    /// Where a ref that isn't the current branch — a tag — is pushed or deleted.
    /// Falls back the way `git push` itself does when there is nothing to derive
    /// it from. Nil only when the repository has no remotes at all.
    var defaultRemote: String? {
        if let upstreamRemote { return upstreamRemote }
        return remotes.contains { $0.name == "origin" } ? "origin" : remotes.first?.name
    }

    /// Explicit push destination derived from the other branch, Gitbox-style
    /// (`git push <remote> <current>:<remoteBranch>`), so pushing works even
    /// when local and remote branch names differ. Falls back to plain `git push`.
    private var pushTarget: (remote: String?, refspec: String?) {
        guard let current = currentBranch, let other = otherBranch, let remote = upstreamRemote else {
            return (nil, nil)
        }
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

    /// Commit and Stage All are pure model operations — no view involved — so
    /// the menu item and the composer's button can share one implementation
    /// without the menu having to reach into the detail pane.
    func commit(_ vm: RepositoryViewModel) async {
        let message = vm.commitMessage
        let committed = await vm.run {
            try await self.git.commit(message: message, at: vm.repository.url)
        }
        if committed { vm.commitMessage = "" }
        await vm.refreshAll(using: git)
    }

    func stageAll(_ vm: RepositoryViewModel) async {
        let paths = vm.unstagedPaths
        guard !paths.isEmpty else { return }
        await vm.run { try await self.git.stage(paths: paths, at: vm.repository.url) }
        await vm.refreshStatusOnly(using: git)
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
