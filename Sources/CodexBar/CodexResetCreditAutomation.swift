import CodexBarCore
import Foundation

struct CodexResetCreditAutomationSettings: Equatable, Sendable {
    let expiryAlertsEnabled: Bool
    let autoRedeemEnabled: Bool
}

struct CodexResetCreditExpiryAlert: Equatable, Sendable {
    let creditID: String
    let fireDate: Date
    let expiresAt: Date
}

struct CodexResetCreditAutoRedemption: Equatable, Sendable {
    let creditID: String
    let fireDate: Date
    let expiresAt: Date
}

struct CodexResetCreditAutomationPlan: Equatable, Sendable {
    static let expiryAlertLeadTime: TimeInterval = 5 * 60
    static let autoRedeemLeadTime: TimeInterval = 60
    static let immediateSchedulingDelay: TimeInterval = 1

    let expiryAlerts: [CodexResetCreditExpiryAlert]
    let autoRedemptions: [CodexResetCreditAutoRedemption]

    static func make(
        snapshot: CodexRateLimitResetCreditsSnapshot?,
        settings: CodexResetCreditAutomationSettings,
        now: Date) -> Self
    {
        var seenCreditIDs: Set<String> = []
        var credits: [(credit: CodexRateLimitResetCredit, expiresAt: Date)] = []
        for credit in snapshot?.credits ?? [] {
            guard credit.status == .available,
                  let expiresAt = credit.expiresAt,
                  expiresAt > now,
                  seenCreditIDs.insert(credit.id).inserted
            else {
                continue
            }
            credits.append((credit, expiresAt))
        }
        credits.sort { lhs, rhs in
            if lhs.expiresAt == rhs.expiresAt {
                return lhs.credit.id < rhs.credit.id
            }
            return lhs.expiresAt < rhs.expiresAt
        }

        let earliestFireDate = now.addingTimeInterval(Self.immediateSchedulingDelay)
        let alerts: [CodexResetCreditExpiryAlert] = settings.expiryAlertsEnabled
            ? credits.compactMap { item in
                let fireDate = max(
                    item.expiresAt.addingTimeInterval(-Self.expiryAlertLeadTime),
                    earliestFireDate)
                guard fireDate < item.expiresAt else { return nil }
                return CodexResetCreditExpiryAlert(
                    creditID: item.credit.id,
                    fireDate: fireDate,
                    expiresAt: item.expiresAt)
            }
            : []
        let redemptions: [CodexResetCreditAutoRedemption] = settings.autoRedeemEnabled
            ? credits.map { item in
                CodexResetCreditAutoRedemption(
                    creditID: item.credit.id,
                    fireDate: max(
                        item.expiresAt.addingTimeInterval(-Self.autoRedeemLeadTime),
                        now),
                    expiresAt: item.expiresAt)
            }
            : []

        return Self(expiryAlerts: alerts, autoRedemptions: redemptions)
    }
}

enum CodexResetCreditAutoRedeemEvent: Equatable, Sendable {
    case completed(CodexRateLimitResetCreditConsumeOutcome)
    case failed(String)
}

@MainActor
protocol CodexResetCreditNotificationScheduling: AnyObject {
    func replaceExpiryAlerts(_ alerts: [CodexResetCreditExpiryAlert])
    func postAutoRedeemEvent(_ event: CodexResetCreditAutoRedeemEvent)
}

@MainActor
final class CodexResetCreditNotifier: CodexResetCreditNotificationScheduling {
    private static let notificationPrefix = "codex-reset-expiry"

    func replaceExpiryAlerts(_ alerts: [CodexResetCreditExpiryAlert]) {
        let notifications = alerts.map { alert in
            ScheduledAppNotification(
                id: alert.creditID,
                title: L("Codex reset expires soon"),
                body: L("An available Codex reset will expire soon."),
                fireDate: alert.fireDate,
                soundEnabled: true)
        }
        AppNotifications.shared.replaceScheduled(
            idPrefix: Self.notificationPrefix,
            notifications: notifications)
    }

    func postAutoRedeemEvent(_ event: CodexResetCreditAutoRedeemEvent) {
        let copy: (title: String, body: String) = switch event {
        case .completed(.reset), .completed(.alreadyRedeemed):
            (
                L("Codex reset used automatically"),
                L("The expiring reset was applied to an eligible Codex rate-limit window."))
        case .completed(.nothingToReset):
            (
                L("Codex reset was not needed"),
                L("No Codex rate-limit window was eligible for a reset."))
        case .completed(.noCredit):
            (
                L("Codex reset was unavailable"),
                L("Codex reported that no earned reset was available."))
        case let .completed(.unknown(outcome)):
            (
                L("Codex reset result was unknown"),
                String(format: L("Codex returned the result: %@"), outcome))
        case let .failed(message):
            (
                L("Codex reset could not be used"),
                String(format: L("Automatic reset failed: %@"), message))
        }

        AppNotifications.shared.post(
            idPrefix: "codex-reset-auto-redeem",
            title: copy.title,
            body: copy.body)
    }
}

