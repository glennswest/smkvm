// smkvm-probe — headless live test: log in, open the KVM session, print the
// protocol log, save the first complete frame as a PNG.
//
//   smkvm-probe <bmc> [user] [--seconds N] [--png out.png] [--no-keepalive] [--mouse-info-len N]
//
// The password comes from $SMKVM_PASSWORD or the same Keychain item the app
// uses (service "smkvm.bmc", account "<user>@<bmc>").
import Foundation
import ImageIO
import Security
import SMKVMCore
import UniformTypeIdentifiers

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let seconds = Double(option("--seconds") ?? "15") ?? 15
let pngPath = option("--png") ?? "smkvm-probe.png"
let noKeepAlive = flag("--no-keepalive")
let mouseInfoLen = option("--mouse-info-len").flatMap(Int.init)
guard let host = args.first else {
    FileHandle.standardError.write(Data("usage: smkvm-probe <bmc> [user] [--seconds N] [--png file]\n".utf8))
    exit(2)
}
let user = args.count > 1 ? args[1] : "ADMIN"

@MainActor func keychainPassword() -> String? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "smkvm.bmc",
        kSecAttrAccount as String: "\(user)@\(host)",
        kSecReturnData as String: true,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
    return String(data: d, encoding: .utf8)
}
guard let password = ProcessInfo.processInfo.environment["SMKVM_PASSWORD"] ?? keychainPassword() else {
    print("no password: set SMKVM_PASSWORD or add Keychain item smkvm.bmc / \(user)@\(host)")
    exit(2)
}

let start = Date()
func stamp() -> String { String(format: "%7.3f", Date().timeIntervalSince(start)) }

let client = KVMClient(host: host, user: user, password: password)
client.keepAliveEnabled = !noKeepAlive
if let mouseInfoLen { client.mouseInfoLength = mouseInfoLen }
client.log = { print("\(stamp()) \($0)") }

nonisolated(unsafe) var frames = 0
nonisolated(unsafe) var saved = false
client.onFrame = { f in
    frames += 1
    guard !saved, f.width > 0 else { return }
    saved = true
    let data = f.pixels.withUnsafeBytes { Data($0) } as CFData
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    if let provider = CGDataProvider(data: data),
       let img = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: f.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: pngPath) as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print("\(stamp()) saved \(f.width)x\(f.height) frame to \(pngPath)")
    }
}

client.start()
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
print("\(stamp()) frames delivered: \(frames)")
client.stop()
RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // let the session log out
