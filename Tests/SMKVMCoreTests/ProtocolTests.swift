import XCTest
import ImageIO
@testable import SMKVMCore

/// Writes bits MSB-first into 32-bit words stored little-endian — the
/// inverse of the AST2100 BitReader.
private struct BitWriter {
    var words: [UInt32] = []
    var cur: UInt64 = 0
    var n = 0

    mutating func put(_ v: UInt32, _ bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            cur = cur << 1 | UInt64(v >> i & 1)
            n += 1
            if n == 32 { words.append(UInt32(cur)); cur = 0; n = 0 }
        }
    }

    mutating func put(_ s: String) {
        for ch in s { put(ch == "1" ? 1 : 0, 1) }
    }

    var bytes: [UInt8] {
        var w = words
        if n > 0 { w.append(UInt32(cur << (32 - n))) }
        return w.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 24)] }
    }
}

final class HermonTests: XCTestCase {
    func testTileLandsAtRowColumn() throws {
        var p: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0]
        p += [0, 0, 0, 0, 1, 2]                      // a, b, row 1, col 2
        // Pure red in RGB555 LE: 0x7C00.
        for _ in 0..<256 { p += [0x00, 0x7C] }
        let fb = Framebuffer(width: 0, height: 0)
        try HermonDecoder.decode(p, width: 64, height: 32, into: fb)
        XCTAssertEqual(fb.width, 64)
        XCTAssertEqual(fb.pixels[16 * 64 + 32], 0xFFFF_0000)
        XCTAssertEqual(fb.pixels[31 * 64 + 47], 0xFFFF_0000)
        XCTAssertEqual(fb.pixels[16 * 64 + 31], 0xFF00_0000)
    }

    func testOverhangingTileIsClipped() throws {
        var p: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        for _ in 0..<256 { p += [0xFF, 0x7F] }
        let fb = Framebuffer(width: 0, height: 0)
        try HermonDecoder.decode(p, width: 10, height: 6, into: fb)
        XCTAssertEqual(fb.pixels.count, 60)
        XCTAssertEqual(fb.pixels[59], 0xFFFF_FFFF)
    }

    func testRawFrame() throws {
        var p: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        p += [0x1F, 0x00, 0xE0, 0x03]                 // blue, green
        let fb = Framebuffer(width: 0, height: 0)
        try HermonDecoder.decode(p, width: 2, height: 1, into: fb)
        XCTAssertEqual(fb.pixels, [0xFF00_00FF, 0xFF00_FF00])
    }
}

final class AST2100Tests: XCTestCase {
    private func frame(_ build: (inout BitWriter) -> Void) -> [UInt8] {
        var w = BitWriter()
        build(&w)
        return [11, 11, 0x01, 0xBC] + w.bytes   // selectors 11/11, 4:4:4
    }

    func testFlatDCTBlockIsMidGrey() throws {
        let data = frame { w in
            w.put(0x8, 4); w.put(1, 8); w.put(0, 8)   // positioned block at MCU (1,0)
            w.put("00"); w.put("1010")                 // Y: DC cat 0, AC EOB
            w.put("00"); w.put("00")                   // Cb
            w.put("00"); w.put("00")                   // Cr
            w.put(0x9, 4)
        }
        let fb = Framebuffer(width: 0, height: 0)
        try AST2100Decoder().decode(data, width: 16, height: 8, into: fb)
        let px = fb.pixels[3 * 16 + 12]
        XCTAssertEqual(px, 0xFF82_8282)               // 1.164 × (128 − 16) ≈ 130
        XCTAssertEqual(fb.pixels[0], 0xFF00_0000)     // MCU (0,0) untouched
    }

