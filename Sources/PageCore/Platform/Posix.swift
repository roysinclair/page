import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// POSIX spellings that differ between macOS and Linux.
enum Posix {
    /// `write(2)` (Foundation also has a `write` in scope in some files).
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(fd, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.write(fd, buffer, count)
        #else
        return Musl.write(fd, buffer, count)
        #endif
    }

    /// Marks a pipe so writing to a dead reader fails with EPIPE instead of
    /// raising SIGPIPE. macOS only (`F_SETNOSIGPIPE`); on Linux there is no
    /// per-pipe switch, and `paged` ignores SIGPIPE process-wide at startup,
    /// as the Mac app does in main.swift.
    static func setNoSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        #endif
    }
}

/// `ProcessInfo.ThermalState` on macOS. corelibs Foundation has no thermal
/// state, so elsewhere this is a same-shaped enum the platform fills in
/// (`Platform.thermalState`, /sys/class/thermal on Linux).
#if canImport(Darwin)
typealias ThermalState = ProcessInfo.ThermalState
#else
enum ThermalState: Int {
    case nominal, fair, serious, critical
}
#endif

extension stat {
    /// Last modification, whole and fractional seconds.
    var modificationDate: Date {
        #if canImport(Darwin)
        return Date(timeIntervalSince1970: TimeInterval(st_mtimespec.tv_sec) + TimeInterval(st_mtimespec.tv_nsec) / 1e9)
        #else
        return Date(timeIntervalSince1970: TimeInterval(st_mtim.tv_sec) + TimeInterval(st_mtim.tv_nsec) / 1e9)
        #endif
    }

    /// Last modification, whole seconds (what the callers that used
    /// `st_mtimespec.tv_sec` alone compare).
    var modificationSeconds: TimeInterval {
        #if canImport(Darwin)
        return TimeInterval(st_mtimespec.tv_sec)
        #else
        return TimeInterval(st_mtim.tv_sec)
        #endif
    }
}

extension StringProtocol {
    /// True when the regular expression matches the whole string.
    ///
    /// `^…$` alone is not enough off macOS: corelibs Foundation lets `$` match
    /// before a final newline, so "%12\n" would pass a `^%[0-9]+$` check. The
    /// validators that guard what Page types or runs use this instead.
    func matchesEntirely(_ pattern: String) -> Bool {
        guard let r = range(of: pattern, options: .regularExpression) else { return false }
        return r.lowerBound == startIndex && r.upperBound == endIndex
    }
}

enum RuntimeEnvironment {
    /// Running inside an XCTest bundle. macOS: the XCTestCase class is loaded.
    /// Linux: corelibs XCTest's classes are Swift classes, which
    /// NSClassFromString only finds by their module-qualified name, and the
    /// runner is `<Package>PackageTests.xctest`.
    static let isUnderXCTest: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        #if !canImport(Darwin)
        if NSClassFromString("XCTest.XCTestCase") != nil { return true }
        if let exe = ProcessInfo.processInfo.arguments.first, exe.hasSuffix(".xctest") { return true }
        #endif
        return false
    }()
}
