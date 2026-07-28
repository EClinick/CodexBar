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
}
