import Foundation
import MiioKit

let usage = """
用法：
  miio discover
  miio <ip> <token> info
  miio <ip> <token> get <siid> <piid>
  miio <ip> <token> set <siid> <piid> on|off
"""

let args = Array(CommandLine.arguments.dropFirst())
if args == ["discover"] {
    for (deviceID, ip) in await MiioDevice.discover().sorted(by: { $0.value < $1.value }) {
        print(ip, deviceID)
    }
    exit(0)
}
guard args.count >= 3 else {
    print(usage)
    exit(2)
}

do {
    let device = try MiioDevice(host: args[0], token: args[1])
    switch (args[2], args.count) {
    case ("info", 3):
        let info = try await device.info()
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    case ("get", 5):
        guard let siid = Int(args[3]), let piid = Int(args[4]) else { print(usage); exit(2) }
        print(try await device.getPower(siid: siid, piid: piid) ? "on" : "off")
    case ("set", 6):
        guard let siid = Int(args[3]), let piid = Int(args[4]), ["on", "off"].contains(args[5]) else {
            print(usage)
            exit(2)
        }
        try await device.setPower(args[5] == "on", siid: siid, piid: piid)
        print("ok")
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
    exit(1)
}
