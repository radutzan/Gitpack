import Foundation

// MARK: - Log parser

nonisolated enum LogParser {
    /// The `--format=` both plain history and search use. The record separator
    /// leads rather than trails so that the patch `-p` prints *after* a record
    /// still belongs to that record's chunk, and the trailing US keeps it out of
    /// `%b` — without it the diff would be glued onto every commit body.
    static let format = "%x1e%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%s%x1f%b%x1f"

    /// Parses `git log --format=<format>` records (US field / RS record separators).
    static func parse(_ text: String) -> [Commit] {
        let dates = ISODates()
        return records(text).compactMap { commit(from: $0, dates: dates) }
    }

    /// The search pass: same records, but each one carries its `-p` patch, and
    /// only the chunks every token matches are parsed into commits. Matching
    /// against the raw chunk is what makes SHA, author, e-mail, ISO date,
    /// message *and* diff one haystack, with no per-field plumbing.
    ///
    /// ponytail: that haystack also holds the parent SHAs and the diff's own
    /// `index abc..def` lines, so a hex query can match a commit next to the one
    /// you meant. Narrow it by field if that ever bites.
    static func parseSearch(_ text: String, tokens: [SearchToken]) -> CommitSearchPage {
        let dates = ISODates()
        var matches: [Commit] = []
        var scanned = 0
        for record in records(text) {
            scanned += 1
            guard SearchQuery.matches(tokens, in: record),
                  let commit = commit(from: record, dates: dates) else { continue }
            matches.append(commit)
        }
        return CommitSearchPage(matches: matches, scanned: scanned)
    }

    private static func records(_ text: String) -> [Substring] {
        text.split(separator: "\u{1E}", omittingEmptySubsequences: true)
    }

    private static func commit(from record: Substring, dates: ISODates) -> Commit? {
        let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.components(separatedBy: "\u{1F}")
        guard fields.count >= 8 else { return nil }
        let parents = fields[5].split(separator: " ").map(String.init)
        return Commit(
            id: fields[0],
            shortID: fields[1],
            authorName: fields[2],
            authorEmail: fields[3],
            date: dates.date(from: fields[4]),
            parents: parents,
            subject: fields[6],
            body: fields[7].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Built per parse and passed down: `ISO8601DateFormatter` is a class and
    /// isn't `Sendable`, so a `nonisolated` parser can't keep one around.
    private struct ISODates {
        private let fractional = ISO8601DateFormatter()
        private let plain = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain.formatOptions = [.withInternetDateTime]
        }

        func date(from string: String) -> Date {
            fractional.date(from: string) ?? plain.date(from: string) ?? Date()
        }
    }
}

// MARK: - Search query

/// One term of a search query. Unquoted terms match case-insensitively; a
/// quoted one matches "ровно так, как введен" — exactly as typed, which is the
/// whole reason to quote it.
nonisolated struct SearchToken: Hashable, Sendable {
    let text: String
    let exactCase: Bool

    var options: String.CompareOptions { exactCase ? [] : [.caseInsensitive] }
}

nonisolated enum SearchQuery {
    /// Splits a query into tokens: whitespace separates, double quotes group,
    /// and a backslash escapes the next character inside quotes. An unclosed
    /// quote is treated as closing at the end of the query.
    static func parse(_ query: String) -> [SearchToken] {
        var tokens: [SearchToken] = []
        var current = ""
        var quoted = false
        var escaping = false
        var wasQuoted = false

        func flush() {
            if !current.isEmpty {
                tokens.append(SearchToken(text: current, exactCase: wasQuoted))
            }
            current = ""
            wasQuoted = false
        }

        for character in query {
            if escaping {
                current.append(character)
                escaping = false
            } else if quoted && character == "\\" {
                escaping = true
            } else if character == "\"" {
                if quoted {
                    quoted = false
                    flush()
                } else {
                    flush()
                    quoted = true
                    wasQuoted = true
                }
            } else if !quoted && character.isWhitespace {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    /// Every token has to appear somewhere — space-separated terms AND together.
    /// No tokens matches everything, which is what makes a bare path filter
    /// (Show File History) run through the same pipeline.
    static func matches(_ tokens: [SearchToken], in haystack: some StringProtocol) -> Bool {
        tokens.allSatisfy { haystack.range(of: $0.text, options: $0.options) != nil }
    }

    /// Every occurrence of every token, for highlighting. Overlaps are left in —
    /// painting the same range twice costs nothing.
    static func ranges(of tokens: [SearchToken], in text: String) -> [Range<String.Index>] {
        guard !tokens.isEmpty, !text.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        for token in tokens where !token.text.isEmpty {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: token.text, options: token.options, range: start..<text.endIndex) {
                found.append(range)
                start = range.isEmpty ? text.index(after: range.lowerBound) : range.upperBound
            }
        }
        return found
    }
}

// MARK: - rev-list --left-right parser

nonisolated enum RevListParser {
    /// Parses `git rev-list --left-right A...B`: one SHA per line, prefixed
    /// `<` (reachable only from A) or `>` (reachable only from B).
    static func parseLeftRight(_ text: String) -> (left: Set<String>, right: Set<String>) {
        var left = Set<String>()
        var right = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("<") {
                left.insert(String(line.dropFirst()))
            } else if line.hasPrefix(">") {
                right.insert(String(line.dropFirst()))
            }
        }
        return (left, right)
    }
}

// MARK: - Porcelain v2 parser

nonisolated enum PorcelainV2Parser {
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

nonisolated enum DiffTreeParser {
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
