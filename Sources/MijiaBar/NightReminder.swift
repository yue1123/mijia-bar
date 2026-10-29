import Foundation
import UserNotifications

/// 天黑提醒走系统通知：点通知本身或「开灯」按钮，就打开通知里列的那几台。
/// `swift run` 跑起来的不是 .app，没有 bundle ID，碰 UNUserNotificationCenter 会崩，这时什么都不做。
@MainActor
final class NightReminder: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "nightfall"
    private static let turnOnAction = "turnOn"

    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    /// 第一次调用时系统弹授权框，之后直接返回。开了「天黑开灯」的设备才需要。
    static func requestAuthorization() {
        Task { _ = try? await center?.requestAuthorization(options: [.alert, .sound]) }
    }

    private let store: DeviceStore

    init(store: DeviceStore) {
        self.store = store
        super.init()
        guard let center = Self.center else { return }
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.turnOnAction, title: "开灯")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [action], intentIdentifiers: [])])
    }

    func remind(_ devices: [Device]) {
        guard let center = Self.center else { return }
        let content = UNMutableNotificationContent()
        content.title = "天黑了"
        content.body = "\(devices.map(\.name).joined(separator: "、")) 还关着，点这里开灯"
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["devices": devices.map(\.id.uuidString)]
        // 同一个 identifier，新提醒顶掉旧的，通知中心里不会堆一串
        center.add(UNNotificationRequest(identifier: Self.category, content: content, trigger: nil))
    }

    /// 菜单栏 App 一直算在前台，不处理的话通知不弹横幅
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let ids = response.notification.request.content.userInfo["devices"] as? [String] ?? []
        await turnOn(ids)
    }

    private func turnOn(_ ids: [String]) async {
        for device in store.devices where ids.contains(device.id.uuidString) {
            await store.setPower(true, for: device)
        }
    }
}
