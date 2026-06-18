import Foundation

/// Loads and persists the user's repository list to
/// ~/Library/Application Support/Gitpack/repositories.json.
@MainActor
final class RepositoryStore {
    private let fileURL: URL
    private(set) var repositories: [Repository] = []

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fm = FileManager.default
            let support = (try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            let dir = support.appendingPathComponent("Gitpack", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("repositories.json")
        }
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Repository].self, from: data) {
            repositories = decoded
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(repositories) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ repo: Repository) {
        guard !repositories.contains(where: { $0.url.standardizedFileURL == repo.url.standardizedFileURL }) else { return }
        repositories.append(repo)
        save()
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0.id == repo.id || $0.parentID == repo.id }
        save()
    }

    func update(_ repo: Repository) {
        if let idx = repositories.firstIndex(where: { $0.id == repo.id }) {
            repositories[idx] = repo
            save()
        }
    }

    func contains(url: URL) -> Bool {
        let target = url.standardizedFileURL
        return repositories.contains { $0.url.standardizedFileURL == target }
    }
}
