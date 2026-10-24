import XCTest
import WirelineCore
@testable import Wireline

/// `AIClient` is where privacy is enforced for every AI feature: the request
/// that leaves must carry placeholders only, and the streamed reply must come
/// back with real values, even when a placeholder is split across chunks.
final class AIClientPrivacyTests: XCTestCase {

    /// Records the request and answers with an SSE stream built from it.
    final class StubModel: URLProtocol {
        nonisolated(unsafe) static var lastBody = ""
        nonisolated(unsafe) static var reply: (String) -> [String] = { _ in [] }

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    body.append(buf, count: n)
                }
                stream.close()
            }
            Self.lastBody = String(decoding: body, as: UTF8.self)
            let sse = Self.reply(Self.lastBody).map { chunk -> String in
                let json = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": chunk]]]])
                return "data: " + String(decoding: json, as: UTF8.self) + "\n\n"
            }.joined() + "data: [DONE]\n\n"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(sse.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    override func setUp() {
        URLProtocol.registerClass(StubModel.self)
        PrivacyContext.passwordsForTesting = ["Tr0ub4dor&3"]
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubModel.self)
        PrivacyContext.passwordsForTesting = nil
    }

    private func config(_ level: PrivacyPolicy.Level) -> AIConfig {
        let c = AIConfig()
        c.provider = .ollama
        c.ollamaBaseURL = "http://stub.test/v1"
        c.privacyLevel = level
        return c
    }

    private func collect(_ client: AIClient, _ text: String, masker: PrivacyMasker? = nil) async throws -> String {
        var out = ""
        for try await d in client.stream(system: "sys", messages: [AIMessage(role: .user, content: text)], masker: masker) {
            out += d
        }
        return out
    }

    func testRequestIsMaskedAndReplyRestored() async throws {
        // The "model" echoes back the placeholder it was given, split in three.
        StubModel.reply = { body in
            guard let r = body.range(of: #"\[WL[a-z0-9]{4}_SECRET_\d+\]"#, options: .regularExpression) else { return ["none"] }
            let token = String(body[r])
            let a = token.index(token.startIndex, offsetBy: 3), b = token.index(token.startIndex, offsetBy: 9)
            return ["echo ", String(token[..<a]), String(token[a..<b]), String(token[b...]), " ok"]
        }
        let reply = try await collect(AIClient(config: config(.secrets)), "the db password is Tr0ub4dor&3")
        XCTAssertFalse(StubModel.lastBody.contains("Tr0ub4dor"), "secret left the machine")
        XCTAssertTrue(StubModel.lastBody.contains("脱敏说明"), "the model wasn't told about placeholders")
        XCTAssertEqual(reply, "echo Tr0ub4dor&3 ok")
    }

    func testOffSendsTheRealText() async throws {
        StubModel.reply = { _ in ["fine"] }
        _ = try await collect(AIClient(config: config(.off)), "password=hunter22")
        XCTAssertTrue(StubModel.lastBody.contains("hunter22"))
        XCTAssertFalse(StubModel.lastBody.contains("脱敏说明"))
    }

    func testConversationMaskerKeepsPlaceholdersAcrossRequests() async throws {
        StubModel.reply = { _ in ["ok"] }
        let masker = PrivacyMasker(policy: PrivacyPolicy(level: .all))
        let client = AIClient(config: config(.all))
        _ = try await collect(client, "ping 203.0.113.7", masker: masker)
        let first = StubModel.lastBody
        _ = try await collect(client, "again 203.0.113.7", masker: masker)
        let token = "[WL\(masker.nonce)_IP_1]"
        XCTAssertTrue(first.contains(token))
        XCTAssertTrue(StubModel.lastBody.contains(token))
        XCTAssertFalse(StubModel.lastBody.contains("203.0.113.7"))
    }
}
