import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexResetCreditAutomationTests {
    @MainActor
    private final class NotifierSpy: CodexResetCreditNotificationScheduling {
        private(set) var replacements: [[CodexResetCreditExpiryAlert]] = []
        private(set) var events: [CodexResetCreditAutoRedeemEvent] = []

        func replaceExpiryAlerts(_ alerts: [CodexResetCreditExpiryAlert]) {
            self.replacements.append(alerts)
        }

        func postAutoRedeemEvent(_ event: CodexResetCreditAutoRedeemEvent) {
            self.events.append(event)
        }
    }

    private actor RedemptionRecorder {
        struct Call: Equatable, Sendable {
            let creditID: String
            let idempotencyKey: UUID
        }

        struct Completion: Equatable, Sendable {
            let creditID: String
            let outcome: CodexRateLimitResetCreditConsumeOutcome
        }

        private var calls: [Call] = []
        private var completions: [Completion] = []
        private var completionWaiters: [CheckedContinuation<Void, Never>] = []

        func recordCall(creditID: String, idempotencyKey: UUID) -> Int {
            self.calls.append(Call(creditID: creditID, idempotencyKey: idempotencyKey))
            return self.calls.count
        }

        func recordCompletion(creditID: String, outcome: CodexRateLimitResetCreditConsumeOutcome) {
            self.completions.append(Completion(creditID: creditID, outcome: outcome))
            let waiters = self.completionWaiters
            self.completionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func waitForCompletion() async {
            guard self.completions.isEmpty else { return }
            await withCheckedContinuation { continuation in
                self.completionWaiters.append(continuation)
            }
        }

        func snapshot() -> (calls: [Call], completions: [Completion]) {
            (self.calls, self.completions)
        }
    }

    private final class IDSequence: @unchecked Sendable {
        private let lock = NSLock()
        private let values: [UUID]
        private var index = 0

        init(_ values: [UUID]) {
            self.values = values
        }

        func next() -> UUID {
            self.lock.lock()
            defer { self.lock.unlock() }
            let value = self.values[min(self.index, self.values.count - 1)]
            self.index += 1
            return value
        }

        func callCount() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.index
        }
    }

    private struct StubFailure: Error, LocalizedError {
        var errorDescription: String? {
            "stub failure"
        }
    }

    @Test
    func `plan schedules alerts five minutes and redemption one minute before expiry`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstExpiry = now.addingTimeInterval(10 * 60)
        let secondExpiry = now.addingTimeInterval(15 * 60)
        let snapshot = Self.snapshot([
            Self.credit(id: "second", expiresAt: secondExpiry),
            Self.credit(id: "first", expiresAt: firstExpiry),
        ], now: now)

        let plan = CodexResetCreditAutomationPlan.make(
            snapshot: snapshot,
            settings: .init(expiryAlertsEnabled: true, autoRedeemEnabled: true),
            now: now)

        #expect(plan.expiryAlerts == [
            CodexResetCreditExpiryAlert(
                creditID: "first",
                fireDate: firstExpiry.addingTimeInterval(-5 * 60),
                expiresAt: firstExpiry),
            CodexResetCreditExpiryAlert(
                creditID: "second",
                fireDate: secondExpiry.addingTimeInterval(-5 * 60),
                expiresAt: secondExpiry),
        ])
        #expect(plan.autoRedemptions == [
            CodexResetCreditAutoRedemption(
                creditID: "first",
                fireDate: firstExpiry.addingTimeInterval(-60),
                expiresAt: firstExpiry),
            CodexResetCreditAutoRedemption(
                creditID: "second",
                fireDate: secondExpiry.addingTimeInterval(-60),
                expiresAt: secondExpiry),
        ])
    }

    @Test
    func `plan handles late discovery without scheduling after expiry`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let finalMinuteExpiry = now.addingTimeInterval(30)
        let twoMinuteExpiry = now.addingTimeInterval(120)
        let tooLateExpiry = now.addingTimeInterval(0.5)
        let snapshot = Self.snapshot([
            Self.credit(id: "final-minute", expiresAt: finalMinuteExpiry),
            Self.credit(id: "two-minutes", expiresAt: twoMinuteExpiry),
            Self.credit(id: "too-late", expiresAt: tooLateExpiry),
        ], now: now)

        let plan = CodexResetCreditAutomationPlan.make(
            snapshot: snapshot,
            settings: .init(expiryAlertsEnabled: true, autoRedeemEnabled: true),
            now: now)

        #expect(plan.expiryAlerts.map(\.creditID) == ["final-minute", "two-minutes"])
        #expect(plan.expiryAlerts.allSatisfy { $0.fireDate == now.addingTimeInterval(1) })
        #expect(plan.autoRedemptions == [
            CodexResetCreditAutoRedemption(
                creditID: "too-late",
                fireDate: now,
                expiresAt: tooLateExpiry),
            CodexResetCreditAutoRedemption(
                creditID: "final-minute",
                fireDate: now,
                expiresAt: finalMinuteExpiry),
            CodexResetCreditAutoRedemption(
                creditID: "two-minutes",
                fireDate: now.addingTimeInterval(60),
                expiresAt: twoMinuteExpiry),
        ])
    }

    @Test
    func `plan ignores unusable credits and de-duplicates credit ids`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let validExpiry = now.addingTimeInterval(600)
        let snapshot = Self.snapshot([
            Self.credit(id: "valid", expiresAt: validExpiry),
            Self.credit(id: "valid", expiresAt: now.addingTimeInterval(900)),
            Self.credit(id: "redeemed", status: .redeemed, expiresAt: validExpiry),
            Self.credit(id: "expired", expiresAt: now.addingTimeInterval(-1)),
            Self.credit(id: "missing-expiry", expiresAt: nil),
        ], now: now)

        let plan = CodexResetCreditAutomationPlan.make(
            snapshot: snapshot,
            settings: .init(expiryAlertsEnabled: true, autoRedeemEnabled: true),
            now: now)

        #expect(plan.expiryAlerts.map(\.creditID) == ["valid"])
        #expect(plan.autoRedemptions.map(\.creditID) == ["valid"])
        #expect(plan.expiryAlerts.first?.expiresAt == validExpiry)
    }

    @Test
    func `settings independently control alerts and automatic redemption`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = Self.snapshot([
            Self.credit(id: "credit", expiresAt: now.addingTimeInterval(600)),
        ], now: now)

        let alertsOnly = CodexResetCreditAutomationPlan.make(
            snapshot: snapshot,
            settings: .init(expiryAlertsEnabled: true, autoRedeemEnabled: false),
            now: now)
        let redemptionOnly = CodexResetCreditAutomationPlan.make(
            snapshot: snapshot,
            settings: .init(expiryAlertsEnabled: false, autoRedeemEnabled: true),
            now: now)

        #expect(alertsOnly.expiryAlerts.count == 1)
        #expect(alertsOnly.autoRedemptions.isEmpty)
        #expect(redemptionOnly.expiryAlerts.isEmpty)
        #expect(redemptionOnly.autoRedemptions.count == 1)
    }

    @Test
    func `controller redeems through injected closure once and reports the mocked result`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let idempotencyKey = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let snapshot = Self.snapshot([
            Self.credit(id: "credit-to-use", expiresAt: now.addingTimeInterval(30)),
        ], now: now)
        let notifier = NotifierSpy()
        let recorder = RedemptionRecorder()
        let controller = CodexResetCreditAutomationController(
            notifier: notifier,
            now: { now },
            sleepUntil: { _ in },
            makeID: { idempotencyKey })
        let settings = CodexResetCreditAutomationSettings(
            expiryAlertsEnabled: true,
            autoRedeemEnabled: true)

        controller.reconcile(
            snapshot: snapshot,
            settings: settings,
            scopeID: "account-one",
            redeem: { creditID, key in
                _ = await recorder.recordCall(creditID: creditID, idempotencyKey: key)
                return .reset
            },
            completion: { creditID, outcome in
                await recorder.recordCompletion(creditID: creditID, outcome: outcome)
            })
        await recorder.waitForCompletion()

        controller.reconcile(
            snapshot: snapshot,
            settings: settings,
            scopeID: "account-one",
            redeem: { creditID, key in
                _ = await recorder.recordCall(creditID: creditID, idempotencyKey: key)
                return .reset
            },
            completion: { creditID, outcome in
                await recorder.recordCompletion(creditID: creditID, outcome: outcome)
            })
        for _ in 0..<5 {
            await Task.yield()
        }

        let recorded = await recorder.snapshot()
        #expect(recorded.calls == [
            .init(creditID: "credit-to-use", idempotencyKey: idempotencyKey),
        ])
        #expect(recorded.completions == [
            .init(creditID: "credit-to-use", outcome: .reset),
        ])
        #expect(notifier.events == [.completed(.reset)])
    }

    @Test
    func `controller reuses idempotency key when a mocked redemption is retried`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let secondID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let ids = IDSequence([firstID, secondID])
        let snapshot = Self.snapshot([
            Self.credit(id: "credit-to-retry", expiresAt: now.addingTimeInterval(30)),
        ], now: now)
        let notifier = NotifierSpy()
        let recorder = RedemptionRecorder()
        let controller = CodexResetCreditAutomationController(
            notifier: notifier,
            now: { now },
            sleepUntil: { _ in },
            makeID: { ids.next() })
        let settings = CodexResetCreditAutomationSettings(
            expiryAlertsEnabled: false,
            autoRedeemEnabled: true)
        let redeem: CodexResetCreditAutomationController.Redeem = { creditID, key in
            let attempt = await recorder.recordCall(creditID: creditID, idempotencyKey: key)
            if attempt == 1 {
                throw StubFailure()
            }
            return .reset
        }

        controller.reconcile(
            snapshot: snapshot,
            settings: settings,
            scopeID: "account-one",
            redeem: redeem,
            completion: { creditID, outcome in
                await recorder.recordCompletion(creditID: creditID, outcome: outcome)
            })
        for _ in 0..<100 where notifier.events.isEmpty {
            await Task.yield()
        }
        #expect(notifier.events == [.failed("stub failure")])

        controller.reconcile(
            snapshot: snapshot,
            settings: settings,
            scopeID: "account-one",
            redeem: redeem,
            completion: { creditID, outcome in
                await recorder.recordCompletion(creditID: creditID, outcome: outcome)
            })
        await recorder.waitForCompletion()

        let recorded = await recorder.snapshot()
        #expect(recorded.calls.map(\.idempotencyKey) == [firstID, firstID])
        #expect(ids.callCount() == 1)
        #expect(notifier.events == [.failed("stub failure"), .completed(.reset)])
    }

    @Test
    func `disabling settings clears alerts and cancels pending automatic redemption`() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = Self.snapshot([
            Self.credit(id: "pending", expiresAt: now.addingTimeInterval(600)),
        ], now: now)
        let notifier = NotifierSpy()
        let recorder = RedemptionRecorder()
        let controller = CodexResetCreditAutomationController(
            notifier: notifier,
            now: { now },
            sleepUntil: { _ in try await Task.sleep(for: .seconds(60)) })

        controller.reconcile(
            snapshot: snapshot,
            settings: .init(expiryAlertsEnabled: true, autoRedeemEnabled: true),
            scopeID: "account-one",
            redeem: { creditID, key in
                _ = await recorder.recordCall(creditID: creditID, idempotencyKey: key)
                return .reset
            },
            completion: { creditID, outcome in
                await recorder.recordCompletion(creditID: creditID, outcome: outcome)
            })
        await Task.yield()
        controller.reconcile(
            snapshot: snapshot,
            settings: .init(expiryAlertsEnabled: false, autoRedeemEnabled: false),
            scopeID: "account-one",
            redeem: { _, _ in .reset },
            completion: { _, _ in })
        for _ in 0..<5 {
            await Task.yield()
        }

        #expect(notifier.replacements.last?.isEmpty == true)
        #expect(await recorder.snapshot().calls.isEmpty)
    }

    private static func snapshot(
        _ credits: [CodexRateLimitResetCredit],
        now: Date) -> CodexRateLimitResetCreditsSnapshot
    {
        CodexRateLimitResetCreditsSnapshot(
            credits: credits,
            availableCount: credits.count(where: { $0.status == .available }),
            updatedAt: now)
    }

    private static func credit(
        id: String,
        status: CodexRateLimitResetCreditStatus = .available,
        expiresAt: Date?) -> CodexRateLimitResetCredit
    {
        CodexRateLimitResetCredit(
            id: id,
            resetType: "full",
            status: status,
            grantedAt: Date(timeIntervalSince1970: 1_799_000_000),
            expiresAt: expiresAt,
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: "Full reset",
            description: nil)
    }
}
