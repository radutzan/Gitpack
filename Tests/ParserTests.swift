import Foundation

// Assert-based parser tests, run via Tests/run-tests.sh.
// Every fixture is byte-exact output of the corresponding git command.

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok — \(label)")
    } else {
        print("FAIL — \(label)")
        exit(1)
    }
}

@main
struct ParserTests {
    static func main() {
        testPorcelainV2()
        testDiffTree()
        testLog()
        testRevList()
        testChangeClassifier()
        testSearchQuery()
        testSearchLog()
        testTags()
        testStashes()
    }

    // MARK: - Tags and stashes

    static func testTags() {
        // git for-each-ref --sort=-version:refname
        //   --format='%(refname:short)%1f%(objectname)%1f%(*objectname)%00' refs/tags
        // v1.10.0 is annotated (its own object, then the peeled commit);
        // v1.9.0 is lightweight, so the peeled field is empty.
        let fixture = "v1.10.0\u{1F}3a5c22002945deb6c74e8f2bb5426a119037f533"
            + "\u{1F}8725446dee534a3f7dcce51c4c62911c44c0370b\u{00}\n"
            + "v1.9.0\u{1F}cc2e1d6fb4de25ff3dfa9481e90e6cb27a2fe039\u{1F}\u{00}\n"
        let tags = TagParser.parse(fixture)
        check(tags.count == 2, "tags: two records")
        check(tags.map(\.name) == ["v1.10.0", "v1.9.0"], "tags: git's own version sort is kept")
        check(
            tags[0].targetSHA == "8725446dee534a3f7dcce51c4c62911c44c0370b",
            "tags: annotated tag resolves to the peeled commit"
        )
        check(
            tags[1].targetSHA == "cc2e1d6fb4de25ff3dfa9481e90e6cb27a2fe039",
            "tags: lightweight tag resolves to its own object"
        )
        check(TagParser.parse("").isEmpty, "tags: no tags")
    }

    static func testStashes() {
        // git stash list --format='%gd%x1f%gs%x1f%aI%x00'
        let fixture = "stash@{0}\u{1F}On main: a.txt tweak\u{1F}2026-08-01T14:17:33-07:00\u{00}\n"
            + "stash@{1}\u{1F}On main: b.txt work\u{1F}2026-08-01T14:17:32-07:00\u{00}\n"
        let stashes = StashParser.parse(fixture)
        check(stashes.count == 2, "stashes: two records")
        check(stashes[0].ref == "stash@{0}", "stashes: reflog selector kept verbatim")
        check(stashes[1].message == "On main: b.txt work", "stashes: message")
        check(stashes[0].date > stashes[1].date, "stashes: newest first")
        check(StashParser.parse("").isEmpty, "stashes: no stashes")
    }

    // MARK: - SearchQuery

