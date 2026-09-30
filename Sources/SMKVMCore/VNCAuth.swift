import CommonCrypto
import Foundation

/// Standard VNC authentication (RFB security type 2): DES-encrypt the
/// server's 16-byte challenge with the password as key, where each key
/// byte has its bit order reversed (a quirk of the original VNC code).
public enum VNCAuth {
    public static func response(challenge: [UInt8], password: String) -> [UInt8]? {
        guard challenge.count == 16 else { return nil }
        var key = Array(password.utf8.prefix(8))
        key += [UInt8](repeating: 0, count: 8 - key.count)
        key = key.map(reverseBits)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, kCCKeySizeDES, nil, challenge, 16, &out, 16, &moved)
        return status == kCCSuccess && moved == 16 ? out : nil
    }

    static func reverseBits(_ b: UInt8) -> UInt8 {
        var v = b, r: UInt8 = 0
        for _ in 0..<8 { r = r << 1 | v & 1; v >>= 1 }
        return r
    }
}
