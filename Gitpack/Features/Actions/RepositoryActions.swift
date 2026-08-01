import AppKit

/// Every branch/tag/stash/history operation: the dialog it needs, the git call,
/// and the refresh, in one place.
///
/// The branch popup, the commit context menu, the menu bar, the settings sheet
/// and the file lists all drive these same methods — each of those surfaces
/// would otherwise grow its own copy of prompt → `run` → `refreshAll`.
/// Everything here is fire-and-forget so an `@objc` menu handler stays a
/// one-liner.
@MainActor
struct RepositoryActions {
    let appState: AppState

    private var vm: RepositoryViewModel? { appState.selectedViewModel }
    private var git: GitService { appState.git }

    /// `git` is handed in rather than read off `self` inside the closure: the
    /// body runs inside the view model's `perform`, and threading it through
    /// keeps the closure free of main-actor state.
    private func perform(_ body: @escaping (GitService, URL) async throws -> Void) {
        guard let vm else { return }
        let url = vm.repository.url
        let git = git
        Task { await vm.perform(using: git) { try await body(git, url) } }
    }

    /// A SHA is unreadable at full length and unambiguous at seven.
    private func short(_ ref: String) -> String {
        ref.count == 40 && ref.allSatisfy(\.isHexDigit) ? String(ref.prefix(7)) : ref
    }

    // MARK: - Checkout

    func checkout(_ ref: String) {
        perform { git, url in try await git.checkout(ref: ref, at: url) }
    }

    func checkoutTracking(_ remoteBranch: String) {
        perform { git, url in try await git.checkoutTracking(remoteBranch: remoteBranch, at: url) }
    }

    /// Checking out a commit or a tag leaves HEAD detached, which is a state
    /// worth naming before you're in it.
    func checkoutDetached(_ ref: String) {
        guard Prompt.confirm(
            "Check out \(short(ref))?",
            detail: "HEAD will be detached: new commits belong to no branch until you make one.",
            action: "Check Out",
            destructive: false
        ) else { return }
        checkout(ref)
    }

    /// The branch popup's "Checkout Commit…" — any ref git understands.
    func checkoutCommitPrompt() {
        guard let values = Prompt.text(
            "Checkout Commit",
            detail: "A commit SHA, tag, or any other ref.",
            action: "Check Out",
            fields: [Prompt.Field(placeholder: "SHA or ref")]
        ), let ref = values.first else { return }
        checkoutDetached(ref)
    }

    // MARK: - Branches

    func newBranch(from ref: String) {
        guard let values = Prompt.text(
            "New Branch",
            detail: "Creates a branch at \(short(ref)) and switches to it.",
            action: "Create",
            fields: [Prompt.Field(placeholder: "Branch name")]
        ), let name = values.first else { return }
        perform { git, url in
            try await git.createBranch(name: name, from: ref, checkout: true, at: url)
        }
    }

    func deleteBranch(_ name: String) {
        guard let vm, Prompt.confirm("Delete branch “\(name)”?", action: "Delete") else { return }
        let url = vm.repository.url
        let git = git
        Task {
            do {
                try await git.deleteBranch(name: name, force: false, at: url)
            } catch {
                // `git branch -d` refusing is the only warning the user gets that
                // commits are about to become unreachable, so it's a question,
                // not something to force past by default.
                if Prompt.confirm(
                    "“\(name)” is not fully merged.",
                    detail: "Deleting it may discard commits that exist on no other branch.",
                    action: "Delete Anyway"
                ) {
                    await vm.run { try await git.deleteBranch(name: name, force: true, at: url) }
                }
            }
            await vm.refreshAll(using: git)
        }
    }

    func deleteRemoteBranch(_ remoteBranch: String) {
        let parts = remoteBranch.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        guard Prompt.confirm(
            "Delete “\(parts[1])” from \(parts[0])?",
            detail: "This deletes the branch on the remote, for everyone.",
            action: "Delete"
        ) else { return }
        perform { git, url in
            try await git.deleteRemoteBranch(remote: parts[0], branch: parts[1], at: url)
        }
    }

    // MARK: - Tags

    func newTag(at ref: String) {
        guard let values = Prompt.text(
            "New Tag",
            detail: "Tags \(short(ref)).",
            action: "Create",
            fields: [
                Prompt.Field(placeholder: "Tag name"),
                Prompt.Field(placeholder: "Message (optional)"),
            ]
        ), let name = values.first, !name.isEmpty else { return }
        let message = values.count > 1 && !values[1].isEmpty ? values[1] : nil
        perform { git, url in
            try await git.createTag(name: name, message: message, ref: ref, at: url)
        }
    }

    func deleteTag(_ name: String) {
        guard Prompt.confirm(
            "Delete tag “\(name)”?",
            detail: "The tag is removed locally. A copy already pushed stays on the remote.",
            action: "Delete"
        ) else { return }
        perform { git, url in try await git.deleteTag(name: name, at: url) }
    }

    // MARK: - History operations

    func merge(_ commit: Commit) {
        perform { git, url in try await git.merge(ref: commit.id, at: url) }
    }

