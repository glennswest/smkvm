import XCTest
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
