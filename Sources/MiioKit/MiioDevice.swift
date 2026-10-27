import CommonCrypto
import CryptoKit
import Foundation
import Network

public enum MiioError: LocalizedError {
    case invalidToken
    case unreachable
    case noReply
    case badResponse(String)
    case device(String)

    public var errorDescription: String? {
        switch self {
        case .invalidToken: "token 应为 32 位十六进制"
        case .unreachable: "连不上设备：IP 不对，或者不在同一个局域网"
        case .noReply: "设备收到了握手但不响应命令：多半是 token 不对"
        case .badResponse(let s): "响应格式不对：\(s)"
        case .device(let s): "设备返回错误：\(s)"
        }
    }
}

/// 局域网 miio 协议（UDP 54321）的最小实现。
///
/// 每次调用都先握手拿设备 ID 和时间戳，再发加密的 JSON-RPC。
/// 包头 32 字节：魔数 0x2131、总长度、4 字节保留、设备 ID、时间戳、MD5 校验和；
/// 负载用 AES-128-CBC 加密，key = MD5(token)，iv = MD5(key + token)。
public struct MiioDevice: Sendable {
    public let host: String
    private let token: Data
    private let key: Data
    private let iv: Data
    private let timeout: TimeInterval

    public init(host: String, token: String, timeout: TimeInterval = 3) throws {
        guard let t = Data(hex: token), t.count == 16 else { throw MiioError.invalidToken }
        self.host = host
        self.token = t
        key = Data(Insecure.MD5.hash(data: t))
        iv = Data(Insecure.MD5.hash(data: key + t))
        self.timeout = timeout
    }

    public func info() async throws -> [String: Any] {
        guard let result = try await call("miIO.info", params: []) as? [String: Any] else {
            throw MiioError.badResponse("miIO.info 不是对象")
        }
        return result
    }

    public func getPower(siid: Int, piid: Int) async throws -> Bool {
        let item = try await property("get_properties", ["did": "power", "siid": siid, "piid": piid])
        guard let value = item["value"] as? Bool else {
            throw MiioError.badResponse("属性 \(siid)/\(piid) 不是开关（布尔值）")
        }
        return value
    }

    public func setPower(_ on: Bool, siid: Int, piid: Int) async throws {
        _ = try await property("set_properties", ["did": "power", "siid": siid, "piid": piid, "value": on])
    }

    private func property(_ method: String, _ param: [String: Any]) async throws -> [String: Any] {
        guard let item = (try await call(method, params: [param]) as? [[String: Any]])?.first else {
            throw MiioError.badResponse("\(method) 的结果不是数组")
        }
        if let code = item["code"] as? Int, code != 0 {
            throw MiioError.device("属性错误码 \(code)")
        }
        return item
    }

    public func call(_ method: String, params: [Any]) async throws -> Any {
        guard let hello = try await exchange(Self.hello) else { throw MiioError.unreachable }
        let header = [UInt8](hello)
        guard header.count >= 32, header[0] == 0x21, header[1] == 0x31 else {
            throw MiioError.badResponse("握手响应不是 miio 包")
        }
        let deviceID = UInt32(bigEndian: header[8..<12])
        let stamp = UInt32(bigEndian: header[12..<16])

        let id = Int.random(in: 1...999_999)
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        guard let reply = try await exchange(packet(payload, deviceID: deviceID, stamp: stamp &+ 1)) else {
            throw MiioError.noReply
        }
        let json = try decode(reply)
        if let error = json["error"] { throw MiioError.device("\(error)") }
        guard json["id"] as? Int == id, let result = json["result"] else {
            throw MiioError.badResponse("缺少 result 或 id 对不上")
        }
        return result
    }

    private static let hello = Data([0x21, 0x31, 0x00, 0x20] + [UInt8](repeating: 0xFF, count: 28))

