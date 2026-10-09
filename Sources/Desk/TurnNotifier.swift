import AppKit
import Foundation
import UserNotifications

private let threadUserInfoKey = "thread"

@MainActor
protocol TurnNotifier: AnyObject {
    /// Called when the user clicks a notification, after the app is activated.
    var onOpen: (@MainActor (Thread.ID) -> Void)? { get set }
    func turnFinished(threadID: Thread.ID, title: String, body: String)
    func waitingForApproval(threadID: Thread.ID, title: String, body: String)
    func setBadge(_ count: Int)
}

/// For `swift run` and tests, where there is no bundle to notify as.
@MainActor
final class NoTurnNotifier: TurnNotifier {
    var onOpen: (@MainActor (Thread.ID) -> Void)?
    func turnFinished(threadID _: Thread.ID, title _: String, body _: String) {}
    func waitingForApproval(threadID _: Thread.ID, title _: String, body _: String) {}
    func setBadge(_: Int) {}
}

@MainActor
final class SystemTurnNotifier: NSObject, TurnNotifier, UNUserNotificationCenterDelegate {
    var onOpen: (@MainActor (Thread.ID) -> Void)?

    /// `UNUserNotificationCenter` crashes in a process without a bundle identifier.
    static func ifBundled() -> any TurnNotifier {
        guard Bundle.main.bundleIdentifier != nil else { return NoTurnNotifier() }
        return SystemTurnNotifier()
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func turnFinished(threadID: Thread.ID, title: String, body: String) {
        post(threadID: threadID, title: title, body: body)
    }

    func waitingForApproval(threadID: Thread.ID, title: String, body: String) {
        post(threadID: threadID, title: title, body: body)
    }

    private func post(threadID: Thread.ID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [threadUserInfoKey: threadID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            // The first request shows the system prompt; later ones return the saved answer.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    func setBadge(_ count: Int) {
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let text = response.notification.request.content.userInfo[threadUserInfoKey] as? String,
              let id = UUID(uuidString: text) else { return }
        await MainActor.run {
            NSApplication.shared.activate()
            onOpen?(id)
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}
