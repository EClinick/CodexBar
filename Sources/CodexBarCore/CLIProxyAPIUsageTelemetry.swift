import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CLIProxyAPIUsageRecord: Codable, Equatable, Sendable {
    struct Tokens: Codable, Equatable, Sendable {
        let input: Int
        let output: Int
        let reasoning: Int
        let cached: Int
        let cacheRead: Int
        let cacheCreation: Int
        let total: Int

        private enum CodingKeys: String, CodingKey {
            case input = "input_tokens"
            case output = "output_tokens"
            case reasoning = "reasoning_tokens"
            case cached = "cached_tokens"
            case cacheRead = "cache_read_tokens"
            case cacheCreation = "cache_creation_tokens"
            case total = "total_tokens"
        }

        init(
            input: Int,
            output: Int,
            reasoning: Int = 0,
            cached: Int = 0,
            cacheRead: Int = 0,
            cacheCreation: Int = 0,
            total: Int)
        {
            self.input = input
            self.output = output
            self.reasoning = reasoning
            self.cached = cached
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
            self.total = total
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
            self.output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
            self.reasoning = try container.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0
            self.cached = try container.decodeIfPresent(Int.self, forKey: .cached) ?? 0
            self.cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
            self.cacheCreation = try container.decodeIfPresent(Int.self, forKey: .cacheCreation) ?? 0
            self.total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        }
    }

    let timestamp: Date
    let provider: String
    let executorType: String?
    let model: String
    let alias: String
    let endpoint: String
    let authType: String
    let requestID: String
    let failed: Bool
    let generate: Bool
    let tokens: Tokens

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case provider
        case executorType = "executor_type"
        case model
        case alias
        case endpoint
        case authType = "auth_type"
        case requestID = "request_id"
        case failed
        case generate
        case tokens
    }

    init(
        timestamp: Date,
        provider: String,
        executorType: String? = nil,
        model: String,
        alias: String,
        endpoint: String,
        authType: String,
        requestID: String,
        failed: Bool = false,
        generate: Bool = true,
        tokens: Tokens)
    {
        self.timestamp = timestamp
        self.provider = provider
        self.executorType = executorType
        self.model = model
        self.alias = alias
        self.endpoint = endpoint
        self.authType = authType
        self.requestID = requestID
        self.failed = failed
        self.generate = generate
        self.tokens = tokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.executorType = try container.decodeIfPresent(String.self, forKey: .executorType)
        self.model = try container.decode(String.self, forKey: .model)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? self.model
        self.endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        self.authType = try container.decodeIfPresent(String.self, forKey: .authType) ?? ""
        self.requestID = try container.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        self.failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        self.generate = try container.decodeIfPresent(Bool.self, forKey: .generate) ?? true
        self.tokens = try container.decodeIfPresent(Tokens.self, forKey: .tokens)
            ?? Tokens(input: 0, output: 0, total: 0)
    }
}

enum CLIProxyAPIUsageCacheIO {
    private struct Cache: Codable, Equatable {
        var version: Int = 1
        var records: [CLIProxyAPIUsageRecord] = []
    }

    private static let maximumRecordAge: TimeInterval = 366 * 24 * 60 * 60

    static func load(
        cacheRoot: URL? = nil,
        now: Date = Date()) -> [CLIProxyAPIUsageRecord]
    {
        let cutoff = now.addingTimeInterval(-self.maximumRecordAge)
        return self.loadCache(cacheRoot: cacheRoot).records.filter { $0.timestamp >= cutoff }
    }

