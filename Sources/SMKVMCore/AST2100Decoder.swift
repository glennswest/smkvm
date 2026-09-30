import Foundation

/// ASPEED AST2100-family video (encoding 0x57, X10-era boards): a JPEG-like
/// DCT codec plus a small VQ mode. See docs/protocol.md §7.
///
/// Stateful across frames (VQ codebook, loaded quantisation tables), so keep
/// one decoder per session.
public final class AST2100Decoder: @unchecked Sendable {
    private var lumaSel = -1, chromaSel = -1
    private var qtLuma = [Int32](repeating: 0, count: 64)
    private var qtChroma = [Int32](repeating: 0, count: 64)
    private var codebook: [(UInt8, UInt8, UInt8)] = AST2100Decoder.initialCodebook
    private var lookup = [0, 1, 2, 3]

    private static let initialCodebook: [(UInt8, UInt8, UInt8)] =
        [(0x00, 0x80, 0x80), (0xFF, 0x80, 0x80), (0x80, 0x80, 0x80), (0xC0, 0x80, 0x80)]

    public init() {}

    public func decode(_ data: [UInt8], width: Int, height: Int, into fb: Framebuffer) throws {
        guard data.count >= 4 else { throw DecodeError.truncated("AST2100 header") }
        let ls = Int(data[0]), cs = Int(data[1])
        guard ls < 12, cs < 12 else { throw DecodeError.unsupported("AST2100 quant selector \(ls)/\(cs)") }
        if ls != lumaSel { qtLuma = Self.scaled(AST2100Tables.lumaQT[ls]); lumaSel = ls }
        if cs != chromaSel { qtChroma = Self.scaled(AST2100Tables.chromaQT[cs]); chromaSel = cs }
        let mode = Int(data[2]) << 8 | Int(data[3])
        guard mode == 444 || mode == 422 else { throw DecodeError.unsupported("AST2100 subsampling \(mode)") }

        fb.resize(width: width, height: height)
        let mcu = mode == 444 ? 8 : 16
        let wMCU = (width + mcu - 1) / mcu, hMCU = (height + mcu - 1) / mcu
        var bits = BitReader(data, start: 4)
        var mx = 0, my = 0
        var prevDC: [Int32] = [0, 0, 0]
        let limit = max(width * height / 64, 4096)

        try fb.withPixels { px, fw, fh in
            var out = Block(mcu: mcu, px: px, fw: fw, fh: fh)
            for _ in 0..<limit {
                let code = bits.read(4)
                switch code {
                case 0x0, 0x4, 0x8, 0xC:
                    if code & 8 != 0 { mx = Int(bits.read(8)); my = Int(bits.read(8)) }
                    // 0x4/0xC ("LOW_JPEG") use a second QT pair not yet observed;
                    // the current tables are the closest available (UNVERIFIED).
                    try decodeMCU(&bits, mode: mode, prevDC: &prevDC, out: &out, x: mx * mcu, y: my * mcu)
                case 0x5, 0x6, 0x7, 0xD, 0xE, 0xF:
                    if code & 8 != 0 { mx = Int(bits.read(8)); my = Int(bits.read(8)) }
                    guard mcu == 8 else { throw DecodeError.unsupported("AST2100 VQ block in 4:2:0 mode") }
                    decodeVQ(&bits, size: Int(code & 7) - 5, out: &out, x: mx * 8, y: my * 8)
                case 0x9:
                    return
                default:
                    throw DecodeError.unsupported(String(format: "AST2100 block code 0x%X", code))
                }
                mx += 1
                if mx >= wMCU { mx = 0; my += 1 }
                if my >= hMCU { my = 0 }
                if bits.overrun { throw DecodeError.truncated("AST2100 bitstream") }
            }
        }
    }

    // MARK: DCT

