import Foundation
import Security
import LocalAuthentication
import SQLite3
import CommonCrypto

/// Reads only the Claude session cookie; no browser automation or app injection.
/// Called on the store's serial refresh path, never concurrently.
enum ClaudeWebReader {
    struct Failure: Error { let message: String }
    private static var encryptionKey: Data?
    private static var verifiedSession: (fingerprint: Data, organization: String)?

    static func read(organizationID: String?, allowKeychainPrompt: Bool = false) -> ServiceUsage {
        do {
            let cookie = try sessionCookie(allowPrompt: allowKeychainPrompt)
            let fingerprint = sha256(Data(cookie.utf8))
            let org: String
            if let verifiedSession, verifiedSession.fingerprint == fingerprint,
               organizationID == nil || organizationID == verifiedSession.organization {
                org = verifiedSession.organization
            } else {
                let organizations = try request(path: "/api/organizations", cookie: cookie)
                guard organizations.status == 200 else { return failure(organizations) }
                guard let list = try JSONSerialization.jsonObject(with: organizations.data) as? [[String: Any]],
                      let selected = selectOrganization(list, preferred: organizationID) else {
                    throw Failure(message: "OPEN CLAUDE TO SELECT AN ACCOUNT")
                }
                org = selected
                verifiedSession = (fingerprint, org)
            }
            let response = try request(path: "/api/organizations/\(org)/usage?skip_spend=1", cookie: cookie)
            guard response.status == 200 else {
                if response.status == 401 || response.status == 403 { verifiedSession = nil }
                return failure(response)
            }
            var result = ClaudeReader.parse(body: response.data)
            result.organizationID = org
            result.source = "LIVE"
            return result
        } catch let error as Failure {
            return ServiceUsage(error: error.message)
        } catch {
            return ServiceUsage(error: "CLAUDE USAGE UNAVAILABLE")
        }
    }

    static func selectOrganization(_ list: [[String: Any]], preferred: String?) -> String? {
        let ids = list.compactMap { $0["uuid"] as? String }.filter { UUID(uuidString: $0) != nil }
        if let preferred { return ids.contains(preferred) ? preferred : nil }
        return ids.count == 1 ? ids.first : nil
    }

    private static func sessionCookie(allowPrompt: Bool) throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Cookies").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw Failure(message: "OPEN CLAUDE AND SIGN IN")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        let sql = "SELECT host_key, encrypted_value, (SELECT value FROM meta WHERE key='version') FROM cookies WHERE name='sessionKey' AND host_key IN ('.claude.ai','claude.ai')"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(message: "CLAUDE COOKIE STORE UNAVAILABLE")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let hostText = sqlite3_column_text(statement, 0),
              let bytes = sqlite3_column_blob(statement, 1) else {
            throw Failure(message: "OPEN CLAUDE AND SIGN IN")
        }
        let host = String(cString: hostText)
        let encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        let version = sqlite3_column_int(statement, 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure(message: "CLAUDE COOKIE SELECTION AMBIGUOUS")
        }
        let key = try key(allowPrompt: allowPrompt)
        return try decrypt(encrypted, host: host, version: Int(version), key: key)
    }

    private static func key(allowPrompt: Bool) throws -> Data {
        if let encryptionKey { return encryptionKey }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        query[kSecUseAuthenticationContext as String] = context
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let password = value as? Data else {
            throw Failure(message: "CLICK REFRESH TO ALLOW KEYCHAIN")
        }
        let derived = try deriveKey(password)
        encryptionKey = derived
        return derived
    }

    static func deriveKey(_ password: Data) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    input.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    output.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        guard status == kCCSuccess else { throw Failure(message: "CLAUDE COOKIE KEY UNAVAILABLE") }
        return key
    }

    static func decrypt(_ encrypted: Data, host: String, version: Int, key: Data) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)), key.count == 16 else {
            throw Failure(message: "UNSUPPORTED CLAUDE COOKIE FORMAT")
        }
        let ciphertext = Data(encrypted.dropFirst(3))
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        let status = output.withUnsafeMutableBytes { out in
            key.withUnsafeBytes { key in
                ciphertext.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), key.baseAddress, 16, iv,
                            input.baseAddress, ciphertext.count, out.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure(message: "CLAUDE COOKIE DECRYPTION FAILED") }
        output.count = written
        if version >= 24 {
            let digest = sha256(Data(host.utf8))
            guard output.starts(with: digest) else { throw Failure(message: "CLAUDE COOKIE HOST MISMATCH") }
            output = Data(output.dropFirst(digest.count))
        }
        guard let cookie = String(data: output, encoding: .utf8), cookie.hasPrefix("sk-ant-"),
              cookie.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 59 }) else {
            throw Failure(message: "INVALID CLAUDE SESSION COOKIE")
        }
        return cookie
    }

    private static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    private struct Response { let status: Int; let data: Data; let retryAfter: String? }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static func request(path: String, cookie: String) throws -> Response {
        // No shared cookie jar, disk cache, redirects, or secret-bearing diagnostics.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: URL(string: "https://claude.ai" + path)!)
        req.setValue("sessionKey=" + cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenTracker/1.0", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var result: Response?
        session.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = Response(status: http.statusCode, data: data ?? Data(),
                                  retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            }
            sem.signal()
        }.resume()
        guard sem.wait(timeout: .now() + 22) == .success, let result else {
            throw Failure(message: "CLAUDE NETWORK ERROR")
        }
        return result
    }

    private static func failure(_ response: Response) -> ServiceUsage {
        if response.status == 429 {
            return ServiceUsage(error: "RATE LIMITED — WILL RETRY",
                                retryAfter: ClaudePolling.retryDelay(response.retryAfter))
        }
        if response.status == 401 { return ServiceUsage(error: "SIGN IN AGAIN IN CLAUDE") }
        if response.status == 403 {
            let text = String(data: response.data, encoding: .utf8)?.lowercased() ?? ""
            return ServiceUsage(error: text.contains("challenge") || text.contains("just a moment")
                ? "CLAUDE WEB CHALLENGE" : "CLAUDE ACCESS DENIED")
        }
        return ServiceUsage(error: "CLAUDE HTTP \(response.status)")
    }
}

struct ClaudePolling {
    var lastAttempt: Date?
    var notBefore: Date?
    var failures = 0

    static func interval(configured: Double, active: Bool) -> TimeInterval {
        let seconds = configured.isFinite && configured > 0 ? max(30, configured) : 60
        return active ? seconds : max(300, seconds)
    }
    func due(now: Date, interval: TimeInterval, force: Bool) -> Bool {
        if let notBefore, now < notBefore { return false }
        return lastAttempt.map { now.timeIntervalSince($0) >= (force ? 15 : interval) } ?? true
    }
    mutating func record(_ usage: ServiceUsage, now: Date) {
        if usage.error == nil { failures = 0; notBefore = nil; return }
        failures = min(failures + 1, 6)
        notBefore = now.addingTimeInterval(usage.retryAfter ?? min(900, 60 * pow(2, Double(failures - 1))))
    }
    static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval {
        if let header, let seconds = Double(header), seconds.isFinite { return max(1, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let header, let date = formatter.date(from: header) { return max(1, date.timeIntervalSince(now)) }
        return 900
    }
}
