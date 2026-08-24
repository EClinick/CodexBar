import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIPreCredentialRollbackTests {
    @Test
    func `pre credential rollback restores staged artifacts without isolating the prior configuration`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-pre-credential-rollback-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }

        let generationUpdate = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(stateRoot: root, fileManager: fileManager))
        let artifactsUpdate = try #require(CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: [costUsage],
            stateRoot: root,
            expectedGeneration: generationUpdate.generation,
            fileManager: fileManager,
            disconnectedStateAfterRollback: false,
            prepareState: {
                CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
                    true,
                    stateRoot: root,
                    fileManager: fileManager)
            }))
        #expect(CostUsageCacheLocations.markCLIProxyAPIArtifactsUpdateForRollback(
            artifactsUpdate,
            rollbackCredentialsRestored: true,
            fileManager: fileManager))

        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root, fileManager: fileManager) {}

        #expect(fileManager.fileExists(atPath: usageFile.path))
        #expect(!CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
        CostUsageCacheLocations.discardCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager)
    }
}