    private func decodeMCU(_ bits: inout BitReader, mode: Int, prevDC: inout [Int32],
                           out: inout Block, x: Int, y: Int) throws {
        var coef = [Int32](repeating: 0, count: 64)
        if mode == 444 {
            try dataUnit(&bits, luma: true, &prevDC[0], &coef); Self.idct(qtLuma, coef, &out.y[0])
            try dataUnit(&bits, luma: false, &prevDC[1], &coef); Self.idct(qtChroma, coef, &out.cb)
            try dataUnit(&bits, luma: false, &prevDC[2], &coef); Self.idct(qtChroma, coef, &out.cr)
            for i in 0..<64 {
                out.put(x + i & 7, y + i >> 3, out.y[0][i], out.cb[i], out.cr[i])
            }
        } else {
            for k in 0..<4 {
                try dataUnit(&bits, luma: true, &prevDC[0], &coef); Self.idct(qtLuma, coef, &out.y[k])
            }
            try dataUnit(&bits, luma: false, &prevDC[1], &coef); Self.idct(qtChroma, coef, &out.cb)
            try dataUnit(&bits, luma: false, &prevDC[2], &coef); Self.idct(qtChroma, coef, &out.cr)
            // Y0 top-left, Y1 top-right, Y2 bottom-left, Y3 bottom-right; chroma ×2.
            for k in 0..<4 {
                let bx = (k & 1) * 8, by = (k >> 1) * 8
                for i in 0..<64 {
                    let px = bx + i & 7, py = by + i >> 3
                    let c = (py >> 1) * 8 + (px >> 1)
                    out.put(x + px, y + py, out.y[k][i], out.cb[c], out.cr[c])
                }
            }
        }
    }

    private func dataUnit(_ bits: inout BitReader, luma: Bool, _ dc: inout Int32, _ coef: inout [Int32]) throws {
        for i in 0..<64 { coef[i] = 0 }
        let dcTable = luma ? Huffman.dcLuma : Huffman.dcChroma
        let acTable = luma ? Huffman.acLuma : Huffman.acChroma
        let cat = try dcTable.decode(&bits)
        dc &+= Self.extend(bits.read(Int(cat)), Int(cat))
        coef[0] = dc
        var k = 1
        while k < 64 {
            let rs = try acTable.decode(&bits)
            let r = Int(rs >> 4), s = Int(rs & 15)
            if s == 0 {
                if r == 15 { k += 16; continue }
                break   // EOB
            }
            k += r
            guard k < 64 else { throw DecodeError.unsupported("AST2100 AC run past block end") }
            coef[Huffman.zigzag[k]] = Self.extend(bits.read(s), s)
            k += 1
        }
    }

    @inline(__always)
    static func extend(_ v: UInt32, _ s: Int) -> Int32 {
        guard s > 0 else { return 0 }
        let v = Int32(v)
        return v < (1 << (s - 1)) ? v - (1 << s) + 1 : v
    }

    static let aan: [Double] = [1.0, 1.387039845, 1.306562965, 1.175875602,
                                1.0, 0.785694958, 0.541196100, 0.275899379]

    static func scaled(_ qt: [Int32]) -> [Int32] {
        (0..<64).map { i in Int32(Double(qt[i]) * aan[i & 7] * aan[i >> 3] * 65536.0) }
    }