    @discardableResult
    static func merge(
        _ records: [CLIProxyAPIUsageRecord],
        cacheRoot: URL? = nil,
        now: Date = Date()) -> Int?
    {
        let cutoff = now.addingTimeInterval(-self.maximumRecordAge)
        let existingCache = self.loadCache(cacheRoot: cacheRoot)
        var byKey: [String: CLIProxyAPIUsageRecord] = [:]
        for record in existingCache.records where record.timestamp >= cutoff {
            byKey[self.recordKey(record)] = record
        }
        let priorCount = byKey.count
        for record in records where record.timestamp >= cutoff {
            byKey[self.recordKey(record)] = record
        }
        let cache = Cache(records: byKey.values.sorted { $0.timestamp < $1.timestamp })
        if cache == existingCache {
            return 0
        }
        guard self.save(cache, cacheRoot: cacheRoot) else { return nil }
        return max(0, byKey.count - priorCount)
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("cliproxyapi-usage-v1.json", isDirectory: false)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = CostUsageDateParser.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid CLIProxyAPI usage timestamp.")
            }
            return date
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func recordKey(_ record: CLIProxyAPIUsageRecord) -> String {
        let requestID = record.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestID.isEmpty {
            return "request:\(requestID)"
        }
        let timestamp = Int64(record.timestamp.timeIntervalSince1970 * 1000)
        return [
            "fallback",
            String(timestamp),
            record.provider,
            record.model,
            record.alias,
            record.endpoint,
            record.authType,
            String(record.tokens.input),
            String(record.tokens.cacheRead),
            String(record.tokens.cacheCreation),
            String(record.tokens.output),
        ].joined(separator: ":")
    }

    private static func loadCache(cacheRoot: URL?) -> Cache {
        guard let data = try? Data(contentsOf: self.cacheFileURL(cacheRoot: cacheRoot)),
              let cache = try? self.decoder.decode(Cache.self, from: data),
              cache.version == 1
        else { return Cache() }
        return cache
    }

    private static func save(_ cache: Cache, cacheRoot: URL?) -> Bool {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try self.encoder.encode(cache)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}

enum CLIProxyAPIUsagePendingIO {
    private struct PendingBatch: Codable {
        var version: Int = 1
        var records: [CLIProxyAPIUsageRecord] = []
    }

