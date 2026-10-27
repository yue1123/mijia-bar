import ServiceManagement
import SwiftUI

@main
struct MijiaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)

        Window("MijiaBar 设置", id: "settings") {
            SettingsView(store: delegate.store)
        }
        .defaultSize(width: 720, height: 540)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// 菜单栏图标：有设备开着就是实心灯泡，全关是线条灯泡。
private struct MenuBarLabel: View {
    @ObservedObject var store: DeviceStore

    var body: some View {
        Image(nsImage: bulbIcon(on: store.states.values.contains(.on), size: 18))
    }
}

/// Tabler Icons（MIT，Paweł Kuna）的 bulb / bulb-filled，照 24×24 的 SVG 路径画成 size pt 的模板图，跟着前景色变深浅。
func bulbIcon(on: Bool, size: CGFloat) -> NSImage {
    let scale = size / 24
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
    /// 圆心 (cx, cy) 上从点 a 画到点 b 的圆弧；clockwise 是按数值角度递减（flipped 画布里看是逆时针）。
    func arc(_ path: NSBezierPath, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
             from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat), clockwise: Bool) {
        func angle(_ q: (CGFloat, CGFloat)) -> CGFloat { atan2(q.1 - cy, q.0 - cx) * 180 / .pi }
        path.appendArc(withCenter: p(cx, cy), radius: r * scale,
                       startAngle: angle(a), endAngle: angle(b), clockwise: clockwise)
    }

    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        NSColor.black.set()
        let stroke = NSBezierPath()
        // 光线：M3 12h1m8 -9v1m8 8h1m-15.4 -6.4l.7 .7m12.1 -.7l-.7 .7
        for (from, to) in [((3, 12), (4, 12)), ((12, 3), (12, 4)), ((20, 12), (21, 12)),
                           ((5.6, 5.6), (6.3, 6.3)), ((18.4, 5.6), (17.7, 6.3))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
            stroke.move(to: p(from.0, from.1))
            stroke.line(to: p(to.0, to.1))
        }
        if on {
            // 灯泡：半径 6 的圆在 y=17 处截平；灯头：顶边圆角 1，底部半径 3 的半圆
            let fill = NSBezierPath()
            let dx: CGFloat = 11.squareRoot()  // 半径 6 的圆在 y=17（离圆心 5）处的半弦长
            arc(fill, 12, 12, 6, from: (12 - dx, 17), to: (12 + dx, 17), clockwise: false)
            fill.close()
            fill.move(to: p(12, 18))
            fill.appendArc(from: p(15, 18), to: p(15, 19), radius: scale)
            arc(fill, 12, 19, 3, from: (15, 19), to: (9, 19), clockwise: false)
            fill.appendArc(from: p(9, 18), to: p(12, 18), radius: scale)
            fill.close()
            fill.fill()
        } else {
            // 灯泡：M9 16a5 5 0 1 1 6 0a3.5 3.5 0 0 0 -1 3a2 2 0 0 1 -4 0a3.5 3.5 0 0 0 -1 -3
            // 两段 3.5 的弧圆心按 SVG 端点参数算出来是 (12 ± 5.4623, 18.4874)
            stroke.move(to: p(9, 16))
            arc(stroke, 12, 12, 5, from: (9, 16), to: (15, 16), clockwise: false)
            arc(stroke, 17.4623, 18.4874, 3.5, from: (15, 16), to: (14, 19), clockwise: true)
            arc(stroke, 12, 19, 2, from: (14, 19), to: (10, 19), clockwise: false)
            arc(stroke, 6.5377, 18.4874, 3.5, from: (10, 19), to: (9, 16), clockwise: true)
            // 灯头上的横线：M9.7 17l4.6 0
            stroke.move(to: p(9.7, 17))
            stroke.line(to: p(14.3, 17))
        }
        stroke.lineWidth = 2 * scale
        stroke.lineCapStyle = .round
        stroke.lineJoinStyle = .round
        stroke.stroke()
        return true
    }
    image.isTemplate = true
    return image
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = DeviceStore()
    private var monitor: PowerMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = store
        monitor = PowerMonitor(
            onSleep: { await store.handleSleep() },
            onEvent: { event, on in Task { await store.handle(event, on: on) } }
        )
        // 面板是点开才创建的，它的 .task 刷新不到；菜单栏图标一启动就要知道灯亮没亮
        Task { await store.refresh() }
    }
}

