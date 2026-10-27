import Foundation
import MiioKit
import os
import Security

let log = Logger(subsystem: "me.dh.mijia-bar", category: "app")

struct Device: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "新设备"
    var host = ""
    var siid = 2
    var piid = 1
    var offOnSleep = false
    var onOnWake = false
    var trigger = Trigger.sleep
    /// 导入时才有，用来认出同一台设备、再导入时只更新 IP 和 token
    var did: String?
    var model: String?
}

/// 触发时机按强弱排：睡眠 < 息屏 < 锁屏。
/// 关：强的模式也响应弱的事件（息屏模式睡眠时也关，锁屏模式息屏、睡眠时也关），真睡眠前不一定先息屏、先锁屏，比如合盖。
/// 恢复：锁屏模式只认解锁，亮屏、唤醒时还停在锁屏界面；其余模式唤醒也算，防止亮屏通知没来。
enum Trigger: String, Codable, CaseIterable {
    case sleep, display, lock

    var name: String { ["睡眠 / 唤醒", "息屏 / 亮屏", "锁屏 / 解锁"][level] }
    var offEvent: String { ["睡眠", "息屏", "锁屏"][level] }
    var onEvent: String { ["唤醒", "亮屏", "解锁"][level] }

    private var level: Int { Self.allCases.firstIndex(of: self)! }

    func turnsOff(on event: Trigger) -> Bool { level >= event.level }
    func restores(on event: Trigger) -> Bool { self == .lock ? event == .lock : level >= event.level }
}

// 写在 extension 里才能保留成员初始化器。旧版本存的数据没有 trigger 等字段，缺的取默认值。
extension Device {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Device()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        siid = try c.decodeIfPresent(Int.self, forKey: .siid) ?? d.siid
        piid = try c.decodeIfPresent(Int.self, forKey: .piid) ?? d.piid
        offOnSleep = try c.decodeIfPresent(Bool.self, forKey: .offOnSleep) ?? d.offOnSleep
        onOnWake = try c.decodeIfPresent(Bool.self, forKey: .onOnWake) ?? d.onOnWake
        trigger = try c.decodeIfPresent(Trigger.self, forKey: .trigger) ?? d.trigger
        did = try c.decodeIfPresent(String.self, forKey: .did)
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

enum PowerState: Equatable {
    case unknown, on, off
    case failed(String)
}

/// 设备列表存 UserDefaults，token 单独存钥匙串。
@MainActor
final class DeviceStore: ObservableObject {
    @Published var devices: [Device] { didSet { save() } }
    @Published private(set) var states: [Device.ID: PowerState] = [:]
    @Published private(set) var lastEvent: String?
    /// 设置窗口的扫码导入弹窗；菜单栏面板的空状态也要能打开它，所以放这里而不是视图状态
    @Published var importRequested = false