    func cherryPick(_ commit: Commit) {
        perform { git, url in try await git.cherryPick(sha: commit.id, commit: true, at: url) }
    }

    func applyAsPatch(_ commit: Commit) {
        perform { git, url in try await git.cherryPick(sha: commit.id, commit: false, at: url) }
    }

    func revert(_ commit: Commit) {
        guard Prompt.confirm(
            "Revert \(commit.shortID)?",
            detail: "Creates a new commit undoing “\(commit.subject)”.",
            action: "Revert",
            destructive: false
        ) else { return }
        perform { git, url in try await git.revert(sha: commit.id, at: url) }
    }

    func reset(to commit: Commit) {
        guard let vm else { return }
        let branch = vm.currentBranch ?? "HEAD"
        let dirty = !(vm.status?.isClean ?? true)
        guard Prompt.confirm(
            "Reset \(branch) to \(commit.shortID)?",
            detail: dirty
                ? "Later commits are dropped from this branch. Uncommitted changes are stashed first."
                : "Later commits are dropped from this branch.",
            action: "Reset"
        ) else { return }
        perform { git, url in
            // Stash first rather than reset --keep: the changes stay recoverable
            // from the stash list instead of blocking the reset.
            if dirty {
                try await git.stashPush(message: "Before reset to \(commit.shortID)", at: url)
            }
            try await git.reset(to: commit.id, at: url)
        }
    }

    // MARK: - Stash

    func stashChanges() {
        guard let vm, let status = vm.status, !status.isClean else { return }
        guard let values = Prompt.text(
            "Stash Changes",
            detail: "Sets the working copy aside, untracked files included.",
            action: "Stash",
            fields: [Prompt.Field(placeholder: "Description", value: stashMessage(for: status))]
        ), let message = values.first else { return }
        perform { git, url in try await git.stashPush(message: message, at: url) }
    }

    /// Gitbox's auto message: the file names themselves.
    private func stashMessage(for status: WorkingCopyStatus) -> String {
        let names = status.entries.map { ($0.path as NSString).lastPathComponent }
        let head = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(head) +\(names.count - 3) more" : head
    }

    func applyStash(_ stash: Stash) {
        perform { git, url in try await git.stashApply(ref: stash.ref, at: url) }
    }

    func removeStashes() {
        guard let vm, !vm.stashes.isEmpty else { return }
        let count = vm.stashes.count
        guard Prompt.confirm(
            count == 1 ? "Remove the stash?" : "Remove all \(count) stashes?",
            detail: "Stashed changes that were never applied are lost.",
            action: "Remove"
        ) else { return }
        perform { git, url in try await git.stashClear(at: url) }
    }

    // MARK: - Conflicted state

    func resolve(_ operation: RepositoryOperation, _ action: OperationAction) {
        if action == .abort, !Prompt.confirm(
            "Abort the \(operation.label.lowercased())?",
            detail: "The working copy goes back to where it was before it started.",
            action: "Abort"
        ) { return }
        perform { git, url in try await git.resolveOperation(operation, action, at: url) }
    }

    // MARK: - Remotes

    func addRemote() {
        guard let values = Prompt.text(
            "Add Remote",
            action: "Add",
            fields: [
                Prompt.Field(placeholder: "Name", value: "origin"),
                Prompt.Field(placeholder: "URL"),
            ]
        ), values.count == 2, !values[0].isEmpty, !values[1].isEmpty else { return }
        perform { git, url in
            try await git.addRemote(name: values[0], remoteURL: values[1], at: url)
        }
    }

    func removeRemote(_ name: String) {
        guard Prompt.confirm(
            "Remove remote “\(name)”?",
            detail: "Its remote-tracking branches go with it. Nothing on the remote itself changes.",
            action: "Remove"
        ) else { return }
        perform { git, url in try await git.removeRemote(name: name, at: url) }
    }

    // MARK: - Working copy files

    /// Appends a pattern to the repository's `.gitignore`, creating it if needed.
    func ignore(path: String) {
        guard let vm, let values = Prompt.text(
            "Ignore File",
            detail: "Appended to .gitignore.",
            action: "Ignore",
            fields: [Prompt.Field(placeholder: "Pattern", value: "/" + path)]
        ), let pattern = values.first else { return }

        let file = vm.repository.url.appendingPathComponent(".gitignore")
        var contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += pattern + "\n"
        do {
            try contents.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            vm.lastError = error.localizedDescription
        }
        Task { await vm.refreshStatusOnly(using: git) }
    }

    /// Moves files to the Trash rather than `git rm`: the deletion still shows
    /// up as a change to stage, and it stays recoverable.
    func delete(paths: [String]) {
        guard let vm, !paths.isEmpty else { return }
        guard Prompt.confirm(
            paths.count == 1 ? "Move “\(paths[0])” to the Trash?" : "Move \(paths.count) files to the Trash?",
            detail: "The deletion still has to be staged and committed.",
            action: "Move to Trash"
        ) else { return }
        for path in paths {
            let file = vm.repository.url.appendingPathComponent(path)
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            } catch {
                vm.lastError = error.localizedDescription
            }
        }
        Task { await vm.refreshStatusOnly(using: git) }
    }
}
