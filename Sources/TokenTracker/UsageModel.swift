import Foundation
import Combine
import CoreGraphics

struct WindowUsage {
    var percent: Double // used, 0-100
    var resetsAt: Date?
    var asOf: Date? = nil // when this figure was observed, for staleness
    var remaining: Double { min(100, max(0, 100 - percent)) }
}

struct ServiceUsage {
    var session: WindowUsage? = nil
    var weekly: WindowUsage? = nil
    var plan: String? = nil
    var error: String? = nil
    var staleNote: String? = nil // data shown is old; this says why
    var asOf: Date? = nil
    var retryAfter: TimeInterval? = nil // server-dictated backoff (429 Retry-After)
    var organizationID: String? = nil
    var source: String? = nil
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

// MARK: - Claude Desktop plan-usage snapshots

enum ClaudeDesktopUsageHistory {
    private struct Sample {
        let asOf: Date
        let organizationID: String?
        let session: WindowUsage?
        let weekly: WindowUsage?
    }

    static func read() -> ServiceUsage? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else { return nil }

        guard let latest = samples.compactMap(sample).max(by: { $0.asOf < $1.asOf }) else {
            return nil
        }
        guard latest.session != nil || latest.weekly != nil else { return nil }
        return ServiceUsage(session: latest.session,
                            weekly: latest.weekly,
                            asOf: latest.asOf,
                            organizationID: latest.organizationID, source: "DESKTOP SNAPSHOT")
    }

    private static func sample(_ object: [String: Any]) -> Sample? {
        guard let rawTime = (object["t"] as? NSNumber)?.doubleValue,
              rawTime.isFinite, rawTime > 0,
              let usage = object["u"] as? [String: Any] else { return nil }

        let timestamp = rawTime > 1e11 ? rawTime / 1000 : rawTime
        let asOf = Date(timeIntervalSince1970: timestamp)
        guard asOf <= Date().addingTimeInterval(5 * 60) else { return nil }

        let session = window(usage["fh"], asOf: asOf)
        let weekly = window(usage["sd"], asOf: asOf)
        guard session != nil || weekly != nil else { return nil }
        return Sample(asOf: asOf, organizationID: object["org"] as? String, session: session, weekly: weekly)
    }

    private static func window(_ value: Any?, asOf: Date) -> WindowUsage? {
        guard let number = value as? NSNumber else { return nil }
        let percent = number.doubleValue
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return WindowUsage(percent: percent, resetsAt: nil, asOf: asOf)
    }
}

// MARK: - Claude usage response parsing

enum ClaudeReader {
    static func parse(body: Data) -> ServiceUsage {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ServiceUsage(error: "BAD RESPONSE")
        }
        // The windows moved out of the response root into `rate_limits`,
        // alongside `subscription_type` / `rate_limits_available`. Fall back to
        // the root so an older server still parses.
        guard obj["rate_limits_available"] as? Bool != false else {
            return ServiceUsage(error: "PLAN LIMITS N/A — API KEY")
        }
        let limits = (obj["rate_limits"] as? [String: Any]) ?? obj
        var u = ServiceUsage()
        u.plan = obj["subscription_type"] as? String
        let now = Date()
        u.session = window(limits["five_hour"])
        u.weekly = window(limits["seven_day"])
        u.session?.asOf = now
        u.weekly?.asOf = now
        u.asOf = now
        if u.session == nil && u.weekly == nil {
            return ServiceUsage(plan: u.plan, error: "NO USAGE WINDOWS")
        }
        return u
    }

    /// `utilization` is a 0-100 percentage, but both it and the window itself
    /// are nullable — a plan that has no such window sends null, which is an
    /// absent bar, not a 0%-used one.
    private static func window(_ any: Any?) -> WindowUsage? {
        guard let d = any as? [String: Any],
              let pct = d["utilization"] as? Double, pct.isFinite, (0...100).contains(pct) else { return nil }
        return WindowUsage(percent: pct,
                           resetsAt: Dates.parseISO(d["resets_at"] as? String))
    }
}

// MARK: - Codex (rate_limits events in ~/.codex/sessions rollout logs)

enum CodexReader {
    /// One limit bucket's most recent reading. Codex meters several buckets at
    /// once — `codex` for overall usage, plus model-specific ones such as
    /// `codex_bengalfox` (GPT-5.3-Codex-Spark) — and each session logs only the
    /// bucket it is billing against, so the newest event on disk is not
    /// necessarily the bucket that is actually constraining you.
    private struct Reading {
        var limitID: String
        var session: WindowUsage?
        var weekly: WindowUsage?
        var plan: String?
        var at: Date
    }

    // How far back to look for a bucket's newest event. A session that switches
    // model logs the old bucket well before the end of the file, so the first
    // scan reaches deep; after that only the tail can hold anything new.
    private static let firstScan: UInt64 = 16 * 1024 * 1024
    private static let tailScan: UInt64 = 512 * 1024

    // Rollout logs are append-only, so a file whose mtime hasn't moved cannot
    // have a newer event than last time we looked. Caching on mtime keeps the
    // 15-second refresh from re-reading megabytes of unchanged logs.
    private static let lock = NSLock()
    private static var cache: [URL: (mtime: Date, readings: [String: Reading])] = [:]

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

