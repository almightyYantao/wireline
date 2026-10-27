import XCTest
@testable import WirelineCore

/// Scrollback as Claude Code and Codex leave it (copied from real sessions,
/// trimmed): the reader must find the last answer and nothing else.
final class AgentAnswerExtractorTests: XCTestCase {

    func testClaudeCodeLastTurnSkipsToolsAndInputBox() {
        let screen = """
        ╭───────────────────────────────────────────────────╮
        │ ✻ Welcome to Claude Code!                         │
        ╰───────────────────────────────────────────────────╯

        > 第一个问题

        ⏺ 旧的回答，不该出现。

        > 为什么构建失败？

        ⏺ 我先看一下构建日志。

        ⏺ Bash(swift build 2>&1 | tail -20)
          ⎿  error: cannot find 'foo' in scope
             … +12 lines (ctrl+r to expand)

        ⏺ Read(Sources/App/Main.swift)
          ⎿  Read 120 lines (ctrl+r to expand)

        ⏺ 原因是 `foo` 在 Main.swift 第 42 行被删掉了，但调用处还在。

          修复方法：
          - 恢复 `foo` 的定义，或者
          - 把调用改成 `bar()`

        ✻ Cogitated for 12s

        ────────────────────────────────────────────────────────
        >
        ────────────────────────────────────────────────────────
          ? for shortcuts
        """
        XCTAssertEqual(AgentAnswerExtractor.latestAnswer(in: screen, agent: .claude), """
        我先看一下构建日志。

        原因是 `foo` 在 Main.swift 第 42 行被删掉了，但调用处还在。

        修复方法：
        - 恢复 `foo` 的定义，或者
        - 把调用改成 `bar()`
        """)
    }

    func testClaudeCodeWithColoursAndOldBox() {
        let screen = "\u{1b}[1m> \u{1b}[0mhello\r\n\r\n\u{1b}[38;5;231m⏺\u{1b}[0m Hi! How can I\r\n  help today?\r\n\r\n"
            + "\u{1b}]8;;\u{07}╭────────╮\r\n│ > \u{1b}[7m \u{1b}[0m     │\r\n╰────────╯\r\n"
        XCTAssertEqual(AgentAnswerExtractor.latestAnswer(in: screen, agent: .claude), "Hi! How can I\nhelp today?")
    }

    func testCodexSkipsRanAndExplored() {
        let screen = """
        › 列出最大的三个文件

        • Explored
          └ List ls -la

        • Ran du -sh * | sort -h | tail -3
          └ 1.2G  .build
            300M  Vendor

        • 最大的三个是：

          1. .build — 1.2G
          2. Vendor — 300M
          3. docs — 12M

        ─ Worked for 8s ──────────────────────────────────────────

        › Summarize recent commits

          100% context left · ? for shortcuts
        """
        XCTAssertEqual(AgentAnswerExtractor.latestAnswer(in: screen, agent: .codex), """
        最大的三个是：

        1. .build — 1.2G
        2. Vendor — 300M
        3. docs — 12M
        """)
    }

    func testCodeIndentAndMCPTool() {
        let screen = """
        > show me

        ⏺ github - search_code (MCP)(q: "foo")
          ⎿  3 results

        ⏺ Here:

            func foo() {
                bar()
            }

        >
        """
        XCTAssertEqual(AgentAnswerExtractor.latestAnswer(in: screen), "Here:\n\n  func foo() {\n      bar()\n  }")
    }

    func testReaderBlocks() {
        let answer = """
        # 结论
        原因是缓存没有
        失效，hard-wrapped at
        the terminal width.

        - 第一项
          继续第一项
        - 第二项

          let x = 1
          print(x)

        ```bash
        swift build
        ```
        """
        XCTAssertEqual(ReaderBlock.parse(answer), [
            .heading(level: 1, text: "结论"),
            .prose("原因是缓存没有失效，hard-wrapped at the terminal width."),
            .prose("- 第一项继续第一项\n- 第二项"),
            .code(language: nil, text: "let x = 1\nprint(x)"),
            .code(language: "bash", text: "swift build"),
        ])
    }

    func testNothingToRead() {
        XCTAssertNil(AgentAnswerExtractor.latestAnswer(in: "$ ls\nfoo bar\n$ "))
        XCTAssertNil(AgentAnswerExtractor.latestAnswer(in: "> run it\n\n⏺ Bash(make)\n  ⎿  ok\n"))
    }
}
