import Foundation

struct CLIProxyAPIAttributionResolver: Sendable {
    struct Observation: Sendable, Equatable {
        let sessionID: String
        let model: String
        let timestamp: Date?
    }

    struct AuthProvider: Sendable, Equatable, Hashable {
        let provider: String
        let authType: CostUsageAttribution.Upstream.AuthType
    }

    struct TokenSignature: Sendable, Equatable {
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let output: Int
    }

    private static let requestBodyMarker = "=== REQUEST BODY ==="
    private static let responseMarkers = ["=== API RESPONSE ===", "=== RESPONSE ==="]
    private static let maxLogPrefixBytes = 2 * 1024 * 1024
    private static let maximumRouteMatchDistance: TimeInterval = 60 * 60
    private static let maximumTelemetryMatchDistance: TimeInterval = 5

    private let observationsBySessionID: [String: [Observation]]
    private let usageRecordsByCanonicalModel: [String: [CLIProxyAPIUsageRecord]]
    private let authProviders: [AuthProvider]
    private let hasConfiguredOpenAIAPIUpstream: Bool

    init(
        observations: [Observation],
        usageRecords: [CLIProxyAPIUsageRecord] = [],
        authProviders: [AuthProvider] = [],
        hasConfiguredOpenAIAPIUpstream: Bool = false)
    {
        self.observationsBySessionID = Dictionary(grouping: observations, by: \.sessionID)
        self.usageRecordsByCanonicalModel = Self.indexUsageRecords(usageRecords)
        self.authProviders = authProviders
        self.hasConfiguredOpenAIAPIUpstream = hasConfiguredOpenAIAPIUpstream
    }

