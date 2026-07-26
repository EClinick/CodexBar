import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIAttributionResolverTests {
    @Test
    func `request log confirms route without guessing upstream`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.6-sol", timestamp: timestamp),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.cliProxyRequestLog, .modelProvider])
    }

    @Test
    func `request log confirms the entire claude code session route`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.6-sol", timestamp: timestamp),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.addingTimeInterval(3 * 60 * 60).timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.cliProxyRequestLog, .modelProvider])
    }

    @Test
    func `codex auth inventory identifies upstream after this session route is proven`() {
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "logged-session", model: "gpt-5.6-sol", timestamp: nil),
            ],
            authProviders: [
                .init(provider: "codex", authType: .oauth),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "logged-session",
            timestampUnixMs: nil,
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == .init(
            provider: "codex",
            authType: .oauth,
            model: "gpt-5.6-sol"))
        #expect(attribution.evidence == [
            .cliProxyAuthInventory,
            .cliProxyRequestLog,
            .modelProvider,
        ])
    }

    @Test
    func `codex auth inventory does not transfer route proof between sessions`() {
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "logged-session", model: "gpt-5.6-sol", timestamp: nil),
            ],
            authProviders: [
                .init(provider: "codex", authType: .oauth),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "unrelated-session",
            timestampUnixMs: nil,
            tokens: Self.tokens)

        #expect(attribution.route == .unknown)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.modelProvider])
    }

    @Test
    func `request telemetry identifies exact codex oauth upstream`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.6-sol", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(
                    timestamp: timestamp.addingTimeInterval(1),
                    provider: "codex",
                    authType: "oauth"),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream?.provider == "codex")
        #expect(attribution.upstream?.authType == .oauth)
        #expect(attribution.upstream?.model == "gpt-5.6-sol")
        #expect(attribution.evidence == [
            .cliProxyRequestLog,
            .cliProxyUsageTelemetry,
            .modelProvider,
        ])
    }

    @Test
    func `request telemetry preserves api key authentication type`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.6-sol", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(timestamp: timestamp, provider: "openrouter", authType: "apikey"),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.upstream?.provider == "openrouter")
        #expect(attribution.upstream?.authType == .apiKey)
        #expect(attribution.upstream?.displayName == "OpenRouter API key")
    }

    @Test
    func `ambiguous telemetry does not claim an upstream`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.6-sol", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(timestamp: timestamp, provider: "codex", authType: "oauth"),
                Self.record(timestamp: timestamp, provider: "openrouter", authType: "api_key"),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == nil)
        #expect(!attribution.evidence.contains(.cliProxyUsageTelemetry))
    }

    @Test
    func `failed and token mismatched telemetry are ignored`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.6-sol", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(
                    timestamp: timestamp,
                    provider: "codex",
                    authType: "oauth",
                    failed: true),
                CLIProxyAPIUsageRecord(
                    timestamp: timestamp.addingTimeInterval(1),
                    provider: "codex",
                    model: "gpt-5.6-sol",
                    alias: "gpt-5.6-sol",
                    endpoint: "POST /v1/messages",
                    authType: "oauth",
                    requestID: "request-mismatch",
                    tokens: .init(input: 999, output: 999, total: 1998)),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == nil)
    }

    @Test
    func `model without correlated request does not claim cliproxyapi`() {
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "other-session", model: "gpt-5.6-sol", timestamp: nil),
            ],
            usageRecords: [
                Self.record(timestamp: Date(), provider: "codex", authType: "oauth"),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: nil,
            tokens: Self.tokens)

        #expect(attribution.route == .unknown)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.modelProvider])
    }

    @Test
    func `filesystem loader correlates sanitized cached telemetry`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-attribution-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let requestLog = """
        === REQUEST INFO ===
        URL: /v1/messages
        Method: POST
        Timestamp: 2026-07-16T12:00:00Z
        === HEADERS ===
        X-Claude-Code-Session-Id: session-1
        === REQUEST BODY ===
        {"model":"gpt-5.6-sol"}
        === RESPONSE ===
        Status: 200
        """
        try Data(requestLog.utf8).write(to: logs.appendingPathComponent("v1-messages.log"))
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:01Z"))
        CLIProxyAPIUsageCacheIO.merge(
            [Self.record(timestamp: timestamp, provider: "codex", authType: "oauth")],
            cacheRoot: cacheRoot,
            now: timestamp)

        let resolver = CLIProxyAPIAttributionResolver.load(
            home: home,
            cacheRoot: cacheRoot,
            fileManager: fileManager)
        let attribution = resolver.attribution(
            model: "gpt-5.6-sol",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream?.isCodex == true)
        #expect(attribution.evidence.contains(.cliProxyUsageTelemetry))
    }

    @Test
    func `usage cache never persists source or api key fields`() throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let payload = """
        [{
          "timestamp":"2026-07-16T12:00:00Z",
          "source":"private@example.com",
          "api_key":"secret-client-key",
          "provider":"codex",
          "executor_type":"CodexExecutor",
          "model":"gpt-5.6-sol",
          "alias":"gpt-5.6-sol",
          "endpoint":"POST /v1/messages",
          "auth_type":"oauth",
          "request_id":"request-1",
          "failed":false,
          "generate":true,
          "tokens":{
            "input_tokens":10,
            "output_tokens":20,
            "cache_read_tokens":30,
            "cache_creation_tokens":40,
            "total_tokens":100
          }
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([CLIProxyAPIUsageRecord].self, from: Data(payload.utf8))
        let now = try #require(CostUsageDateParser.parse("2026-07-16T12:00:01Z"))

        #expect(CLIProxyAPIUsageCacheIO.merge(records, cacheRoot: cacheRoot, now: now) == 1)
        let persisted = try String(
            contentsOf: CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: cacheRoot),
            encoding: .utf8)
        #expect(!persisted.contains("private@example.com"))
        #expect(!persisted.contains("secret-client-key"))
        #expect(persisted.contains("\"provider\":\"codex\""))
    }

    @Test
    func `usage queue client authenticates and decodes sanitized records`() async throws {
        let responseBody = """
        [{
          "timestamp":"2026-07-16T12:00:00.123456789Z",
          "source":"private@example.com",
          "api_key":"secret-client-key",
          "provider":"codex",
          "executor_type":"CodexExecutor",
          "model":"gpt-5.6-sol",
          "alias":"gpt-5.6-sol",
          "endpoint":"POST /v1/messages",
          "auth_type":"oauth",
          "request_id":"request-1",
          "failed":false,
          "generate":true,
          "tokens":{"input_tokens":10,"output_tokens":20,"total_tokens":30}
        }]
        """
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                #expect(request.url?.absoluteString ==
                    "http://127.0.0.1:8317/v0/management/usage-queue?count=100")
                #expect(request.value(forHTTPHeaderField: "Authorization") ==
                    "Bearer management-secret")
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data(responseBody.utf8), response)
            })

        let records = try await client.pop(count: 100)

        #expect(records.count == 1)
        #expect(records[0].provider == "codex")
        #expect(records[0].authType == "oauth")
        #expect(records[0].tokens.total == 30)
    }

    @Test
    func `plain http management url is limited to loopback`() {
        #expect(CLIProxyAPIConnectionSettings(
            baseURL: "http://127.0.0.1:8317",
            managementKey: "secret").isConfigured)
        #expect(CLIProxyAPIConnectionSettings(
            baseURL: "http://localhost:8317",
            managementKey: "secret").isConfigured)
        #expect(!CLIProxyAPIConnectionSettings(
            baseURL: "http://192.168.1.10:8317",
            managementKey: "secret").isConfigured)
        #expect(CLIProxyAPIConnectionSettings(
            baseURL: "https://proxy.example.com",
            managementKey: "secret").isConfigured)
    }

    private static let tokens = CLIProxyAPIAttributionResolver.TokenSignature(
        input: 10,
        cacheRead: 30,
        cacheCreate: 40,
        output: 20)

    private static func record(
        timestamp: Date,
        provider: String,
        authType: String,
        failed: Bool = false) -> CLIProxyAPIUsageRecord
    {
        CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: provider,
            executorType: provider == "codex" ? "CodexExecutor" : "OpenAICompatExecutor",
            model: "gpt-5.6-sol",
            alias: "gpt-5.6-sol",
            endpoint: "POST /v1/messages",
            authType: authType,
            requestID: "request-\(provider)-\(authType)-\(timestamp.timeIntervalSince1970)",
            failed: failed,
            tokens: .init(
                input: 10,
                output: 20,
                cacheRead: 30,
                cacheCreation: 40,
                total: 100))
    }
}
