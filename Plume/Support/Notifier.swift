import AppKit
import Foundation
import Observation
import UserNotifications
import os

/// Delivers system notifications, and remembers which tab the user clicked
/// back to.
///
/// Authorization is requested the first time something actually wants to
/// notify, so a user who never leaves a task running is never asked. A denied
/// or undetermined-then-denied request makes every later post a no-op rather
/// than re-prompting.
@MainActor
@Observable
final class Notifier: NSObject {
    static let shared = Notifier()

    /// Set when the user clicks a notification; `MainWindow` observes it,
    /// moves selection, and clears it.
    var pendingRoute: Route?

    /// Answers "what is the user looking at", so suppression can be decided
    /// without this type reaching into the view tree. `MainWindow` installs it.
    @ObservationIgnored var audience: () -> NotificationAudience = { .inactive }

    @ObservationIgnored private let center: UNUserNotificationCenter?
    @ObservationIgnored private var authorization: Authorization = .unknown
    @ObservationIgnored private var isRequestingAuthorization = false
    /// Posts held while the first authorization request is in flight.
    @ObservationIgnored private var queued: [Request] = []

    struct Route: Equatable {
        var taskID: UUID
        var tabID: UUID
    }

    struct Request {
        var taskID: UUID
        var tabID: UUID
        var title: String
        var body: String
        /// Replaces any still-showing notification with the same identity, so
        /// a chatty tab leaves one entry in Notification Center, not twenty.
        var dedupeKey: String
    }

    private enum Authorization {
        case unknown, granted, denied
    }

    /// The center is unavailable to a process with no bundle identity — the
    /// test host, notably, where `current()` traps. Nil there, and every post
    /// becomes a no-op.
    private override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        center?.delegate = self
    }

    // MARK: - Posting

    /// Posts unless the user is already looking at the tab.
    func notifyIfUnseen(_ request: Request) {
        guard NotificationSuppression.shouldNotify(
            tabID: request.tabID, taskID: request.taskID, audience: audience()
        ) else { return }
        post(request)
    }

    func post(_ request: Request) {
        guard let center else { return }

        switch authorization {
        case .denied:
            return
        case .unknown:
            queued.append(request)
            requestAuthorization()
        case .granted:
            deliver(request, to: center)
        }
    }

    private func requestAuthorization() {
        guard let center, !isRequestingAuthorization else { return }
        isRequestingAuthorization = true

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Log.app.error("Notification authorization failed: \(error, privacy: .public)")
            }
            Task { @MainActor in
                self?.finishAuthorization(granted: granted)
            }
        }
    }

    private func finishAuthorization(granted: Bool) {
        isRequestingAuthorization = false
        authorization = granted ? .granted : .denied

        let pending = queued
        queued.removeAll()
        guard granted, let center else { return }
        for request in pending {
            deliver(request, to: center)
        }
    }

    private func deliver(_ request: Request, to center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = [
            Self.taskIDKey: request.taskID.uuidString,
            Self.tabIDKey: request.tabID.uuidString,
        ]

        center.add(UNNotificationRequest(
            identifier: request.dedupeKey, content: content, trigger: nil
        )) { error in
            guard let error else { return }
            Log.app.error("Could not post notification: \(error, privacy: .public)")
        }
    }

    // MARK: - Routing

    nonisolated private static let taskIDKey = "taskID"
    nonisolated private static let tabIDKey = "tabID"

    nonisolated static func route(from userInfo: [AnyHashable: Any]) -> Route? {
        guard let task = (userInfo[taskIDKey] as? String).flatMap(UUID.init(uuidString:)),
              let tab = (userInfo[tabIDKey] as? String).flatMap(UUID.init(uuidString:))
        else { return nil }
        return Route(taskID: task, tabID: tab)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let route = Self.route(from: userInfo) else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            pendingRoute = route
        }
    }
}
