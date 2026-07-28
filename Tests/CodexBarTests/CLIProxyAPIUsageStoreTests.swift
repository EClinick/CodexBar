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
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            await recorder.recordCancellation()
        }
        store.cliProxyAPIUsageCollectorTask = task
        var didClearConfiguration = false

        let removed = store.removeCLIProxyAPIConfiguration {
            didClearConfiguration = true
            return true
        }
        await task.value

        #expect(removed)
        #expect(didClearConfiguration)
        #expect(store.cliProxyAPIUsageCollectorTask == nil)
        #expect(await recorder.wasCancelled)
    }
}
