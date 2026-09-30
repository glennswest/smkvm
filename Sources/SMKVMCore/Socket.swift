import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum SocketError: Error, CustomStringConvertible {
    case resolve(String)
    case connect(String)
    case closed
    case io(String)
    case timedOut

    public var description: String {
        switch self {
        case .resolve(let s): return "cannot resolve \(s)"
        case .connect(let s): return "connect failed: \(s)"
        case .closed: return "connection closed by BMC"
        case .io(let s): return "socket error: \(s)"
        case .timedOut: return "BMC stopped responding"
        }
    }
}

/// Blocking TCP socket with a read buffer. Reads happen on one thread;
/// writes may come from any thread and are serialised.
final class Socket: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private var buf = [UInt8](repeating: 0, count: 64 * 1024)
    private var bufStart = 0
    private var bufEnd = 0

    init(host: String, port: Int, timeout: TimeInterval = 5) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw SocketError.resolve(host)
        }
        defer { freeaddrinfo(res) }

        var lastError = "no addresses"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            ai = a.pointee.ai_next
            let s = Darwin.socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s < 0 { continue }
            if Self.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen, timeout, &lastError) {
                var one: Int32 = 1
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                fd = s
                return
            }
            Darwin.close(s)
        }
        throw SocketError.connect("\(host):\(port): \(lastError)")
    }

    private static func connect(_ s: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: socklen_t,
                                _ timeout: TimeInterval, _ err: inout String) -> Bool {
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(s, F_SETFL, flags) }
        if Darwin.connect(s, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { err = String(cString: strerror(errno)); return false }
        var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        let n = poll(&p, 1, Int32(timeout * 1000))
        if n <= 0 { err = "timed out"; return false }
        var soErr: Int32 = 0
        var l = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &l)
        if soErr != 0 { err = String(cString: strerror(soErr)); return false }
        return true
    }

    deinit { Darwin.close(fd) }

    /// Bounds each blocking read (0 = wait forever). Used so a server that
    /// accepts the TCP connection but never speaks can't stall the handshake.
    func setReadTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Unblocks a reader stuck in recv; subsequent I/O fails.
    func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }

    // MARK: reading

    private func fill() throws {
        if bufStart == bufEnd { bufStart = 0; bufEnd = 0 }
        if bufEnd == buf.count {
            buf.removeSubrange(0..<bufStart)
            buf.append(contentsOf: [UInt8](repeating: 0, count: bufStart))
            bufEnd -= bufStart
            bufStart = 0
        }
        let n = buf.withUnsafeMutableBytes { p in
            recv(fd, p.baseAddress! + bufEnd, p.count - bufEnd, 0)
        }
        if n == 0 { throw SocketError.closed }
        if n < 0 {
            if errno == EINTR { return }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timedOut }
            throw SocketError.io(String(cString: strerror(errno)))
        }
        bufEnd += n
    }

    func read(_ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            if bufStart == bufEnd { try fill() }
            let take = min(count - out.count, bufEnd - bufStart)
            out.append(contentsOf: buf[bufStart..<bufStart + take])
            bufStart += take
        }
        return out
    }

    func skip(_ count: Int) throws {
        var left = count
        while left > 0 {
            if bufStart == bufEnd { try fill() }
            let take = min(left, bufEnd - bufStart)
            bufStart += take
            left -= take
        }
    }

    func u8() throws -> UInt8 {
        if bufStart == bufEnd { try fill() }
        defer { bufStart += 1 }
        return buf[bufStart]
    }

    func u16() throws -> UInt16 {
        let b = try read(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    func u32() throws -> UInt32 {
        let b = try read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    // MARK: writing

    func write(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { p in
                send(fd, p.baseAddress! + off, bytes.count - off, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.io(String(cString: strerror(errno)))
            }
            off += n
        }
    }
}
