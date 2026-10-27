import AppKit
import IOKit.pwr_mgt

// IOKit 的这几个消息是宏，Swift 导入不进来，按 IOMessage.h 手写。
private let kCanSystemSleep: UInt32 = 0xE000_0270
private let kSystemWillSleep: UInt32 = 0xE000_0280

/// 睡眠用 IOKit：收到「即将睡眠」后等 `onSleep` 跑完才放行，关闭命令才来得及发出去。
/// 唤醒用 NSWorkspace 的 didWake：它只在真正唤醒时发，Power Nap 这类后台唤醒不发。
/// 息屏 / 亮屏用 NSWorkspace 的 screensDidSleep / screensDidWake。
/// 锁屏 / 解锁用分布式通知 com.apple.screenIsLocked / screenIsUnlocked（没有公开常量，系统一直这么发）。
/// 除睡眠外的事件都交给 `onEvent(时机, 是否是「开」的那一侧)`。
final class PowerMonitor {
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let onSleep: () async -> Void

    init(onSleep: @escaping () async -> Void, onEvent: @escaping (Trigger, Bool) -> Void) {
        self.onSleep = onSleep
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notifyPort, { refcon, _, type, argument in
            guard let refcon else { return }
            Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, Int(bitPattern: argument))
        }, &notifier)
        IONotificationPortSetDispatchQueue(notifyPort, .main)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in onEvent(.sleep, true) }
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in onEvent(.display, false) }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in onEvent(.display, true) }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in onEvent(.lock, false) }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in onEvent(.lock, true) }
    }

    private func handle(_ type: UInt32, _ notificationID: Int) {
        switch type {
        case kCanSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case kSystemWillSleep:
            Task { @MainActor in
                await onSleep()
                IOAllowPowerChange(rootPort, notificationID)
            }
        default:
            break
        }
    }
}
