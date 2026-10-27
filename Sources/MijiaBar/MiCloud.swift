import CryptoKit
import Foundation

/// 小米云扫码登录，登录后拉取账号下的设备（含局域网 token）。
///
/// 照 Xiaomi-cloud-tokens-extractor（MIT，Piotr Machowski）的 QrCodeXiaomiCloudConnector 重写，
/// 只保留扫码这条路，绕开密码登录的验证码和二次验证。非官方接口、模拟米家 App 的请求，
/// 小米改接口就会失效。只查中国大陆服务器。
enum MiCloud {
    struct QRCode {
        let image: Data
        fileprivate let pollURL: URL
        fileprivate let timeout: TimeInterval
    }

    enum Failure: LocalizedError {
        case badResponse(String)
        case expired

        var errorDescription: String? {
            switch self {
            case .badResponse(let s): "小米服务器返回的数据不对：\(s)"
            case .expired: "二维码过期了，点「重试」重新获取"
            }
        }
    }

    /// 一次登录一个会话，cookie 只在内存里。
    final class Login {
        private let session = URLSession(configuration: .ephemeral)

        func requestQRCode() async throws -> QRCode {
            var components = URLComponents(string: "https://account.xiaomi.com/longPolling/loginUrl")!
            components.queryItems = [
                URLQueryItem(name: "_qrsize", value: "480"),
                URLQueryItem(name: "qs", value: "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
                URLQueryItem(name: "callback", value: "https://sts.api.io.mi.com/sts"),
                URLQueryItem(name: "_hasLogo", value: "false"),
                URLQueryItem(name: "sid", value: "xiaomiio"),
                URLQueryItem(name: "serviceParam", value: ""),
                URLQueryItem(name: "_locale", value: "en_GB"),
                URLQueryItem(name: "_dc", value: String(Int(Date.now.timeIntervalSince1970 * 1000))),
            ]
            let (data, _) = try await session.data(from: components.url!)
            let json = try parseAccountJSON(data)
            guard let qr = (json["qr"] as? String).flatMap(URL.init(string:)),
                  let poll = (json["lp"] as? String).flatMap(URL.init(string:)) else {
                throw Failure.badResponse("没有二维码地址")
            }
            let (image, _) = try await session.data(from: qr)
            return QRCode(image: image, pollURL: poll, timeout: json["timeout"] as? Double ?? 300)
        }

        /// 长轮询到扫码确认，再用返回的 location 换 serviceToken。
        func waitForScan(_ qr: QRCode) async throws -> Account {
            let deadline = Date.now + qr.timeout
            let request = URLRequest(url: qr.pollURL, timeoutInterval: 10)
            var body: Data
            while true {
                guard Date.now < deadline else { throw Failure.expired }
                let data: Data, response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch let error as URLError where error.code == .timedOut {
                    continue
                }
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    body = data
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }

            let json = try parseAccountJSON(body)
            guard let userId = json["userId"], let ssecurity = json["ssecurity"] as? String,
                  let location = (json["location"] as? String).flatMap(URL.init(string:)) else {
                throw Failure.badResponse("登录结果缺字段")
            }
            _ = try await session.data(from: location)
            guard let token = session.configuration.httpCookieStorage?.cookies?.first(where: { $0.name == "serviceToken" })?.value else {
                throw Failure.badResponse("没拿到 serviceToken")
            }
            return Account(userId: "\(userId)", ssecurity: ssecurity, serviceToken: token)
        }

        private func parseAccountJSON(_ data: Data) throws -> [String: Any] {
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "&&&START&&&", with: "")
            guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw Failure.badResponse("不是 JSON 对象")
            }
            return json
        }
    }

    struct Account {
        let userId: String
        fileprivate let ssecurity: String
        fileprivate let serviceToken: String
        private let agent = Account.makeAgent()

        fileprivate init(userId: String, ssecurity: String, serviceToken: String) {
            self.userId = userId
            self.ssecurity = ssecurity
            self.serviceToken = serviceToken
        }

        /// 自己的家庭 + 别人共享的家庭里的全部设备，按 did 去重。
        func devices() async throws -> [CloudDevice] {
            var homes: [(id: String, owner: String)] = []
            let own = try await call("/v2/homeroom/gethome",
                                     #"{"fg": true, "fetch_share": true, "fetch_share_dev": true, "limit": 300, "app_ver": 7}"#)
            for home in result(own)?["homelist"] as? [[String: Any]] ?? [] {
                if let id = home["id"] { homes.append(("\(id)", userId)) }
            }
            let shared = try await call("/v2/user/get_device_cnt", #"{ "fetch_own": true, "fetch_share": true}"#)
            for home in (result(shared)?["share"] as? [String: Any])?["share_family"] as? [[String: Any]] ?? [] {
                if let id = home["home_id"], let owner = home["home_owner"] { homes.append(("\(id)", "\(owner)")) }
            }

            var seen = Set<String>()
            var devices: [CloudDevice] = []
            for home in homes {
                let list = try await call("/v2/home/home_device_list",
                                          #"{"home_owner": \#(home.owner),"home_id": \#(home.id),  "limit": 200,  "get_split_device": true, "support_smart_home": true}"#)
                for d in result(list)?["device_info"] as? [[String: Any]] ?? [] {
                    guard let did = d["did"] as? String, seen.insert(did).inserted else { continue }
                    devices.append(CloudDevice(did: did, name: d["name"] as? String ?? did, localip: d["localip"] as? String,
                                               token: d["token"] as? String, model: d["model"] as? String))
                }
            }
            return devices
        }

        private func result(_ json: [String: Any]) -> [String: Any]? { json["result"] as? [String: Any] }

        private func call(_ path: String, _ data: String) async throws -> [String: Any] {
            let minutes = UInt32(Date.now.timeIntervalSince1970 / 60)
            let nonce = (Data((0..<8).map { _ in UInt8.random(in: 0...255) }) + withUnsafeBytes(of: minutes.bigEndian) { Data($0) })
                .base64EncodedString()
            let params = try Account.encryptedParams(path: path, data: data, nonce: nonce, ssecurity: ssecurity)

            var components = URLComponents(string: "https://api.io.mi.com/app" + path)!
            components.percentEncodedQuery = params.map { "\($0.0)=\(Account.formEncode($0.1))" }.joined(separator: "&")
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            for (field, value) in [
                "Accept-Encoding": "identity",
                "User-Agent": agent,
                "Content-Type": "application/x-www-form-urlencoded",
                "x-xiaomi-protocal-flag-cli": "PROTOCAL-HTTP2",
                "MIOT-ENCRYPT-ALGORITHM": "ENCRYPT-RC4",
                "Cookie": "userId=\(userId); yetAnotherServiceToken=\(serviceToken); serviceToken=\(serviceToken); "
                    + "locale=en_GB; timezone=GMT+02:00; is_daylight=1; dst_offset=3600000; channel=MI_APP_STORE",
            ] {
                request.setValue(value, forHTTPHeaderField: field)
            }

            let (body, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure.badResponse("\(path) HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            return try Account.decrypt(body, nonce: nonce, ssecurity: ssecurity)
        }

        // MARK: 签名与加密（纯函数，和 extractor 的同名函数逐字节一致）

        static func encryptedParams(path: String, data: String, nonce: String, ssecurity: String) throws -> [(String, String)] {
            let signed = try signedNonce(nonce, ssecurity: ssecurity)
            let key = Data(base64Encoded: signed)!
            var params = [("data", data)]
            params.append(("rc4_hash__", encSignature(path: path, params: params, signedNonce: signed)))
            params = params.map { ($0.0, rc4(key: key, Data($0.1.utf8)).base64EncodedString()) }
            params.append(("signature", encSignature(path: path, params: params, signedNonce: signed)))
            params += [("ssecurity", ssecurity), ("_nonce", nonce)]
            return params
        }

        static func decrypt(_ body: Data, nonce: String, ssecurity: String) throws -> [String: Any] {
            let key = Data(base64Encoded: try signedNonce(nonce, ssecurity: ssecurity))!
            guard let encrypted = Data(base64Encoded: String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  let json = try JSONSerialization.jsonObject(with: rc4(key: key, encrypted)) as? [String: Any] else {
                throw Failure.badResponse("解密后不是 JSON")
            }
            return json
        }

        private static func signedNonce(_ nonce: String, ssecurity: String) throws -> String {
            guard let a = Data(base64Encoded: ssecurity), let b = Data(base64Encoded: nonce) else {
                throw Failure.badResponse("ssecurity 不是 base64")
            }
            return Data(SHA256.hash(data: a + b)).base64EncodedString()
        }

        /// 签名用的路径去掉了 /app 前缀。
        private static func encSignature(path: String, params: [(String, String)], signedNonce: String) -> String {
            let text = (["POST", path] + params.map { "\($0.0)=\($0.1)" } + [signedNonce]).joined(separator: "&")
            return Data(Insecure.SHA1.hash(data: Data(text.utf8))).base64EncodedString()
        }

        /// RC4，先丢掉密钥流的前 1024 字节。
        private static func rc4(key: Data, _ input: Data) -> Data {
            let k = [UInt8](key)
            var s = (0...255).map { UInt8($0) }
            var j = 0
            for i in 0..<256 {
                j = (j + Int(s[i]) + Int(k[i % k.count])) & 255
                s.swapAt(i, j)
            }
            var i = 0
            j = 0
            func next() -> UInt8 {
                i = (i + 1) & 255
                j = (j + Int(s[i])) & 255
                s.swapAt(i, j)
                return s[(Int(s[i]) + Int(s[j])) & 255]
            }
            for _ in 0..<1024 { _ = next() }
            return Data(input.map { $0 ^ next() })
        }

        /// base64 里的 + / = 都要编码，否则 + 会被服务器当成空格。
        private static func formEncode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
        }

        private static func makeAgent() -> String {
            let text = String((0..<18).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
            let id = String((0..<13).map { _ in Character(UnicodeScalar(UInt8.random(in: 65...69))) })
            return "\(text)-\(id) APP/com.xiaomi.mihome APPV/10.5.201"
        }
    }
}
