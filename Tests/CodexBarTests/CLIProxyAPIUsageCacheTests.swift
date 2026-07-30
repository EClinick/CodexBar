import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIUsageCacheTests {
    @Test
    func `integration cleanup removes telemetry pending and derived Claude cache artifacts`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-cleanup-\(UUID().uuidString)", isDirectory: true)
        let legacy = root
            .appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
        let durable = root
            .appendingPathComponent("durable", isDirectory: true)
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        for directory in [legacy, durable] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("usage".utf8).write(to: directory.appendingPathComponent(
                CostUsageCacheLocations.cliProxyAPIUsageFileName))
            try Data("pending".utf8).write(to: directory.appendingPathComponent(
                CostUsageCacheLocations.cliProxyAPIPendingFileName))
        }
        for directory in [legacy, durable] {
            let claudeCache = CostUsageCacheIO.cacheFileURL(
                provider: .claude,
                cacheRoot: directory.deletingLastPathComponent())
            try Data("derived attribution".utf8).write(to: claudeCache)
        }
        let unrelated = durable.appendingPathComponent("codex-v11.json")
        try Data("keep".utf8).write(to: unrelated)

        let cleared = CostUsageCacheLocations.clearCLIProxyAPIArtifacts(
            in: [legacy, durable],
            stateRoot: root,
            fileManager: fileManager)

        #expect(cleared)
        for directory in [legacy, durable] {
            #expect(!fileManager.fileExists(atPath: directory.appendingPathComponent(
                CostUsageCacheLocations.cliProxyAPIUsageFileName).path))
            #expect(!fileManager.fileExists(atPath: directory.appendingPathComponent(
                CostUsageCacheLocations.cliProxyAPIPendingFileName).path))
            #expect(!fileManager.fileExists(atPath: CostUsageCacheIO.cacheFileURL(
                provider: .claude,
                cacheRoot: directory.deletingLastPathComponent()).path))
        }
        #expect(fileManager.fileExists(atPath: unrelated.path))
    }

    @Test
    func `integration cleanup waits for the collector interprocess lock`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-cleanup-lock-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: costUsage, withIntermediateDirectories: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let clearStarted = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)
        let collector = Task.detached {
            try await CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root) {
                lockAcquired.signal()
                _ = await Self.waitForSignal(releaseLock, timeout: .distantFuture)
            }
        }
        #expect(await Self.waitForSignal(lockAcquired, timeout: .now() + 1))

        let clear = Task.detached {
            clearStarted.signal()
            let result = CostUsageCacheLocations.clearCLIProxyAPIArtifacts(
                in: [costUsage],
                stateRoot: root,
                fileManager: .default)
            clearFinished.signal()
            return result
        }
        #expect(await Self.waitForSignal(clearStarted, timeout: .now() + 1))
        let finishedBeforeRelease = await Self.waitForSignal(
            clearFinished,
            timeout: .now() + .milliseconds(50))
        #expect(!finishedBeforeRelease)

        releaseLock.signal()
        try await collector.value
        #expect(await clear.value)
        #expect(!FileManager.default.fileExists(atPath: usageFile.path))
    }

    @Test
    func `explicit disconnect state survives artifact cleanup and can be cleared on reconnect`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-disconnect-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
            true,
            stateRoot: root,
            fileManager: fileManager))
        #expect(CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        #expect(CostUsageCacheLocations.clearCLIProxyAPIArtifacts(
            in: [costUsage],
            stateRoot: root,
            fileManager: fileManager))
        #expect(CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))

        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
            false,
            stateRoot: root,
            fileManager: fileManager))
        #expect(!CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
    }

    @Test
    func `explicit disconnect prevents saved connection settings from loading`() {
        var didReadStoredSettings = false
        let loaded = CLIProxyAPIConnectionSettingsStore.load(
            isDisconnected: { true },
            loadStored: {
                didReadStoredSettings = true
                return CLIProxyAPIConnectionSettings(managementKey: "test-management-key")
            })

        #expect(loaded == nil)
        #expect(!didReadStoredSettings)
    }

    @Test
    func `reconnect rolls back saved credentials when disconnect state cannot be cleared`() {
        let settings = CLIProxyAPIConnectionSettings(
            baseURL: "http://127.0.0.1:8317",
            managementKey: "test-management-key")
        var didStore = false
        var didRollback = false

        let saved = CLIProxyAPIConnectionSettingsStore.save(
            settings,
            store: { _ in
                didStore = true
                return true
            },
            clearDisconnectedState: { false },
            rollback: {
                didRollback = true
                return true
            })

        #expect(!saved)
        #expect(didStore)
        #expect(didRollback)
    }

    @Test
    func `explicit disconnect prevents collection with persisted settings`() async {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-disconnected-collection-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
            true,
            stateRoot: root,
            fileManager: fileManager))

        let result = await CLIProxyAPIUsageCollector.collect(
            cacheRoot: root,
            settings: CLIProxyAPIConnectionSettings(managementKey: "secret"))

        #expect(result == .notConfigured)
    }

    @Test
    func `cost cache locations include durable telemetry storage`() throws {
        let fileManager = FileManager.default
        let directories = CostUsageCacheLocations.directories(fileManager: fileManager)
        let cacheRoot = try #require(fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask).first)
        let applicationSupportRoot = try #require(fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first)

        #expect(directories == [cacheRoot, applicationSupportRoot].map { root in
            root
                .appendingPathComponent("CodexBar", isDirectory: true)
                .appendingPathComponent("cost-usage", isDirectory: true)
        })
        #expect(directories.contains(
            CLIProxyAPIUsageCacheIO.cacheFileURL().deletingLastPathComponent()))
        #expect(directories.contains(
            CLIProxyAPIUsagePendingIO.pendingFileURL().deletingLastPathComponent()))
    }

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
        #expect(await Self.waitForSignal(lockAcquired, timeout: .now() + 1))

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
        #expect(await Self.waitForSignal(loadStarted, timeout: .now() + 1))
        #expect(await Self.waitForSignal(mergeStarted, timeout: .now() + 1))
        let loadFinishedBeforeRelease = await Self.waitForSignal(
            loadFinished,
            timeout: .now() + .milliseconds(50))
        let mergeFinishedBeforeRelease = await Self.waitForSignal(
            mergeFinished,
            timeout: .now() + .milliseconds(50))
        #expect(!loadFinishedBeforeRelease)
        #expect(!mergeFinishedBeforeRelease)

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
            records,
            cacheRoot: root,
            now: second) == 0)

        let roundTripped = CLIProxyAPIUsageCacheIO.load(
            cacheRoot: root,
            now: second)
        #expect(roundTripped.count == 2)
        #expect(
            roundTripped.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) }
                == records.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) })
    }

    @Test
    func `corrupt durable cache is preserved instead of overwritten`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-corrupt-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let cacheURL = CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: root)
        try fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let corruptData = Data(#"{"version":2,"records":[]}"#.utf8)
        try corruptData.write(to: cacheURL)
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))

        let result = CLIProxyAPIUsageCacheIO.merge(
            [Self.record(id: "new", timestamp: timestamp)],
            cacheRoot: root,
            now: timestamp)

        #expect(result == nil)
        #expect(try Data(contentsOf: cacheURL) == corruptData)
    }

    @Test
    func `fallback record identity survives pending journal round trips within one second`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-pending-fractional-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let second = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let records = [
            Self.record(id: "", timestamp: second.addingTimeInterval(0.1)),
            Self.record(id: "", timestamp: second.addingTimeInterval(0.9)),
        ]

        #expect(CLIProxyAPIUsagePendingIO.save(records, pendingRoot: root))
        let roundTripped = try #require(CLIProxyAPIUsagePendingIO.load(pendingRoot: root))

        #expect(roundTripped.count == 2)
        #expect(
            roundTripped.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) }
                == records.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) })
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

    private static func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime) async -> Bool
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }
}
