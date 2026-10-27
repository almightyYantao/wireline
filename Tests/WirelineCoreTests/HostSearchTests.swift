import XCTest
@testable import WirelineCore

final class HostSearchTests: XCTestCase {
    private let hosts = [
        Host(alias: "web-prod", hostname: "10.0.1.5", user: "deploy", group: "Prod", descriptionText: "nginx #web #edge"),
        Host(alias: "db-main", hostname: "10.0.2.9", user: "root", group: "Prod", descriptionText: "mysql primary #db"),
        Host(alias: "staging", hostname: "web.staging.local", user: "ubuntu", group: "Staging"),
        Host(alias: "myweb", hostname: "192.168.1.2", user: "root", group: "Home"),
    ]

    private func aliases(_ q: String) -> [String] { HostSearch.search(q, in: hosts).map(\.host.alias) }

    func testTagsFromDescription() {
        XCTAssertEqual(hosts[0].tags, ["web", "edge"])
        XCTAssertEqual(Host(alias: "x", descriptionText: "no tags").tags, [])
    }

    func testRankingAliasPrefixThenContainsThenAddress() {
        XCTAssertEqual(aliases("web"), ["web-prod", "myweb", "staging"])
    }

    func testAndAcrossTerms() {
        XCTAssertEqual(aliases("prod mysql"), ["db-main"])
        XCTAssertEqual(aliases("root 10.0"), ["db-main"])
        XCTAssertEqual(aliases("root nothing"), [])
    }

    func testPrefixFilters() {
        XCTAssertEqual(aliases("tag:db"), ["db-main"])
        XCTAssertEqual(aliases("#edge"), ["web-prod"])
        XCTAssertEqual(Set(aliases("group:prod")), ["web-prod", "db-main"])
        XCTAssertEqual(aliases("user:root group:home"), ["myweb"])
        XCTAssertEqual(aliases("user:root db"), ["db-main"])
    }

    func testFieldsReported() {
        let m = HostSearch.search("mysql", in: hosts).first
        XCTAssertEqual(m?.fields, [.description])
        XCTAssertEqual(HostSearch.search("10.0.1", in: hosts).first?.fields, [.address])
    }

    func testEmptyQueryReturnsAllSorted() {
        XCTAssertEqual(aliases("  "), ["db-main", "myweb", "staging", "web-prod"])
    }

    func testSubsequenceFallback() {
        XCTAssertEqual(aliases("dbmn"), ["db-main"])
    }

    func testHighlightRanges() {
        let text = "Web-prod web"
        let r = HostSearch.highlightRanges(in: text, terms: ["web", "eb-p"])
        XCTAssertEqual(r.map { String(text[$0]) }, ["Web-p", "web"])
    }
}
