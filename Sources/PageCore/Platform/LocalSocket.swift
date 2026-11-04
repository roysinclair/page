import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The few Unix-socket calls that differ between macOS and Linux, for the
/// local socket servers and clients (`AuraLinkServer` — the Page Aura and
/// Page Orbit link — and `HerdrBridge`). Everything else in them is POSIX.
///
/// - SIGPIPE: macOS sets `SO_NOSIGPIPE` once per socket; Linux has no such
///   option, so every write goes through `send(…, MSG_NOSIGNAL)`.
/// - Peer identity: macOS `getpeereid`, Linux `SO_PEERCRED`.
/// - `sockaddr_un`: 104 path bytes and a `sun_len` on macOS, 108 and none on Linux.
enum LocalSocket {
    #if canImport(Darwin)
    /// `sun_path` capacity without the terminating NUL.
    static let maxPathBytes = 103
    #else
    static let maxPathBytes = 107
    #endif

    /// A new AF_UNIX stream socket, or -1.
    static func makeStream() -> Int32 {
        #if canImport(Darwin)
        return socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    /// Never die of SIGPIPE when the other end has gone (macOS: per socket).
    static func disableSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// `write` that can't raise SIGPIPE on either system.
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(fd, buffer, count)
        #else
        return send(fd, buffer, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    static func close(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #elseif canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Musl.close(fd)
        #endif
    }

    /// The uid of the process at the other end of a connected socket.
    static func peerUID(_ fd: Int32) -> uid_t? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        #else
        // struct ucred { pid_t pid; uid_t uid; gid_t gid; } (Glibc hides the
        // type behind _GNU_SOURCE, so read it as three 32-bit fields).
        var cred: (Int32, UInt32, UInt32) = (0, 0, 0)
        var len = socklen_t(MemoryLayout<(Int32, UInt32, UInt32)>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0,
              len == socklen_t(MemoryLayout<(Int32, UInt32, UInt32)>.size) else { return nil }
        return cred.1
        #endif
    }

    /// `sockaddr_un` for `path` (nil when it doesn't fit), passed to `body`
    /// with its length, for `bind` and `connect`.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes, !bytes.contains(0) else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
