import Foundation

/// 小米云设备列表里的一台设备。
struct CloudDevice: Identifiable {
    let did: String
    let name: String
    let localip: String?
    let token: String?
    let model: String?

    var id: String { did }

    /// 能局域网直连：有 IP 和 token。蓝牙、网关子设备没有自己的 IP。
    var isLocal: Bool {
        !did.hasPrefix("blt") && !(localip ?? "").isEmpty && token?.count == 32
    }
}

/// miot-spec.org 的公开接口：型号 → spec → 第一个可写的布尔 `on` 属性。
struct MiotSpec {
    private struct Instances: Decodable {
        struct Instance: Decodable { let model: String; let version: Int; let type: String }
        let instances: [Instance]
    }

    private struct Spec: Decodable {
        struct Service: Decodable { let iid: Int; let properties: [Property]? }
        struct Property: Decodable { let iid: Int; let type: String; let format: String; let access: [String] }
        let services: [Service]
    }

    private let instances: [Instances.Instance]

    /// 型号清单有 2MB，一次导入只拉一遍。
    static func load() async throws -> MiotSpec {
        let url = URL(string: "https://miot-spec.org/miot-spec-v2/instances?status=released")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return MiotSpec(instances: try JSONDecoder().decode(Instances.self, from: data).instances)
    }

    func powerProperty(model: String) async throws -> (siid: Int, piid: Int)? {
        guard let type = instances.filter({ $0.model == model }).max(by: { $0.version < $1.version })?.type else {
            return nil
        }
        var components = URLComponents(string: "https://miot-spec.org/miot-spec-v2/instance")!
        components.queryItems = [URLQueryItem(name: "type", value: type)]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let spec = try JSONDecoder().decode(Spec.self, from: data)
        for service in spec.services.sorted(by: { $0.iid < $1.iid }) {
            if let property = service.properties?.first(where: {
                $0.type.contains(":property:on:") && $0.format == "bool" && $0.access.contains("write")
            }) {
                return (service.iid, property.iid)
            }
        }
        return nil
    }
}
