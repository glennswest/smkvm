import Foundation

/// Standard RFB (VNC) client side of KVMClient: RFB 3.3–3.8, None or VNC
/// password auth, 32-bit true colour, Raw / CopyRect / Hextile and
/// DesktopSize. Used for Dell iDRAC's built-in VNC server and similar.
extension KVMClient {
    static let vncEncodings: [Int32] = [5, 1, 0, -223]   // Hextile, CopyRect, Raw, DesktopSize

    func vncHandshake(_ s: Socket) throws {
        let banner = try s.read(12)
        guard banner.starts(with: Array("RFB ".utf8)),
              let minor = Int(String(decoding: banner[8..<11], as: UTF8.self)) else {
            throw KVMError.protocolError("bad banner \(hex(banner))")
        }
        let v38 = minor >= 8
        try s.write(Array((minor >= 7 ? (v38 ? "RFB 003.008\n" : "RFB 003.007\n") : "RFB 003.003\n").utf8))

        var type: UInt8
        if minor >= 7 {
            let n = Int(try s.u8())
            if n == 0 { throw KVMError.refused(try reason(s)) }
            let types = try s.read(n)
            if types.contains(2) { type = 2 } else if types.contains(1) { type = 1 } else {
                throw KVMError.protocolError("no supported VNC security type in \(types)")
            }
            try s.write([type])
        } else {
            let t = try s.u32()
            if t == 0 { throw KVMError.refused(try reason(s)) }
            type = UInt8(truncatingIfNeeded: t)
        }

        if type == 2 {
            let challenge = try s.read(16)
            guard let resp = VNCAuth.response(challenge: challenge, password: password) else {
                throw KVMError.protocolError("VNC DES failed")
            }
            try s.write(resp)
        }
        if type == 2 || v38 {
            let result = try s.u32()
            if result != 0 {
                throw KVMError.vncAuthFailed(v38 ? ((try? reason(s)) ?? "") : "")
            }
        }

        try s.write([1])   // ClientInit: shared
        let w = Int(try s.u16()), h = Int(try s.u16())
        _ = try s.read(16)
        let nameLen = Int(try s.u32())
        guard nameLen <= 4096 else { throw KVMError.protocolError("server name length \(nameLen)") }
        let name = String(decoding: try s.read(nameLen), as: UTF8.self)
        log?("VNC server \"\(name)\" \(w)x\(h), RFB 3.\(minor), security \(type)")

        // 32 bpp, depth 24, little-endian, true colour, R<<16 G<<8 B: the
        // Framebuffer's own layout.
        try s.write([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        var enc: [UInt8] = [2, 0] + ATENMessages.be16(Self.vncEncodings.count)
        for e in Self.vncEncodings { enc += ATENMessages.be32(UInt32(bitPattern: e)) }
        try s.write(enc)

        fb.resize(width: w, height: h)
        try s.write(ATENMessages.updateRequest(incremental: false, width: w, height: h))
    }

    private func reason(_ s: Socket) throws -> String {
        let len = Int(try s.u32())
        return String(decoding: try s.read(min(len, 4096)), as: UTF8.self)
    }

    func vncReadLoop(_ s: Socket) throws {
        while isRunning {
            let type = try s.u8()
            lastRx = Date()
            switch type {
            case 0:
                try vncUpdate(s)
            case 1:   // SetColourMapEntries (unused with true colour)
                _ = try s.u8()
                _ = try s.u16()
                try s.skip(Int(try s.u16()) * 6)
            case 2:   // Bell
                break
            case 3:   // ServerCutText
                try s.skip(3)
                try s.skip(Int(try s.u32()))
            default:
                let peek = (try? s.read(16)) ?? []
                throw KVMError.protocolError(String(format: "unknown VNC message %d, next bytes %@", type, hex(peek)))
            }
        }
    }

    private func vncUpdate(_ s: Socket) throws {
        _ = try s.u8()
        let n = Int(try s.u16())
        var full = false
        for _ in 0..<n {
            let h = try s.read(12)
            let x = Int(u16(h, 0)), y = Int(u16(h, 2)), w = Int(u16(h, 4)), hh = Int(u16(h, 6))
            let enc = Int32(bitPattern: u32(h, 8))
            switch enc {
            case 0:
                let data = try s.read(w * hh * 4)
                fb.withPixels { px, fw, fh in blitBGRX(data, 0, stride: w, x: x, y: y, w: w, h: hh, px, fw, fh) }
            case 1:
                let sx = Int(try s.u16()), sy = Int(try s.u16())
                copyRect(sx: sx, sy: sy, x: x, y: y, w: w, h: hh)
            case 5:
                try hextile(s, x: x, y: y, w: w, h: hh)
            case -223:
                log?("VNC desktop size \(w)x\(hh)")
                fb.resize(width: w, height: hh)
                full = true
            default:
                throw DecodeError.unsupported("VNC encoding \(enc)")
            }
        }
        deliver()
        try s.write(ATENMessages.updateRequest(incremental: !full,
                                               width: max(fb.width, 1), height: max(fb.height, 1)))
    }

    private func copyRect(sx: Int, sy: Int, x: Int, y: Int, w: Int, h: Int) {
        fb.withPixels { px, fw, fh in
            guard sx >= 0, sy >= 0, sx + w <= fw, sy + h <= fh, x + w <= fw, y + h <= fh else { return }
            // Row order that is safe for overlapping source and destination.
            let rows: [Int] = sy < y ? Array((0..<h).reversed()) : Array(0..<h)
            for r in rows {
                let src = (sy + r) * fw + sx, dst = (y + r) * fw + x
                let tmp = Array(px[src..<src + w])
                for i in 0..<w { px[dst + i] = tmp[i] }
            }
        }
    }

    private func hextile(_ s: Socket, x rx: Int, y ry: Int, w rw: Int, h rh: Int) throws {
        var bg: UInt32 = 0xFF00_0000, fg: UInt32 = 0xFFFF_FFFF
        func pixel() throws -> UInt32 {
            let b = try s.read(4)
            return 0xFF00_0000 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])
        }
        var ty = ry
        while ty < ry + rh {
            let th = min(16, ry + rh - ty)
            var tx = rx
            while tx < rx + rw {
                let tw = min(16, rx + rw - tx)
                let sub = try s.u8()
                if sub & 1 != 0 {
                    let data = try s.read(tw * th * 4)
                    fb.withPixels { px, fw, fh in blitBGRX(data, 0, stride: tw, x: tx, y: ty, w: tw, h: th, px, fw, fh) }
                } else {
                    if sub & 2 != 0 { bg = try pixel() }
                    fb.fill(x: tx, y: ty, w: tw, h: th, argb: bg)
                    if sub & 4 != 0 { fg = try pixel() }
                    if sub & 8 != 0 {
                        let count = Int(try s.u8())
                        let coloured = sub & 16 != 0
                        for _ in 0..<count {
                            let c = coloured ? try pixel() : fg
                            let b = try s.read(2)
                            fb.fill(x: tx + Int(b[0] >> 4), y: ty + Int(b[0] & 15),
                                    w: Int(b[1] >> 4) + 1, h: Int(b[1] & 15) + 1, argb: c)
                        }
                    }
                }
                tx += 16
            }
            ty += 16
        }
    }
}

/// Copies 32-bit little-endian B,G,R,X pixels into the framebuffer, clipped.
func blitBGRX(_ p: [UInt8], _ start: Int, stride: Int, x: Int, y: Int, w: Int, h: Int,
              _ px: UnsafeMutableBufferPointer<UInt32>, _ fw: Int, _ fh: Int) {
    let cols = min(w, fw - x), rows = min(h, fh - y)
    guard cols > 0, rows > 0, x >= 0, y >= 0 else { return }
    p.withUnsafeBufferPointer { src in
        for r in 0..<rows {
            var s = start + r * stride * 4
            var d = (y + r) * fw + x
            for _ in 0..<cols {
                px[d] = 0xFF00_0000 | UInt32(src[s + 2]) << 16 | UInt32(src[s + 1]) << 8 | UInt32(src[s])
                s += 4
                d += 1
            }
        }
    }
}
