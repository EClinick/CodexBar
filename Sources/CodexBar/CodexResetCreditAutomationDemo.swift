import CodexBarCore
import Foundation

enum CodexResetCreditAutomationDemoState: Equatable, Sendable {
    case idle
    case running(String)
    case succeeded(String)
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:
            [
                "Runs the real Codex fetch, scheduling, notification, and consume-RPC paths against an isolated",
                "fake Codex App Server. Live settings, accounts, usage, and the installed Codex CLI are untouched.",
            ].joined(separator: " ")
        case let .running(message):
            "Mock test running: \(message)"
        case let .succeeded(message):
            "Mock test passed: \(message)"
        case let .failed(message):
            "Mock test failed: \(message)"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum CodexResetCreditAutomationDemo {
    static let phaseDelay: TimeInterval = 2
    static let accountEmail = "codexbar-mock@example.invalid"
    static let expiryProviderCreditID = "codexbar-mock-expiry-alert"
    static let autoRedeemProviderCreditID = "codexbar-mock-auto-redeem"

    struct ConsumeRecord: Codable, Equatable, Sendable {
        let creditId: String
        let idempotencyKey: String
    }

    struct CompletionRecord: Equatable, Sendable {
        let creditID: String
        let outcome: CodexRateLimitResetCreditConsumeOutcome
    }

    actor CompletionRecorder {
        private var completion: CompletionRecord?

        func record(creditID: String, outcome: CodexRateLimitResetCreditConsumeOutcome) {
            self.completion = CompletionRecord(creditID: creditID, outcome: outcome)
        }

        func waitForCompletion(timeout: TimeInterval = 5) async throws -> CompletionRecord {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try Task.checkCancellation()
                if let completion = self.completion {
                    return completion
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw DemoError.completionNotRecorded
        }
    }

    @MainActor
    final class NotificationScheduleRecorder {
        private var result: ScheduledAppNotificationReplacementResult?

        func record(_ result: ScheduledAppNotificationReplacementResult) {
            self.result = result
        }

        func waitForResult(timeout: TimeInterval = 5) async throws -> ScheduledAppNotificationReplacementResult {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try Task.checkCancellation()
                if let result = self.result {
                    return result
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw DemoError.notificationScheduleNotConfirmed
        }
    }

    struct Fixture: Sendable {
        let providerCreditID: String
        let stableCreditID: String
        let accountEmail: String
        let rootURL: URL
        let consumeRecordURL: URL
        let fetcher: UsageFetcher

        func consumeRecord() throws -> ConsumeRecord {
            let data = try Data(contentsOf: self.consumeRecordURL)
            return try JSONDecoder().decode(ConsumeRecord.self, from: data)
        }

        func waitForConsumeRecord(timeout: TimeInterval = 5) async throws -> ConsumeRecord {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: self.consumeRecordURL.path) {
                    return try self.consumeRecord()
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw DemoError.consumeNotRecorded
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.rootURL)
        }
    }

    enum DemoError: LocalizedError {
        case missingUsage
        case missingResetCredit
        case unexpectedAccount(String?)
        case unexpectedCredit(String)
        case invalidIdempotencyKey(String)
        case consumeNotRecorded
        case completionNotRecorded
        case unexpectedCompletionCredit(String)
        case unexpectedOutcome(CodexRateLimitResetCreditConsumeOutcome)
        case notificationPermissionDenied
        case notificationScheduleNotConfirmed
        case notificationScheduleFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingUsage:
                "The fake Codex App Server did not return a usage snapshot."
            case .missingResetCredit:
                "The fake Codex App Server did not return its reset credit."
            case let .unexpectedAccount(email):
                "The mock account guard received \(email ?? "no email") instead of \(accountEmail)."
            case let .unexpectedCredit(creditID):
                "The fake Codex App Server received the wrong reset credit ID: \(creditID)."
            case let .invalidIdempotencyKey(value):
                "The fake Codex App Server received an invalid idempotency key: \(value)."
            case .consumeNotRecorded:
                "The fake Codex App Server did not receive the consume RPC before the timeout."
            case .completionNotRecorded:
                "The reset automation controller did not finish the fake consume RPC before the timeout."
            case let .unexpectedCompletionCredit(creditID):
                "The reset automation controller completed the wrong reset credit: \(creditID)."
            case let .unexpectedOutcome(outcome):
                "The fake Codex App Server returned an unexpected outcome: \(outcome.rawValue)."
            case .notificationPermissionDenied:
                "Enable CodexBar notifications in System Settings, then run the isolated test again."
            case .notificationScheduleNotConfirmed:
                "CodexBar did not receive confirmation that macOS scheduled the mock expiry alert."
            case let .notificationScheduleFailed(message):
                message
            }
        }
    }