    func testVQBlockUpdatesCodebook() throws {
        let data = frame { w in
            w.put(0xD, 4); w.put(0, 8); w.put(0, 8)   // 1-colour VQ at (0,0)
            w.put(1, 1); w.put(2, 2)                   // update slot 2
            w.put(0xFF, 8); w.put(0x80, 8); w.put(0x80, 8)
            w.put(0x5, 4)                              // next MCU (1,0): 1 colour, reuse slot 2
            w.put(0, 1); w.put(2, 2)
            w.put(0x9, 4)
        }
        let fb = Framebuffer(width: 0, height: 0)
        try AST2100Decoder().decode(data, width: 16, height: 8, into: fb)
        XCTAssertEqual(fb.pixels[0], 0xFFFF_FFFF)
        XCTAssertEqual(fb.pixels[7 * 16 + 15], 0xFFFF_FFFF)
    }

    func testDCValueShiftsBrightness() throws {
        // Y DC cat 6 (luma DC code "1110"), value +63. Selector 11's QT is all
        // ones, so the pixel moves by 63/8 ≈ 8 levels above mid grey.
        let data = frame { w in
            w.put(0x0, 4)
            w.put("1110"); w.put(63, 6); w.put("1010")
            w.put("00"); w.put("00")
            w.put("00"); w.put("00")
            w.put(0x9, 4)
        }
        let fb = Framebuffer(width: 0, height: 0)
        try AST2100Decoder().decode(data, width: 8, height: 8, into: fb)
        let y = fb.pixels[0] & 0xFF
        XCTAssertGreaterThan(y, 0x82)
        XCTAssertEqual(fb.pixels[0], fb.pixels[63])   // DC-only block is flat
    }

    func testBitReaderWordOrder() {
        // Word 0x80000001 stored LE: first bit read is the word's MSB.
        var r = BitReader([0, 0, 0, 0, 0x01, 0x00, 0x00, 0x80], start: 4)
        XCTAssertEqual(r.read(1), 1)
        XCTAssertEqual(r.read(30), 0)
        XCTAssertEqual(r.read(1), 1)
    }
}

final class MessageTests: XCTestCase {
    func testKeyEvent() {
        let m = ATENMessages.key(hid: 0x04, down: true)
        XCTAssertEqual(m.count, 18)
        XCTAssertEqual(Array(m.prefix(9)), [4, 0, 1, 0, 0, 0, 0, 0, 0x04])
    }

    func testPointerEvent() {
        let m = ATENMessages.pointer(x: 0x123, y: 0x45, buttons: 1)
        XCTAssertEqual(m.count, 18)
        XCTAssertEqual(Array(m.prefix(7)), [5, 0, 1, 0x01, 0x23, 0x00, 0x45])
    }

    func testCredentialsArePadded() {
        let m = ATENMessages.credentials(user: "abc", password: String(repeating: "x", count: 30))
        XCTAssertEqual(m.count, 48)
        XCTAssertEqual(Array(m.prefix(4)), [0x61, 0x62, 0x63, 0])
        XCTAssertEqual(m[47], 0)
    }

    func testKeyMap() {
        XCTAssertEqual(KeyMap.hid(forMacKeyCode: 0x00), 0x04)   // A
        XCTAssertEqual(KeyMap.hid(forMacKeyCode: 0x24), 0x28)   // Return
        XCTAssertEqual(KeyMap.hid(forMacKeyCode: 0x37), 0xE3)   // Command → GUI
    }

    func testJNLPParsing() throws {
        let xml = """
        <jnlp spec="1.0+" codebase="http://10.0.0.5:80/">
        <application-desc main-class="tw.com.aten.ikvm.KVMMain">
        <argument>10.0.0.5</argument><argument>Cl8xFRaBRZTRMIR</argument>
        <argument>jwGw&amp;erg==</argument><argument>null</argument>
        <argument>5900</argument><argument>623</argument><argument>2</argument>
        <argument>0</argument></application-desc></jnlp>
        """
        let t = try BMCWeb.parseJNLP(xml, host: "10.0.0.5")
        XCTAssertEqual(t.user, "Cl8xFRaBRZTRMIR")
        XCTAssertEqual(t.password, "jwGw&erg==")
        XCTAssertEqual(t.port, 5900)
        XCTAssertFalse(t.tls)
    }