@MainActor
final class CodexResetCreditAutomationController {
    typealias Redeem = @Sendable (
        _ creditID: String,
        _ idempotencyKey: UUID) async throws -> CodexRateLimitResetCreditConsumeOutcome
    typealias Completion = @MainActor @Sendable (
        _ creditID: String,
        _ outcome: CodexRateLimitResetCreditConsumeOutcome) async -> Void
    typealias SleepUntil = @Sendable (_ date: Date) async throws -> Void

    private struct RedemptionKey: Hashable {
        let scopeID: String
        let creditID: String
    }

    private struct ScheduledRedemption {
        let taskID: UUID
        let fireDate: Date
        let expiresAt: Date
        let task: Task<Void, Never>
    }

    private let notifier: any CodexResetCreditNotificationScheduling
    private let now: @Sendable () -> Date
    private let sleepUntil: SleepUntil
    private let makeID: @Sendable () -> UUID
    private let logger = CodexBarLog.logger(LogCategories.codexRPC)
    private var lastExpiryAlerts: [CodexResetCreditExpiryAlert]?
    private var scheduledRedemptions: [RedemptionKey: ScheduledRedemption] = [:]
    private var completedRedemptions: Set<RedemptionKey> = []
    private var idempotencyKeys: [RedemptionKey: UUID] = [:]

    init(
        notifier: any CodexResetCreditNotificationScheduling = CodexResetCreditNotifier(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleepUntil: @escaping SleepUntil = { date in
            let delay = date.timeIntervalSinceNow
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
        },
        makeID: @escaping @Sendable () -> UUID = UUID.init)
    {
        self.notifier = notifier
        self.now = now
        self.sleepUntil = sleepUntil
        self.makeID = makeID
    }

    func reconcile(
        snapshot: CodexRateLimitResetCreditsSnapshot?,
        settings: CodexResetCreditAutomationSettings,
        scopeID: String,
        redeem: @escaping Redeem,
        completion: @escaping Completion)
    {
        let plan = CodexResetCreditAutomationPlan.make(
            snapshot: snapshot,
            settings: settings,
            now: self.now())
        if self.lastExpiryAlerts != plan.expiryAlerts {
            self.notifier.replaceExpiryAlerts(plan.expiryAlerts)
            self.lastExpiryAlerts = plan.expiryAlerts
        }

        var desired: [RedemptionKey: CodexResetCreditAutoRedemption] = [:]
        for redemption in plan.autoRedemptions {
            let key = RedemptionKey(scopeID: scopeID, creditID: redemption.creditID)
            if desired[key] == nil {
                desired[key] = redemption
            }
        }
        let availableKeys = Set((snapshot?.credits ?? []).compactMap { credit -> RedemptionKey? in
            guard credit.status == .available,
                  let expiresAt = credit.expiresAt,
                  expiresAt > self.now()
            else {
                return nil
            }
            return RedemptionKey(scopeID: scopeID, creditID: credit.id)
        })
        self.completedRedemptions.formIntersection(availableKeys)
        self.idempotencyKeys = self.idempotencyKeys.filter { availableKeys.contains($0.key) }

        let obsoleteKeys = self.scheduledRedemptions.compactMap { key, scheduled -> RedemptionKey? in
            guard let target = desired[key],
                  target.fireDate == scheduled.fireDate,
                  target.expiresAt == scheduled.expiresAt
            else {
                return key
            }
            return nil
        }
        for key in obsoleteKeys {
            self.scheduledRedemptions.removeValue(forKey: key)?.task.cancel()
        }

        for (key, target) in desired
            where self.scheduledRedemptions[key] == nil && !self.completedRedemptions.contains(key)
        {
            let idempotencyKey = self.idempotencyKeys[key] ?? self.makeID()
            self.idempotencyKeys[key] = idempotencyKey
            let taskID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.sleepUntil(target.fireDate)
                    try Task.checkCancellation()
                    guard self.now() < target.expiresAt else { return }

                    let outcome = try await redeem(target.creditID, idempotencyKey)
                    try Task.checkCancellation()
                    self.completedRedemptions.insert(key)
                    self.notifier.postAutoRedeemEvent(.completed(outcome))
                    await completion(target.creditID, outcome)
                } catch is CancellationError {
                    // Settings, account selection, or refreshed credit state canceled this attempt.
                } catch {
                    self.logger.error(
                        "automatic reset redemption failed",
                        metadata: ["error": String(describing: error)])
                    self.notifier.postAutoRedeemEvent(.failed(error.localizedDescription))
                }
                if self.scheduledRedemptions[key]?.taskID == taskID {
                    self.scheduledRedemptions.removeValue(forKey: key)
                }
            }
            self.scheduledRedemptions[key] = ScheduledRedemption(
                taskID: taskID,
                fireDate: target.fireDate,
                expiresAt: target.expiresAt,
                task: task)
        }
    }

    func stop(clearExpiryAlerts: Bool = true) {
        for scheduled in self.scheduledRedemptions.values {
            scheduled.task.cancel()
        }
        self.scheduledRedemptions.removeAll()
        if clearExpiryAlerts, self.lastExpiryAlerts != [] {
            self.notifier.replaceExpiryAlerts([])
            self.lastExpiryAlerts = []
        }
    }
}