        // Scan a window of recent sessions rather than just the newest: the
        // buckets interleave, so the newest reading for one can sit several
        // files behind the newest reading for another.
        let recent = Array(files.prefix(16))
        var newestPerBucket: [String: Reading] = [:]
        for (url, mtime) in recent {
            for (id, r) in readings(url: url, mtime: mtime) {
                if let seen = newestPerBucket[id], seen.at >= r.at { continue }
                newestPerBucket[id] = r
            }
        }
        let readings = Array(newestPerBucket.values)
        guard !readings.isEmpty else { return ServiceUsage(error: "NO CODEX USAGE DATA") }

        // You hit whichever bucket is furthest along first, so each bar shows
        // the worst case across buckets instead of whoever logged most recently.
        var u = ServiceUsage()
        u.session = readings.compactMap(\.session).max { $0.percent < $1.percent }
        u.weekly = readings.compactMap(\.weekly).max { $0.percent < $1.percent }
        let newest = readings.max { $0.at < $1.at }
        u.plan = newest?.plan
        u.asOf = newest?.at
        if u.session == nil && u.weekly == nil { return ServiceUsage(error: "NO CODEX USAGE DATA") }
        return u
    }

    private static func readings(url: URL, mtime: Date) -> [String: Reading] {
        lock.lock()
        let hit = cache[url]
        lock.unlock()
        if let hit, hit.mtime == mtime { return hit.readings }

        // Append-only: once a file has been scanned, only its tail can hold
        // anything new, so merge a cheap tail read over what we already had
        // instead of re-reading megabytes every 15 seconds.
        let fresh = parse(url: url, limit: hit == nil ? firstScan : tailScan)
        var merged = hit?.readings ?? [:]
        for (id, r) in fresh where (merged[id]?.at ?? .distantPast) < r.at {
            merged[id] = r
        }
        lock.lock()
        // Bound the cache to roughly the scan window so it can't grow forever.
        if cache.count > 200 { cache.removeAll() }
        cache[url] = (mtime, merged)
        lock.unlock()
        return merged
    }

    private static func parse(url: URL, limit: UInt64) -> [String: Reading] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > limit ? size - limit : 0)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [:] }

        // A session bills against a different bucket when the model changes, so
        // one file can hold several. Scanning backwards, the first reading seen
        // for a bucket is its newest — keep collecting instead of stopping at
        // the first event, or a mid-session model switch hides the other bucket.
        var found: [String: Reading] = [:]
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            var r = Reading(limitID: (rl["limit_id"] as? String) ?? "codex",
                            plan: rl["plan_type"] as? String,
                            at: Dates.parseISO(obj["timestamp"] as? String) ?? .distantPast)
            // `primary`/`secondary` are positional, not fixed windows: the
            // overall bucket now sends its weekly window in `primary` with
            // `secondary` null, while model-specific buckets still send 5h then
            // weekly. Route each by its own length instead of its position.
            for key in ["primary", "secondary"] {
                guard let dict = rl[key] as? [String: Any],
                      var w = window(dict) else { continue }
                w.asOf = r.at
                let mins = (dict["window_minutes"] as? Double) ?? 0
                if mins >= 1440 { r.weekly = w } else { r.session = w }
            }
            if r.session == nil && r.weekly == nil { continue }
            if found[r.limitID] == nil { found[r.limitID] = r }
        }
        return found
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
    private var polling = ClaudePolling()

    func refreshAll(forceClaude: Bool = false, opening: Bool = false) {
        guard !refreshing else { return }
        refreshing = true
        let now = Date()
        // System idle time is metadata only: no input events or UI are captured.
        let active = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) < 300 || ClaudeActivity.isActive()
        let interval = ClaudePolling.interval(
            configured: UserDefaults.standard.double(forKey: "ClaudePollSeconds"), active: active)
        // Keychain repair may retry immediately after a user click; server backoff cannot.
        if forceClaude, claude.error == "CLICK REFRESH TO ALLOW KEYCHAIN" ||
            claude.staleNote == "CLICK REFRESH TO ALLOW KEYCHAIN" {
            polling.notBefore = nil
            polling.lastAttempt = nil
        }
        let due = polling.due(now: now, interval: interval, force: forceClaude || opening)
        if due { polling.lastAttempt = now }

        DispatchQueue.global(qos: .utility).async {
            let codex = CodexReader.read()
            let desktop = ClaudeDesktopUsageHistory.read()
            let live = due ? ClaudeWebReader.read(organizationID: desktop?.organizationID,
                                                  allowKeychainPrompt: forceClaude) : nil
            DispatchQueue.main.async {
                self.codex = codex
                if let desktop, let currentOrg = self.claude.organizationID,
                   desktop.organizationID != currentOrg {
                    self.claude = desktop
                }
                if let live {
                    self.polling.record(live, now: Date())
                    if live.error == nil {
                        self.claude = live
                    } else {
                        self.claude = Self.fallback(current: self.claude, desktop: desktop, error: live.error!)
                    }
                } else if let desktop,
                          desktop.asOf ?? .distantPast > self.claude.asOf ?? .distantPast {
                    var updated = desktop
                    updated.staleNote = self.claude.staleNote ?? self.claude.error
                    self.claude = updated
                }
                self.lastUpdated = Date()
                self.refreshing = false
                self.onUpdate?()
            }
        }
    }

    static func fallback(current: ServiceUsage, desktop: ServiceUsage?, error: String) -> ServiceUsage {
        var result = current
        if let desktop, desktop.asOf ?? .distantPast > current.asOf ?? .distantPast {
            result = desktop
        }
        if result.session != nil || result.weekly != nil {
            result.error = nil
            result.staleNote = error
        } else {
            result = ServiceUsage(error: error)
        }
        return result
    }
}
