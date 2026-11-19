import AppKit
import EarshotCore
import UserNotifications

/// Local "Summary ready" notifications. Permission is asked the first time one is needed, never
/// at launch, and a refusal is respected silently.
@MainActor
final class SummaryNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let folderKey = "folder"

    /// Opens the call in a notification that was clicked.
    var onOpen: ((URL) -> Void)?

    /// `UNUserNotificationCenter` needs an app bundle; `swift run` starts a bare executable.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? .current() : nil

    override init() {
        super.init()
        center?.delegate = self
    }

    /// True when notifications were turned off for Earshot in System Settings.
    func isDenied() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    func summaryReady(folder: URL, title: String, summaryMarkdown: String?) {
        post(
            folder: folder, title: "Summary ready — \(title)",
            body: summaryMarkdown.flatMap { SummaryNotice.body(summaryMarkdown: $0) } ?? "Open it in Earshot.")
    }

    func summaryFailed(folder: URL, title: String, error: Error) {
        post(
            folder: folder, title: "Summary failed — \(title)",
            body: "The transcript is saved. " + SummaryNotice.truncate(error.localizedDescription, limit: 140))
    }

    private func post(folder: URL, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.folderKey: folder.path]
        // One notification per call: a regenerated summary replaces the earlier one.
        let request = UNNotificationRequest(identifier: folder.path, content: content, trigger: nil)
        Task {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                guard granted else { return Log.write("notifications not allowed") }
            case .denied:
                return
            default:
                break
            }
            do {
                try await center.add(request)
            } catch {
                Log.write("notification failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the banner even while Earshot is the active app (its window may be closed or behind).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let path = response.notification.request.content.userInfo[Self.folderKey] as? String
        else { return }
        await MainActor.run { self.onOpen?(URL(fileURLWithPath: path)) }
    }
}
