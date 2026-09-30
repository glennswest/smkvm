/// Client → server message encoders (docs/protocol.md §5). Big-endian.
public enum ATENMessages {
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    /// 24-byte NUL-padded credential field (≤23 characters, so always terminated).
    static func field24(_ s: String) -> [UInt8] {
        var b = Array(s.utf8.prefix(23))
        b += [UInt8](repeating: 0, count: 24 - b.count)
        return b
    }

    public static func credentials(user: String, password: String) -> [UInt8] {
        field24(user) + field24(password)
    }

    public static func updateRequest(incremental: Bool, width: Int, height: Int) -> [UInt8] {
        [3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(width) + be16(height)
    }

    /// 18 bytes: [4][encrypted=0][down][0][0][u32 HID usage][9 × 0].
    public static func key(hid: UInt8, down: Bool) -> [UInt8] {
        [4, 0, down ? 1 : 0, 0, 0] + be32(UInt32(hid)) + [UInt8](repeating: 0, count: 9)
    }

    /// 18 bytes: [5][encrypted=0][buttons][u16 x][u16 y][11 × 0], absolute pixels.
    public static func pointer(x: Int, y: Int, buttons: UInt8) -> [UInt8] {
        [5, 0, buttons] + be16(max(0, x)) + be16(max(0, y)) + [UInt8](repeating: 0, count: 11)
    }

    public static let keepAlive: [UInt8] = [0x15] + be32(1) + be32(0)

    /// Power: 0 off, 1 on, 2 reset, 3 soft-off (ACPI).
    public static func power(_ code: UInt8) -> [UInt8] { [0x1A, code] }
}