    func testJNLPWithTLS() throws {
        let args = ["h", "u", "p", "null", "63630", "623", "0", "0", "1", "5900"]
        let xml = args.map { "<argument>\($0)</argument>" }.joined()
        let t = try BMCWeb.parseJNLP(xml, host: "other")
        XCTAssertTrue(t.tls)
        XCTAssertEqual(t.port, 5900)
    }
}

final class ScreenLoggerTests: XCTestCase {
    private func frame(_ w: Int, _ h: Int, _ fill: UInt32, text: Bool) -> FrameSnapshot {
        var px = [UInt32](repeating: fill, count: w * h)
        if text { for i in stride(from: 0, to: px.count / 2, by: 3) { px[i] = 0xFFAA_AAAA } }
        return FrameSnapshot(width: w, height: h, pixels: px)
    }

    private func pngs(_ dir: URL) -> [String] {
        let e = FileManager.default.enumerator(atPath: dir.path)
        return (e?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".png") }.sorted()
    }

    private func drain(_ l: ScreenLogger) {
        let done = expectation(description: "written")
        l.onSaved = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testBlankDetection() {
        XCTAssertTrue(ScreenLogger.isBlank(frame(64, 48, 0xFF00_0000, text: false)))
        XCTAssertFalse(ScreenLogger.isBlank(frame(64, 48, 0xFF00_0000, text: true)))
        // A text cursor on an otherwise clear screen still counts as blank.
        var cursor = frame(640, 400, 0xFF00_0000, text: false).pixels
        for x in 0..<8 { cursor[15 * 640 + x] = 0xFFAA_AAAA; cursor[14 * 640 + x] = 0xFFAA_AAAA }
        XCTAssertTrue(ScreenLogger.isBlank(FrameSnapshot(width: 640, height: 400, pixels: cursor)))
    }

    func testSavesContentBeforeClearOnceEach() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smkvm-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = ScreenLogger(directory: dir)
        let page = frame(64, 48, 0xFF00_0000, text: true)
        let blank = frame(64, 48, 0xFF00_0000, text: false)
        l.feed(page); l.feed(blank)          // cls → 1
        l.feed(blank)                        // still blank → nothing
        l.feed(page); l.feed(blank)          // same page again → deduplicated
        l.feed(frame(80, 50, 0xFF11_1111, text: true))
        l.feed(frame(32, 24, 0xFF00_0000, text: true))   // mode change → 2
        l.sessionEnded()                                  // → 3
        drain(l)
        let files = pngs(dir)
        XCTAssertEqual(files.count, 3, "\(files)")
        XCTAssertEqual(files.filter { $0.hasSuffix("-cls.png") }.count, 1)
        XCTAssertEqual(files.filter { $0.hasSuffix("-mode-change.png") }.count, 1)
        XCTAssertEqual(files.filter { $0.hasSuffix("-disconnect.png") }.count, 1)
    }
}

/// Synthetic text screens: 8×16 character cells with a per-character glyph.
private struct TextScreen {
    static let w = 640, h = 400, bg: UInt32 = 0xFF00_0000, fg: UInt32 = 0xFFC0_C0C0
    var px = [UInt32](repeating: bg, count: w * h)

    mutating func put(_ s: String, row: Int, col: Int = 0) {
        for (i, ch) in s.unicodeScalars.enumerated() {
            let seed = Int(ch.value)
            guard ch != " " else { continue }
            for gy in 2..<14 {
                for gx in 1..<7 where (seed * 31 + gx * 7 + gy * 13) % 3 != 0 {
                    px[(row * 16 + gy) * Self.w + (col + i) * 8 + gx] = Self.fg
                }
            }
        }
    }

    var snap: FrameSnapshot { FrameSnapshot(width: Self.w, height: Self.h, pixels: px) }

    static func page(_ lines: [String]) -> TextScreen {
        var t = TextScreen()
        for (i, l) in lines.enumerated() { t.put(l, row: i) }
        return t
    }
}

