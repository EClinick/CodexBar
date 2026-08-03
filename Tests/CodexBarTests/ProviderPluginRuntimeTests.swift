#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginRuntimeTests {
    @Test
    func `context exposes no browser or timer globals`() throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin())

        #expect(try runtime.globalType(of: "fetch") == "undefined")
        #expect(try runtime.globalType(of: "XMLHttpRequest") == "undefined")
        #expect(try runtime.globalType(of: "setTimeout") == "undefined")
        #expect(try runtime.globalType(of: "setInterval") == "undefined")
        #expect(try runtime.globalType(of: "ctx") == "undefined")
    }

    @Test
    func `origin allowlist rejects before issuing request`() async throws {
        let requests = RequestRecorder()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            const response = await ctx.http.getJSON("https://other.example/usage");
            return { primary: { usedPercent: response.status } };
            """),
            transport: Self.transport(recorder: requests))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
        #expect(await requests.isEmpty)
    }

    @Test
    func `HTTP broker injects auth and returns JSON`() async throws {
        let requests = RequestRecorder()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            const response = await ctx.http.getJSON("https://api.example.test/usage", {
              headers: { "X-Client": "plugin-test" },
            });
            return { primary: { usedPercent: response.json.used } };
            """),
            transport: Self.transport(recorder: requests, body: #"{"used":42}"#))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret-value"])

        #expect(snapshot.primary?.usedPercent == 42)
        let request = try #require(await requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value")
        #expect(request.value(forHTTPHeaderField: "X-Client") == "plugin-test")
    }

    @Test
    func `undeclared secret access fails`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        ctx.secrets.get("OTHER_KEY");
        return { primary: { usedPercent: 1 } };
        """))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
    }

    @Test(arguments: [
        "defineProvider({",
        "defineProvider({ id: 'synthetic' });",
        """
        defineProvider({
          id: "not-a-provider",
          name: "Bad",
          endpoints: ["https://api.example.test"],
          auth: { type: "bearer", secret: "TEST_KEY" },
          settings: [{ key: "TEST_KEY", title: "Key" }],
          fetchUsage: async () => ({ primary: { usedPercent: 0 } }),
        });
        """,
    ])
    func `malformed plugins have descriptive load errors`(source: String) {
        #expect(throws: ProviderPluginError.self) {
            _ = try ProviderPluginRuntime(source: source)
        }
    }

    @Test
    func `wrong typed snapshot field fails`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        return { primary: { usedPercent: "42" } };
        """))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
    }

    @Test
    func `details map strictly and trim display strings`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        return {
          details: [{
            title: " Summary ",
            rows: [{ label: " Requests ", value: " 42 ", secondaryValue: " Today " }],
            chart: {
              kind: "line",
              title: " Daily ",
              unit: " tokens ",
              points: [{ label: " Mon ", value: 12.5 }],
            },
          }],
        };
        """))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])

        let section = try #require(snapshot.details.first)
        #expect(section.title == "Summary")
        #expect(try section.rows == [ProviderDetailSection.Row(
            label: "Requests",
            value: "42",
            secondaryValue: "Today")])
        let expectedChart = try ProviderDetailSection.Chart(
            kind: .line,
            title: "Daily",
            unit: "tokens",
            points: [ProviderDetailSection.Chart.Point(label: "Mon", value: 12.5)])
        #expect(section.chart == expectedChart)
    }

    @Test(arguments: [
        #"details: {}"#,
        #"details: [{ rows: [{ label: "ok", value: 1 }] }]"#,
        #"details: [{ rows: [], chart: { kind: "pie", points: [] } }]"#,
        #"details: [{ rows: [], chart: { kind: "bars", points: [{ label: "x", value: NaN }] } }]"#,
        #"""
        details: [{
          rows: [],
          chart: { kind: "bars", points: Array.from({length: 121}, (_, i) => ({label: String(i), value: i})) },
        }]
        """#,
    ])
    func `present invalid details fail the fetch`(body: String) async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: "return { \(body) };"))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
    }

    @Test
    func `promise rejection preserves message`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        throw new Error("fixture rejected");
        """))

        do {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
            Issue.record("Expected rejection")
        } catch {
            #expect(error.localizedDescription.contains("fixture rejected"))
        }
    }

    @Test
    func `script errors redact known secrets`() async throws {
        let secret = "super-secret-fixture-value"
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        throw new Error(`leaked: ${ctx.secrets.get("TEST_KEY")}`);
        """))

        do {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": secret])
            Issue.record("Expected rejection")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
            #expect(error.localizedDescription.contains("<redacted>"))
        }
    }

    @Test
    func `hung script times out and next fetch uses a fresh context`() async throws {
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            if (ctx.secrets.get("TEST_KEY") === "hang") while (true) {}
            return { primary: { usedPercent: 7 } };
            """),
            timeout: 0.15)
        let start = Date()

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "hang"])
        }
        #expect(Date().timeIntervalSince(start) < 1)

        let recovered = try await runtime.fetchUsage(secrets: ["TEST_KEY": "ok"])
        #expect(recovered.primary?.usedPercent == 7)
    }

    private static func plugin(fetchBody: String = "return { primary: { usedPercent: 1 } };") -> String {
        """
        defineProvider({
          id: "synthetic",
          name: "Fixture",
          endpoints: ["https://api.example.test"],
          auth: { type: "bearer", secret: "TEST_KEY" },
          settings: [{ key: "TEST_KEY", title: "API key", type: "secure" }],
          async fetchUsage(ctx) {
            \(fetchBody)
          },
        });
        """
    }

    private static func transport(
        recorder: RequestRecorder,
        body: String = #"{"ok":true}"#) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
    }
}

private actor RequestRecorder {
    private var requests: [URLRequest] = []

    var isEmpty: Bool {
        self.requests.isEmpty
    }

    var first: URLRequest? {
        self.requests.first
    }

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}
#endif