    static func makeFixture(providerCreditID: String, expiresAt: Date) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-reset-automation-demo-\(UUID().uuidString)", isDirectory: true)
        let executableURL = rootURL.appendingPathComponent("codex-mock-app-server", isDirectory: false)
        let consumeRecordURL = rootURL.appendingPathComponent("consume.json", isDirectory: false)
        let codexHomeURL = rootURL.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)

        do {
            let script = try self.appServerScript(
                providerCreditID: providerCreditID,
                expiresAt: expiresAt,
                consumeRecordURL: consumeRecordURL)
            try Data(script.utf8).write(to: executableURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path)
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }

        let fetcher = try UsageFetcher(
            isolatedCodexExecutableURL: executableURL,
            environment: [
                "CODEX_HOME": codexHomeURL.path,
            ])
        let stableCreditID = CodexRateLimitResetCredit(
            id: providerCreditID,
            resetType: "codexRateLimits",
            status: .available,
            grantedAt: Date(),
            expiresAt: expiresAt,
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil).id
        return Fixture(
            providerCreditID: providerCreditID,
            stableCreditID: stableCreditID,
            accountEmail: self.accountEmail,
            rootURL: rootURL,
            consumeRecordURL: consumeRecordURL,
            fetcher: fetcher)
    }

    private static func appServerScript(
        providerCreditID: String,
        expiresAt: Date,
        consumeRecordURL: URL) throws -> String
    {
        let grantedAt = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970.rounded(.down))
        let expiry = Int64(expiresAt.timeIntervalSince1970.rounded(.up))
        let rateLimitsResult = try self.jsonLiteral([
            "rateLimits": [
                "primary": [
                    "usedPercent": 100,
                    "windowDurationMins": 300,
                    "resetsAt": expiry,
                ],
                "planType": "pro",
            ],
            "rateLimitResetCredits": [
                "availableCount": 1,
                "credits": [[
                    "id": providerCreditID,
                    "resetType": "codexRateLimits",
                    "status": "available",
                    "grantedAt": grantedAt,
                    "expiresAt": expiry,
                    "title": "Mock full reset",
                    "description": "Isolated CodexBar App Server fixture",
                ]],
            ],
        ])
        let accountResult = try self.jsonLiteral([
            "account": [
                "type": "chatgpt",
                "email": self.accountEmail,
                "planType": "pro",
            ],
            "requiresOpenaiAuth": false,
        ])
        return """
        #!/bin/sh
        set -eu

        provider_credit_id=\(self.shellStringLiteral(providerCreditID))
        consume_record_path=\(self.shellStringLiteral(consumeRecordURL.path))
        rate_limits_result=\(self.shellStringLiteral(rateLimitsResult))
        account_result=\(self.shellStringLiteral(accountResult))

        case " $* " in
          *" app-server "*) ;;
          *) printf '%s\\n' 'unexpected non app-server Codex invocation' >&2; exit 92 ;;
        esac

        while IFS= read -r line; do
          method=$(
            printf '%s\\n' "$line" |
              /usr/bin/sed -nE 's/.*"method"[[:space:]]*:[[:space:]]*"([^"]+)".*/\\1/p' |
              /usr/bin/sed 's#\\\\/#/#g'
          )
          [ "$method" = "initialized" ] && continue
          identifier=$(printf '%s\\n' "$line" | /usr/bin/sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\\1/p')
          [ -n "$identifier" ] || continue

          if [ "$method" = "initialize" ]; then
            printf '{"id":%s,"result":{}}\\n' "$identifier"
          elif [ "$method" = "account/rateLimits/read" ]; then
            printf '{"id":%s,"result":%s}\\n' "$identifier" "$rate_limits_result"
          elif [ "$method" = "account/read" ]; then
            printf '{"id":%s,"result":%s}\\n' "$identifier" "$account_result"
          elif [ "$method" = "account/rateLimitResetCredit/consume" ]; then
            credit_id=$(
              printf '%s\\n' "$line" |
                /usr/bin/sed -nE 's/.*"creditId"[[:space:]]*:[[:space:]]*"([^"]+)".*/\\1/p'
            )
            idempotency_key=$(
              printf '%s\\n' "$line" |
                /usr/bin/sed -nE 's/.*"idempotencyKey"[[:space:]]*:[[:space:]]*"([^"]+)".*/\\1/p'
            )
            if [ "$credit_id" != "$provider_credit_id" ] || [ -z "$idempotency_key" ]; then
              printf '{"id":%s,"error":{"message":"unexpected reset credit consume parameters"}}\\n' "$identifier"
            else
              consume_record_temp_path="${consume_record_path}.tmp.$$"
              printf '{"creditId":"%s","idempotencyKey":"%s"}' \
                "$credit_id" "$idempotency_key" > "$consume_record_temp_path"
              /bin/mv "$consume_record_temp_path" "$consume_record_path"
              printf '{"id":%s,"result":{"outcome":"reset"}}\\n' "$identifier"
            fi
          else
            printf '{"id":%s,"error":{"message":"unexpected method"}}\\n' "$identifier"
          fi
        done
        """
    }

    private static func jsonLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let literal = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return literal
    }

    private static func shellStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

