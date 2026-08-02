import CodexBarCore
import Foundation
@preconcurrency import UserNotifications

struct ScheduledAppNotification: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let fireDate: Date
    let soundEnabled: Bool
}

enum ScheduledAppNotificationReplacementResult: Equatable, Sendable {
    case scheduled(Int)
    case cleared
    case notAuthorized
    case noFutureNotifications
    case failed(String)
    case superseded
    case suppressedForTests

    var failureDescription: String {
        switch self {
        case let .scheduled(count):
            "Scheduled \(count) notification(s)."
        case .cleared:
            "The scheduled notification was cleared before it could fire."
        case .notAuthorized:
            "macOS notification permission is not enabled for CodexBar."
        case .noFutureNotifications:
            "The mock notification time passed before macOS accepted the schedule."
        case let .failed(message):
            "macOS rejected the mock notification: \(message)"
        case .superseded:
            "A newer notification schedule replaced the mock notification."
        case .suppressedForTests:
            "Notification delivery is suppressed under unit tests."
        }
    }
}

struct AppNotificationCenterClient {
    let authorizationStatus: @MainActor @Sendable () async -> UNAuthorizationStatus?
    let requestAuthorization: @MainActor @Sendable () async -> Bool
    let pendingIdentifiers: @MainActor @Sendable () async -> [String]
    let removePending: @MainActor @Sendable ([String]) -> Void
    let add: @MainActor @Sendable (UNNotificationRequest) async throws -> Void

    static func live(
        centerProvider: @escaping @Sendable () -> UNUserNotificationCenter) -> AppNotificationCenterClient
    {
        AppNotificationCenterClient(
            authorizationStatus: {
                let center = centerProvider()
                return await withCheckedContinuation { continuation in
                    center.getNotificationSettings { settings in
                        continuation.resume(returning: settings.authorizationStatus)
                    }
                }
            },
            requestAuthorization: {
                let center = centerProvider()
                return await withCheckedContinuation { continuation in
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        continuation.resume(returning: granted)
                    }
                }
            },
            pendingIdentifiers: {
                let center = centerProvider()
                return await withCheckedContinuation { continuation in
                    center.getPendingNotificationRequests { requests in
                        continuation.resume(returning: requests.map(\.identifier))
                    }
                }
            },
            removePending: { identifiers in
                let center = centerProvider()
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
            },
            add: { request in
                let center = centerProvider()
                try await center.add(request)
            })
    }
}

@MainActor
final class AppNotifications {
    static let shared = AppNotifications()

    private let client: AppNotificationCenterClient
    private let suppressesDeliveryUnderTests: Bool
    private let logger = CodexBarLog.logger(LogCategories.notifications)
    private var authorizationTask: Task<Bool, Never>?
    private var scheduledReplacementGenerations: [String: UUID] = [:]

    init(centerProvider: @escaping @Sendable () -> UNUserNotificationCenter = { UNUserNotificationCenter.current() }) {
        self.client = .live(centerProvider: centerProvider)
        self.suppressesDeliveryUnderTests = Self.isRunningUnderTests
    }

    init(client: AppNotificationCenterClient, suppressesDeliveryUnderTests: Bool) {
        self.client = client
        self.suppressesDeliveryUnderTests = suppressesDeliveryUnderTests
    }

    func requestAuthorizationOnStartup() {
        guard !self.suppressesDeliveryUnderTests else { return }
        _ = self.ensureAuthorizationTask()
    }

    func prepareAuthorization() async -> Bool {
        guard !self.suppressesDeliveryUnderTests else { return true }
        // This is an explicit user action. Re-read System Settings so retrying after a
        // permission change does not reuse startup's completed authorization task.
        self.authorizationTask = nil
        return await self.requestAuthorization()
    }

