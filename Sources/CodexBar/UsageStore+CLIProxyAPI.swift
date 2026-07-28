import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    private static let cliProxyAPIUsageCollectionInterval: Duration = .seconds(30)

    func startCLIProxyAPIUsageCollector() {
        self.cliProxyAPIUsageCollectorTask?.cancel()
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

    func collectCLIProxyAPIUsageNow(
        collector: @escaping @Sendable () async -> CLIProxyAPIUsageCollectionResult = {
            await CLIProxyAPIUsageCollector.collect()
        }) async -> CLIProxyAPIUsageCollectionResult
    {
        guard self.settings.costUsageEnabled else { return .disabled }
        return await collector()
    }
}