@MainActor
final class CodexResetCreditDemoNotifier: CodexResetCreditNotificationScheduling {
    enum Kind {
        case expiryAlert
        case autoRedeem
    }

    private let kind: Kind
    private let notificationScheduleRecorder: CodexResetCreditAutomationDemo.NotificationScheduleRecorder?

    init(
        kind: Kind,
        notificationScheduleRecorder: CodexResetCreditAutomationDemo.NotificationScheduleRecorder? = nil)
    {
        self.kind = kind
        self.notificationScheduleRecorder = notificationScheduleRecorder
    }

    func replaceExpiryAlerts(_ alerts: [CodexResetCreditExpiryAlert]) {
        let notifications = alerts.map { alert in
            ScheduledAppNotification(
                id: alert.creditID,
                title: L("Test: Codex reset expires soon"),
                body: L("Mock App Server only — this exercises the real five-minute expiry scheduling path."),
                fireDate: alert.fireDate,
                soundEnabled: true)
        }
        AppNotifications.shared.replaceScheduled(
            idPrefix: self.notificationPrefix,
            notifications: notifications,
            completion: { [weak notificationScheduleRecorder = self.notificationScheduleRecorder] result in
                notificationScheduleRecorder?.record(result)
            })
    }

    func postAutoRedeemEvent(_ event: CodexResetCreditAutoRedeemEvent) {
        let copy: (title: String, body: String) = switch event {
        case .completed(.reset), .completed(.alreadyRedeemed):
            (
                L("Test: Mock Codex reset RPC completed"),
                L("The fake Codex App Server received the real consume RPC. No live reset was used."))
        case let .completed(outcome):
            (
                L("Test: Mock Codex reset RPC finished"),
                String(format: L("The fake App Server returned: %@."), outcome.rawValue))
        case let .failed(message):
            (
                L("Test: Mock Codex reset RPC failed"),
                String(format: L("The isolated App Server test failed: %@."), message))
        }

        AppNotifications.shared.post(
            idPrefix: self.notificationPrefix,
            title: copy.title,
            body: copy.body)
    }

    private var notificationPrefix: String {
        switch self.kind {
        case .expiryAlert:
            "codex-reset-demo-expiry"
        case .autoRedeem:
            "codex-reset-demo-auto-redeem"
        }
    }
}
