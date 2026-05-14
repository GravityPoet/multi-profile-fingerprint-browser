import Darwin
import Foundation

enum PortAllocatorError: Error, LocalizedError {
    case rangeExhausted(from: Int, to: Int)

    var errorDescription: String? {
        switch self {
        case .rangeExhausted(let from, let to):
            return "No free Marionette port in range \(from)–\(to)"
        }
    }
}

/// Allocates Marionette ports for spawned Camoufox instances.
/// Starts at 2828 (Firefox's default Marionette port) and walks up,
/// checking each port by attempting a `bind(127.0.0.1:port)`.
/// Allocations are tracked in-memory so two simultaneous launches
/// in the same app process never request the same port.
final class PortAllocator {
    static let shared = PortAllocator()

    private let queue = DispatchQueue(label: "local.multi-profile-fingerprint-browser.port-allocator")
    private var reserved = Set<Int>()

    private let defaultStart = 2828
    private let defaultEnd = 2828 + 200

    private init() {}

    /// Returns the first free port in `[start, end]` that is both unbound
    /// at the OS level and not already reserved in this process.
    func allocate(start: Int? = nil, end: Int? = nil) throws -> Int {
        let s = start ?? defaultStart
        let e = end ?? defaultEnd
        return try queue.sync {
            for port in s...e where !reserved.contains(port) {
                if Self.isPortFree(port) {
                    reserved.insert(port)
                    AppLogger.info("Allocated Marionette port \(port)")
                    return port
                }
            }
            throw PortAllocatorError.rangeExhausted(from: s, to: e)
        }
    }

    /// Returns a port to the pool when the corresponding Camoufox process exits.
    func release(_ port: Int) {
        queue.sync {
            if reserved.remove(port) != nil {
                AppLogger.debug("Released Marionette port \(port)")
            }
        }
    }

    // MARK: OS probe

    /// Attempts a temporary `bind` on `127.0.0.1:port`. If bind succeeds we
    /// know the port is currently free; we then close immediately so the
    /// caller can use it. `SO_REUSEADDR` is intentionally NOT set: we want
    /// the same behaviour Firefox will see when it tries to bind.
    private static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
