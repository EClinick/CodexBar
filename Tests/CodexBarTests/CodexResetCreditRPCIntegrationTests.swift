import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexResetCreditRPCIntegrationTests {
    @Test
    func `mock app server maps reset credits and consumes the requested credit`() async throws {
        let creditID = "reset-credit-test"
        let idempotencyKey = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let stubPath = try Self.makeStubCodexCLI(
            expectedCreditID: creditID,
            expectedIdempotencyKey: idempotencyKey)
        defer { try? FileManager.default.removeItem(atPath: stubPath) }

        let fetcher = UsageFetcher(
            environment: [:],
            initializeTimeoutSeconds: 1,
            requestTimeoutSeconds: 1,
            codexArguments: ["app-server"],
            codexExecutableResolver: { _, _ in stubPath })

        let accountSnapshot = try await fetcher.loadLatestCLIAccountSnapshot()
        let usage = try #require(accountSnapshot.usage)
        let resetCredits = try #require(usage.codexResetCredits)
        let resetCredit = try #require(resetCredits.credits.first)

        #expect(usage.accountEmail(for: .codex) == "stub@example.com")
        #expect(resetCredits.availableCount == 1)
        #expect(resetCredit.id == creditID)
        #expect(resetCredit.resetType == "full")
        #expect(resetCredit.status == .available)
        #expect(resetCredit.grantedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(resetCredit.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))

        let outcome = try await fetcher.consumeRateLimitResetCredit(
            creditID: creditID,
            idempotencyKey: idempotencyKey,
            expectedAccountEmail: "STUB@example.com")

        #expect(outcome == .reset)
    }

    @Test
    func `mock app server refuses to consume after the selected account changes`() async throws {
        let creditID = "reset-credit-test"
        let idempotencyKey = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let consumeMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-reset-credit-consume-\(UUID().uuidString)", isDirectory: false)
        let stubPath = try Self.makeStubCodexCLI(
            expectedCreditID: creditID,
            expectedIdempotencyKey: idempotencyKey,
            accountEmail: "other@example.com",
            consumeMarkerPath: consumeMarker.path)
        defer {
            try? FileManager.default.removeItem(atPath: stubPath)
            try? FileManager.default.removeItem(at: consumeMarker)
        }

        let fetcher = UsageFetcher(
            environment: [:],
            initializeTimeoutSeconds: 1,
            requestTimeoutSeconds: 1,
            codexArguments: ["app-server"],
            codexExecutableResolver: { _, _ in stubPath })

        do {
            _ = try await fetcher.consumeRateLimitResetCredit(
                creditID: creditID,
                idempotencyKey: idempotencyKey,
                expectedAccountEmail: "selected@example.com")
            Issue.record("Expected the mocked account mismatch to block consumption")
        } catch RPCWireError.accountMismatch {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: consumeMarker.path))
    }

    @Test
    func `malformed optional reset credits do not hide mocked core rate limits`() async throws {
        let idempotencyKey = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let stubPath = try Self.makeStubCodexCLI(
            expectedCreditID: "unused",
            expectedIdempotencyKey: idempotencyKey,
            malformedResetCredits: true)
        defer { try? FileManager.default.removeItem(atPath: stubPath) }

        let fetcher = UsageFetcher(
            environment: [:],
            initializeTimeoutSeconds: 1,
            requestTimeoutSeconds: 1,
            codexArguments: ["app-server"],
            codexExecutableResolver: { _, _ in stubPath })

        let usage = try #require(try await fetcher.loadLatestCLIAccountSnapshot().usage)
        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.codexResetCredits == nil)
    }

    private static func makeStubCodexCLI(
        expectedCreditID: String,
        expectedIdempotencyKey: UUID,
        accountEmail: String = "stub@example.com",
        consumeMarkerPath: String? = nil,
        malformedResetCredits: Bool = false) throws -> String
    {
        let consumeMarkerStatement = consumeMarkerPath.map {
            "open(\"\($0)\", \"w\", encoding=\"utf-8\").write(\"consume called\")"
        } ?? "pass"
        let resetCreditsPayload = malformedResetCredits
            ? "{\"availableCount\": 1, \"credits\": [{\"id\": 17}]}"
            : """
            {
                "availableCount": 1,
                "credits": [{
                    "id": "\(expectedCreditID)",
                    "resetType": "full",
                    "status": "available",
                    "grantedAt": 1800000000,
                    "expiresAt": 1900000000,
                    "title": "Full reset",
                    "description": "Mocked credit"
                }]
            }
            """
        let script = """
        #!/usr/bin/python3 -S
        import json
        import sys

        if "app-server" not in sys.argv[1:]:
            sys.stderr.write("unexpected non app-server Codex invocation\\n")
            sys.exit(92)

        for line in sys.stdin:
            if not line.strip():
                continue
            message = json.loads(line)
            method = message.get("method")
            if method == "initialized":
                continue

            identifier = message.get("id")
            if method == "initialize":
                payload = {"id": identifier, "result": {}}
            elif method == "account/rateLimits/read":
                payload = {
                    "id": identifier,
                    "result": {
                        "rateLimits": {
                            "primary": {
                                "usedPercent": 12.5,
                                "windowDurationMins": 300,
                                "resetsAt": 1900000000
                            },
                            "planType": "pro"
                        },
                        "rateLimitResetCredits": \(resetCreditsPayload)
                    }
                }
            elif method == "account/read":
                payload = {
                    "id": identifier,
                    "result": {
                        "account": {
                            "type": "chatgpt",
                            "email": "\(accountEmail)",
                            "planType": "pro"
                        },
                        "requiresOpenaiAuth": False
                    }
                }
            elif method == "account/rateLimitResetCredit/consume":
                \(consumeMarkerStatement)
                params = message.get("params", {})
                if (params.get("creditId") != "\(expectedCreditID)" or
                        params.get("idempotencyKey") != "\(expectedIdempotencyKey.uuidString)"):
                    payload = {
                        "id": identifier,
                        "error": {"message": "unexpected reset credit consume parameters"}
                    }
                else:
                    payload = {"id": identifier, "result": {"outcome": "reset"}}
            else:
                payload = {"id": identifier, "error": {"message": "unexpected method " + str(method)}}

            print(json.dumps(payload), flush=True)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-reset-credit-stub-\(UUID().uuidString)", isDirectory: false)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
