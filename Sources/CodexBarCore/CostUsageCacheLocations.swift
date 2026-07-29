import Foundation

public enum CostUsageCacheLocations {
    static let cliProxyAPIUsageFileName = "cliproxyapi-usage-v1.json"
    static let cliProxyAPIPendingFileName = "cliproxyapi-pending-v1.json"

    public static func directories(fileManager: FileManager = .default) -> [URL] {
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let applicationSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
        return [cacheRoot, applicationSupportRoot].map { root in
            root
                .appendingPathComponent("CodexBar", isDirectory: true)
                .appendingPathComponent("cost-usage", isDirectory: true)
        }
    }

    @discardableResult
    public static func clearCLIProxyAPIArtifacts(fileManager: FileManager = .default) -> Bool {
        self.clearCLIProxyAPIArtifacts(
            in: self.directories(fileManager: fileManager),
            fileManager: fileManager)
    }

    @discardableResult
    static func clearCLIProxyAPIArtifacts(
        in directories: [URL],
        fileManager: FileManager = .default) -> Bool
    {
        var succeeded = true
        for directory in directories {
            for name in [self.cliProxyAPIUsageFileName, self.cliProxyAPIPendingFileName] {
                let url = directory.appendingPathComponent(name, isDirectory: false)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    succeeded = false
                }
            }
        }
        return succeeded
    }
}
