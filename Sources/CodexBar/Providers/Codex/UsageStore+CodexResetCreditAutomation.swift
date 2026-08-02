import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func runCodexResetCreditAutomationDemo() async {
        guard !self.settings.codexResetCreditAutomationEnabled else { return }
        guard !self.codexResetCreditAutomationDemoState.isRunning else { return }

        self.codexResetCreditAutomationController.stop()
        self.cancelCodexResetCreditAutomationDemo(resetStatus: false)
        let runID = UUID()
        self.codexResetCreditAutomationDemoRunID = runID
        self.codexResetCreditAutomationDemoState = .running("starting the isolated fake Codex App Server")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCodexResetCreditAutomationDemo(runID: runID)
        }
        self.codexResetCreditAutomationDemoTask = task
        await task.value
        if self.codexResetCreditAutomationDemoRunID == runID {
            self.codexResetCreditAutomationDemoTask = nil
            self.codexResetCreditAutomationDemoRunID = nil
        }
    }

    func cancelCodexResetCreditAutomationDemo(resetStatus: Bool = true) {
        self.codexResetCreditAutomationDemoTask?.cancel()
        self.codexResetCreditAutomationDemoTask = nil
        self.codexResetCreditAutomationDemoRunID = nil
        self.codexResetCreditAutomationDemoController?.stop()
        self.codexResetCreditAutomationDemoController = nil
        if resetStatus {
            self.codexResetCreditAutomationDemoState = .idle
        }
    }

    private func performCodexResetCreditAutomationDemo(runID: UUID) async {
        do {
            let expiryCreditID = try await self.runCodexResetExpiryAlertDemoPhase(runID: runID)
            try Task.checkCancellation()
            self.codexResetCreditAutomationDemoState = .running(
                "five-minute alert scheduled from App Server credit \(expiryCreditID); testing consume RPC")
            let record = try await self.runCodexResetAutoRedeemDemoPhase(runID: runID)
            try Task.checkCancellation()
            guard self.codexResetCreditAutomationDemoRunID == runID else { return }
            self.codexResetCreditAutomationDemoState = .succeeded(
                "the real controller scheduled the alert and the fake App Server captured consume for " +
                    "\(record.creditId) with idempotency key \(record.idempotencyKey)")
        } catch is CancellationError {
            guard self.codexResetCreditAutomationDemoRunID == runID else { return }
            self.codexResetCreditAutomationDemoState = .idle
        } catch {
            guard self.codexResetCreditAutomationDemoRunID == runID else { return }
            self.codexResetCreditAutomationDemoState = .failed(error.localizedDescription)
        }
        if self.codexResetCreditAutomationDemoRunID == runID {
            self.codexResetCreditAutomationDemoController?.stop()
            self.codexResetCreditAutomationDemoController = nil
        }
    }

    private func runCodexResetExpiryAlertDemoPhase(runID: UUID) async throws -> String {
        self.codexResetCreditAutomationDemoState = .running("checking macOS notification permission")
        guard await AppNotifications.shared.prepareAuthorization() else {
            throw CodexResetCreditAutomationDemo.DemoError.notificationPermissionDenied
        }
        try Task.checkCancellation()
        guard self.codexResetCreditAutomationDemoRunID == runID else { throw CancellationError() }

        let fixture = try CodexResetCreditAutomationDemo.makeFixture(
            providerCreditID: CodexResetCreditAutomationDemo.expiryProviderCreditID,
            expiresAt: Date().addingTimeInterval(
                CodexResetCreditAutomationPlan.expiryAlertLeadTime +
                    CodexResetCreditAutomationDemo.phaseDelay))
        defer { fixture.cleanup() }
        let snapshot = try await self.loadCodexResetCreditAutomationDemoSnapshot(fixture: fixture)
        try Task.checkCancellation()
        guard self.codexResetCreditAutomationDemoRunID == runID else { throw CancellationError() }

        let notificationScheduleRecorder = CodexResetCreditAutomationDemo.NotificationScheduleRecorder()
        let controller = CodexResetCreditAutomationController(
            notifier: CodexResetCreditDemoNotifier(
                kind: .expiryAlert,
                notificationScheduleRecorder: notificationScheduleRecorder),
            now: Date.init)
        self.codexResetCreditAutomationDemoController = controller
        controller.reconcile(
            snapshot: snapshot,
            settings: CodexResetCreditAutomationSettings(
                expiryAlertsEnabled: true,
                autoRedeemEnabled: false),
            scopeID: "codex-reset-expiry-app-server-demo",
            redeem: { _, _ in .noCredit },
            completion: { _, _ in })
        let scheduleResult = try await notificationScheduleRecorder.waitForResult()
        switch scheduleResult {
        case let .scheduled(count) where count > 0:
            break
        case .suppressedForTests:
            break
        default:
            throw CodexResetCreditAutomationDemo.DemoError.notificationScheduleFailed(
                scheduleResult.failureDescription)
        }
        try await Task.sleep(for: .seconds(CodexResetCreditAutomationDemo.phaseDelay + 1.5))
        try Task.checkCancellation()
        controller.stop()
        return fixture.providerCreditID
    }

    private func runCodexResetAutoRedeemDemoPhase(
        runID: UUID) async throws -> CodexResetCreditAutomationDemo.ConsumeRecord
    {
        let fixture = try CodexResetCreditAutomationDemo.makeFixture(
            providerCreditID: CodexResetCreditAutomationDemo.autoRedeemProviderCreditID,
            expiresAt: Date().addingTimeInterval(
                CodexResetCreditAutomationPlan.autoRedeemLeadTime +
                    CodexResetCreditAutomationDemo.phaseDelay))
        defer { fixture.cleanup() }
        let snapshot = try await self.loadCodexResetCreditAutomationDemoSnapshot(fixture: fixture)
        try Task.checkCancellation()
        guard self.codexResetCreditAutomationDemoRunID == runID else { throw CancellationError() }

        self.codexResetCreditAutomationDemoController?.stop()
        let controller = CodexResetCreditAutomationController(
            notifier: CodexResetCreditDemoNotifier(kind: .autoRedeem),
            now: Date.init)
        self.codexResetCreditAutomationDemoController = controller
        let fetcher = fixture.fetcher
        let expectedAccountEmail = fixture.accountEmail
        let completionRecorder = CodexResetCreditAutomationDemo.CompletionRecorder()
        controller.reconcile(
            snapshot: snapshot,
            settings: CodexResetCreditAutomationSettings(
                expiryAlertsEnabled: false,
                autoRedeemEnabled: true),
            scopeID: "codex-reset-auto-redeem-app-server-demo",
            redeem: { creditID, idempotencyKey in
                try await fetcher.consumeRateLimitResetCredit(
                    creditID: creditID,
                    idempotencyKey: idempotencyKey,
                    expectedAccountEmail: expectedAccountEmail)
            },
            completion: { creditID, outcome in
                await completionRecorder.record(creditID: creditID, outcome: outcome)
            })

        let record = try await fixture.waitForConsumeRecord()
        let completion = try await completionRecorder.waitForCompletion()
        guard record.creditId == fixture.providerCreditID else {
            throw CodexResetCreditAutomationDemo.DemoError.unexpectedCredit(record.creditId)
        }
        guard UUID(uuidString: record.idempotencyKey) != nil else {
            throw CodexResetCreditAutomationDemo.DemoError.invalidIdempotencyKey(record.idempotencyKey)
        }
        guard completion.creditID == fixture.stableCreditID else {
            throw CodexResetCreditAutomationDemo.DemoError.unexpectedCompletionCredit(completion.creditID)
        }
        guard completion.outcome == .reset else {
            throw CodexResetCreditAutomationDemo.DemoError.unexpectedOutcome(completion.outcome)
        }
        return record
    }

    private func loadCodexResetCreditAutomationDemoSnapshot(
        fixture: CodexResetCreditAutomationDemo.Fixture) async throws -> CodexRateLimitResetCreditsSnapshot
    {
        let accountSnapshot = try await fixture.fetcher.loadLatestCLIAccountSnapshot()
        guard let usage = accountSnapshot.usage else {
            throw CodexResetCreditAutomationDemo.DemoError.missingUsage
        }
        let accountEmail = usage.accountEmail(for: .codex)
        guard accountEmail == fixture.accountEmail else {
            throw CodexResetCreditAutomationDemo.DemoError.unexpectedAccount(accountEmail)
        }
        guard let snapshot = usage.codexResetCredits,
              snapshot.credits.contains(where: { $0.id == fixture.stableCreditID })
        else {
            throw CodexResetCreditAutomationDemo.DemoError.missingResetCredit
        }
        return snapshot
    }

    func reconcileCodexResetCreditAutomation(snapshot: UsageSnapshot?) {
        if self.settings.codexResetCreditAutomationEnabled {
            self.cancelCodexResetCreditAutomationDemo()
        }
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
