import Foundation

/// Finds JetKVMs with no infrastructure: an HTTP sweep of the local IPv4
/// subnets, fingerprinting `GET /device/status` (the one JetKVM endpoint
/// that answers before setup and without auth). The devices only announce
/// a `<hostname>.local` mDNS name — there is no DNS-SD service to browse —
/// so a sweep is what works on any network.
public enum JetKVMDiscovery {
    public struct Device: Sendable, Equatable {
        public let address: String
        public let isSetup: Bool
    }

    /// The /24 of every up, non-loopback IPv4 interface, as "a.b.c" prefixes.
    public static func localSubnets() -> [String] {
        var result: [String] = []
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return [] }
        defer { freeifaddrs(addrs) }
        var p = addrs
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            // Link-local means no DHCP happened; nothing to find there.
            guard !ip.hasPrefix("169.254."), !result.contains(prefix) else { continue }
            result.append(prefix)
        }
        return result
    }

    /// Sweeps the given "a.b.c" prefixes (default: every local /24) and
    /// returns the JetKVMs found. Blocking — call off the main thread.
    /// A /24 takes about `timeout` × 4 at 64-way concurrency.
    public static func scan(subnets: [String]? = nil, timeout: TimeInterval = 1.0,
                            progress: ((String) -> Void)? = nil) -> [Device] {
        let prefixes = subnets ?? localSubnets()
        guard !prefixes.isEmpty else { return [] }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let found = Found()
        let gate = DispatchSemaphore(value: 64)
        let group = DispatchGroup()
        for prefix in prefixes {
            progress?("scanning \(prefix).0/24")
            for n in 1...254 {
                let ip = "\(prefix).\(n)"
                guard let url = URL(string: "http://\(ip)/device/status") else { continue }
                gate.wait()
                group.enter()
                session.dataTask(with: url) { data, response, _ in
                    defer { gate.signal(); group.leave() }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          let data,
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let isSetup = obj["isSetup"] as? Bool else { return }
                    found.add(Device(address: ip, isSetup: isSetup))
                }.resume()
            }
        }
        group.wait()
        return found.sorted()
    }

    /// Thread-safe collection bucket for the concurrent probes.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var devices: [Device] = []

        func add(_ d: Device) {
            lock.lock()
            devices.append(d)
            lock.unlock()
        }

        func sorted() -> [Device] {
            lock.lock()
            defer { lock.unlock() }
            return devices.sorted {
                let a = $0.address.split(separator: ".").compactMap { Int($0) }
                let b = $1.address.split(separator: ".").compactMap { Int($0) }
                return a.lexicographicallyPrecedes(b)
            }
        }
    }
}