    static func testSearchQuery() {
        let simple = SearchQuery.parse("  fix   Crash ")
        check(simple.map(\.text) == ["fix", "Crash"], "query: whitespace splits")
        check(simple.allSatisfy { !$0.exactCase }, "query: bare tokens are case-insensitive")

        let quoted = SearchQuery.parse(#"fix "NSTable View" tail"#)
        check(quoted.map(\.text) == ["fix", "NSTable View", "tail"], "query: quoted phrase kept whole")
        check(quoted[1].exactCase && !quoted[0].exactCase, "query: only the quoted token is exact-case")

        let escaped = SearchQuery.parse(#""say \"hi\"""#)
        check(escaped.map(\.text) == [#"say "hi""#], "query: escaped quotes inside a phrase")

        let unclosed = SearchQuery.parse(#"a "b c"#)
        check(unclosed.map(\.text) == ["a", "b c"], "query: unclosed quote closes at the end")
        check(SearchQuery.parse("   ").isEmpty, "query: whitespace only is no tokens")

        // AND across tokens, and the case rules the tokens carry.
        check(SearchQuery.matches(SearchQuery.parse("fix crash"), in: "Fix the CRASH"), "query: AND, case-insensitive")
        check(!SearchQuery.matches(SearchQuery.parse("fix nope"), in: "Fix the CRASH"), "query: one miss fails the AND")
        check(!SearchQuery.matches(SearchQuery.parse("\"CRASH\""), in: "Fix the crash"), "query: quoted is case-sensitive")
        check(SearchQuery.matches([], in: "anything"), "query: no tokens matches everything")

        let ranges = SearchQuery.ranges(of: SearchQuery.parse("ab"), in: "ab-AB-ab")
        check(ranges.count == 3, "query: every occurrence found, both cases")
    }

    // MARK: - LogParser search pass

    static func testSearchLog() {
        let us = "\u{1F}", rs = "\u{1E}"
        func record(_ sha: String, _ subject: String, patch: String) -> String {
            "\(rs)\(sha)\(us)\(sha.prefix(3))\(us)Radu Dutzan\(us)radu@example.com\(us)" +
            "2026-07-06T12:00:00Z\(us)p1\(us)\(subject)\(us)\(us)\(patch)"
        }
        // git log -p -U0 output: the format record, then the patch, per commit.
        let raw =
            record("aaa111", "Rename the widget", patch: """
            \ndiff --git a/Sources/Widget.swift b/Sources/Widget.swift
            @@ -3 +3 @@
            -let name = "old"
            +let name = "new"\n
            """) +
            record("bbb222", "Unrelated", patch: "\ndiff --git a/README.md b/README.md\n@@ -1 +1 @@\n-Hi\n+Hello\n")

        // Body stays empty even though a patch follows it — the trailing US is
        // what keeps the diff out of `%b`.
        let all = LogParser.parseSearch(raw, tokens: [])
        check(all.scanned == 2 && all.matches.count == 2, "search: no tokens matches every commit")
        check(all.matches[0].subject == "Rename the widget", "search: subject parsed")
        check(all.matches[0].body.isEmpty, "search: patch does not leak into the body")

        // A removed line, an added line, a path, and metadata all match.
        check(LogParser.parseSearch(raw, tokens: SearchQuery.parse("\"old\"")).matches.map(\.id) == ["aaa111"], "search: removed line")
        check(LogParser.parseSearch(raw, tokens: SearchQuery.parse("Hello")).matches.map(\.id) == ["bbb222"], "search: added line")
        check(LogParser.parseSearch(raw, tokens: SearchQuery.parse("Widget.swift")).matches.map(\.id) == ["aaa111"], "search: file path")
        check(LogParser.parseSearch(raw, tokens: SearchQuery.parse("radu@example.com")).matches.count == 2, "search: author e-mail")
        check(LogParser.parseSearch(raw, tokens: SearchQuery.parse("bbb222")).matches.map(\.id) == ["bbb222"], "search: sha")
        check(LogParser.parseSearch(raw, tokens: SearchQuery.parse("2026-07")).matches.count == 2, "search: date")

        // AND spans the whole record: message term + diff term.
        check(
            LogParser.parseSearch(raw, tokens: SearchQuery.parse("rename new")).matches.map(\.id) == ["aaa111"],
            "search: message term AND diff term"
        )
        check(LogParser.parseSearch(raw, tokens: SearchQuery.parse("nothinghere")).matches.isEmpty, "search: no match")
        check(LogParser.parseSearch("", tokens: []).scanned == 0, "search: empty input")
    }

    // MARK: - GitChangeClassifier

    static func testChangeClassifier() {
        func kind(_ paths: String...) -> WatchRefreshKind {
            GitChangeClassifier.refreshKind(for: paths)
        }
        let repo = "/tmp/repo/.git/"

        // Transient lock files are noise — git writes `X.lock` then renames to
        // `X`, so a real ref update still fires an event for the final path.
        // `git fetch` touches refs/remotes/<remote>/HEAD.lock on EVERY run even
        // when nothing changed; classifying that as .full caused constant
        // destructive history reloads (the disappearing-content bug).
        check(kind(repo + "refs/remotes/origin/HEAD.lock") == .none, "classifier: ref lock is noise")
        check(kind(repo + "HEAD.lock") == .none, "classifier: HEAD lock is noise")
        check(kind(repo + "index.lock") == .none, "classifier: index lock is noise")
        check(kind(repo + "objects/maintenance.lock") == .none, "classifier: maintenance lock is noise")

        // Real changes still classify correctly.
        check(kind(repo + "refs/remotes/origin/main") == .full, "classifier: remote ref moved is full")
        check(kind(repo + "refs/heads/main") == .full, "classifier: local ref moved is full")
        check(kind(repo + "HEAD") == .full, "classifier: HEAD is full")
        check(kind(repo + "packed-refs") == .full, "classifier: packed-refs is full")
        check(kind(repo + "index") == .status, "classifier: index is status")
        check(kind("/tmp/repo/Sources/File.swift") == .status, "classifier: working tree is status")
        check(kind(repo + "FETCH_HEAD") == .none, "classifier: FETCH_HEAD is noise")
        check(kind(repo + "objects/ab/cdef") == .none, "classifier: loose object is noise")

        // Batches take the coarsest.
        check(kind(repo + "index.lock", repo + "refs/heads/main") == .full, "classifier: batch coarsest wins")
        check(kind(repo + "index.lock", "/tmp/repo/a.txt") == .status, "classifier: lock + tree is status")
    }

    // MARK: - RevListParser

    static func testRevList() {
        let raw = "<aaa111\n>bbb222\n<ccc333\n>ddd444\n"
        let (left, right) = RevListParser.parseLeftRight(raw)
        check(left == ["aaa111", "ccc333"], "rev-list: left set")
        check(right == ["bbb222", "ddd444"], "rev-list: right set")

        let (l2, r2) = RevListParser.parseLeftRight("")
        check(l2.isEmpty && r2.isEmpty, "rev-list: empty input")

        let (l3, r3) = RevListParser.parseLeftRight("<only\n")
        check(l3 == ["only"] && r3.isEmpty, "rev-list: one-sided")
    }

    // MARK: - PorcelainV2Parser

    static func testPorcelainV2() {
        // git status --porcelain=v2 --branch -z with: headers, a staged+unstaged
        // modified file, a rename (type-2, origPath in the following NUL record),
        // an untracked file, and an unmerged file.
        let raw = [
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 MM N... 100644 100644 100644 aaaa bbbb Sources/App file.swift",
            "2 R. N... 100644 100644 100644 cccc dddd R100 new/path.swift",
            "old/path.swift",
            "? untracked file.txt",
            "u UU N... 100644 100644 100644 100644 eeee ffff gggg conflicted.swift",
            ""
        ].joined(separator: "\u{00}")
        let status = PorcelainV2Parser.parse(Data(raw.utf8))

        check(status.branch == "main", "porcelain: branch head")
        check(status.upstream == "origin/main", "porcelain: upstream")
        check(status.ahead == 2 && status.behind == 1, "porcelain: ahead/behind")
        check(status.entries.count == 4, "porcelain: entry count")

        let modified = status.entries[0]
        check(modified.path == "Sources/App file.swift", "porcelain: path with space survives -z")
        check(modified.stagedStatus == .modified && modified.unstagedStatus == .modified, "porcelain: MM split")
        check(modified.isPartiallyStaged, "porcelain: partial staging flag")

        let renamed = status.entries[1]
        check(renamed.path == "new/path.swift" && renamed.oldPath == "old/path.swift", "porcelain: rename paths")
        check(renamed.stagedStatus == .renamed && renamed.unstagedStatus == nil, "porcelain: rename staged only")
        check(renamed.isFullyStaged, "porcelain: rename fully staged")

        let untracked = status.entries[2]
        check(untracked.path == "untracked file.txt" && untracked.isUntracked, "porcelain: untracked")

        let unmerged = status.entries[3]
        check(unmerged.path == "conflicted.swift" && unmerged.stagedStatus == .unmerged, "porcelain: unmerged")

        // Clean repo, detached HEAD: only headers.
        let detachedRaw = "# branch.oid 1234\u{00}# branch.head (detached)\u{00}"
        let detached = PorcelainV2Parser.parse(Data(detachedRaw.utf8))
        check(detached.branch == nil, "porcelain: detached head is nil branch")
        check(detached.isClean, "porcelain: clean status")
    }

    // MARK: - DiffTreeParser

    static func testDiffTree() {
        // git diff-tree --no-commit-id --name-status -r -z:
        // plain entries are status\0path\0, renames are R<score>\0old\0new\0.
        let raw = "M\u{00}a/b.swift\u{00}A\u{00}new.swift\u{00}R087\u{00}before.swift\u{00}after.swift\u{00}D\u{00}gone.swift\u{00}"
        let changes = DiffTreeParser.parse(raw)

        check(changes.count == 4, "diff-tree: entry count")
        check(changes[0].status == .modified && changes[0].path == "a/b.swift", "diff-tree: modified")
        check(changes[1].status == .added && changes[1].path == "new.swift", "diff-tree: added")
        check(changes[2].status == .renamed && changes[2].path == "after.swift" && changes[2].oldPath == "before.swift", "diff-tree: rename")
        check(changes[3].status == .deleted, "diff-tree: deleted")
        check(DiffTreeParser.parse("").isEmpty, "diff-tree: empty input")
    }

    // MARK: - LogParser

    static func testLog() {
        let us = "\u{1F}", rs = "\u{1E}"
        // Two records: a merge commit with empty body, and a normal commit with
        // a multi-line body containing a US-free but newline-heavy message.
        // The RS leads each record and a US trails it — that trailing separator
        // is what keeps a `-p` patch out of `%b` in the search pass.
        let raw =
            "\(rs)abc123\(us)abc\(us)Radu Dutzan\(us)radu@example.com\(us)2026-07-06T12:00:00+02:00\(us)p1 p2\(us)Merge branch 'x'\(us)\(us)" +
            "\(rs)def456\(us)def\(us)Someone Else\(us)e@example.com\(us)2026-07-05T09:30:00Z\(us)p1\(us)Fix the thing\(us)Long body line one.\nLine two.\n\(us)"
        let commits = LogParser.parse(raw)

        check(commits.count == 2, "log: record count")
        let merge = commits[0]
        check(merge.id == "abc123" && merge.shortID == "abc", "log: ids")
        check(merge.isMerge && merge.parents == ["p1", "p2"], "log: merge parents")
        check(merge.body.isEmpty, "log: empty body")
        check(merge.subject == "Merge branch 'x'", "log: subject")

        let normal = commits[1]
        check(!normal.isMerge, "log: single parent")
        check(normal.body == "Long body line one.\nLine two.", "log: multiline body trimmed")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: normal.date)
        check(comps.year == 2026 && comps.month == 7 && comps.day == 5 && comps.hour == 9, "log: ISO date parsed")

        check(LogParser.parse("").isEmpty, "log: empty input")
        check(LogParser.parse("garbage without separators").isEmpty, "log: malformed record dropped")
    }
}
