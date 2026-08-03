import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct CostUsageCacheClearResult: Equatable, Sendable {
    public let cleared: Int
    public let errorDescription: String?
}

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

    public static func clearAllCostUsageCaches(
        fileManager: FileManager = .default) -> CostUsageCacheClearResult
    {
        self.clearAllCostUsageCaches(
            in: self.directories(fileManager: fileManager),
            stateRoot: nil,
            fileManager: fileManager)
    }

    public static func clearAllCostUsageCaches(
        in directories: [URL],
        stateRoot: URL?,
        fileManager: FileManager = .default) -> CostUsageCacheClearResult
    {
        do {
            return try self.withCLIProxyAPIInterprocessLock(
                stateRoot: stateRoot,
                fileManager: fileManager)
            {
                var cleared = 0
                for directory in directories where fileManager.fileExists(atPath: directory.path) {
                    do {
                        try fileManager.removeItem(at: directory)
                        cleared += 1
                    } catch {
                        return CostUsageCacheClearResult(
                            cleared: cleared,
                            errorDescription: error.localizedDescription)
                    }
                }
                return CostUsageCacheClearResult(cleared: cleared, errorDescription: nil)
            }
        } catch {
            return CostUsageCacheClearResult(cleared: 0, errorDescription: error.localizedDescription)
        }
    }

    static func withCLIProxyAPIInterprocessLock<T>(
        stateRoot: URL?,
        fileManager: FileManager = .default,
        operation: () throws -> T) throws -> T
    {
        let descriptor = try self.acquireCLIProxyAPILock(stateRoot: stateRoot, fileManager: fileManager)
        defer { self.releaseCLIProxyAPILock(descriptor) }
        return try operation()
    }

    static func withCLIProxyAPIInterprocessLock<T>(
        stateRoot: URL?,
        fileManager: FileManager = .default,
        operation: () async throws -> T) async throws -> T
    {
        let descriptor = try self.acquireCLIProxyAPILock(stateRoot: stateRoot, fileManager: fileManager)
        defer { self.releaseCLIProxyAPILock(descriptor) }
        return try await operation()
    }

    @discardableResult
    public static func clearCLIProxyAPIArtifacts(fileManager: FileManager = .default) -> Bool {
        let directories = self.directories(fileManager: fileManager)
        return self.clearCLIProxyAPIArtifacts(
            in: directories,
            stateRoot: directories[1].deletingLastPathComponent(),
            fileManager: fileManager)
    }

    @discardableResult
    static func clearCLIProxyAPIArtifacts(
        in directories: [URL],
        stateRoot: URL?,
        fileManager: FileManager = .default) -> Bool
    {
        do {
            return try self.withCLIProxyAPIInterprocessLock(
                stateRoot: stateRoot,
                fileManager: fileManager)
            {
                self.clearCLIProxyAPIArtifactsUnserialized(
                    in: directories,
                    fileManager: fileManager)
            }
        } catch {
            return false
        }
    }

    static func clearCLIProxyAPIArtifactsUnserialized(
        in directories: [URL],
        fileManager: FileManager) -> Bool
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

    public static func isCLIProxyAPIExplicitlyDisconnected(
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

    private static func acquireCLIProxyAPILock(
        stateRoot: URL?,
        fileManager: FileManager) throws -> Int32
    {
        let root = stateRoot ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let lockURL = root.appendingPathComponent("cliproxyapi-collection.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return descriptor
    }

    private static func releaseCLIProxyAPILock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