    /// libjpeg jidctfst (AAN) in integer form, CONST_BITS 8, PASS1_BITS 0,
    /// matching the ASPEED reference (including row output 6 = tmp1 − tmp6).
    static func idct(_ q: [Int32], _ c: [Int32], _ out: inout [UInt8]) {
        @inline(__always) func mul(_ a: Int32, _ b: Int32) -> Int32 { (a &* b) >> 8 }
        @inline(__always) func dq(_ i: Int) -> Int32 { (q[i] &* c[i]) >> 8 }
        var ws = [Int32](repeating: 0, count: 64)

        for x in 0..<8 {
            var acZero = true
            for y in 1..<8 where c[8 * y + x] != 0 { acZero = false; break }
            if acZero {
                let dc = dq(x) >> 8
                for y in 0..<8 { ws[8 * y + x] = dc }
                continue
            }
            var t0 = dq(x), t1 = dq(16 + x), t2 = dq(32 + x), t3 = dq(48 + x)
            let t10 = t0 + t2, t11 = t0 - t2
            let t13 = t1 + t3
            let t12 = mul(t1 - t3, 362) - t13
            t0 = t10 + t13; t3 = t10 - t13
            t1 = t11 + t12; t2 = t11 - t12
            let t4 = dq(8 + x), t5 = dq(24 + x), t6 = dq(40 + x), t7 = dq(56 + x)
            let (o0, o1, o2, o3, o4, o5, o6, o7) = odd(t0, t1, t2, t3, t4, t5, t6, t7, mul)
            ws[x] = o0 >> 8; ws[x + 56] = o7 >> 8
            ws[x + 8] = o1 >> 8; ws[x + 48] = o6 >> 8
            ws[x + 16] = o2 >> 8; ws[x + 40] = o5 >> 8
            ws[x + 32] = o4 >> 8; ws[x + 24] = o3 >> 8
        }
        for y in 0..<8 {
            let w = 8 * y
            let t10 = ws[w] + ws[w + 4], t11 = ws[w] - ws[w + 4]
            let t13 = ws[w + 2] + ws[w + 6]
            let t12 = mul(ws[w + 2] - ws[w + 6], 362) - t13
            let (o0, o1, o2, o3, o4, o5, o6, o7) = odd(t10 + t13, t11 + t12, t11 - t12, t10 - t13,
                                                       ws[w + 1], ws[w + 3], ws[w + 5], ws[w + 7], mul)
            @inline(__always) func lim(_ v: Int32) -> UInt8 { UInt8(clamping: (v >> 3) + 128) }
            out[w] = lim(o0); out[w + 7] = lim(o7)
            out[w + 1] = lim(o1); out[w + 6] = lim(o6)
            out[w + 2] = lim(o2); out[w + 5] = lim(o5)
            out[w + 4] = lim(o4); out[w + 3] = lim(o3)
        }
    }

    /// Odd part and butterfly shared by both passes. Takes the even-part
    /// results (t0…t3) and the odd inputs (in1, in3, in5, in7); returns
    /// outputs 0…7 before descaling.
    @inline(__always)
    private static func odd(_ t0: Int32, _ t1: Int32, _ t2: Int32, _ t3: Int32,
                            _ in1: Int32, _ in3: Int32, _ in5: Int32, _ in7: Int32,
                            _ mul: (Int32, Int32) -> Int32)
        -> (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32) {
        let z13 = in5 + in3, z10 = in5 - in3
        let z11 = in1 + in7, z12 = in1 - in7
        let t7 = z11 + z13
        let t11 = mul(z11 - z13, 362)
        let z5 = mul(z10 + z12, 473)
        let t10 = mul(277, z12) - z5
        let t12 = mul(-669, z10) + z5
        let t6 = t12 - t7
        let t5 = t11 - t6
        let t4 = t10 + t5
        return (t0 + t7, t1 + t6, t2 + t5, t3 - t4, t3 + t4, t2 - t5, t1 - t6, t0 - t7)
    }

    // MARK: VQ

    private func decodeVQ(_ bits: inout BitReader, size: Int, out: inout Block, x: Int, y: Int) {
        for i in 0..<(1 << size) {
            let update = bits.read(1)
            let slot = Int(bits.read(2))
            if update != 0 {
                codebook[slot] = (UInt8(bits.read(8)), UInt8(bits.read(8)), UInt8(bits.read(8)))
            }
            lookup[i] = slot
        }
        for p in 0..<64 {
            let idx = size == 0 ? 0 : Int(bits.read(size))
            let (yy, cb, cr) = codebook[lookup[idx]]
            out.put(x + p & 7, y + p >> 3, yy, cb, cr)
        }
    }
}

/// Scratch buffers plus the destination for one MCU.
private struct Block {
    var y = [[UInt8]](repeating: [UInt8](repeating: 0, count: 64), count: 4)
    var cb = [UInt8](repeating: 0, count: 64)
    var cr = [UInt8](repeating: 0, count: 64)
    let px: UnsafeMutableBufferPointer<UInt32>
    let fw: Int, fh: Int

