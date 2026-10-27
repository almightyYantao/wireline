import Foundation
import Testing
@testable import WirelineCore

@Suite struct CompletionTests {
    @Test func trackerFollowsTyping() {
        var t = CompletionLineTracker()
        t.feed(Array("git chk".utf8))
        t.feed([0x7F])
        t.feed(Array("eckout".utf8))
        #expect(t.line == "git checkout")
        t.feed([0x17])
        #expect(t.line == "git ")
        let done = t.feed(Array("status\r".utf8))
        #expect(done == ["git status"])
        #expect(t.line == "" && t.isValid)
    }

    @Test func trackerGivesUpOnEscapesAndTab() {
        var t = CompletionLineTracker()
        t.feed(Array("ls".utf8))
        t.feed(Array("\u{1b}[A".utf8))
        #expect(!t.isValid)
        t.feed(Array("x".utf8))
        #expect(t.line == "")
        #expect(t.feed([0x0D]) == [])
        #expect(t.isValid)
        t.feed(Array("ab\t".utf8))
        #expect(!t.isValid)
        t.feed([0x03])
        #expect(t.isValid && t.line == "")
    }

    @Test func trackerUTF8() {
        var t = CompletionLineTracker()
        let bytes = Array("cd 文档".utf8)
        for b in bytes { t.feed([b]) }
        #expect(t.line == "cd 文档")
        t.feed([0x7F])
        #expect(t.line == "cd 文")
    }

    @Test func parseQuotesAndSeparators() {
        let c = CompletionContext.parse("cd a && git checkout 'my br")
        #expect(c.words == ["git", "checkout"])
        #expect(c.current == "my br")
        let d = CompletionContext.parse("cat foo\\ bar ")
        #expect(d.words == ["cat", "foo bar"])
        #expect(d.current == "")
    }

    @Test func gitBranches() {
        var data = CompletionData()
        data.branches = ["main", "feat/x", "master"]
        let r = CompletionEngine.suggest(.parse("git checkout ma"), data: data)
        #expect(r.map(\.display) == ["main", "master"])
        #expect(r.first?.insert == "in ")
        let all = CompletionEngine.suggest(.parse("git switch "), data: data)
        #expect(all.map(\.display) == ["main", "feat/x", "master"])
        #expect(CompletionEngine.needs(for: .parse("git branch -d f")).contains(.branches))
        let sub = CompletionEngine.suggest(.parse("git che"), data: data)
        #expect(sub.first?.display == "checkout")
    }

    @Test func scriptsTargetsHosts() {
        var data = CompletionData()
        data.scripts = ["build", "dev", "test"]
        data.makeTargets = ["all", "install"]
        data.hosts = ["prod", "prod-db", "staging"]
        #expect(CompletionEngine.suggest(.parse("npm run d"), data: data).map(\.display) == ["dev"])
        #expect(CompletionEngine.suggest(.parse("pnpm "), data: data).count == 3)
        #expect(CompletionEngine.suggest(.parse("yarn run t"), data: data).map(\.display) == ["test"])
        #expect(CompletionEngine.suggest(.parse("make i"), data: data).map(\.display) == ["install"])
        #expect(CompletionEngine.suggest(.parse("ssh pr"), data: data).map(\.display) == ["prod", "prod-db"])
        #expect(CompletionEngine.suggest(.parse("ssh -p "), data: data).isEmpty)
    }

    @Test func paths() {
        var data = CompletionData()
        data.pathEntries = ["My Docs/", "main.swift", ".hidden"]
        let r = CompletionEngine.suggest(.parse("cd src/M"), data: data)
        #expect(r.map(\.display) == ["src/My Docs/"])
        #expect(r.first?.insert == "y\\ Docs/")
        #expect(CompletionEngine.suggest(.parse("cat "), data: data).isEmpty)
        #expect(CompletionEngine.suggest(.parse("cat ."), data: data).map(\.display) == [".hidden"])
        #expect(CompletionEngine.pathDirectoryPart("~/a/b") == "~/a/")
    }

    @Test func historyAfterSources() {
        var data = CompletionData()
        data.branches = ["main"]
        data.history = ["git checkout main && git pull", "git checkout main", "ls"]
        let r = CompletionEngine.suggest(.parse("git checkout m"), data: data)
        #expect(r.first?.kind == .branch)
        #expect(r.contains { $0.kind == .history && $0.insert == "ain && git pull" })
        #expect(CompletionEngine.suggest(.parse("l"), data: data).isEmpty)
    }

    @Test func fileParsers() {
        let pkg = Data(#"{"name":"x","scripts":{"dev":"vite","build":"tsc"}}"#.utf8)
        #expect(CompletionParsers.packageScripts(pkg) == ["build", "dev"])
        let mk = "CC := clang\n.PHONY: all\nall: build\nbuild test: deps\n\techo hi\n%.o: %.c\n"
        #expect(CompletionParsers.makeTargets(mk) == ["all", "build", "test"])
        let cfg = "Host *\n  User me\nHost prod prod2\nHost !bad dev\nhost=lower\n"
        #expect(CompletionParsers.sshHosts(cfg) == ["prod", "prod2", "dev", "lower"])
        let hist = ": 1700000000:0;ls -la\n: 1700000001:0;git status\nmulti \\\nline\nls -la\n"
        #expect(CompletionParsers.history(hist) == ["ls -la", "git status"])
    }

    @Test func trackerResyncsFromScreen() {
        let p = "~/src ❯ "
        #expect(CompletionLineTracker.lineFromScreen(prompt: p, before: p + "git sw", after: "") == "git sw")
        #expect(CompletionLineTracker.lineFromScreen(prompt: p, before: p + "ls ", after: "      12:01") == "ls ")
        // Cursor mid-line, autosuggestion or a changed prompt: give up.
        #expect(CompletionLineTracker.lineFromScreen(prompt: p, before: p + "git", after: "status") == nil)
        #expect(CompletionLineTracker.lineFromScreen(prompt: p, before: p + "git", after: " status") == nil)
        #expect(CompletionLineTracker.lineFromScreen(prompt: p, before: "other> git", after: "") == nil)
        #expect(CompletionLineTracker.lineFromScreen(prompt: "  ", before: "  git", after: "") == nil)

        var t = CompletionLineTracker()
        t.feed(Array("\u{1b}[A".utf8))
        t.resync("git log")
        t.feed(Array(" -1".utf8))
        #expect(t.isValid && t.line == "git log -1")
    }

    @Test func fuzzyMatchesRankAfterPrefix() {
        let items = ["feature/login", "fix-logs", "main", "fl", "release/1.0"]
        #expect(CompletionEngine.rank(items, prefix: "fl") == ["fl"])
        #expect(CompletionEngine.rank(items, prefix: "fl", fuzzy: true) == ["fl", "fix-logs", "feature/login"])
        #expect(CompletionEngine.rank(items, prefix: "MN", fuzzy: true) == ["main"])
        #expect(CompletionEngine.subsequenceScore("xyz", in: "main") == nil)

        var data = CompletionData()
        data.branches = ["main", "feature/login"]
        let fuzzy = CompletionEngine.suggest(.parse("git checkout flgn"), data: data)
        #expect(fuzzy.first == Completion(kind: .branch, display: "feature/login", insert: "feature/login ", erase: 4))
        let prefix = CompletionEngine.suggest(.parse("git checkout ma"), data: data)
        #expect(prefix.first == Completion(kind: .branch, display: "main", insert: "in ", erase: 0))
        // Quoted words can't be retyped safely: prefix only.
        #expect(CompletionEngine.suggest(.parse("git checkout 'flgn"), data: data).isEmpty)
    }
}
