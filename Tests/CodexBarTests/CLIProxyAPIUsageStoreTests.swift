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
        var didClearConfiguration = false
        var collectorFinishedBeforePurge = false

        let removed = await store.removeCLIProxyAPIConfiguration(
            purgeTelemetry: {
                collectorFinishedBeforePurge = collectorFinished.value
                return true
            },
            clear: {
                didClearConfiguration = true
                return true
            })
        await task.value

        #expect(removed == .removed)
        #expect(didClearConfiguration)
        #expect(collectorFinishedBeforePurge)
        #expect(store.cliProxyAPIUsageCollectorTask == nil)
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
        var didPurgeTelemetry = false

        let removed = await store.removeCLIProxyAPIConfiguration(
            purgeTelemetry: {
                didPurgeTelemetry = true
                return true
            },
            clear: { false })

        #expect(removed == .configurationRemovalFailed)
        #expect(!didPurgeTelemetry)
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

        let removed = await store.removeCLIProxyAPIConfiguration(
            purgeTelemetry: { false },
            clear: { true })

        #expect(removed == .telemetryCleanupFailed)
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
}