    init(mcu: Int, px: UnsafeMutableBufferPointer<UInt32>, fw: Int, fh: Int) {
        self.px = px; self.fw = fw; self.fh = fh
    }

    @inline(__always)
    func put(_ x: Int, _ y: Int, _ yy: UInt8, _ cb: UInt8, _ cr: UInt8) {
        guard x < fw, y < fh else { return }
        let l = (0x129FC * Int32(yy) - 0x121FC0) >> 16
        let r = l + ((0x19900 * Int32(cr) - 0xCC0000) >> 16)
        let g = l + ((0x688000 - 0xD000 * Int32(cr)) >> 16) + ((0x328000 - 0x6400 * Int32(cb)) >> 16)
        let b = l + ((0x20400 * Int32(cb) - 0x1018000) >> 16)
        px[y * fw + x] = 0xFF00_0000 | UInt32(UInt8(clamping: r)) << 16
            | UInt32(UInt8(clamping: g)) << 8 | UInt32(UInt8(clamping: b))
    }
}

/// Bit reader over 32-bit little-endian words, bits MSB-first within each
/// word; zero-padded past the end.
struct BitReader {
    private let data: [UInt8]
    private var pos: Int          // next byte to load
    private var window: UInt64 = 0
    private var avail = 0         // valid bits at the top of `window`
    private(set) var overrun = false

    init(_ data: [UInt8], start: Int) {
        self.data = data
        self.pos = start
    }

    private mutating func refill() {
        while avail <= 32 {
            var w: UInt32 = 0
            if pos + 4 <= data.count {
                w = UInt32(data[pos]) | UInt32(data[pos + 1]) << 8
                    | UInt32(data[pos + 2]) << 16 | UInt32(data[pos + 3]) << 24
            } else if pos < data.count {
                for i in 0..<(data.count - pos) { w |= UInt32(data[pos + i]) << (8 * i) }
            } else if pos >= data.count + 8 {
                overrun = true
            }
            pos += 4
            window |= UInt64(w) << (32 - avail)
            avail += 32
        }
    }

    mutating func peek(_ n: Int) -> UInt32 {
        if avail < n { refill() }
        return n == 0 ? 0 : UInt32(window >> (64 - n))
    }

    mutating func read(_ n: Int) -> UInt32 {
        guard n > 0 else { return 0 }
        let v = peek(n)
        window <<= n
        avail -= n
        return v
    }
}

/// Canonical JPEG Huffman table (Annex K), decoded by code length.
struct Huffman {
    private var maxCode = [Int32](repeating: -1, count: 17)
    private var valPtr = [Int32](repeating: 0, count: 17)
    private var minCode = [Int32](repeating: 0, count: 17)
    private let values: [UInt8]

    init(bits: [Int], values: [UInt8]) {
        self.values = values
        var code: Int32 = 0, k: Int32 = 0
        for len in 1...16 {
            valPtr[len] = k
            minCode[len] = code
            code += Int32(bits[len])
            k += Int32(bits[len])
            maxCode[len] = bits[len] > 0 ? code - 1 : -1
            code <<= 1
        }
    }

    func decode(_ r: inout BitReader) throws -> UInt8 {
        let window = r.peek(16)
        for len in 1...16 {
            let c = Int32(window >> (16 - len))
            if maxCode[len] >= 0 && c <= maxCode[len] {
                _ = r.read(len)
                return values[Int(valPtr[len] + c - minCode[len])]
            }
        }
        throw DecodeError.unsupported("AST2100 invalid Huffman code")
    }

    static let zigzag = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    static let dcLuma = Huffman(bits: [0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
                                values: Array(0...11))
    static let dcChroma = Huffman(bits: [0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
                                  values: Array(0...11))
    static let acLuma = Huffman(bits: [0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D], values: [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ])
    static let acChroma = Huffman(bits: [0, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], values: [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
        0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
        0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
        0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ])
}
