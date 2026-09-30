import AppKit
import SMKVMCore

/// Draws the remote framebuffer (aspect-fit) and forwards keyboard and mouse
/// input in framebuffer coordinates.
final class ConsoleView: NSView {
    var onKey: ((UInt16, Bool) -> Void)?
    var onPointer: ((Int, Int, UInt8) -> Void)?

    private var image: CGImage?
    private var fbSize = CGSize(width: 0, height: 0)
    private var buttons: UInt8 = 0
    private var lastFlags: NSEvent.ModifierFlags = []
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called on the main thread with a snapshot of the framebuffer.
    func show(_ fb: FrameSnapshot) {
        fbSize = CGSize(width: fb.width, height: fb.height)
        image = Self.makeImage(fb)
        needsDisplay = true
    }

    private static func makeImage(_ fb: FrameSnapshot) -> CGImage? {
        guard fb.width > 0, fb.height > 0 else { return nil }
        let data = fb.pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: fb.width, height: fb.height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: fb.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// The rectangle the framebuffer occupies inside the view.
    private var imageRect: CGRect {
        guard fbSize.width > 0, fbSize.height > 0 else { return .zero }
        let s = min(bounds.width / fbSize.width, bounds.height / fbSize.height)
        let w = fbSize.width * s, h = fbSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect
        ctx.saveGState()
        // CGContext draws images bottom-up; flip back since the view is flipped.
        ctx.translateBy(x: 0, y: r.maxY + r.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: r)
        ctx.restoreGState()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func sendPointer(_ event: NSEvent) {
        let r = imageRect
        guard r.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let x = Int(((p.x - r.minX) / r.width * fbSize.width).rounded(.down))
        let y = Int(((p.y - r.minY) / r.height * fbSize.height).rounded(.down))
        let cx = min(max(x, 0), Int(fbSize.width) - 1)
        let cy = min(max(y, 0), Int(fbSize.height) - 1)
        onPointer?(cx, cy, buttons)
    }

    override func mouseMoved(with e: NSEvent) { sendPointer(e) }
    override func mouseDragged(with e: NSEvent) { sendPointer(e) }
    override func rightMouseDragged(with e: NSEvent) { sendPointer(e) }
    override func otherMouseDragged(with e: NSEvent) { sendPointer(e) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; sendPointer(e) }
    override func mouseUp(with e: NSEvent) { buttons &= ~1; sendPointer(e) }
    override func rightMouseDown(with e: NSEvent) { buttons |= 4; sendPointer(e) }
    override func rightMouseUp(with e: NSEvent) { buttons &= ~4; sendPointer(e) }
    override func otherMouseDown(with e: NSEvent) { buttons |= 2; sendPointer(e) }
    override func otherMouseUp(with e: NSEvent) { buttons &= ~2; sendPointer(e) }

    override func scrollWheel(with e: NSEvent) {
        let dy = e.scrollingDeltaY
        guard abs(dy) >= 1 else { return }
        let bit: UInt8 = dy > 0 ? 8 : 16
        buttons |= bit; sendPointer(e)
        buttons &= ~bit; sendPointer(e)
    }

    // MARK: - Keyboard

    override func keyDown(with e: NSEvent) { onKey?(e.keyCode, true) }
    override func keyUp(with e: NSEvent) { onKey?(e.keyCode, false) }

    /// Modifier keys arrive as flagsChanged; work out which one moved.
    override func flagsChanged(with e: NSEvent) {
        let flag: NSEvent.ModifierFlags?
        switch e.keyCode {
        case 56, 60: flag = .shift
        case 59, 62: flag = .control
        case 58, 61: flag = .option
        case 55, 54: flag = .command
        case 57: flag = .capsLock
        default: flag = nil
        }
        guard let flag else { return }
        if flag == .capsLock {
            // Caps Lock only reports its toggled state; send a full press.
            onKey?(e.keyCode, true)
            onKey?(e.keyCode, false)
        } else {
            onKey?(e.keyCode, e.modifierFlags.contains(flag))
        }
        lastFlags = e.modifierFlags
    }

    /// Keep Cmd-key combos (except Cmd-Q/W handled by the menu) going to the host.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        let chars = e.charactersIgnoringModifiers ?? ""
        if e.modifierFlags.contains(.command), ["q", "w"].contains(chars) { return false }
        onKey?(e.keyCode, true)
        onKey?(e.keyCode, false)
        return true
    }
}
