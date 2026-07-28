import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIUsageCollectorTests {
    @Test
    func `retries a popped batch after cache write failure`() async throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-blocked-\(UUID().uuidString)", isDirectory: false)
        try Data("not-a-directory".utf8).write(to: cacheRoot)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let record = CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: "codex",
            model: "gpt-5.6-sol",
            alias: "gpt-5.6-sol",
            endpoint: "POST /v1/messages",
            authType: "oauth",
            requestID: "request-1",
            tokens: .init(input: 10, output: 20, total: 30))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([record])
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (data, response)
            })

        let result = await CLIProxyAPIUsageCollector.collect(cacheRoot: cacheRoot, client: client)

        #expect(result == .failed("Could not save CLIProxyAPI usage telemetry."))
        try fileManager.removeItem(at: cacheRoot)
        let retryClient = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).map(\.requestID) == ["request-1"])
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data("[]".utf8), response)
            })

        let retryResult = await CLIProxyAPIUsageCollector.collect(cacheRoot: cacheRoot, client: retryClient)

        #expect(retryResult == .collected(1))
        #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).map(\.requestID) == ["request-1"])
    }
}
