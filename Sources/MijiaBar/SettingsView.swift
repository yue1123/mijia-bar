import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: DeviceStore
    @State private var selection: Device.ID?

    var body: some View {
        NavigationSplitView {
            List(store.devices, selection: $selection) { device in
                let state = store.states[device.id] ?? .unknown
                HStack(spacing: 8) {
                    DeviceIcon(kind: device.kind, isOn: state == .on, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).lineLimit(1)
                        Text(state == .unknown ? device.host : state.label)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Button("添加", systemImage: "plus") {
                        let device = Device()
                        store.devices.append(device)
                        selection = device.id
                    }
                    .help("手动添加设备")
                    Spacer()
                    Button("导入", systemImage: "qrcode.viewfinder") { store.importRequested = true }
                        .help("扫码导入小米账号下的设备")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let index = store.devices.firstIndex(where: { $0.id == selection }) {
                DeviceEditor(device: $store.devices[index], store: store) {
                    store.remove(store.devices[index].id)
                    selection = store.devices.first?.id
                }
                .id(store.devices[index].id)
            } else {
                ContentUnavailableView {
                    Label(store.devices.isEmpty ? "还没有设备" : "选择一台设备", systemImage: "lightbulb")
                } description: {
                    Text("用米家 App 扫码，导入账号下的 Wi-Fi 设备")
                } actions: {
                    Button("扫码导入") { store.importRequested = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear { selection = selection ?? store.devices.first?.id }
        .sheet(isPresented: $store.importRequested) {
            ImportView(store: store)
        }
    }
}

private struct ImportView: View {
    @ObservedObject var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.loading("正在获取二维码…")
    @State private var candidates: [CloudDevice] = []
    @State private var skipped = 0
    @State private var selected: Set<String> = []
    @State private var attempt = 0

    private enum Phase {
        case loading(String)
        case qrCode(NSImage)
        case list
        case importing
        case done(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扫码导入").font(.headline)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if case .importing = phase { ProgressView().controlSize(.small) }
                Spacer()
                switch phase {
                case .list:
                    Button("取消") { dismiss() }
                    Button("导入") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty)
                case .done:
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                case .failed:
                    Button("取消") { dismiss() }
                    Button("重试") { attempt += 1 }.keyboardShortcut(.defaultAction)
                default:
                    Button("取消") { dismiss() }
                }
            }
        }
        .padding()
        .frame(width: 460, height: 460)
        .task(id: attempt) { await login() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading(let text):
            VStack(spacing: 10) {
                ProgressView()
                Text(text).foregroundStyle(.secondary)
            }
        case .qrCode(let image):
            VStack(spacing: 12) {
                Image(nsImage: image).resizable().interpolation(.none).frame(width: 240, height: 240)
                Text("用米家 App 扫码，在手机上确认登录").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .list, .importing, .done:
            deviceList
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(candidates) { item in
                Toggle(isOn: Binding(
                    get: { selected.contains(item.did) },
                    set: { if $0 { selected.insert(item.did) } else { selected.remove(item.did) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text([item.model, item.localip, store.devices.contains { $0.did == item.did } ? "已添加，会更新 IP 和 token" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled({ if case .list = phase { false } else { true } }())
            if skipped > 0 {
                Text("另有 \(skipped) 台没有局域网 IP（蓝牙或网关子设备），不能直连，已略过。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .done(let message) = phase {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func login() async {
        phase = .loading("正在获取二维码…")
        do {
            let login = MiCloud.Login()
            let qrCode = try await login.requestQRCode()
            guard let image = NSImage(data: qrCode.image) else { throw MiCloud.Failure.badResponse("二维码图片打不开") }
            phase = .qrCode(image)
            let account = try await login.waitForScan(qrCode)
            phase = .loading("已登录，正在读取设备…")
            let all = try await account.devices()
            candidates = all.filter(\.isLocal)
            skipped = all.count - candidates.count
            phase = candidates.isEmpty ? .failed("账号下没有能局域网直连的 Wi-Fi 设备。") : .list
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func run() {
        phase = .importing
        Task {
            let unresolved = await store.importDevices(candidates.filter { selected.contains($0.did) })
            phase = .done("已导入 \(selected.count) 台。"
                + (unresolved.isEmpty ? "" : "\n没查到开关属性：\(unresolved.joined(separator: "、"))，先用了 2 / 1，不对的话在设置里改。"))
        }
    }
}

private struct DeviceEditor: View {
    @Binding var device: Device
    @ObservedObject var store: DeviceStore
    let onDelete: () -> Void
    @State private var token = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var confirmingDelete = false
    @State private var showAdvanced = false

    private var state: PowerState { store.states[device.id] ?? .unknown }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    DeviceIcon(kind: device.kind, isOn: state == .on, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("名称", text: $device.name, prompt: Text("名称"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                        Text([device.model, device.host.isEmpty ? nil : device.host].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(testResult ?? state.label)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .help(testResult ?? state.label)
                    Button(testing ? "测试中…" : "测试") { test() }
                        .disabled(testing)
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("触发时机", selection: $device.trigger) {
                    ForEach(Trigger.allCases, id: \.self) { Text($0.offEvent).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("电脑\(device.trigger.offEvent)时关闭", isOn: $device.offOnSleep)
                Toggle("电脑\(device.trigger.onEvent)时恢复", isOn: $device.onOnWake)
            } header: {
                Text("自动化")
            } footer: {
                Text("只恢复关之前开着的设备。息屏、锁屏模式在真正睡眠时也会关；锁屏模式只在解锁时恢复。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("连接") {
                TextField("IP", text: $device.host, prompt: Text("192.168.1.50"))
                SecureField("token", text: $token, prompt: Text("32 位十六进制"))
                    .onChange(of: token) { _, value in store.setToken(value, for: device) }
            }

            Section {
                DisclosureGroup("高级", isExpanded: $showAdvanced) {
                    TextField("siid", value: $device.siid, format: .number)
                    TextField("piid", value: $device.piid, format: .number)
                    Text("开关属性。导入时按型号自动查好；手动添加的设备可以在 home.miot-spec.com 按型号查，插座、灯多数是 2 / 1。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("删除这台设备", role: .destructive) { confirmingDelete = true }
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .onAppear { token = store.token(for: device) }
        .confirmationDialog("删除「\(device.name)」？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive, action: onDelete)
        } message: {
            Text("钥匙串里的 token 也会一起删掉。之后可以重新扫码导入。")
        }
    }

    private var statusColor: Color {
        if testResult != nil { return .secondary }
        if case .failed = state { return .red }
        return state == .on ? .green : .secondary
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            testResult = await store.testConnection(device)
            testing = false
        }
    }
}
