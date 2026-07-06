import Foundation

struct WindowUsage {
    var percent: Double // used, 0-100
    var resetsAt: Date?
    var remaining: Double { min(100, max(0, 100 - percent)) }
}

struct ServiceUsage {
    var session: WindowUsage? = nil
    var weekly: WindowUsage? = nil
    var plan: String? = nil
    var error: String? = nil
    var staleNote: String? = nil // data shown is old; this says why
    var asOf: Date? = nil
}

enum Dates {
    static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
                    "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                    "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    static func resetLabel(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "EEE h:mm a"
        return "resets \(f.string(from: d))".uppercased()
    }
}

// MARK: - Claude (Keychain OAuth token -> Anthropic usage endpoint)

enum ClaudeReader {
    static func read() -> ServiceUsage {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch {
            return ServiceUsage(error: "KEYCHAIN UNAVAILABLE")
        }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return ServiceUsage(error: "NO CLAUDE CODE LOGIN")
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10

        let sem = DispatchSemaphore(value: 0)
        var result = ServiceUsage(error: "NETWORK ERROR")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, let data else { return }
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 401, 403:
                    result = ServiceUsage(error: "TOKEN EXPIRED — OPEN CLAUDE CODE")
                case 429:
                    result = ServiceUsage(error: "RATE LIMITED — WILL RETRY")
                default:
                    result = ServiceUsage(error: "HTTP \(http.statusCode)")
                }
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = ServiceUsage(error: "BAD RESPONSE")
                return
            }
            var u = ServiceUsage()
            if let w = obj["five_hour"] as? [String: Any] {
                u.session = WindowUsage(percent: (w["utilization"] as? Double) ?? 0,
                                        resetsAt: Dates.parseISO(w["resets_at"] as? String))
            }
            if let w = obj["seven_day"] as? [String: Any] {
                u.weekly = WindowUsage(percent: (w["utilization"] as? Double) ?? 0,
                                       resetsAt: Dates.parseISO(w["resets_at"] as? String))
            }
            u.asOf = Date()
            result = u
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        return result
    }
}

// MARK: - Codex (rate_limits events in ~/.codex/sessions rollout logs)

enum CodexReader {
    static func read() -> ServiceUsage {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ServiceUsage(error: "NO CODEX SESSIONS FOUND")
        }
        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            files.append((url, d))
        }
        files.sort { $0.1 > $1.1 }
        // Resuming an old session bumps its file's mtime without necessarily
        // logging a fresh rate_limits event, so the newest file can carry stale
        // numbers. Keep the newest event across candidates instead; stop once
        // no remaining file can win (events are never newer than their mtime).
        var best: (usage: ServiceUsage, at: Date)? = nil
        for (url, mtime) in files.prefix(8) {
            if let b = best, b.at >= mtime { break }
            guard let u = parse(url: url) else { continue }
            let at = u.asOf ?? mtime
            if best == nil || at > best!.at { best = (u, at) }
        }
        if let best { return best.usage }
        return ServiceUsage(error: "NO CODEX USAGE DATA")
    }

    private static func parse(url: URL) -> ServiceUsage? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 512 * 1024
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            var u = ServiceUsage()
            u.plan = rl["plan_type"] as? String
            u.session = window(rl["primary"])
            u.weekly = window(rl["secondary"])
            u.asOf = Dates.parseISO(obj["timestamp"] as? String)
            if u.session == nil && u.weekly == nil { continue }
            return u
        }
        return nil
    }

    private static func window(_ any: Any?) -> WindowUsage? {
        guard let d = any as? [String: Any],
              let p = d["used_percent"] as? Double else { return nil }
        var resets: Date? = nil
        if let epoch = d["resets_at"] as? Double {
            resets = Date(timeIntervalSince1970: epoch)
        }
        // If the window already elapsed since the last logged event, usage is back to 0.
        if let r = resets, r < Date() {
            return WindowUsage(percent: 0, resetsAt: nil)
        }
        return WindowUsage(percent: p, resetsAt: resets)
    }
}

// MARK: - Claude Code activity detection (local transcripts)

enum ClaudeActivity {
    /// True when any Claude Code transcript was written in the last 5 minutes,
    /// i.e. the user is actively burning tokens and the numbers are moving.
    static func isActive() -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        let cutoff = Date().addingTimeInterval(-300)
        for case let url as URL in en where url.pathExtension == "jsonl" {
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, d > cutoff {
                return true
            }
        }
        return false
    }
}

// MARK: - Store

final class UsageStore: ObservableObject {
    @Published var claude = ServiceUsage()
    @Published var codex = ServiceUsage()
    @Published var lastUpdated: Date?
    var onUpdate: (() -> Void)?
    private var refreshing = false
    private var lastClaudeAttempt: Date?
    private var claudeBackoffUntil: Date?

    // Codex is a local file read — free, refreshed every tick (~15s).
    // Claude hits Anthropic's usage endpoint, which 429s under sustained
    // fast polling: 3 min while Claude Code is actively in use (numbers are
    // moving), 15 min when idle (they aren't), 15-min backoff after a 429.
    private func claudeGap(force: Bool) -> TimeInterval {
        if force { return 60 }
        return ClaudeActivity.isActive() ? 180 : 15 * 60
    }

    func refreshAll(forceClaude: Bool = false) {
        guard !refreshing else { return }
        refreshing = true

        let now = Date()
        var claudeDue: Bool
        if let until = claudeBackoffUntil, now < until, !forceClaude {
            claudeDue = false
        } else {
            let gap = claudeGap(force: forceClaude)
            claudeDue = lastClaudeAttempt.map { now.timeIntervalSince($0) >= gap } ?? true
        }
        if claudeDue { lastClaudeAttempt = now }

        DispatchQueue.global(qos: .utility).async {
            let codex = CodexReader.read()
            let claude = claudeDue ? ClaudeReader.read() : nil
            DispatchQueue.main.async {
                self.codex = codex
                if let claude {
                    if let err = claude.error {
                        if err.contains("RATE LIMITED") {
                            self.claudeBackoffUntil = Date().addingTimeInterval(15 * 60)
                        }
                        if self.claude.session != nil {
                            // Keep last good numbers; note why they're stale.
                            self.claude.staleNote = err
                        } else {
                            self.claude = claude
                        }
                    } else {
                        self.claudeBackoffUntil = nil
                        self.claude = claude
                    }
                }
                self.lastUpdated = Date()
                self.refreshing = false
                self.onUpdate?()
            }
        }
    }
}
