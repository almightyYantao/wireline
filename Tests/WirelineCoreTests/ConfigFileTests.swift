import XCTest
@testable import WirelineCore

final class ConfigFileTests: XCTestCase {
    func testParsesKeyValuesCommentsAndQuotes() {
        let text = """
        # a comment
        font-size = 14

          Font-Family = "JetBrains Mono"
        background-image =
        garbage line
        """
        let r = ConfigFile.parse(text)
        XCTAssertEqual(r.entries.map(\.key), ["font-size", "font-family", "background-image"])
        XCTAssertEqual(r.entries[1].value, "JetBrains Mono")
        XCTAssertEqual(r.entries[2].value, "")
        XCTAssertEqual(r.entries[1].line, 4)
        XCTAssertEqual(r.issues.count, 1)
        XCTAssertEqual(r.issues.first?.line, 6)
    }

    func testValueWithEqualsSignIsKept() {
        let r = ConfigFile.parse("keybind = cmd+shift+t=new_local_terminal")
        XCTAssertEqual(r.entries.first?.value, "cmd+shift+t=new_local_terminal")
    }

    func testKeybind() {
        let kb = ConfigFile.keybind("cmd+shift+t=new_local_terminal")
        XCTAssertEqual(kb?.key, "t")
        XCTAssertEqual(kb?.command, true)
        XCTAssertEqual(kb?.shift, true)
        XCTAssertEqual(kb?.option, false)
        XCTAssertEqual(kb?.action, "new_local_terminal")
        XCTAssertEqual(ConfigFile.keybind("ctrl+alt+==x")?.key, "=")
        XCTAssertEqual(ConfigFile.keybind("cmd++=x")?.key, "+")
        XCTAssertNil(ConfigFile.keybind("hyper+t=x"))
        XCTAssertNil(ConfigFile.keybind("cmd+t="))
        XCTAssertNil(ConfigFile.keybind("cmd+tab=x"))
        XCTAssertEqual(ConfigFile.keybind("cmd+opt+left=goto_split:left")?.key, "left")
        XCTAssertEqual(ConfigFile.keybind("cmd+shift+enter=toggle_split_zoom")?.key, "return")
    }

    func testCoercion() {
        XCTAssertEqual(ConfigFile.bool("ON"), true)
        XCTAssertEqual(ConfigFile.bool("no"), false)
        XCTAssertNil(ConfigFile.bool("maybe"))
        XCTAssertEqual(ConfigFile.number("99", in: 6...72), 72)
        XCTAssertNil(ConfigFile.number("big", in: 0...1))
    }

    func testIncludesOptionalAndCycles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("config")
        try """
        font-size = 12
        config-file = extra
        config-file = ?missing
        config-file = nothere
        font-size = 16
        """.write(to: main, atomically: true, encoding: .utf8)
        try "theme = Dracula\nconfig-file = config\n".write(
            to: dir.appendingPathComponent("extra"), atomically: true, encoding: .utf8)

        let r = ConfigFile.load(main)
        XCTAssertEqual(r.entries.map(\.key), ["font-size", "theme", "font-size"])
        XCTAssertEqual(r.entries.last?.value, "16")
        XCTAssertEqual(r.files.count, 2)
        // One cycle report (extra → config) + one unreadable required include.
        XCTAssertEqual(r.issues.count, 2)
    }

    func testMissingMainFileIsNotAnError() {
        let r = ConfigFile.load(URL(fileURLWithPath: "/nonexistent/wireline/config"))
        XCTAssertTrue(r.entries.isEmpty)
        XCTAssertTrue(r.issues.isEmpty)
    }

    func testDefaultURLHonoursXDG() {
        XCTAssertEqual(ConfigFile.defaultURL(environment: ["XDG_CONFIG_HOME": "/tmp/x"]).path,
                       "/tmp/x/wireline/config")
        XCTAssertTrue(ConfigFile.defaultURL(environment: [:]).path.hasSuffix("/.config/wireline/config"))
    }
}