    private static let key = "devices"

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        devices = data.flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? []
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: Self.key)
    }

    func remove(_ id: Device.ID) {
        Keychain.delete(id.uuidString)
        tokens[id] = nil
        devices.removeAll { $0.id == id }
    }

    /// 钥匙串每台设备只在第一次用到时读一次，之后走内存：每次打开面板都会刷新状态，
    /// 不缓存的话每次都要读钥匙串。
    private var tokens: [Device.ID: String] = [:]

    /// 读不到（授权框被拒、条目不存在）不缓存，下次再试。
    func token(for device: Device) -> String {
        if let token = tokens[device.id] { return token }
        guard let token = Keychain.get(device.id.uuidString) else { return "" }
        tokens[device.id] = token
        return token
    }

    func setToken(_ token: String, for device: Device) {
        tokens[device.id] = token
        if token.isEmpty {
            Keychain.delete(device.id.uuidString)
        } else {
            Keychain.set(token, for: device.id.uuidString)
        }
    }

    private func client(for device: Device) throws -> MiioDevice {
        try MiioDevice(host: device.host, token: token(for: device))
    }

    /// 连不上时扫一遍局域网，按 did 找回换了 IP 的设备，更新 IP 后重试一次。
    private func withClient<T>(_ device: Device, _ body: (MiioDevice) async throws -> T) async throws -> T {
        do {
            return try await body(client(for: device))
        } catch MiioError.unreachable {
            guard let did = device.did.flatMap(UInt32.init), let host = await locate(did), host != device.host,
                  let index = devices.firstIndex(where: { $0.id == device.id }) else { throw MiioError.unreachable }
            log.notice("\(device.name, privacy: .public) 的 IP 从 \(device.host, privacy: .public) 变成了 \(host, privacy: .public)")
            devices[index].host = host
            return try await body(client(for: devices[index]))
        }
    }

    /// 扫描结果缓存 10 秒：几台设备同时连不上、或者唤醒后反复重试时，不用每次都扫。
    private var scan: (at: Date, hosts: [UInt32: String])?
    private var scanning: Task<[UInt32: String], Never>?

    private func locate(_ did: UInt32) async -> String? {
        if let scan, Date.now.timeIntervalSince(scan.at) < 10 { return scan.hosts[did] }
        let task = scanning ?? Task { await MiioDevice.discover() }
        scanning = task
        let hosts = await task.value
        scanning = nil
        scan = (.now, hosts)
        return hosts[did]
    }

    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for device in devices {
                group.addTask { await self.refresh(device) }
            }
        }
    }

    private func refresh(_ device: Device) async {
        do {
            let on = try await withClient(device) { try await $0.getPower(siid: device.siid, piid: device.piid) }
            states[device.id] = on ? .on : .off
        } catch {
            states[device.id] = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func setPower(_ on: Bool, for device: Device) async -> Bool {
        do {
            try await withClient(device) { try await $0.setPower(on, siid: device.siid, piid: device.piid) }
            states[device.id] = on ? .on : .off
            return true
        } catch {
            states[device.id] = .failed(error.localizedDescription)
            log.error("\(device.name, privacy: .public) \(on ? "打开" : "关闭", privacy: .public)失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 已有的设备（按 did 认）只更新 IP 和 token；新设备按型号查开关属性，查不到就留默认的 2 / 1。
    /// 返回查不到开关属性的设备名。
    func importDevices(_ items: [CloudDevice]) async -> [String] {
        let spec = try? await MiotSpec.load()
        var unresolved: [String] = []
        for item in items {
            var device = devices.first { $0.did == item.did } ?? Device(name: item.name)
            let isNew = device.did == nil
            device.did = item.did
            device.host = item.localip ?? ""
            device.model = item.model
            if isNew {
                if let model = item.model, let property = try? await spec?.powerProperty(model: model) {
                    (device.siid, device.piid) = property
                } else {
                    unresolved.append(item.name)
                }
            }
            setToken(item.token ?? "", for: device)
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                devices[index] = device
            } else {
                devices.append(device)
            }
        }
        await refresh()
        return unresolved
    }

    func testConnection(_ device: Device) async -> String {
        do {
            let info = try await withClient(device) { try await $0.info() }
            return "已连上：\(info["model"] as? String ?? "未知型号")"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: 自动开关

    /// 自动关掉时原本开着的设备，等到对应事件再打开；本来就关着的不碰。
    private var toRestore: Set<Device.ID> = []

    /// 系统会等这个函数返回再睡（最多 30 秒），所以每台只试一次。
    func handleSleep() async {
        await turnOff(on: .sleep, attempts: 1)
    }

    func handle(_ event: Trigger, on: Bool) async {
        if on {
            await restore(on: event)
        } else {
            await turnOff(on: event, attempts: 3)
        }
    }

    private func turnOff(on event: Trigger, attempts: Int) async {
        let targets = devices.filter { $0.offOnSleep && $0.trigger.turnsOff(on: event) }
        guard !targets.isEmpty else { return }
        // 先看现在开没开；读不到就按最后一次知道的状态算
        var wereOn: [Device] = []
        for device in targets {
            let isOn = (try? await withClient(device) { try await $0.getPower(siid: device.siid, piid: device.piid) })
                ?? (states[device.id] == .on)
            if isOn { wereOn.append(device) }
        }
        guard !wereOn.isEmpty else { return record(event.offEvent, "灯本来就都关着") }
        toRestore.formUnion(wereOn.map(\.id))
        let done = await apply(false, to: wereOn, attempts: attempts)
        record(event.offEvent, summary("关闭", done: done, total: wereOn.count))
    }

    /// 刚唤醒时网络往往还没连上，多重试几次。先从待恢复里摘掉，唤醒和亮屏前后脚到时不会开两遍。
    private func restore(on event: Trigger) async {
        let targets = devices.filter { $0.onOnWake && $0.trigger.restores(on: event) && toRestore.contains($0.id) }
        guard !targets.isEmpty else { return }
        toRestore.subtract(targets.map(\.id))
        let done = await apply(true, to: targets, attempts: 15)
        record(event.onEvent, summary("打开", done: done, total: targets.count))
    }

    /// 各设备并发，失败每 2 秒重试，最多 `attempts` 次。返回成功的设备名。
    private func apply(_ on: Bool, to targets: [Device], attempts: Int) async -> [String] {
        var done: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for device in targets {
                group.addTask {
                    for attempt in 1...attempts {
                        if await self.setPower(on, for: device) { return (device.name, true) }
                        if attempt < attempts { try? await Task.sleep(for: .seconds(2)) }
                    }
                    return (device.name, false)
                }
            }
            for await (name, ok) in group where ok { done.append(name) }
        }
        return done
    }

    private func summary(_ action: String, done: [String], total: Int) -> String {
        guard !done.isEmpty else { return "\(action)失败" }
        let failed = total - done.count
        return "已\(action)\(done.joined(separator: "、"))" + (failed > 0 ? "，\(failed) 盏失败" : "")
    }

    private func record(_ event: String, _ detail: String) {
        lastEvent = "\(Date.now.formatted(date: .omitted, time: .shortened)) \(event)，\(detail)"
        log.notice("\(self.lastEvent ?? "", privacy: .public)")
    }
}

enum Keychain {
    private static let service = "me.dh.mijia-bar"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