    /// 给本机所在网段的每个地址发握手包，收集回包：设备 ID → IP。
    /// 不用广播：实测米家设备（或路由器）不回广播握手，只回单播。
    public static func discover(timeout: TimeInterval = 2) async -> [UInt32: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: discoverBlocking(timeout)) }
        }
    }

    private static func discoverBlocking(_ timeout: TimeInterval) -> [UInt32: String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let packet = [UInt8](hello)
        for var address in subnetHosts() {
            address.sin_port = UInt16(54321).bigEndian
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [UInt32: String] = [:]
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date.now + timeout
        while Date.now < deadline {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count >= 32, buffer[0] == 0x21, buffer[1] == 0x31 else { continue }
            let deviceID = UInt32(bigEndian: buffer[8..<12])
            guard deviceID != 0xFFFF_FFFF else { continue }  // 自己发出去的握手包
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            found[deviceID] = String(cString: ip)
        }
        return found
    }

    /// 本机各 IPv4 局域网接口所在网段的全部主机地址，跳过本机；网段大于 /22 的不扫。
    private static func subnetHosts() -> [sockaddr_in] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [sockaddr_in] = []
        var cursor = head
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  entry.ifa_addr?.pointee.sa_family == sa_family_t(AF_INET),
                  let address = entry.ifa_addr, let netmask = entry.ifa_netmask else { continue }
            let own = UInt32(bigEndian: address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            let mask = UInt32(bigEndian: netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            guard mask.nonzeroBitCount >= 22 else { continue }
            let network = own & mask
            for host in 1..<(~mask) where network | host != own {
                var target = sockaddr_in()
                target.sin_family = sa_family_t(AF_INET)
                target.sin_addr.s_addr = (network | host).bigEndian
                result.append(target)
            }
        }
        return result
    }

    private func packet(_ payload: Data, deviceID: UInt32, stamp: UInt32) throws -> Data {
        let encrypted = try crypt(CCOperation(kCCEncrypt), payload)
        var header = Data([0x21, 0x31])
        header += bigEndian(UInt16(32 + encrypted.count))
        header += bigEndian(UInt32(0))
        header += bigEndian(deviceID)
        header += bigEndian(stamp)
        return header + Data(Insecure.MD5.hash(data: header + token + encrypted)) + encrypted
    }

    private func decode(_ reply: Data) throws -> [String: Any] {
        let bytes = [UInt8](reply)
        guard bytes.count > 32, bytes[0] == 0x21, bytes[1] == 0x31 else {
            throw MiioError.badResponse("不是 miio 包")
        }
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 32, length <= bytes.count else { throw MiioError.badResponse("长度字段不对") }
        let encrypted = Data(bytes[32..<length])
        guard Data(Insecure.MD5.hash(data: Data(bytes[0..<16]) + token + encrypted)) == Data(bytes[16..<32]) else {
            throw MiioError.badResponse("校验和不对")
        }
        var plain = try crypt(CCOperation(kCCDecrypt), encrypted)
        while plain.last == 0 { plain.removeLast() }
        guard let json = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw MiioError.badResponse("负载不是 JSON 对象")
        }
        return json
    }

    private func crypt(_ op: CCOperation, _ input: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, kCCKeySizeAES128, v.baseAddress,
                                inp.baseAddress, input.count, out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MiioError.badResponse("AES 失败（\(status)）") }
        return output.prefix(moved)
    }

    /// 发一个 UDP 包、等一个回包；超时返回 nil。
    private func exchange(_ packet: Data) async throws -> Data? {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 54321, using: .udp)
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            let finish = { (result: Result<Data?, Error>) in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state { finish(.failure(error)) }
            }
            connection.start(queue: .global())
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error { finish(.failure(error)) }
            })
            connection.receiveMessage { data, _, _, _ in
                if let data, !data.isEmpty { finish(.success(data)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.success(nil)) }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

private extension UInt32 {
    init(bigEndian bytes: ArraySlice<UInt8>) {
        self = bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

private extension Data {
    init?(hex: String) {
        let chars = Array(hex.trimmingCharacters(in: .whitespaces))
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