struct MenuView: View {
    @ObservedObject var store: DeviceStore
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("灯光").font(.title3.bold())
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !store.devices.isEmpty {
                    IconButton(systemImage: "arrow.clockwise", help: "刷新状态") { refresh() }
                        .disabled(refreshing)
                }
                IconButton(systemImage: "gearshape", help: "设置") { openSettings() }
            }

            if store.devices.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    ForEach(store.devices) { device in
                        DeviceTile(device: device, state: store.states[device.id] ?? .unknown,
                                   toggle: { on in Task { await store.setPower(on, for: device) } },
                                   openSettings: openSettings)
                    }
                }
            }

            if let event = store.lastEvent {
                Label("上次 \(event)", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 230)
        .task { refresh() }
    }

    private var summary: String {
        guard !store.devices.isEmpty else { return "还没有添加灯" }
        let on = store.devices.filter { store.states[$0.id] == .on }.count
        return "\(store.devices.count) 盏灯 · " + (on == 0 ? "全部熄灭" : on == store.devices.count ? "全部亮着" : "\(on) 盏亮着")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "lightbulb.slash").font(.title).foregroundStyle(.secondary)
            Text("还没有添加灯").font(.headline)
            Text("用米家 App 扫码，导入账号下的 Wi-Fi 灯")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("扫码添加") {
                store.importRequested = true
                openSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func refresh() {
        refreshing = true
        Task {
            await store.refresh()
            refreshing = false
        }
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate()
    }
}

private struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 26)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// 「家庭」App 样式的磁贴：开时亮白底、图标上色，关时半透明暗底。整块可点，右键有菜单。
private struct DeviceTile: View {
    let device: Device
    let state: PowerState
    let toggle: (Bool) -> Void
    let openSettings: () -> Void
    @State private var hovering = false

    private var isOn: Bool { state == .on }

    var body: some View {
        Button { toggle(!isOn) } label: {
            HStack(spacing: 8) {
                DeviceIcon(kind: device.kind, isOn: isOn, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(status)
                        .font(.system(size: 11)).foregroundStyle(statusColor).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(isOn ? Color.black : Color.primary)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(isOn ? 0.15 : 0), radius: 3, y: 1)
            .overlay(alignment: .topTrailing) {
                if device.offOnSleep || device.onOnWake {
                    Image(systemName: device.trigger.symbol)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isOn ? Color.black.opacity(0.3) : Color.secondary.opacity(0.6))
                        .padding(7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(state == .unknown)
        .onHover { hovering = $0 }
        .help(help)
        .contextMenu {
            Button(isOn ? offAction : onAction) { toggle(!isOn) }
            Button("设置…", action: openSettings)
        }
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private var background: Color {
        isOn ? Color.white.opacity(0.95) : Color.primary.opacity(hovering ? 0.12 : 0.07)
    }

    // 灯说「亮着 / 开灯」，插座和开关还是「开启 / 打开」
    private var isLight: Bool { device.kind == .light }
    private var onAction: String { isLight ? "开灯" : "打开" }
    private var offAction: String { isLight ? "关灯" : "关闭" }

    private var status: String {
        guard isLight else { return state.label }
        switch state {
        case .on: return "亮着"
        case .off: return "已熄灭"
        default: return state.label
        }
    }

    private var statusColor: Color {
        if case .failed = state { return .red }
        return isOn ? Color.black.opacity(0.5) : .secondary
    }

    /// 悬停提示：出错原因，或者自动化规则。
    private var help: String {
        if case .failed(let message) = state { return message }
        return device.automationSummary.isEmpty ? "点一下" + (isOn ? offAction : onAction) : "自动：" + device.automationSummary
    }
}

/// 圆形设备图标，菜单栏面板和设置窗口共用。
struct DeviceIcon: View {
    let kind: DeviceKind
    let isOn: Bool
    let size: CGFloat

    var body: some View {
        Group {
            if kind == .light {
                Image(nsImage: bulbIcon(on: isOn, size: size * 0.7))
            } else {
                Image(systemName: isOn ? kind.symbolOn : kind.symbolOff)
                    .font(.system(size: size * 0.47, weight: .semibold))
            }
        }
        .foregroundStyle(isOn ? kind.color : Color.secondary)
        .frame(width: size, height: size)
        .background(isOn ? kind.color.opacity(0.16) : Color.primary.opacity(0.08), in: Circle())
    }
}

enum DeviceKind {
    case light, plug, toggleSwitch

    /// 灯用 bulbIcon 画，这两个只给插座和开关用。
    var symbolOn: String { [.plug: "powerplug.fill", .toggleSwitch: "switch.2"][self]! }
    var symbolOff: String { [.plug: "powerplug", .toggleSwitch: "switch.2"][self]! }
    var color: Color { [.light: Color.orange, .plug: Color.green, .toggleSwitch: Color.blue][self]! }
}

extension Device {
    /// 按型号猜：插座、开关，其余当灯。
    var kind: DeviceKind {
        let model = model ?? ""
        if model.contains("plug") || model.contains("outlet") { return .plug }
        if model.contains("switch") { return .toggleSwitch }
        return .light
    }

    /// 「锁屏时关闭，解锁时恢复」；没开自动化是空串。
    var automationSummary: String {
        [offOnSleep ? "\(trigger.offEvent)时关闭" : nil, onOnWake ? "\(trigger.onEvent)时恢复" : nil]
            .compactMap { $0 }.joined(separator: "，")
    }
}

extension Trigger {
    var symbol: String { ["moon.fill", "display", "lock.fill"][Self.allCases.firstIndex(of: self)!] }
}

extension PowerState {
    var label: String {
        switch self {
        case .unknown: "正在更新…"
        case .on: "开启"
        case .off: "关闭"
        case .failed: "无响应"
        }
    }
}
