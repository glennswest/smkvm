import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saves a PNG of the screen each time it is cleared.
///
/// A clear wipes the content, so what's worth keeping is the last frame that
/// had content on it. The logger remembers that frame and writes it out
/// when the screen goes blank (cls), the video mode changes, the signal
/// drops, or the session ends. Identical screens are saved once.
///
/// Fed from the session thread with every decoded update; files are written
/// on a background queue.
public final class ScreenLogger: @unchecked Sendable {
    public enum Reason: String, Sendable {
        case clear = "cls"
        case modeChange = "mode-change"
        case noSignal = "no-signal"
        case disconnect = "disconnect"
    }

    public let directory: URL
    /// Called (on the writer queue) after each file is written.
    public var onSaved: ((URL, Reason) -> Void)?

    private let lock = NSLock()
    private var lastContent: FrameSnapshot?
    private var lastWasBlank = true
    private var lastSavedDigest: SHA256Digest?
    private let writer = DispatchQueue(label: "smkvm.screenlog", qos: .utility)

    /// `directory` is the per-host folder; a dated subfolder is added per day.
    public init(directory: URL) {
        self.directory = directory
    }

    public func feed(_ frame: FrameSnapshot) {
        guard frame.width > 0, frame.height > 0 else { return }
        let blank = Self.isBlank(frame)
        lock.lock()
        defer { lock.unlock() }
        if let prev = lastContent, prev.width != frame.width || prev.height != frame.height {
            save(prev, .modeChange)
            lastContent = nil
        }
        if blank {
            if !lastWasBlank, let prev = lastContent { save(prev, .clear) }
            lastContent = nil
        } else {
            lastContent = frame
        }
        lastWasBlank = blank
    }

    public func signalLost() { flush(.noSignal) }

    public func sessionEnded() { flush(.disconnect) }

    private func flush(_ reason: Reason) {
        lock.lock()
        defer { lock.unlock() }
        if let prev = lastContent { save(prev, reason) }
        lastContent = nil
        lastWasBlank = true
    }

    /// Caller holds `lock`.
    private func save(_ frame: FrameSnapshot, _ reason: Reason) {
        let digest = frame.pixels.withUnsafeBytes { SHA256.hash(data: $0) }
        guard digest != lastSavedDigest else { return }
        lastSavedDigest = digest
        let now = Date()
        writer.async { [directory, onSaved] in
            let day = Self.dayFormat.string(from: now)
            let dir = directory.appendingPathComponent(day, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(Self.timeFormat.string(from: now))-\(reason.rawValue).png")
            if Self.writePNG(frame, to: url) { onSaved?(url, reason) }
        }
    }

    // MARK: detection

    /// True when (nearly) every pixel is one colour: a cleared screen, allowing
    /// for a text cursor. Samples every 4th pixel in each direction.
    static func isBlank(_ f: FrameSnapshot) -> Bool {
        let step = 4
        var total = 0
        var counts: [UInt32: Int] = [:]
        f.pixels.withUnsafeBufferPointer { px in
            // Candidate background colours: corners and centre.
            let w = f.width, h = f.height
            for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w / 2, h / 2)] {
                counts[px[y * w + x], default: 0] = 0
            }
            var y = 0
            while y < h {
                var x = 0
                let row = y * w
                while x < w {
                    let p = px[row + x]
                    if let c = counts[p] { counts[p] = c + 1 }
                    total += 1
                    x += step
                }
                y += step
            }
        }
        let best = counts.values.max() ?? 0
        return total > 0 && Double(best) >= Double(total) * 0.995
    }

    // MARK: output

    static func writePNG(_ f: FrameSnapshot, to url: URL) -> Bool {
        let data = f.pixels.withUnsafeBytes { Data($0) } as CFData
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data),
              let img = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: f.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: info, provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss.SSS"
        return f
    }()
}
