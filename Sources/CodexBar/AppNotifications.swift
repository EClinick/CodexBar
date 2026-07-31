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

@MainActor
final class AppNotifications {
    static let shared = AppNotifications()

    private let centerProvider: @Sendable () -> UNUserNotificationCenter
    private let logger = CodexBarLog.logger(LogCategories.notifications)
    private var authorizationTask: Task<Bool, Never>?
    private var scheduledReplacementGenerations: [String: UUID] = [:]

    init(centerProvider: @escaping @Sendable () -> UNUserNotificationCenter = { UNUserNotificationCenter.current() }) {
        self.centerProvider = centerProvider
    }

    func requestAuthorizationOnStartup() {
        guard !Self.isRunningUnderTests else { return }
        _ = self.ensureAuthorizationTask()
    }

    func post(
        idPrefix: String,
        title: String,
        body: String,
        badge: NSNumber? = nil,
        soundEnabled: Bool = true)
    {
        guard !Self.isRunningUnderTests else { return }
        let center = self.centerProvider()
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
                try await center.add(request)
            } catch {
                let errorText = String(describing: error)
                logger.error("failed to post", metadata: ["prefix": idPrefix, "error": errorText])
            }
        }
    }

    func replaceScheduled(
        idPrefix: String,
        notifications: [ScheduledAppNotification])
    {
        guard !Self.isRunningUnderTests else { return }
        let center = self.centerProvider()
        let requestPrefix = "codexbar-\(idPrefix)-"
        let logger = self.logger
        let generation = UUID()
        self.scheduledReplacementGenerations[idPrefix] = generation

        Task { @MainActor in
            var addedIDs: [String] = []
            let existingIDs = await self.pendingNotificationIdentifiers(center: center)
                .filter { $0.hasPrefix(requestPrefix) }
            guard self.scheduledReplacementGenerations[idPrefix] == generation else { return }
            if !existingIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: existingIDs)
            }

            guard !notifications.isEmpty else {
                self.scheduledReplacementGenerations.removeValue(forKey: idPrefix)
                return
            }
            let granted = await self.ensureAuthorized()
            guard self.scheduledReplacementGenerations[idPrefix] == generation else { return }
            guard granted else {
                logger.debug("not authorized; skipping schedule", metadata: ["prefix": idPrefix])
                self.scheduledReplacementGenerations.removeValue(forKey: idPrefix)
                return
            }

            let now = Date()
            for notification in notifications where notification.fireDate > now {
                guard self.scheduledReplacementGenerations[idPrefix] == generation else {
                    center.removePendingNotificationRequests(withIdentifiers: addedIDs)
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
                    try await center.add(request)
                    addedIDs.append(request.identifier)
                    guard self.scheduledReplacementGenerations[idPrefix] == generation else {
                        center.removePendingNotificationRequests(withIdentifiers: addedIDs)
                        return
                    }
                } catch {
                    logger.error(
                        "failed to schedule",
                        metadata: ["prefix": idPrefix, "error": String(describing: error)])
                }
            }
            if self.scheduledReplacementGenerations[idPrefix] == generation {
                self.scheduledReplacementGenerations.removeValue(forKey: idPrefix)
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

        let center = self.centerProvider()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func notificationAuthorizationStatus() async -> UNAuthorizationStatus? {
        let center = self.centerProvider()
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func pendingNotificationIdentifiers(center: UNUserNotificationCenter) async -> [String] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier))
            }
        }
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
