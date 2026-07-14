import Foundation
import UserNotifications

enum FlockNotifications {
    static let focusPaneRequested = Notification.Name("FlockFocusPaneRequested")

    private static var _useNative = false
    private static var useNative: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useNative }
        set { lock.lock(); _useNative = newValue; lock.unlock() }
    }
    /// Debounce: track last notification per pane to suppress duplicates
    private static var lastNotification: [String: (message: String, time: Date)] = [:]
    private static let debounceInterval: TimeInterval = 5.0
    private static let lock = NSLock()

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            useNative = granted
        }
    }

    static func setup() {
        // Check if we already have permission (e.g. from a previous launch)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized {
                useNative = true
            } else if settings.authorizationStatus == .notDetermined {
                requestPermission()
            }
        }
    }

    static func sendCompletion(paneName: String, paneIndex: Int, duration: TimeInterval?) {
        let body = formatDuration(duration)
        send(title: "Flock", body: "\(paneName) — \(body)", key: "pane-\(paneIndex)")
    }

    private static func send(title: String, body: String, key: String) {
        // Debounce: skip if same message for same pane within interval
        let now = Date()
        lock.lock()
        if let last = lastNotification[key],
           last.message == body,
           now.timeIntervalSince(last.time) < debounceInterval {
            lock.unlock()
            return
        }
        lastNotification[key] = (message: body, time: now)
        let shouldNotify = _useNative  // read backing field directly; `useNative` re-locks (NSLock is non-recursive → deadlock)
        lock.unlock()

        if shouldNotify {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private static func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "Completed" }
        let seconds = Int(duration)
        if seconds < 60 {
            return "Completed in \(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 {
            return "Completed in \(minutes)m"
        }
        return "Completed in \(minutes)m \(remainder)s"
    }
}
