import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private actor CLIProxyAPIUsageCollectionRecorder {
    private(set) var callCount = 0

    func collect() -> CLIProxyAPIUsageCollectionResult {
        self.callCount += 1
        return .collected(1)
    }
}

private actor CLIProxyAPIUsageCollectorCancellationRecorder {
    private(set) var wasCancelled = false

    func recordCancellation() {
        self.wasCancelled = true
    }
}

@MainActor
struct CLIProxyAPIUsageStoreTests {
    @Test
    func `cost tracking opt out prevents telemetry collection`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = false
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let recorder = CLIProxyAPIUsageCollectionRecorder()

        let disabledResult = await store.collectCLIProxyAPIUsageNow {
            await recorder.collect()
        }

        #expect(disabledResult == .disabled)
        #expect(await recorder.callCount == 0)

        settings.costUsageEnabled = true
        let enabledResult = await store.collectCLIProxyAPIUsageNow {
            await recorder.collect()
        }

        #expect(enabledResult == .collected(1))
        #expect(await recorder.callCount == 1)
    }

    @Test
    func `removing the integration cancels and clears the active telemetry task`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let recorder = CLIProxyAPIUsageCollectorCancellationRecorder()
        let collectorFinished = LockIsolated(false)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            await recorder.recordCancellation()
            let drainDelay = Task.detached {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await drainDelay.value
            collectorFinished.setValue(true)
        }
        store.cliProxyAPIUsageCollectorTask = task
        var collectorFinishedBeforePurge = false
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .claude)
        let codexPublicationRevision = store.tokenSnapshotPublicationRevision(for: .codex)
        let claudePublicationRevision = store.tokenSnapshotPublicationRevision(for: .claude)
        let claudePublicationGuard = store.tokenRefreshPublicationGuard(for: .claude)
        let claudeScopeSignature = store.tokenSnapshotScopeSignature(for: .claude)

        let removed = await store.removeCLIProxyAPIConfiguration {
            collectorFinishedBeforePurge = collectorFinished.value
            return .removed
        }
        await task.value

        #expect(removed == .removed)
        #expect(collectorFinishedBeforePurge)
        #expect(store.cliProxyAPIUsageCollectorTask == nil)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == codexPublicationRevision + 1)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .claude) == claudePublicationRevision + 1)
        #expect(!store.tokenRefreshPublicationIsCurrent(
            provider: .claude,
            publicationGuard: claudePublicationGuard,
            historyDays: settings.costUsageHistoryDays,
            costScopeSignature: claudeScopeSignature))
        #expect(await recorder.wasCancelled)
    }

    @Test
    func `removing the integration preserves telemetry when configuration removal fails`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        let removed = await store.removeCLIProxyAPIConfiguration {
            .configurationRemovalFailed
        }

        #expect(removed == .configurationRemovalFailed)
        #expect(store.tokenSnapshot(for: .codex) != nil)
    }

    @Test
    func `removing the integration reports telemetry cleanup failure after configuration removal`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)

        let removed = await store.removeCLIProxyAPIConfiguration {
            .telemetryCleanupFailed
        }

        #expect(removed == .telemetryCleanupFailed)
        #expect(store.tokenSnapshot(for: .codex) == nil)
    }

    @Test
    func `reconnecting invalidates and force refreshes both proxy affected token snapshots`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .claude)
        let codexPublicationRevision = store.tokenSnapshotPublicationRevision(for: .codex)
        let claudePublicationRevision = store.tokenSnapshotPublicationRevision(for: .claude)
        var refreshes: [(UsageProvider, Bool)] = []

        await store.refreshCLIProxyAPICostAttribution { provider, force in
            refreshes.append((provider, force))
        }

        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == codexPublicationRevision + 1)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .claude) == claudePublicationRevision + 1)
        #expect(refreshes.map(\.0) == [.claude, .codex])
        #expect(refreshes.map(\.1) == [true, true])
    }

    @Test
    func `clearing cost cache drains the active proxy collector before deletion`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let collectorFinished = LockIsolated(false)
        let deletionStartedAfterDrain = LockIsolated(false)
        store.cliProxyAPIUsageCollectorTask = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            let drainDelay = Task.detached {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await drainDelay.value
            collectorFinished.setValue(true)
        }

        let error = await store.clearCostUsageCache(clearDirectories: {
            deletionStartedAfterDrain.setValue(collectorFinished.value)
            return nil
        })
        store.stopCLIProxyAPIUsageCollector()

        #expect(error == nil)
        #expect(deletionStartedAfterDrain.value)
    }

    @Test
    func `clearing cost cache uses the shared locked deletion path`() async throws {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        let fileManager = CLIProxyAPITestFileManager(root: root)
        let cacheDirectory = CostUsageCacheLocations.directories(fileManager: fileManager)[0]
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let usageFile = cacheDirectory.appendingPathComponent("usage.json")
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let error = await store.clearCostUsageCache(fileManager: fileManager)

        #expect(error == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
    }

    private static func tokenSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.01,
            last30DaysTokens: 10,
            last30DaysCostUSD: 0.01,
            currencyCode: "USD",
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_784_203_200))
    }
}

private final class CLIProxyAPITestFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in _: FileManager.SearchPathDomainMask) -> [URL]
    {
        switch directory {
        case .cachesDirectory:
            [self.root.appendingPathComponent("Caches", isDirectory: true)]
        case .applicationSupportDirectory:
            [self.root.appendingPathComponent("Application Support", isDirectory: true)]
        default:
            super.urls(for: directory, in: .userDomainMask)
        }
    }
}
