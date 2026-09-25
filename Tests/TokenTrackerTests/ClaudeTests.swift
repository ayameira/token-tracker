import XCTest
@testable import TokenTracker

final class ClaudeTests: XCTestCase {
    private func hex(_ string: String) -> Data {
        let chars = Array(string)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...$0+1]), radix: 16)!
        })
    }

    func testChromiumCookieFixtureAndHostBinding() throws {
        // Independent Python/cryptography fixture, with a fake password and cookie.
        let key = try ClaudeWebReader.deriveKey(Data("fake-test-password".utf8))
        XCTAssertEqual(key, hex("aba7c4fb9a58a78cc60b28eea3dd0884"))
        let encrypted = hex("76313088009fdd0c73790c81aa3f21b1068ceed51b338789444254d22839f167016e5b064786955b4ef59040442135819ccad5352b028608bc29916dd4f46b72344460")
        XCTAssertEqual(try ClaudeWebReader.decrypt(encrypted, host: ".claude.ai", version: 24, key: key), "sk-ant-test-only")
        XCTAssertThrowsError(try ClaudeWebReader.decrypt(encrypted, host: "other.example", version: 24, key: key))
        XCTAssertThrowsError(try ClaudeWebReader.decrypt(Data("v20bad".utf8), host: ".claude.ai", version: 24, key: key))
    }

    func testNeverGuessAmongOrganizationsOrReplaceMissingPreferredOrg() {
        let a = "00000000-0000-0000-0000-000000000001"
        let b = "00000000-0000-0000-0000-000000000002"
        let list: [[String: Any]] = [["uuid": a], ["uuid": b]]
        XCTAssertNil(ClaudeWebReader.selectOrganization(list, preferred: nil))
        XCTAssertEqual(ClaudeWebReader.selectOrganization(list, preferred: b), b)
        XCTAssertNil(ClaudeWebReader.selectOrganization([["uuid": a]], preferred: b))
        XCTAssertNil(ClaudeWebReader.selectOrganization([["uuid": "../elsewhere"]], preferred: nil))
    }

    func testCooldownAndRateLimitCannotBeBypassedByManualRefresh() {
        let now = Date(timeIntervalSince1970: 1000)
        var policy = ClaudePolling(lastAttempt: now)
        XCTAssertFalse(policy.due(now: now.addingTimeInterval(59), interval: 60, force: false))
        XCTAssertTrue(policy.due(now: now.addingTimeInterval(60), interval: 60, force: false))
        XCTAssertFalse(policy.due(now: now.addingTimeInterval(14), interval: 60, force: true))
        policy.record(ServiceUsage(error: "RATE LIMITED", retryAfter: 7200), now: now)
        XCTAssertFalse(policy.due(now: now.addingTimeInterval(7199), interval: 60, force: true))
        XCTAssertTrue(policy.due(now: now.addingTimeInterval(7200), interval: 60, force: false))
    }

    func testRetryAfterSupportsSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ClaudePolling.retryDelay("7200", now: now), 7200)
        XCTAssertEqual(ClaudePolling.retryDelay("Thu, 01 Jan 1970 02:00:00 GMT", now: now), 7200)
        XCTAssertEqual(ClaudePolling.retryDelay("invalid", now: now), 900)
    }

    func testActivityIntervalsAndErrorRecovery() {
        XCTAssertEqual(ClaudePolling.interval(configured: 0, active: true), 60)
        XCTAssertEqual(ClaudePolling.interval(configured: 10, active: true), 30)
        XCTAssertEqual(ClaudePolling.interval(configured: 60, active: false), 300)
        let now = Date()
        var policy = ClaudePolling()
        policy.record(ServiceUsage(error: "NETWORK"), now: now)
        policy.record(ServiceUsage(error: "NETWORK"), now: now)
        XCTAssertEqual(policy.notBefore, now.addingTimeInterval(120))
        policy.record(ServiceUsage(session: WindowUsage(percent: 20)), now: now)
        XCTAssertNil(policy.notBefore)
        XCTAssertEqual(policy.failures, 0)
    }

    func testFailedRefreshPreservesActualMeasurementTimeEvenForWeeklyOnly() {
        let original = Date(timeIntervalSince1970: 1000)
        let current = ServiceUsage(weekly: WindowUsage(percent: 12), asOf: original, source: "LIVE")
        let desktop = ServiceUsage(weekly: WindowUsage(percent: 7), asOf: original.addingTimeInterval(-600))
        let retained = UsageStore.fallback(current: current, desktop: desktop, error: "NETWORK")
        XCTAssertEqual(retained.weekly?.percent, 12)
        XCTAssertEqual(retained.asOf, original)
        XCTAssertEqual(retained.staleNote, "NETWORK")
        XCTAssertNil(retained.error)
    }

    func testUsageResponseResetsNullWindowsAndMalformedPercentages() {
        let usage = ClaudeReader.parse(body: Data(#"{"five_hour":{"utilization":63,"resets_at":"2026-09-25T22:40:00.229025+00:00"},"seven_day":null}"#.utf8))
        XCTAssertEqual(usage.session?.remaining, 37)
        XCTAssertNotNil(usage.session?.resetsAt)
        XCTAssertNil(usage.weekly)
        XCTAssertEqual(ClaudeReader.parse(body: Data(#"{"five_hour":{"utilization":101}}"#.utf8)).error, "NO USAGE WINDOWS")
    }
}
