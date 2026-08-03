import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    private static let cliProxyAPIUsageCollectionInterval: Duration = .seconds(30)
    private static let cliProxyAPIPendingPruneInterval: Duration = .seconds(24 * 60 * 60)

    func startCLIProxyAPIUsageCollector() {
        self.stopCLIProxyAPIUsageCollector()
        let pendingPruneInterval = Self.cliProxyAPIPendingPruneInterval
        self.cliProxyAPIUsageCollectorTask = Task.detached(priority: .utility) { [weak self] in
            var nextPendingPruneAt: ContinuousClock.Instant?
            while !Task.isCancelled {
                let now = ContinuousClock.now
                if nextPendingPruneAt.map({ now >= $0 }) ?? true {
                    _ = CLIProxyAPIUsageCollector.prunePendingUsage()
                    nextPendingPruneAt = now.advanced(by: pendingPruneInterval)
                }
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
        remove: (() async -> CLIProxyAPIConfigurationRemovalResult)? = nil) async
        -> CLIProxyAPIConfigurationRemovalResult
    {
        let collectorTask = self.stopCLIProxyAPIUsageCollector()
        await collectorTask?.value
        let result = if let remove {
            await remove()
        } else {
            await Task.detached(priority: .utility) {
                CLIProxyAPIConnectionSettingsStore.removeAndPurgeTelemetry()
            }.value
        }
        if result != .configurationRemovalFailed {
            self.invalidateCLIProxyAPICostAttribution()
        }
        return result
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

    func refreshCLIProxyAPICostAttribution(
        refresh: ((UsageProvider, Bool) async -> Void)? = nil) async
    {
        self.invalidateCLIProxyAPICostAttribution(widgetReason: "cliproxyapi-reconnected")
        for provider in [UsageProvider.claude, .codex] {
            if let refresh {
                await refresh(provider, true)
            } else {
                await self.refreshTokenUsageNow(for: provider, force: true)
            }
        }
    }
}
