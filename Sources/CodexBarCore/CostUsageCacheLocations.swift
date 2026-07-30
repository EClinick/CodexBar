import Foundation

public enum CostUsageCacheLocations {
    static let cliProxyAPIUsageFileName = "cliproxyapi-usage-v1.json"
    static let cliProxyAPIPendingFileName = "cliproxyapi-pending-v1.json"
    private static let cliProxyAPIDisconnectedFileName = "cliproxyapi-disconnected-v1"

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
            let urls = [
                directory.appendingPathComponent(self.cliProxyAPIUsageFileName, isDirectory: false),
                directory.appendingPathComponent(self.cliProxyAPIPendingFileName, isDirectory: false),
                CostUsageCacheIO.cacheFileURL(
                    provider: .claude,
                    cacheRoot: directory.deletingLastPathComponent()),
            ]
            for url in urls {
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

    static func isCLIProxyAPIExplicitlyDisconnected(
        stateRoot: URL? = nil,
        fileManager: FileManager = .default) -> Bool
    {
        fileManager.fileExists(atPath: self.cliProxyAPIDisconnectedURL(
            stateRoot: stateRoot,
            fileManager: fileManager).path)
    }

    @discardableResult
    static func setCLIProxyAPIExplicitlyDisconnected(
        _ disconnected: Bool,
        stateRoot: URL? = nil,
        fileManager: FileManager = .default) -> Bool
    {
        let url = self.cliProxyAPIDisconnectedURL(
            stateRoot: stateRoot,
            fileManager: fileManager)
        if disconnected {
            guard !fileManager.fileExists(atPath: url.path) else { return true }
            do {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Data().write(to: url, options: [.atomic])
                return true
            } catch {
                return false
            }
        }

        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func cliProxyAPIDisconnectedURL(
        stateRoot: URL?,
        fileManager: FileManager) -> URL
    {
        let root = stateRoot ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root.appendingPathComponent(self.cliProxyAPIDisconnectedFileName, isDirectory: false)
    }
}
