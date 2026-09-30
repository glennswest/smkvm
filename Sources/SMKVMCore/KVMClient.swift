import Foundation

/// One KVM session to one BMC: HTTP login → session key → ATEN RFB on 5900.
/// Callbacks are delivered on the main queue.
public final class KVMClient: @unchecked Sendable {
    public var onFrame: ((Framebuffer) -> Void)?
    public var onStatus: ((String) -> Void)?

    public let host: String
    private let user: String
    private let password: String

    public init(host: String, user: String, password: String) {
        self.host = host
        self.user = user
        self.password = password
    }

    public func start() {
        // Protocol implementation lands with docs/protocol.md.
        DispatchQueue.main.async { self.onStatus?("protocol not implemented yet") }
    }

    public func stop() {}

    public func sendKey(macKeyCode: UInt16, down: Bool) {}

    public func sendPointer(x: Int, y: Int, buttons: UInt8) {}

    public func sendCtrlAltDel() {}
}
