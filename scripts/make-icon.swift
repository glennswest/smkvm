// Draws the app icon (1024×1024 PNG): a graphite rounded square holding a
// console screen with a phosphor-green prompt and a row of BMC status LEDs.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func rr(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("could not create bitmap\n".utf8))
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

// Body: the standard macOS icon shape — ~10% margins, 22.5% corner radius —
// with a soft drop shadow.
let body = NSRect(x: 120, y: 132, width: 784, height: 784)
let bodyPath = rr(body, 176)
ctx.saveGraphicsState()
let drop = NSShadow()
drop.shadowColor = NSColor.black.withAlphaComponent(0.35)
drop.shadowOffset = NSSize(width: 0, height: -16)
drop.shadowBlurRadius = 34
drop.set()
color(0x232833).setFill()
bodyPath.fill()
ctx.restoreGraphicsState()
NSGradient(colors: [color(0x475061), color(0x1e222b)])!.draw(in: bodyPath, angle: -90)
color(0xFFFFFF, 0.10).setStroke()
let bezel = rr(body.insetBy(dx: 3, dy: 3), 173)
bezel.lineWidth = 4
bezel.stroke()

// Screen: near-black panel with a faint glass highlight across the top.
let screen = NSRect(x: 212, y: 330, width: 600, height: 480)
let screenPath = rr(screen, 44)
NSGradient(colors: [color(0x131922), color(0x090C11)])!.draw(in: screenPath, angle: -90)
color(0x000000, 0.55).setStroke()
screenPath.lineWidth = 7
screenPath.stroke()
ctx.saveGraphicsState()
screenPath.addClip()
let glass = NSRect(x: screen.minX, y: screen.maxY - 170, width: screen.width, height: 170)
NSGradient(colors: [color(0xFFFFFF, 0.00), color(0xFFFFFF, 0.07)])!.draw(in: glass, angle: 90)
ctx.restoreGraphicsState()

// Prompt and block cursor, phosphor green with a glow.
let green = color(0x3FE08A)
ctx.saveGraphicsState()
screenPath.addClip()
let glow = NSShadow()
glow.shadowColor = green.withAlphaComponent(0.85)
glow.shadowBlurRadius = 26
glow.set()
let font = NSFont(name: "Menlo-Bold", size: 230) ?? .monospacedSystemFont(ofSize: 230, weight: .bold)
("❯" as NSString).draw(at: NSPoint(x: 278, y: 528),
                       withAttributes: [.font: font, .foregroundColor: green])
green.setFill()
NSBezierPath(roundedRect: NSRect(x: 462, y: 560, width: 104, height: 170),
             xRadius: 12, yRadius: 12).fill()
ctx.restoreGraphicsState()

// BMC status LEDs under the screen.
for (i, c) in [0x3DDC84, 0xFFC24B, 0x4EA1FF].enumerated() {
    let led = color(UInt32(c))
    let x = 512.0 - 70 + Double(i) * 70
    ctx.saveGraphicsState()
    let ledGlow = NSShadow()
    ledGlow.shadowColor = led.withAlphaComponent(0.8)
    ledGlow.shadowBlurRadius = 14
    ledGlow.set()
    led.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - 17, y: 232, width: 34, height: 34)).fill()
    ctx.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print(out)
