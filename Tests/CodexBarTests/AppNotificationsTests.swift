import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct AppNotificationsTests {
    @Test
    func `scheduled replacement reports only after the request is accepted`() async throws {
        let client = NotificationClientSpy()
        let notifications = AppNotifications(
            client: client.makeClient(),
            suppressesDeliveryUnderTests: false)
        let result = ReplacementResultProbe()

        notifications.replaceScheduled(
            idPrefix: "test-scheduled",
            notifications: [Self.notification()],
            completion: { result.record($0) })

        #expect(try await result.wait() == .scheduled(1))
        #expect(client.addedIdentifiers.count == 1)
    }

    @Test
    func `scheduled replacement reports add failure`() async throws {
        let client = NotificationClientSpy()
        client.addError = StubFailure()
        let notifications = AppNotifications(
            client: client.makeClient(),
            suppressesDeliveryUnderTests: false)
        let result = ReplacementResultProbe()

        notifications.replaceScheduled(
            idPrefix: "test-failed",
            notifications: [Self.notification()],
            completion: { result.record($0) })

        guard case .failed = try await result.wait() else {
            Issue.record("Expected the injected notification-center failure to be reported")
            return
        }
    }

    @Test
    func `scheduled replacement reports when every fire date has passed`() async throws {
        let client = NotificationClientSpy()
        let notifications = AppNotifications(
            client: client.makeClient(),
            suppressesDeliveryUnderTests: false)
        let result = ReplacementResultProbe()

        notifications.replaceScheduled(
            idPrefix: "test-past",
            notifications: [Self.notification(fireDate: Date().addingTimeInterval(-1))],
            completion: { result.record($0) })

        #expect(try await result.wait() == .noFutureNotifications)
        #expect(client.addedIdentifiers.isEmpty)
    }

    @Test
    func `newer replacement supersedes an in flight schedule`() async throws {
        let client = NotificationClientSpy()
        client.suspendFirstPendingLookup = true
        let notifications = AppNotifications(
            client: client.makeClient(),
            suppressesDeliveryUnderTests: false)
        let firstResult = ReplacementResultProbe()
        let secondResult = ReplacementResultProbe()

        notifications.replaceScheduled(
            idPrefix: "test-generation",
            notifications: [Self.notification(id: "first")],
            completion: { firstResult.record($0) })
        try await client.waitForFirstPendingLookup()

        notifications.replaceScheduled(
            idPrefix: "test-generation",
            notifications: [Self.notification(id: "second")],
            completion: { secondResult.record($0) })

        #expect(try await secondResult.wait() == .scheduled(1))
        client.releaseFirstPendingLookup()
        #expect(try await firstResult.wait() == .superseded)
    }

    @Test
    func `superseded add failure still completes the older replacement`() async throws {
        let client = NotificationClientSpy()
        client.suspendFirstAdd = true
        client.firstAddError = StubFailure()
        let notifications = AppNotifications(
            client: client.makeClient(),
            suppressesDeliveryUnderTests: false)
        let firstResult = ReplacementResultProbe()
        let secondResult = ReplacementResultProbe()

        notifications.replaceScheduled(
            idPrefix: "test-add-generation",
            notifications: [Self.notification(id: "first")],
            completion: { firstResult.record($0) })
        try await client.waitForFirstAdd()

        notifications.replaceScheduled(
            idPrefix: "test-add-generation",
            notifications: [Self.notification(id: "second")],
            completion: { secondResult.record($0) })

        #expect(try await secondResult.wait() == .scheduled(1))
        client.releaseFirstAdd()
        #expect(try await firstResult.wait() == .superseded)
    }

    @Test
    func `explicit authorization preparation observes settings changes`() async {
        let client = NotificationClientSpy()
        client.authorizationStatuses = [.denied, .authorized]
        let notifications = AppNotifications(
            client: client.makeClient(),
            suppressesDeliveryUnderTests: false)

        #expect(await notifications.prepareAuthorization() == false)
        #expect(await notifications.prepareAuthorization() == true)
        #expect(client.authorizationStatusReadCount == 2)
    }

    private static func notification(
        id: String = "credit",
        fireDate: Date = Date().addingTimeInterval(60)) -> ScheduledAppNotification
    {
        ScheduledAppNotification(
            id: id,
            title: "Test",
            body: "Injected notification-center client",
            fireDate: fireDate,
            soundEnabled: false)
    }
}

@MainActor
private final class NotificationClientSpy {
    var authorizationStatuses: [UNAuthorizationStatus] = [.authorized]
    var addError: Error?
    var firstAddError: Error?
    var suspendFirstPendingLookup = false
    var suspendFirstAdd = false
    private(set) var authorizationStatusReadCount = 0
    private(set) var addedIdentifiers: [String] = []
    private(set) var removedIdentifiers: [String] = []
    private var pendingLookupCount = 0
    private var firstPendingLookupReleased = false
    private var addCount = 0
    private var firstAddReleased = false

    func makeClient() -> AppNotificationCenterClient {
        AppNotificationCenterClient(
            authorizationStatus: {
                self.authorizationStatusReadCount += 1
                if self.authorizationStatuses.count > 1 {
                    return self.authorizationStatuses.removeFirst()
                }
                return self.authorizationStatuses.first
            },
            requestAuthorization: { true },
            pendingIdentifiers: {
                self.pendingLookupCount += 1
                if self.suspendFirstPendingLookup, self.pendingLookupCount == 1 {
                    while !self.firstPendingLookupReleased {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                return []
            },
            removePending: { identifiers in
                self.removedIdentifiers.append(contentsOf: identifiers)
            },
            add: { request in
                self.addCount += 1
                if self.suspendFirstAdd, self.addCount == 1 {
                    while !self.firstAddReleased {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    if let firstAddError = self.firstAddError {
                        throw firstAddError
                    }
                }
                if let addError = self.addError {
                    throw addError
                }
                self.addedIdentifiers.append(request.identifier)
            })
    }

    func waitForFirstPendingLookup() async throws {
        let deadline = Date().addingTimeInterval(2)
        while self.pendingLookupCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard self.pendingLookupCount > 0 else { throw TestTimeout() }
    }

    func releaseFirstPendingLookup() {
        self.firstPendingLookupReleased = true
    }

    func waitForFirstAdd() async throws {
        let deadline = Date().addingTimeInterval(2)
        while self.addCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard self.addCount > 0 else { throw TestTimeout() }
    }

    func releaseFirstAdd() {
        self.firstAddReleased = true
    }
}

@MainActor
private final class ReplacementResultProbe {
    private var result: ScheduledAppNotificationReplacementResult?

    func record(_ result: ScheduledAppNotificationReplacementResult) {
        self.result = result
    }

    func wait() async throws -> ScheduledAppNotificationReplacementResult {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let result = self.result { return result }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestTimeout()
    }
}

private struct StubFailure: Error {}
private struct TestTimeout: Error {}
