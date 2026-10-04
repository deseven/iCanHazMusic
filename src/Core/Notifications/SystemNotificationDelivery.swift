import Foundation
import UserNotifications

/// Delivers messages through the system's notification center (`UNUserNotificationCenter`).
///
/// - Every message uses the same request identifier, which makes the system replace the notification that is
///   already there instead of adding another one: only the latest message is ever shown.
/// - macOS asks the user for permission the first time something is delivered. If it was refused, nothing is shown.
/// - There is no delegate on purpose: while the app is in front the system shows no banner (the playback block says
///   it all).
/// - The notification center only works for a signed app bundle; from a bare executable (`swift run`, tests) this does
///   nothing.
@MainActor
final class SystemNotificationDelivery: NotificationDelivery {
    private static let requestID = "playback"

    /// Counts the messages, so that one still waiting for the permission doesn't replace a newer one.
    private var latest = 0
    private var loggedDenied = false

    func deliver(_ message: NotificationMessage, cover: Data?) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        latest += 1
        let number = latest
        Task {
            guard await isAllowed(), number == latest else { return }
            await post(message, cover: cover)
        }
    }

    private func isAllowed() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                Log.info("notifications: permission \(granted ? "granted" : "refused")")
                return granted
            } catch {
                Log.error("notifications: can't ask for permission: \(error.localizedDescription)")
                return false
            }
        case .denied:
            if !loggedDenied {
                loggedDenied = true
                Log.info("notifications: turned off for the app in System Settings")
            }
            return false
        @unknown default:
            return false
        }
    }

    private func post(_ message: NotificationMessage, cover: Data?) async {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = message.subtitle
        content.body = message.body
        if let cover, let attachment = Self.attachment(for: cover) { content.attachments = [attachment] }

        let request = UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.error("notifications: can't deliver: \(error.localizedDescription)")
        }
    }

    /// The system only takes images from files; it moves the file away into its own storage.
    private static func attachment(for image: Data) -> UNNotificationAttachment? {
        let isPNG = image.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppConstants.appShortName)-cover-\(UUID().uuidString)")
            .appendingPathExtension(isPNG ? "png" : "jpg")
        do {
            try image.write(to: url)
            return try UNNotificationAttachment(identifier: "cover", url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            Log.error("notifications: can't attach the cover: \(error.localizedDescription)")
            return nil
        }
    }
}