final class ScreenChangeTests: XCTestCase {
    let a = (0..<20).map { "Line \($0): the quick brown fox jumps over the lazy dog \($0 * 7)" }
    let b = (0..<12).map { "Other screen \($0) — BOOT MENU ENTRY NUMBER \($0 * 13)" }

    func testClearAndRedrawIsReplacement() {
        XCTAssertEqual(ScreenLogger.compare(TextScreen.page(a).snap, TextScreen.page(b).snap), .replaced)
    }

    func testScrollIsNotReplacement() {
        let scrolled = TextScreen.page(Array(a.dropFirst()) + ["Line 20: a brand new line at the bottom"])
        XCTAssertEqual(ScreenLogger.compare(TextScreen.page(a).snap, scrolled.snap), .scrolled)
    }

    func testTypingIsSmall() {
        var typed = TextScreen.page(a)
        typed.put("x", row: 21, col: 0)
        XCTAssertEqual(ScreenLogger.compare(TextScreen.page(a).snap, typed.snap), .small)
    }

    func testAppendedLineIsNotReplacement() {
        let post = TextScreen.page(Array(a.prefix(5)))
        let more = TextScreen.page(Array(a.prefix(6)))
        XCTAssertNotEqual(ScreenLogger.compare(post.snap, more.snap), .replaced)
    }

    func testBoxedScreenEditIsNotScroll() {
        // A setup-style screen: a frame with vertical borders on every row.
        func boxed(_ lines: [String]) -> FrameSnapshot {
            var t = TextScreen.page(lines.map { "  " + $0 })
            for y in 0..<TextScreen.h { t.px[y * TextScreen.w + 4] = TextScreen.fg; t.px[y * TextScreen.w + 600] = TextScreen.fg }
            return t.snap
        }
        let tab1 = boxed((0..<15).map { "Main option \($0)" })
        let tab2 = boxed((0..<15).map { "ADVANCED SETTING \($0 * 3) >" })
        XCTAssertEqual(ScreenLogger.compare(tab1, tab2), .replaced)
    }

    func testLoggerSavesScreenBeforeFastRedraw() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smkvm-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = ScreenLogger(directory: dir)
        var cursor = TextScreen.page(a)
        l.feed(TextScreen.page(a).snap)
        cursor.put("_", row: 21)
        l.feed(cursor.snap)                              // cursor blink: nothing
        l.feed(TextScreen.page(b).snap)                  // redraw, no blank → save A
        let s1 = TextScreen.page(Array(b.dropFirst()) + ["scrolled line"])
        l.feed(s1.snap)                                  // scroll: nothing
        let done = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
        wait(for: [done], timeout: 2)
        let files = (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".png") }
        XCTAssertEqual(files.count, 1, "\(files)")
        XCTAssertTrue(files.first?.hasSuffix("-screen-change.png") == true)
    }
}

/// Optional check against real captures: SMKVM_REAL_POST and SMKVM_REAL_SETUP
/// point at two PNGs of different screens at the same resolution.
final class RealFrameTests: XCTestCase {
    private func load(_ path: String) throws -> FrameSnapshot {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var px = [UInt32](repeating: 0, count: img.width * img.height)
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                bytesPerRow: img.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        return FrameSnapshot(width: img.width, height: img.height, pixels: px)
    }

    func testRealScreens() throws {
        let env = ProcessInfo.processInfo.environment
        guard let post = env["SMKVM_REAL_POST"], let setup = env["SMKVM_REAL_SETUP"] else {
            throw XCTSkip("set SMKVM_REAL_POST / SMKVM_REAL_SETUP")
        }
        let a = try load(post), b = try load(setup)
        XCTAssertEqual(ScreenLogger.compare(a, b), .replaced)
        XCTAssertEqual(ScreenLogger.compare(b, a), .replaced)
        XCTAssertEqual(ScreenLogger.compare(a, a), .small)
        XCTAssertFalse(ScreenLogger.isBlank(a))
    }
}
