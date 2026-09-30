import Foundation

public enum DecodeError: Error, CustomStringConvertible {
    case truncated(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .truncated(let s): return "truncated video data: \(s)"
        case .unsupported(let s): return "unsupported video data: \(s)"
        }
    }
}

/// ATEN "Hermon" video (WPCM450, encoding 0x59 or 0x00): a 10-byte
/// sub-header, then either 16×16 RGB555 tiles or a raw full frame.
/// See docs/protocol.md §6.3.
public enum HermonDecoder {
    static let tileBytes = 6 + 16 * 16 * 2

    public static func decode(_ p: [UInt8], width: Int, height: Int, into fb: Framebuffer) throws {
        guard p.count >= 10 else { throw DecodeError.truncated("Hermon header, \(p.count) bytes") }
        let type = p[0]
        let count = Int(UInt32(p[2]) << 24 | UInt32(p[3]) << 16 | UInt32(p[4]) << 8 | UInt32(p[5]))
        fb.resize(width: width, height: height)

        switch type {
        case 0:
            let n = min(count, (p.count - 10) / tileBytes)
            fb.withPixels { px, w, h in
                for t in 0..<n {
                    let o = 10 + t * tileBytes
                    let ty = Int(p[o + 4]) * 16
                    let tx = Int(p[o + 5]) * 16
                    blit(p, o + 6, stride: 16, x: tx, y: ty, w: 16, h: 16, px, w, h)
                }
            }
        case 1:
            guard p.count - 10 >= width * height * 2 else {
                throw DecodeError.truncated("Hermon raw frame \(width)x\(height), \(p.count - 10) bytes")
            }
            fb.withPixels { px, w, h in
                blit(p, 10, stride: width, x: 0, y: 0, w: width, h: height, px, w, h)
            }
        default:
            throw DecodeError.unsupported("Hermon type \(type)")
        }
    }

    /// Copies a block of RGB555-LE pixels, clipping to the framebuffer.
    @inline(__always)
    private static func blit(_ p: [UInt8], _ start: Int, stride: Int, x: Int, y: Int, w bw: Int, h bh: Int,
                             _ px: UnsafeMutableBufferPointer<UInt32>, _ fw: Int, _ fh: Int) {
        let cols = min(bw, fw - x), rows = min(bh, fh - y)
        guard cols > 0, rows > 0 else { return }
        p.withUnsafeBufferPointer { src in
            for r in 0..<rows {
                var s = start + r * stride * 2
                var d = (y + r) * fw + x
                for _ in 0..<cols {
                    px[d] = rgb555(UInt16(src[s]) | UInt16(src[s + 1]) << 8)
                    s += 2
                    d += 1
                }
            }
        }
    }

    @inline(__always)
    static func rgb555(_ v: UInt16) -> UInt32 {
        let r = UInt32(v >> 10 & 31), g = UInt32(v >> 5 & 31), b = UInt32(v & 31)
        return 0xFF00_0000 | (r << 3 | r >> 2) << 16 | (g << 3 | g >> 2) << 8 | (b << 3 | b >> 2)
    }
}
