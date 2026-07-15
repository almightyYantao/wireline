import Foundation
import Observation
import WirelineCore

/// WebDAV endpoint config for off-machine encrypted backups. The password lives
/// in the Keychain; the (already AES-GCM-encrypted) backup blob is what gets
/// uploaded, so the server never sees plaintext credentials.
@Observable
final class WebDAVConfig: @unchecked Sendable {
    static let shared = WebDAVConfig()

    var baseURL: String { didSet { d.set(baseURL, forKey: "webdav.base") } }
    var username: String { didSet { d.set(username, forKey: "webdav.user") } }
    var filename: String { didSet { d.set(filename, forKey: "webdav.file") } }

    private let d = UserDefaults.standard
    private let keychain = KeychainService()
    private let account = "__wireline_webdav__"

    var password: String {
        get { ((try? keychain.password(for: account)) ?? nil) ?? "" }
        set {
            if newValue.isEmpty { try? keychain.deletePassword(for: account) }
            else { try? keychain.setPassword(newValue, for: account) }
        }
    }

    init() {
        baseURL = d.string(forKey: "webdav.base") ?? ""
        username = d.string(forKey: "webdav.user") ?? ""
        filename = d.string(forKey: "webdav.file") ?? "wireline-backup.wlbk"
    }

    var isConfigured: Bool { !baseURL.isEmpty }
}

struct WebDAVClient: Sendable {
    let config: WebDAVConfig

    enum Failure: LocalizedError {
        case badURL, http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL: return "WebDAV 地址无效"
            case .http(let c): return "WebDAV 请求失败 (HTTP \(c))"
            }
        }
    }

    private func fileURL() throws -> URL {
        let base = config.baseURL.hasSuffix("/") ? config.baseURL : config.baseURL + "/"
        guard let url = URL(string: base + config.filename) else { throw Failure.badURL }
        return url
    }

    private func authorized(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        let token = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
        if !config.username.isEmpty { req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Upload the encrypted backup blob (HTTP PUT).
    func upload(_ data: Data) async throws {
        let req = authorized(try fileURL(), method: "PUT")
        let (_, resp) = try await URLSession.shared.upload(for: req, from: data)
        try check(resp)
    }

    /// Download the encrypted backup blob (HTTP GET).
    func download() async throws -> Data {
        let req = authorized(try fileURL(), method: "GET")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp)
        return data
    }

    private func check(_ resp: URLResponse) throws {
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
    }
}
