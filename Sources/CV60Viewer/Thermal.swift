import Foundation
import UserNotifications

/// Camera thermal levels as reported in live-view frames (resp[20]) — same meaning as the Android app.
enum ThermalLevel: UInt8 {
    case normal = 0, hot = 1, overheat = 2, cold = 3

    /// Notification text; nil when there is nothing to tell the user.
    var alert: (title: String, body: String)? {
        switch self {
        case .normal: return nil
        case .hot: return ("Camera is getting hot", "Disconnect the camera and let it cool down before reconnecting.")
        case .overheat: return ("Camera overheated", "Streaming stopped and the camera was powered off. Let it cool down before reconnecting.")
        case .cold: return ("Camera is very cold", "Camera functionality may be impaired in extremely low temperatures.")
        }
    }
}

/// Reports each thermal level change once, so a camera that stays hot doesn't spam notifications.
struct ThermalMonitor {
    private(set) var level = ThermalLevel.normal

    mutating func update(_ raw: UInt8) -> ThermalLevel? {
        guard let new = ThermalLevel(rawValue: raw), new != level else { return nil }
        level = new
        return new
    }
}

/// macOS notifications. Only available inside the .app bundle (a bare SwiftPM binary has no bundle identifier).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted { NSLog("[CV60] notifications not allowed: %@", error?.localizedDescription ?? "denied") }
        }
    }

    func post(title: String, body: String) {
        guard available else { NSLog("[CV60] %@ — %@", title, body); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show the banner even while our app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
