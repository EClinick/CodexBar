import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CLIProxyAPIPublicationGuardTests {
    @Test
    func `live refresh guard rejects cross process proxy state changes`() throws {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIPublicationGuardTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-live-publication-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(cacheRoot: root),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let historyDays = settings.costUsageHistoryDays
        let scopeSignature = store.tokenSnapshotScopeSignature(for: .codex)

        let generationGuard = store.tokenRefreshPublicationGuard(for: .codex)
        let artifactDirectory = root.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: artifactDirectory.appendingPathComponent("codex-v11.json"))
        let clearResult = CostUsageCacheLocations.clearAllCostUsageCaches(
            in: [artifactDirectory],
            stateRoot: root)
        #expect(clearResult.errorDescription == nil)
        #expect(!store.tokenRefreshPublicationIsCurrent(
            provider: .codex,
            publicationGuard: generationGuard,
            historyDays: historyDays,
            costScopeSignature: scopeSignature))

        let telemetryGuard = store.tokenRefreshPublicationGuard(for: .codex)
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [
                CLIProxyAPIUsageRecord(
                    timestamp: now,
                    provider: "codex",
                    model: "gpt-5.4",
                    alias: "gpt-5.4",
                    endpoint: "POST /v1/messages",
                    authType: "oauth",
                    requestID: "live-publication-race",
                    tokens: .init(input: 10, output: 20, total: 30)),
            ],
            cacheRoot: root,
            now: now) == 1)
        #expect(!store.tokenRefreshPublicationIsCurrent(
            provider: .codex,
            publicationGuard: telemetryGuard,
            historyDays: historyDays,
            costScopeSignature: scopeSignature))

        let isolationGuard = store.tokenRefreshPublicationGuard(for: .codex)
        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(true, stateRoot: root))
        #expect(!store.tokenRefreshPublicationIsCurrent(
            provider: .codex,
            publicationGuard: isolationGuard,
            historyDays: historyDays,
            costScopeSignature: scopeSignature))
    }
}
