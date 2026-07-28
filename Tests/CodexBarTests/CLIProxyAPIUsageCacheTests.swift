import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIUsageCacheTests {
    @Test
    func `default telemetry storage is durable application support`() throws {
        let fileManager = FileManager.default
        let durableURL = CLIProxyAPIUsageCacheIO.cacheFileURL()
        let legacyURL = CLIProxyAPIUsageCacheIO.legacyCacheFileURL()
        let durableRoot = try #require(fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first)
            .appendingPathComponent("CodexBar", isDirectory: true)
        let legacyRoot = try #require(fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask).first)
            .appendingPathComponent("CodexBar", isDirectory: true)

        #expect(durableURL.path.hasPrefix(durableRoot.path + "/"))
        #expect(legacyURL.path.hasPrefix(legacyRoot.path + "/"))
        #expect(durableURL != legacyURL)
    }

    @Test
    func `legacy purgeable telemetry migrates into durable storage`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-migration-\(UUID().uuidString)", isDirectory: true)
        let durableRoot = root.appendingPathComponent("application-support", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("caches", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let record = CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: "codex",
            model: "gpt-5.4",
            alias: "gpt-5.4",
            endpoint: "POST /v1/messages",
            authType: "oauth",
            requestID: "request-1",
            tokens: .init(input: 10, output: 20, total: 30))
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [record],
            cacheRoot: legacyRoot,
            now: timestamp) == 1)
        let legacyURL = CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: legacyRoot)
        #expect(fileManager.fileExists(atPath: legacyURL.path))

        let migrated = CLIProxyAPIUsageCacheIO.load(
            cacheRoot: durableRoot,
            legacyCacheRoot: legacyRoot,
            now: timestamp)

        #expect(migrated.map(\.requestID) == ["request-1"])
        #expect(fileManager.fileExists(
            atPath: CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: durableRoot).path))
        #expect(!fileManager.fileExists(atPath: legacyURL.path))
    }

    @Test
    func `migration and collection share exclusive cache access`() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-lock-\(UUID().uuidString)", isDirectory: true)
        let durableRoot = root.appendingPathComponent("application-support", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("caches", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let legacyRecord = Self.record(id: "legacy", timestamp: timestamp)
        let collectedRecord = Self.record(
            id: "collected",
            timestamp: timestamp.addingTimeInterval(1))
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [legacyRecord],
            cacheRoot: legacyRoot,
            now: timestamp) == 1)

        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let loadStarted = DispatchSemaphore(value: 0)
        let loadFinished = DispatchSemaphore(value: 0)
        let mergeStarted = DispatchSemaphore(value: 0)
        let mergeFinished = DispatchSemaphore(value: 0)
        let lockHolder = Task.detached {
            CLIProxyAPIUsageCacheIO.withExclusiveAccess {
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        #expect(lockAcquired.wait(timeout: .now() + 1) == .success)

        let loadTask = Task.detached {
            loadStarted.signal()
            let records = CLIProxyAPIUsageCacheIO.load(
                cacheRoot: durableRoot,
                legacyCacheRoot: legacyRoot,
                now: timestamp)
            loadFinished.signal()
            return records
        }
        let mergeTask = Task.detached {
            mergeStarted.signal()
            let result = CLIProxyAPIUsageCacheIO.merge(
                [collectedRecord],
                cacheRoot: durableRoot,
                legacyCacheRoot: legacyRoot,
                now: timestamp)
            mergeFinished.signal()
            return result
        }
        #expect(loadStarted.wait(timeout: .now() + 1) == .success)
        #expect(mergeStarted.wait(timeout: .now() + 1) == .success)
        #expect(loadFinished.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
        #expect(mergeFinished.wait(timeout: .now() + .milliseconds(50)) == .timedOut)

        releaseLock.signal()
        await lockHolder.value
        _ = await loadTask.value
        #expect(await mergeTask.value == 1)
        let finalRecords = CLIProxyAPIUsageCacheIO.load(
            cacheRoot: durableRoot,
            legacyCacheRoot: legacyRoot,
            now: timestamp)
        #expect(Set(finalRecords.map(\.requestID)) == ["legacy", "collected"])
    }

    @Test
    func `fallback record identity survives cache round trips within one second`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-fractional-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let second = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let records = [
            Self.record(id: "", timestamp: second.addingTimeInterval(0.1)),
            Self.record(id: "", timestamp: second.addingTimeInterval(0.9)),
        ]

        #expect(CLIProxyAPIUsageCacheIO.merge(
            records,
            cacheRoot: root,
            now: second) == 2)
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [],
            cacheRoot: root,
            now: second) == 0)

        let roundTripped = CLIProxyAPIUsageCacheIO.load(
            cacheRoot: root,
            now: second)
        #expect(roundTripped.count == 2)
        #expect(roundTripped.map(\.timestamp) == records.map(\.timestamp))
    }

    private static func record(id: String, timestamp: Date) -> CLIProxyAPIUsageRecord {
        CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: "codex",
            model: "gpt-5.4",
            alias: "gpt-5.4",
            endpoint: "POST /v1/messages",
            authType: "oauth",
            requestID: id,
            tokens: .init(input: 10, output: 20, total: 30))
    }
}
