import CodexBarCore
import Foundation

struct CLIProxyAPIUsageCollectorState: Equatable {
    enum ConfigurationAvailability: Equatable {
        case unknown
        case available
        case unavailable
    }

    var configurationAvailability: ConfigurationAvailability = .unknown
}

@MainActor
extension UsageStore {
    private static let cliProxyAPIUsageCollectionInterval: Duration = .seconds(30)
    private static let cliProxyAPIPendingPruneInterval: Duration = .seconds(24 * 60 * 60)

    func startCLIProxyAPIUsageCollector() {
        self.stopCLIProxyAPIUsageCollector()
        let pendingPruneInterval = Self.cliProxyAPIPendingPruneInterval
        self.cliProxyAPIUsageCollectorTask = Task.detached(priority: .utility) { [weak self] in
            var nextPendingPruneAt: ContinuousClock.Instant?
            var collectorState = CLIProxyAPIUsageCollectorState()
            while !Task.isCancelled {
                let now = ContinuousClock.now
                if nextPendingPruneAt.map({ now >= $0 }) ?? true {
                    _ = CLIProxyAPIUsageCollector.pruneExpiredUsage()
                    nextPendingPruneAt = now.advanced(by: pendingPruneInterval)
                }
                guard let result = await self?.collectCLIProxyAPIUsageNow() else { return }
                collectorState = await self?.handleCLIProxyAPIUsageCollectionResult(
                    result,
                    collectorState: collectorState) ?? collectorState
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

    func handleCLIProxyAPIUsageCollectionResult(
        _ result: CLIProxyAPIUsageCollectionResult,
        collectorState: CLIProxyAPIUsageCollectorState,
        isExplicitlyDisconnected: () -> Bool = {
            CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected()
        },
        refresh: ((UsageProvider, Bool) async -> Void)? = nil) async -> CLIProxyAPIUsageCollectorState
    {
        var collectorState = collectorState
        switch result {
        case .notConfigured:
            if collectorState.configurationAvailability == .available ||
                (collectorState.configurationAvailability == .unknown && isExplicitlyDisconnected())
            {
                self.invalidateCLIProxyAPICostAttribution(widgetReason: "cliproxyapi-disconnected")
            }
            collectorState.configurationAvailability = .unavailable
        case .collected:
            if collectorState.configurationAvailability == .unavailable {
                await self.refreshCLIProxyAPICostAttribution(refresh: refresh)
            }
            collectorState.configurationAvailability = .available
        case .failed, .disabled:
            break
        }
        return collectorState
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
