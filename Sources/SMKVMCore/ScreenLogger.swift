import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saves a PNG of the screen each time it is cleared.
///
/// A clear wipes the content, so what's worth keeping is the last frame that
/// had content on it. The logger writes that frame out when:
/// - the screen goes blank (`cls`);
/// - most of the content is replaced without a blank frame in between
///   (`screen-change`): a clear-and-redraw faster than the BMC samples, or
///   a program repainting the whole screen. Scrolling and small edits
///   (typing, menu highlights, cursor blink) don't count;
/// - the video mode changes, the signal drops, or the session ends.
/// A screen that matches the last one saved (ignoring a cursor) is skipped.
///
/// Fed from the session thread with every decoded update; files are written
/// on a background queue.
public final class ScreenLogger: @unchecked Sendable {
    public enum Reason: String, Sendable {
        case clear = "cls"
        case replaced = "screen-change"
        case modeChange = "mode-change"
        case noSignal = "no-signal"
        case disconnect = "disconnect"
    }

    public let directory: URL
    /// Called (on the writer queue) after each file is written.
    public var onSaved: ((URL, Reason) -> Void)?

    private let lock = NSLock()
    private var lastContent: FrameSnapshot?
    /// The settled screen that replacement is measured against: follows
    /// small edits, holds still through a repaint in progress.
    private var baseline: FrameSnapshot?
    private var lastWasBlank = true
    private var lastSaved: FrameSnapshot?
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
            baseline = nil
        }
        if blank {
            if !lastWasBlank, let prev = lastContent { save(prev, .clear) }
            lastContent = nil
            baseline = nil
        } else {
            if let base = baseline {
                switch Self.compare(base, frame) {
                case .small:
                    baseline = frame
                case .replaced:
                    save(base, .replaced)
                    baseline = frame
                case .scrolled:
                    baseline = frame
                case .partial:
                    break   // a repaint may be under way; keep measuring from the settled screen
                }
            } else {
                baseline = frame
            }
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
        baseline = nil
        lastWasBlank = true
    }

    /// Caller holds `lock`.
    private func save(_ frame: FrameSnapshot, _ reason: Reason) {
        if let last = lastSaved, Self.compare(last, frame) == .small { return }
        lastSaved = frame
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

    enum Change: Equatable { case small, partial, replaced, scrolled }

    static let step = 4

    /// How much of `old` survives in `new`, on a sampled grid. "Ink" is any
    /// pixel that isn't the screen's background colour.
    static func compare(_ old: FrameSnapshot, _ new: FrameSnapshot) -> Change {
        guard old.width == new.width, old.height == new.height else { return .replaced }
        let w = old.width, h = old.height
        let bgOld = background(old), bgNew = background(new)
        var samples = 0, changed = 0, inkOld = 0, inkNew = 0
        old.pixels.withUnsafeBufferPointer { a in
            new.pixels.withUnsafeBufferPointer { b in
                var y = 0
                while y < h {
                    var i = y * w
                    let end = i + w
                    while i < end {
                        let p = a[i], q = b[i]
                        samples += 1
                        if p != q { changed += 1 }
                        if p != bgOld { inkOld += 1 }
                        if q != bgNew { inkNew += 1 }
                        i += step
                    }
                    y += step
                }
            }
        }
        // Cursor blink, a typed character, a moved highlight.
        if changed <= max(samples / 200, max(inkOld, inkNew) / 20) { return .small }
        // Scrolling moves everything; it is never a replacement.
        if isScroll(old, new, bgOld) { return .scrolled }
        // Most of what was on screen is gone or rewritten.
        let ink = max(inkOld, inkNew, 1)
        if Double(changed) >= Double(ink) * 0.5 && changed >= samples / 100 { return .replaced }
        return .partial
    }

    /// True when `new` is `old` moved up by some whole number of pixel rows
    /// (text-console scrolling), judged on the rows of `new` that have ink
    /// and changed.
    static func isScroll(_ old: FrameSnapshot, _ new: FrameSnapshot, _ bg: UInt32) -> Bool {
        let w = old.width, h = old.height
        return old.pixels.withUnsafeBufferPointer { a in
            new.pixels.withUnsafeBufferPointer { b in
                func rowHasInk(_ y: Int) -> Bool {
                    var x = 0
                    while x < w { if b[y * w + x] != bg { return true }; x += step }
                    return false
                }
                func rowsMatch(_ yNew: Int, _ yOld: Int) -> Bool {
                    var x = 0
                    while x < w { if b[yNew * w + x] != a[yOld * w + x] { return false }; x += step }
                    return true
                }
                // Only rows that changed can tell a scroll from an edit;
                // unchanged rows (borders, blank gaps) match anything.
                let inkRows = stride(from: 0, to: h, by: 2).filter { rowHasInk($0) && !rowsMatch($0, $0) }
                guard inkRows.count >= 4 else { return false }
                // Several lines can scroll between two BMC samples.
                for k in 1...max(1, h / 2) {
                    var match = 0, tried = 0
                    for y in inkRows where y + k < h {
                        tried += 1
                        if rowsMatch(y, y + k) { match += 1 }
                    }
                    if tried > 0 && match * 10 >= tried * 7 { return true }
                }
                return false
            }
        }
    }

    /// The most common colour on a sampled grid.
    static func background(_ f: FrameSnapshot) -> UInt32 {
        var counts: [UInt32: Int] = [:]
        f.pixels.withUnsafeBufferPointer { px in
            var y = 0
            while y < f.height {
                var i = y * f.width
                let end = i + f.width
                while i < end { counts[px[i], default: 0] += 1; i += step * 4 }
                y += step * 4
            }
        }
        return counts.max { $0.value < $1.value }?.key ?? 0
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
