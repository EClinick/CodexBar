import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func runCodexResetExpiryAlertDemo(now: Date = Date()) {
        guard !self.settings.codexResetCreditAutomationEnabled else { return }
        self.codexResetCreditAutomationController.stop()
        let controller = CodexResetCreditAutomationController(
            notifier: CodexResetCreditDemoNotifier(kind: .expiryAlert),
            now: { now })
        controller.reconcile(
            snapshot: CodexResetCreditAutomationDemo.expiryAlertSnapshot(now: now),
            settings: CodexResetCreditAutomationSettings(
                expiryAlertsEnabled: true,
                autoRedeemEnabled: false),
            scopeID: "codex-reset-expiry-demo",
            redeem: { _, _ in .noCredit },
            completion: { _, _ in })
    }

    func runCodexResetAutoRedeemDemo(now: Date = Date()) {
        guard !self.settings.codexResetCreditAutomationEnabled else { return }
        self.codexResetCreditAutomationController.stop()
        self.codexResetCreditAutoRedeemDemoController?.stop(clearExpiryAlerts: false)
        let controller = CodexResetCreditAutomationController(
            notifier: CodexResetCreditDemoNotifier(kind: .autoRedeem),
            now: Date.init)
        self.codexResetCreditAutoRedeemDemoController = controller
        controller.reconcile(
            snapshot: CodexResetCreditAutomationDemo.autoRedeemSnapshot(now: now),
            settings: CodexResetCreditAutomationSettings(
                expiryAlertsEnabled: false,
                autoRedeemEnabled: true),
            scopeID: "codex-reset-auto-redeem-demo",
            redeem: CodexResetCreditAutomationDemo.redeem,
            completion: { [weak self] _, _ in
                self?.codexResetCreditAutoRedeemDemoController = nil
            })
    }

    func reconcileCodexResetCreditAutomation(snapshot: UsageSnapshot?) {
        let expectedGuard = self.freshCodexAccountScopedRefreshGuard()
        let expectedAccountEmail = expectedGuard.accountKey
        let canSafelyRedeem = expectedGuard.identity != .unresolved && expectedAccountEmail != nil
        let automationSettings = CodexResetCreditAutomationSettings(
            expiryAlertsEnabled: self.settings.codexResetExpiryNotificationsEnabled,
            autoRedeemEnabled: self.settings.codexResetAutoRedeemEnabled && canSafelyRedeem)
        let scopedFetcher = self.makeFetchContext(provider: .codex, override: nil).fetcher
        let scopeID = Self.codexResetCreditAutomationScopeID(expectedGuard)

        self.codexResetCreditAutomationController.reconcile(
            snapshot: snapshot?.codexResetCredits,
            settings: automationSettings,
            scopeID: scopeID,
            redeem: { [weak self] creditID, idempotencyKey in
                guard let self,
                      let expectedAccountEmail,
                      await self.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard)
                else {
                    throw CancellationError()
                }
                return try await scopedFetcher.consumeRateLimitResetCredit(
                    creditID: creditID,
                    idempotencyKey: idempotencyKey,
                    expectedAccountEmail: expectedAccountEmail)
            },
            completion: { [weak self] _, _ in
                guard let self else { return }
                await self.refreshProvider(.codex, coalesceIfRefreshing: true)
            })
    }

    private static func codexResetCreditAutomationScopeID(_ guardValue: CodexAccountScopedRefreshGuard) -> String {
        let source = switch guardValue.source {
        case .liveSystem:
            "live-system"
        case let .managedAccount(id):
            "managed:\(id.uuidString)"
        case let .profileHome(path):
            "profile:\(path)"
        }
        return [
            source,
            guardValue.accountKey ?? "account:unresolved",
            guardValue.authFingerprint ?? "auth:unresolved",
        ].joined(separator: "|")
    }
}