    func post(
        idPrefix: String,
        title: String,
        body: String,
        badge: NSNumber? = nil,
        soundEnabled: Bool = true)
    {
        guard !self.suppressesDeliveryUnderTests else { return }
        let logger = self.logger

        Task { @MainActor in
            let granted = await self.ensureAuthorized()
            guard granted else {
                logger.debug("not authorized; skipping post", metadata: ["prefix": idPrefix])
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = soundEnabled ? .default : nil
            content.badge = badge

            let request = UNNotificationRequest(
                identifier: "codexbar-\(idPrefix)-\(UUID().uuidString)",
                content: content,
                trigger: nil)

            logger.info("posting", metadata: ["prefix": idPrefix])
            do {
                try await self.client.add(request)
            } catch {
                let errorText = String(describing: error)
                logger.error("failed to post", metadata: ["prefix": idPrefix, "error": errorText])
            }
        }
    }

    func replaceScheduled(
        idPrefix: String,
        notifications: [ScheduledAppNotification],
        completion: (@MainActor @Sendable (ScheduledAppNotificationReplacementResult) -> Void)? = nil)
    {
        guard !self.suppressesDeliveryUnderTests else {
            completion?(.suppressedForTests)
            return
        }
        let requestPrefix = "codexbar-\(idPrefix)-"
        let logger = self.logger
        let generation = UUID()
        self.scheduledReplacementGenerations[idPrefix] = generation

        Task { @MainActor in
            var addedIDs: [String] = []
            let existingIDs = await self.client.pendingIdentifiers()
                .filter { $0.hasPrefix(requestPrefix) }
            guard self.scheduledReplacementGenerations[idPrefix] == generation else {
                completion?(.superseded)
                return
            }
            if !existingIDs.isEmpty {
                self.client.removePending(existingIDs)
            }

            guard !notifications.isEmpty else {
                self.scheduledReplacementGenerations.removeValue(forKey: idPrefix)
                completion?(.cleared)
                return
            }
            let granted = await self.ensureAuthorized()
            guard self.scheduledReplacementGenerations[idPrefix] == generation else {
                completion?(.superseded)
                return
            }
            guard granted else {
                logger.debug("not authorized; skipping schedule", metadata: ["prefix": idPrefix])
                self.scheduledReplacementGenerations.removeValue(forKey: idPrefix)
                completion?(.notAuthorized)
                return
            }

            let now = Date()
            var firstFailure: String?
            for notification in notifications where notification.fireDate > now {
                guard self.scheduledReplacementGenerations[idPrefix] == generation else {
                    self.client.removePending(addedIDs)
                    completion?(.superseded)
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.body = notification.body
                content.sound = notification.soundEnabled ? .default : nil

                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, notification.fireDate.timeIntervalSince(now)),
                    repeats: false)
                let request = UNNotificationRequest(
                    identifier: "\(requestPrefix)\(generation.uuidString)-\(notification.id)",
                    content: content,
                    trigger: trigger)
                do {
                    try await self.client.add(request)
                    addedIDs.append(request.identifier)
                    guard self.scheduledReplacementGenerations[idPrefix] == generation else {
                        self.client.removePending(addedIDs)
                        completion?(.superseded)
                        return
                    }
                } catch {
                    if firstFailure == nil {
                        firstFailure = error.localizedDescription
                    }
                    logger.error(
                        "failed to schedule",
                        metadata: ["prefix": idPrefix, "error": String(describing: error)])
                }
            }
            if self.scheduledReplacementGenerations[idPrefix] == generation {
                self.scheduledReplacementGenerations.removeValue(forKey: idPrefix)
                if let firstFailure {
                    completion?(.failed(firstFailure))
                } else if addedIDs.isEmpty {
                    completion?(.noFutureNotifications)
                } else {
                    completion?(.scheduled(addedIDs.count))
                }
            } else {
                completion?(.superseded)
            }
        }
    }

    // MARK: - Private

    private func ensureAuthorizationTask() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let task = Task { @MainActor in
            await self.requestAuthorization()
        }
        self.authorizationTask = task
        return task
    }

    private func ensureAuthorized() async -> Bool {
        await self.ensureAuthorizationTask().value
    }

    private func requestAuthorization() async -> Bool {
        if let existing = await self.notificationAuthorizationStatus() {
            if existing == .authorized || existing == .provisional {
                return true
            }
            if existing == .denied {
                return false
            }
        }

        return await self.client.requestAuthorization()
    }

    private func notificationAuthorizationStatus() async -> UNAuthorizationStatus? {
        await self.client.authorizationStatus()
    }

    private static var isRunningUnderTests: Bool {
        // Swift Testing doesn't always set XCTest env vars, and removing XCTest imports from
        // the test target can make NSClassFromString("XCTestCase") return nil. If we're not
        // running inside an app bundle, treat it as "tests/headless" to avoid crashes when
        // accessing UNUserNotificationCenter.
        if Bundle.main.bundleURL.pathExtension != "app" { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["TESTING_LIBRARY_VERSION"] != nil { return true }
        if env["SWIFT_TESTING"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
}
