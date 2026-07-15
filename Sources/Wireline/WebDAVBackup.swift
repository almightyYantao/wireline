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

/// Answers Basic/Digest auth challenges with the WebDAV credential — the robust
/// path that works whether the server wants preemptive Basic or a challenge
/// (some servers, e.g. with Digest, reject a preemptive Basic header → 401).
final class WebDAVAuthDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let user: String
    let password: String
    init(user: String, password: String) { self.user = user; self.password = password }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodHTTPDigest
                || method == NSURLAuthenticationMethodDefault else {
            return (.performDefaultHandling, nil)
        }
        guard challenge.previousFailureCount == 0 else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
    }
}

struct WebDAVClient: Sendable {
    let config: WebDAVConfig

    enum Failure: LocalizedError {
        case badURL, http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL: return "WebDAV 地址无效"
            case .http(401):
                return "认证失败 (401)：检查用户名/密码。坚果云 / Nextcloud 等需使用「应用专用密码」，而非登录密码。"
            case .http(403): return "无权限 (403)：该账号对此路径没有写权限。"
            case .http(404): return "路径不存在 (404)：检查服务地址是否正确。"
            case .http(let c): return "WebDAV 请求失败 (HTTP \(c))"
            }
        }
    }

    private var baseWithSlash: String {
        config.baseURL.hasSuffix("/") ? config.baseURL : config.baseURL + "/"
    }

    private func fileURL() throws -> URL {
        guard let url = URL(string: baseWithSlash + config.filename) else { throw Failure.badURL }
        return url
    }

    /// The exact URL a backup is written to (for showing the user where it went).
    var targetDescription: String { (baseWithSlash + config.filename) }

    /// Best-effort create the collection (folder) the backup lives in. WebDAV
    /// PUT fails with 409 if the parent doesn't exist, so MKCOL it first;
    /// 405/301 mean it already exists — ignore.
    /// Create every path segment of the target directory, from the root down, so
    /// nested folders (e.g. /a/b/c/) all exist before the PUT. Existing folders
    /// return 405/301 — harmless.
    func ensureCollection() async {
        guard var comps = URLComponents(string: baseWithSlash) else { return }
        let parts = comps.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return }
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        var cumulative = ""
        for part in parts {
            cumulative += "/" + part
            comps.path = cumulative + "/"
            guard let url = comps.url else { continue }
            _ = try? await session.data(for: request(url, method: "MKCOL"))
        }
    }

    private func request(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        // Preemptive Basic (covers servers that expect it up front); the delegate
        // additionally handles Basic/Digest challenges.
        let token = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
        if !config.username.isEmpty { req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func makeSession() -> URLSession {
        URLSession(configuration: .default,
                   delegate: WebDAVAuthDelegate(user: config.username, password: config.password),
                   delegateQueue: nil)
    }

    /// Upload the encrypted backup blob (HTTP PUT).
    func upload(_ data: Data) async throws {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (_, resp) = try await session.upload(for: request(try fileURL(), method: "PUT"), from: data)
        try check(resp)
    }

    /// Download the encrypted backup blob (HTTP GET).
    func download() async throws -> Data {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: request(try fileURL(), method: "GET"))
        try check(resp)
        return data
    }

    private func check(_ resp: URLResponse) throws {
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
    }
}
