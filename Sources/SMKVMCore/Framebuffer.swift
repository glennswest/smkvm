import Foundation

/// A 32-bit BGRA (little-endian 0xAARRGGBB) pixel buffer the decoders draw
/// into and the view turns into a CGImage.
public final class Framebuffer: @unchecked Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var pixels: [UInt32]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = Array(repeating: 0xFF00_0000, count: max(0, width * height))
    }

    /// Resizes, clearing to black. No-op when the size is unchanged.
    public func resize(width: Int, height: Int) {
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        pixels = Array(repeating: 0xFF00_0000, count: max(0, width * height))
    }

    @inline(__always)
    public func set(_ x: Int, _ y: Int, _ argb: UInt32) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = argb
    }

    public func fill(x: Int, y: Int, w: Int, h: Int, argb: UInt32) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        for row in y0..<y1 {
            let base = row * width
            for col in x0..<x1 { pixels[base + col] = argb }
        }
    }

    @inline(__always)
    public static func argb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }
}
