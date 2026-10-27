import Testing
@testable import SMKVMCore

struct JetKVMInputTests {
    @Test func keyboardReportSplitsModifiers() {
        // Left Shift (E1) + Left Ctrl (E0) + 'a' (04)
        let r = JetKVMInput.keyboardReport(held: [0xE1, 0xE0, 0x04])
        #expect(r.modifier == 0b0000_0011)
        #expect(r.keys == [0x04])
    }

    @Test func keyboardReportCapsAtSixKeys() {
        let r = JetKVMInput.keyboardReport(held: [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(r.keys.count == 6)
        #expect(r.modifier == 0)
    }

    @Test func keyboardReportEmpty() {
        let r = JetKVMInput.keyboardReport(held: [])
        #expect(r.modifier == 0)
        #expect(r.keys == [])
    }

    @Test func buttonRemapRFBToHID() {
        #expect(JetKVMInput.hidButtons(rfb: 0) == 0)
        #expect(JetKVMInput.hidButtons(rfb: 1) == 1)   // left → left
        #expect(JetKVMInput.hidButtons(rfb: 2) == 4)   // middle → HID middle
        #expect(JetKVMInput.hidButtons(rfb: 4) == 2)   // right → HID right
        #expect(JetKVMInput.hidButtons(rfb: 7) == 7)   // all three
    }

    @Test func absCoordScaling() {
        #expect(JetKVMInput.absCoord(0, extent: 1920) == 0)
        #expect(JetKVMInput.absCoord(1919, extent: 1920) == 32767)
        #expect(JetKVMInput.absCoord(960, extent: 1920) == 960 * 32767 / 1919)
        // Degenerate extents never divide by zero or go out of range.
        #expect(JetKVMInput.absCoord(5, extent: 0) == 0)
        #expect(JetKVMInput.absCoord(5, extent: 1) == 0)
        #expect(JetKVMInput.absCoord(99999, extent: 100) == 32767)
        #expect(JetKVMInput.absCoord(-7, extent: 100) == 0)
    }
}
