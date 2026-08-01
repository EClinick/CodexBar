import CodexBarCore
import Foundation

enum CodexResetCreditAutomationDemo {
    static let visualDelay: TimeInterval = 2

    static func expiryAlertSnapshot(now: Date) -> CodexRateLimitResetCreditsSnapshot {
        self.snapshot(
            providerID: "codexbar-mock-expiry-alert",
            expiresAt: now.addingTimeInterval(
                CodexResetCreditAutomationPlan.expiryAlertLeadTime + self.visualDelay),
            now: now)
    }

    static func autoRedeemSnapshot(now: Date) -> CodexRateLimitResetCreditsSnapshot {
        self.snapshot(
            providerID: "codexbar-mock-auto-redeem",
            expiresAt: now.addingTimeInterval(
                CodexResetCreditAutomationPlan.autoRedeemLeadTime + self.visualDelay),
            now: now)
    }

    static func redeem(
        creditID _: String,
        idempotencyKey _: UUID) async throws -> CodexRateLimitResetCreditConsumeOutcome
    {
        try Task.checkCancellation()
        return .reset
    }

    private static func snapshot(
        providerID: String,
        expiresAt: Date,
        now: Date) -> CodexRateLimitResetCreditsSnapshot
    {
        CodexRateLimitResetCreditsSnapshot(
            credits: [
                CodexRateLimitResetCredit(
                    id: providerID,
                    resetType: "codexRateLimits",
                    status: .available,
                    grantedAt: now,
                    expiresAt: expiresAt,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: "Mock reset",
                    description: "Synthetic CodexBar reset automation demo"),
            ],
            availableCount: 1,
            updatedAt: now)
    }
}

@MainActor
final class CodexResetCreditDemoNotifier: CodexResetCreditNotificationScheduling {
    enum Kind {
        case expiryAlert
        case autoRedeem
    }

    private let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    func replaceExpiryAlerts(_ alerts: [CodexResetCreditExpiryAlert]) {
        let notifications = alerts.map { alert in
            ScheduledAppNotification(
                id: alert.creditID,
                title: L("Test: Codex reset expires soon"),
                body: L("Mock only — no real Codex reset was used. This is the five-minute expiry alert."),
                fireDate: alert.fireDate,
                soundEnabled: true)
        }
        AppNotifications.shared.replaceScheduled(
            idPrefix: self.notificationPrefix,
            notifications: notifications)
    }

    func postAutoRedeemEvent(_ event: CodexResetCreditAutoRedeemEvent) {
        let copy: (title: String, body: String) = switch event {
        case .completed(.reset), .completed(.alreadyRedeemed):
            (
                L("Test: Codex reset used automatically"),
                L("Mock only — the Codex CLI was not contacted and no real reset was used."))
        case let .completed(outcome):
            (
                L("Test: Mock auto-use finished"),
                String(format: L("Mock only — simulated result: %@."), outcome.rawValue))
        case let .failed(message):
            (
                L("Test: Mock auto-use failed"),
                String(format: L("Mock only — simulated failure: %@."), message))
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
