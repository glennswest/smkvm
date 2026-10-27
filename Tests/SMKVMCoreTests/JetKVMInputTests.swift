import XCTest
@testable import SMKVMCore

final class JetKVMInputTests: XCTestCase {
    func testKeyboardReportSplitsModifiers() {
        // Left Shift (E1) + Left Ctrl (E0) + 'a' (04)
        let r = JetKVMInput.keyboardReport(held: [0xE1, 0xE0, 0x04])
        XCTAssertEqual(r.modifier, 0b0000_0011)
        XCTAssertEqual(r.keys, [0x04])
    }

    func testKeyboardReportCapsAtSixKeys() {
        let r = JetKVMInput.keyboardReport(held: [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(r.keys.count, 6)
        XCTAssertEqual(r.modifier, 0)
    }

    func testKeyboardReportEmpty() {
        let r = JetKVMInput.keyboardReport(held: [])
        XCTAssertEqual(r.modifier, 0)
        XCTAssertEqual(r.keys, [])
    }

    func testButtonRemapRFBToHID() {
        XCTAssertEqual(JetKVMInput.hidButtons(rfb: 0), 0)
        XCTAssertEqual(JetKVMInput.hidButtons(rfb: 1), 1)   // left → left
        XCTAssertEqual(JetKVMInput.hidButtons(rfb: 2), 4)   // middle → HID middle
        XCTAssertEqual(JetKVMInput.hidButtons(rfb: 4), 2)   // right → HID right
        XCTAssertEqual(JetKVMInput.hidButtons(rfb: 7), 7)   // all three
    }

    func testAbsCoordScaling() {
        XCTAssertEqual(JetKVMInput.absCoord(0, extent: 1920), 0)
        XCTAssertEqual(JetKVMInput.absCoord(1919, extent: 1920), 32767)
        XCTAssertEqual(JetKVMInput.absCoord(960, extent: 1920), 960 * 32767 / 1919)
        // Degenerate extents never divide by zero or go out of range.
        XCTAssertEqual(JetKVMInput.absCoord(5, extent: 0), 0)
        XCTAssertEqual(JetKVMInput.absCoord(5, extent: 1), 0)
        XCTAssertEqual(JetKVMInput.absCoord(99999, extent: 100), 32767)
        XCTAssertEqual(JetKVMInput.absCoord(-7, extent: 100), 0)
    }
}