    static func load(
        home: URL,
        cacheRoot: URL? = nil,
        fileManager: FileManager = .default,
        checkCancellation: (() throws -> Void)? = nil) throws -> Self
    {
        let observations = try self.loadObservations(
            logDirectory: home.appendingPathComponent("logs", isDirectory: true),
            fileManager: fileManager,
            checkCancellation: checkCancellation)
        return Self(
            observations: observations,
            usageRecords: CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot),
            authProviders: self.loadAuthProviders(home: home, fileManager: fileManager),
            hasConfiguredOpenAIAPIUpstream: self.hasConfiguredOpenAIAPIUpstream(
                home: home,
                fileManager: fileManager))
    }

    func attribution(
        model: String,
        modelProvider: CostUsageAttribution.ModelProvider,
        sessionID: String?,
        timestampUnixMs: Int64?,
        tokens: TokenSignature?) -> CostUsageAttribution
    {
        let routeObservation = self.sessionObservation(sessionID: sessionID)
        let telemetryObservation = self.matchingObservation(
            model: model,
            sessionID: sessionID,
            timestampUnixMs: timestampUnixMs)
        let usageRecord = telemetryObservation.flatMap {
            self.matchingUsageRecord(
                observation: $0,
                model: model,
                tokens: tokens)
        }
        let inventoryUpstream = routeObservation != nil && usageRecord == nil
            ? self.authInventoryUpstream(model: model, modelProvider: modelProvider)
            : nil
        let routeConfirmed = routeObservation != nil || inventoryUpstream != nil
        var evidence: Set<CostUsageAttribution.Evidence> = [.modelProvider]
        if routeObservation != nil || inventoryUpstream != nil {
            evidence.insert(.cliProxyRequestLog)
        }
        if usageRecord != nil {
            evidence.insert(.cliProxyUsageTelemetry)
        }
        if inventoryUpstream != nil {
            evidence.insert(.cliProxyAuthInventory)
        }

        return CostUsageAttribution(
            client: .claudeCode,
            route: routeConfirmed ? .cliProxyAPI : .unknown,
            modelProvider: modelProvider,
            upstream: usageRecord.map(Self.upstream) ?? inventoryUpstream,
            evidence: evidence.sorted { $0.rawValue < $1.rawValue })
    }

    private func sessionObservation(sessionID: String?) -> Observation? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else { return nil }
        return self.observationsBySessionID[sessionID]?.first
    }

    private func matchingObservation(
        model: String,
        sessionID: String?,
        timestampUnixMs: Int64?) -> Observation?
    {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              let observations = self.observationsBySessionID[sessionID]
        else { return nil }

        let canonicalModel = Self.canonicalModel(model)
        let matchingModels = observations.filter { Self.canonicalModel($0.model) == canonicalModel }
        guard !matchingModels.isEmpty else { return nil }
        guard let timestampUnixMs else {
            return matchingModels.count == 1 ? matchingModels[0] : nil
        }
        let timestamp = Date(timeIntervalSince1970: Double(timestampUnixMs) / 1000)
        let candidates = matchingModels.filter { observation in
            guard let observationTimestamp = observation.timestamp else { return true }
            return abs(observationTimestamp.timeIntervalSince(timestamp)) <= Self.maximumRouteMatchDistance
        }
        return Self.uniqueClosest(
            candidates,
            target: timestamp,
            timestamp: \.timestamp)
    }

    private func matchingUsageRecord(
        observation: Observation,
        model: String,
        tokens: TokenSignature?) -> CLIProxyAPIUsageRecord?
    {
        guard let observationTimestamp = observation.timestamp else { return nil }
        let canonicalModel = Self.canonicalModel(model)
        guard let records = self.usageRecordsByCanonicalModel[canonicalModel] else { return nil }
        let earliest = observationTimestamp.addingTimeInterval(-Self.maximumTelemetryMatchDistance)
        let latest = observationTimestamp.addingTimeInterval(Self.maximumTelemetryMatchDistance)
        let startIndex = Self.firstRecordIndex(atOrAfter: earliest, in: records)
        var candidates: [CLIProxyAPIUsageRecord] = []
        for record in records[startIndex...] {
            guard record.timestamp <= latest else { break }
            if tokens.map({ Self.tokensMatch($0, record.tokens) }) ?? true {
                candidates.append(record)
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func indexUsageRecords(
        _ records: [CLIProxyAPIUsageRecord]) -> [String: [CLIProxyAPIUsageRecord]]
    {
        var recordsByModel: [String: [CLIProxyAPIUsageRecord]] = [:]
        for record in records where !record.failed
            && record.generate
            && record.endpoint.lowercased().contains("/v1/messages")
        {
            let models = Set([self.canonicalModel(record.alias), self.canonicalModel(record.model)])
            for model in models where !model.isEmpty {
                recordsByModel[model, default: []].append(record)
            }
        }
        return recordsByModel.mapValues { records in
            records.sorted { $0.timestamp < $1.timestamp }
        }
    }

    private static func firstRecordIndex(
        atOrAfter timestamp: Date,
        in records: [CLIProxyAPIUsageRecord]) -> Int
    {
        var lowerBound = 0
        var upperBound = records.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if records[midpoint].timestamp < timestamp {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private func authInventoryUpstream(
        model: String,
        modelProvider: CostUsageAttribution.ModelProvider) -> CostUsageAttribution.Upstream?
    {
        guard modelProvider == .openAI,
              !self.observationsBySessionID.isEmpty,
              !self.hasConfiguredOpenAIAPIUpstream
        else { return nil }
        let providers = Array(Set(self.authProviders.filter {
            $0.provider.caseInsensitiveCompare("codex") == .orderedSame
        }))
        guard providers.count == 1, let provider = providers.first else { return nil }
        return CostUsageAttribution.Upstream(
            provider: provider.provider,
            authType: provider.authType,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func tokensMatch(
        _ tokens: TokenSignature,
        _ telemetry: CLIProxyAPIUsageRecord.Tokens) -> Bool
    {
        guard telemetry.output == tokens.output else { return false }
        if telemetry.cacheRead != 0 || telemetry.cacheCreation != 0 {
            return telemetry.input == tokens.input
                && telemetry.cacheRead == tokens.cacheRead
                && telemetry.cacheCreation == tokens.cacheCreate
        }
        let claudeInputTotal = tokens.input + tokens.cacheRead + tokens.cacheCreate
        return telemetry.input == tokens.input
            || telemetry.input == claudeInputTotal
            || telemetry.input + telemetry.cached == claudeInputTotal
    }

    private static func uniqueClosest<T>(
        _ candidates: [T],
        target: Date,
        timestamp: (T) -> Date?) -> T?
    {
        let ranked = candidates.compactMap { candidate -> (candidate: T, distance: TimeInterval)? in
            guard let date = timestamp(candidate) else { return (candidate, 0) }
            return (candidate, abs(date.timeIntervalSince(target)))
        }
        .sorted { $0.distance < $1.distance }
        guard let first = ranked.first else { return nil }
        guard ranked.count == 1 || ranked[1].distance > first.distance else { return nil }
        return first.candidate
    }

    private static func upstream(
        _ record: CLIProxyAPIUsageRecord) -> CostUsageAttribution.Upstream
    {
        let authType: CostUsageAttribution.Upstream.AuthType = switch record.authType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "oauth": .oauth
        case "api_key", "api-key", "apikey": .apiKey
        default: .unknown
        }
        return CostUsageAttribution.Upstream(
            provider: record.provider.trimmingCharacters(in: .whitespacesAndNewlines),
            authType: authType,
            model: record.model.trimmingCharacters(in: .whitespacesAndNewlines),
            executorType: record.executorType?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct AuthFile: Decodable {
        let type: String?
        let disabled: Bool?
    }

    private static func loadAuthProviders(
        home: URL,
        fileManager: FileManager) -> [AuthProvider]
    {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let decoder = JSONDecoder()
        let providers = urls.compactMap { url -> AuthProvider? in
            guard url.pathExtension.lowercased() == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let auth = try? decoder.decode(AuthFile.self, from: data),
                  auth.disabled != true,
                  let rawType = auth.type?.trimmingCharacters(in: .whitespacesAndNewlines),
                  rawType.caseInsensitiveCompare("codex") == .orderedSame
            else { return nil }
            return AuthProvider(provider: "codex", authType: .oauth)
        }
        return Array(Set(providers))
    }

    private static func hasConfiguredOpenAIAPIUpstream(
        home: URL,
        fileManager: FileManager) -> Bool
    {
        let url = home.appendingPathComponent("config.yaml", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return false }
        let conflictingKeys = ["codex-api-key", "openai-compatibility"]
        return text.split(whereSeparator: \.isNewline).contains { line in
            guard line.first?.isWhitespace != true else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("#") else { return false }
            return conflictingKeys.contains { trimmed.hasPrefix("\($0):") }
        }
    }

    private static func loadObservations(
        logDirectory: URL,
        fileManager: FileManager,
        checkCancellation: (() throws -> Void)?) throws -> [Observation]
    {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var observations: [Observation] = []
        for url in urls where url.pathExtension.lowercased() == "log" {
            try checkCancellation?()
            if let observation = self.parseObservation(url: url) {
                observations.append(observation)
            }
        }
        return observations
    }

    private static func parseObservation(url: URL) -> Observation? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: self.maxLogPrefixBytes),
              let text = String(data: data, encoding: .utf8),
              let bodyMarkerRange = text.range(of: self.requestBodyMarker)
        else { return nil }

        let info = String(text[..<bodyMarkerRange.lowerBound])
        guard let requestURL = self.field("URL", in: info),
              requestURL.contains("/v1/messages"),
              let sessionID = self.field("X-Claude-Code-Session-Id", in: info)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionID.isEmpty
        else { return nil }

        let bodyStart = bodyMarkerRange.upperBound
        let bodyEnd = self.responseMarkers.compactMap {
            text.range(of: $0, range: bodyStart..<text.endIndex)?.lowerBound
        }.min() ?? text.endIndex
        let requestBody = String(text[bodyStart..<bodyEnd])
        guard let model = self.topLevelJSONStringValue(forKey: "model", in: requestBody) else { return nil }
        let timestamp = self.field("Timestamp", in: info).flatMap(CostUsageDateParser.parse)
        return Observation(sessionID: sessionID, model: model, timestamp: timestamp)
    }

    private static func field(_ name: String, in text: String) -> String? {
        let prefix = "\(name):"
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(prefix) else { continue }
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func topLevelJSONStringValue(forKey key: String, in text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String
        else {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            guard let regex = try? NSRegularExpression(
                pattern: "\"\(escapedKey)\"\\s*:\\s*\"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\""),
                let match = regex.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)),
                let valueRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[valueRange])
        }
        return value
    }

    private static func canonicalModel(_ raw: String) -> String {
        let codexNormalized = CostUsagePricing.normalizeCodexModel(raw)
        return CostUsagePricing.normalizeClaudeModel(codexNormalized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