    static func load(pendingRoot: URL? = nil) -> [CLIProxyAPIUsageRecord]? {
        let url = self.pendingFileURL(pendingRoot: pendingRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let pendingBatch = try? self.decoder.decode(PendingBatch.self, from: data),
              pendingBatch.version == 1
        else { return nil }
        return pendingBatch.records
    }

    static func save(_ records: [CLIProxyAPIUsageRecord], pendingRoot: URL? = nil) -> Bool {
        let url = self.pendingFileURL(pendingRoot: pendingRoot)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try self.encoder.encode(PendingBatch(records: records))
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func clear(pendingRoot: URL? = nil) -> Bool {
        let url = self.pendingFileURL(pendingRoot: pendingRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    static func pendingFileURL(pendingRoot: URL? = nil) -> URL {
        let root = pendingRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("cliproxyapi-pending-v1.json", isDirectory: false)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = CostUsageDateParser.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid pending CLIProxyAPI usage timestamp.")
            }
            return date
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

public struct CLIProxyAPIConnectionSettings: Codable, Equatable, Sendable {
    public static let defaultBaseURL = "http://127.0.0.1:8317"

    public let baseURL: String
    public let managementKey: String

    public init(baseURL: String = Self.defaultBaseURL, managementKey: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.managementKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        !self.managementKey.isEmpty && self.resolvedBaseURL != nil
    }

    var resolvedBaseURL: URL? {
        let value = self.baseURL.isEmpty ? Self.defaultBaseURL : self.baseURL
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              ["127.0.0.1", "::1", "localhost"].contains(host)
        else { return nil }
        return url
    }
}

public enum CLIProxyAPIConnectionSettingsStore {
    private static let key = KeychainCacheStore.Key(
        category: "integration",
        identifier: "cliproxyapi-management")

    public static func load() -> CLIProxyAPIConnectionSettings? {
        switch KeychainCacheStore.load(key: self.key, as: CLIProxyAPIConnectionSettings.self) {
        case let .found(settings): settings
        case .missing, .temporarilyUnavailable, .invalid: nil
        }
    }

    @discardableResult
    public static func save(_ settings: CLIProxyAPIConnectionSettings) -> Bool {
        guard settings.isConfigured else { return false }
        return KeychainCacheStore.storeResult(key: self.key, entry: settings)
    }

    @discardableResult
    public static func clear() -> Bool {
        KeychainCacheStore.clear(key: self.key)
    }
}

public enum CLIProxyAPIUsageCollectionResult: Equatable, Sendable {
    case notConfigured
    case collected(Int)
    case failed(String)
}

private actor CLIProxyAPIUsageCollectionGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        await self.acquire()
        let result = await operation()
        self.release()
        return result
    }

    private func acquire() async {
        if !self.isLocked {
            self.isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    private func release() {
        guard !self.waiters.isEmpty else {
            self.isLocked = false
            return
        }
        self.waiters.removeFirst().resume()
    }
}

public enum CLIProxyAPIUsageCollector {
    private static let maximumBatches = 10
    private static let batchSize = 100
    private static let collectionGate = CLIProxyAPIUsageCollectionGate()

    public static func collect(
        cacheRoot: URL? = nil,
        settings: CLIProxyAPIConnectionSettings? = CLIProxyAPIConnectionSettingsStore.load()) async
        -> CLIProxyAPIUsageCollectionResult
    {
        guard let settings, settings.isConfigured else { return .notConfigured }
        return await self.collect(
            cacheRoot: cacheRoot,
            client: CLIProxyAPIUsageQueueClient(settings: settings))
    }

    static func collect(
        cacheRoot: URL? = nil,
        pendingRoot: URL? = nil,
        client: CLIProxyAPIUsageQueueClient) async -> CLIProxyAPIUsageCollectionResult
    {
        await self.collectionGate.perform {
            await self.collectUnserialized(
                cacheRoot: cacheRoot,
                pendingRoot: pendingRoot,
                client: client)
        }
    }

    private static func collectUnserialized(
        cacheRoot: URL?,
        pendingRoot: URL?,
        client: CLIProxyAPIUsageQueueClient) async -> CLIProxyAPIUsageCollectionResult
    {
        do {
            var added = 0
            guard let pendingRecords = CLIProxyAPIUsagePendingIO.load(pendingRoot: pendingRoot) else {
                return .failed("Could not load pending CLIProxyAPI usage telemetry.")
            }
            if !pendingRecords.isEmpty {
                guard let pendingAdded = CLIProxyAPIUsageCacheIO.merge(
                    pendingRecords,
                    cacheRoot: cacheRoot)
                else {
                    return .failed("Could not save CLIProxyAPI usage telemetry.")
                }
                added += pendingAdded
                guard CLIProxyAPIUsagePendingIO.clear(pendingRoot: pendingRoot) else {
                    return .failed("Could not clear pending CLIProxyAPI usage telemetry.")
                }
            }

            for _ in 0..<self.maximumBatches {
                let batch = try await client.pop(count: self.batchSize)
                let staged = batch.isEmpty || CLIProxyAPIUsagePendingIO.save(
                    batch,
                    pendingRoot: pendingRoot)
                guard let batchAdded = CLIProxyAPIUsageCacheIO.merge(batch, cacheRoot: cacheRoot) else {
                    return .failed("Could not save CLIProxyAPI usage telemetry.")
                }
                added += batchAdded
                if staged, !batch.isEmpty,
                   !CLIProxyAPIUsagePendingIO.clear(pendingRoot: pendingRoot)
                {
                    return .failed("Could not clear pending CLIProxyAPI usage telemetry.")
                }
                if batch.count < self.batchSize {
                    break
                }
            }
            return .collected(added)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct CLIProxyAPIUsageQueueClient: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum ClientError: LocalizedError {
        case invalidBaseURL
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL: "Invalid CLIProxyAPI URL."
            case .invalidResponse: "CLIProxyAPI returned an invalid response."
            case let .httpError(status): "CLIProxyAPI returned HTTP \(status)."
            }
        }
    }

    let settings: CLIProxyAPIConnectionSettings
    let dataLoader: DataLoader

    init(
        settings: CLIProxyAPIConnectionSettings,
        dataLoader: @escaping DataLoader = Self.liveDataLoader)
    {
        self.settings = settings
        self.dataLoader = dataLoader
    }

    func pop(count: Int) async throws -> [CLIProxyAPIUsageRecord] {
        guard let baseURL = self.settings.resolvedBaseURL,
              var components = URLComponents(
                  url: baseURL.appendingPathComponent("v0/management/usage-queue"),
                  resolvingAgainstBaseURL: false)
        else { throw ClientError.invalidBaseURL }
        components.queryItems = [URLQueryItem(name: "count", value: String(max(1, count)))]
        guard let url = components.url else { throw ClientError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(self.settings.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.httpError(httpResponse.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = CostUsageDateParser.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid CLIProxyAPI usage timestamp.")
            }
            return date
        }
        return try decoder.decode([CLIProxyAPIUsageRecord].self, from: data)
    }

    private static func liveDataLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return try await URLSession(configuration: configuration).data(for: request)
    }
}
