import XCTest
@testable import SMKVMCore

final class FramebufferTests: XCTestCase {
    func testFillClipsToBounds() {
        let fb = Framebuffer(width: 4, height: 3)
        fb.fill(x: 2, y: 1, w: 10, h: 10, argb: 0xFFFF_0000)
        XCTAssertEqual(fb.pixels[1 * 4 + 1], 0xFF00_0000)
        XCTAssertEqual(fb.pixels[1 * 4 + 2], 0xFFFF_0000)
        XCTAssertEqual(fb.pixels[2 * 4 + 3], 0xFFFF_0000)
    }

    func testResizeClears() {
        let fb = Framebuffer(width: 2, height: 2)
        fb.set(0, 0, 0xFFFF_FFFF)
        fb.resize(width: 3, height: 3)
        XCTAssertEqual(fb.pixels.count, 9)
        XCTAssertEqual(fb.pixels[0], 0xFF00_0000)
    }
}
