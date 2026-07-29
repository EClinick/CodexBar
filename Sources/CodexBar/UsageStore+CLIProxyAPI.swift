import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    private static let cliProxyAPIUsageCollectionInterval: Duration = .seconds(30)

    func startCLIProxyAPIUsageCollector() {
        self.stopCLIProxyAPIUsageCollector()
        self.cliProxyAPIUsageCollectorTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard await self?.collectCLIProxyAPIUsageNow() != nil else { return }
                do {
                    try await Task.sleep(for: Self.cliProxyAPIUsageCollectionInterval)
                } catch {
                    return
                }
            }
        }
    }

    @discardableResult
    func stopCLIProxyAPIUsageCollector() -> Task<Void, Never>? {
        let task = self.cliProxyAPIUsageCollectorTask
        task?.cancel()
        self.cliProxyAPIUsageCollectorTask = nil
        return task
    }

    @discardableResult
    func removeCLIProxyAPIConfiguration(
        purgeTelemetry: () -> Bool = { CostUsageCacheLocations.clearCLIProxyAPIArtifacts() },
        clear: () -> Bool = { CLIProxyAPIConnectionSettingsStore.clear() }) async -> Bool
    {
        let collectorTask = self.stopCLIProxyAPIUsageCollector()
        await collectorTask?.value
        guard purgeTelemetry() else { return false }
        return clear()
    }

    func collectCLIProxyAPIUsageNow(
        collector: (@Sendable () async -> CLIProxyAPIUsageCollectionResult)? = nil) async
        -> CLIProxyAPIUsageCollectionResult
    {
        guard self.settings.costUsageEnabled else { return .disabled }
        if let collector {
            return await collector()
        }
        return await CLIProxyAPIUsageCollector.collect(shouldContinue: { [weak self] in
            await self?.settings.costUsageEnabled == true
        })
    }
}
