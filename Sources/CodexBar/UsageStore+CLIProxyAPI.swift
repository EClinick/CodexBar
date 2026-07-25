import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    private static let cliProxyAPIUsageCollectionInterval: Duration = .seconds(30)

    func startCLIProxyAPIUsageCollector() {
        self.cliProxyAPIUsageCollectorTask?.cancel()
        self.cliProxyAPIUsageCollectorTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                _ = await CLIProxyAPIUsageCollector.collect()
                do {
                    try await Task.sleep(for: Self.cliProxyAPIUsageCollectionInterval)
                } catch {
                    return
                }
            }
        }
    }

    func collectCLIProxyAPIUsageNow() async -> CLIProxyAPIUsageCollectionResult {
        await CLIProxyAPIUsageCollector.collect()
    }
}
