import Foundation
@testable import PageCore
#if canImport(Glibc)
import Glibc
#endif

/// The Linux `ProcessInspector`: everything from /proc, no subprocess, no
/// root. Only the same user's processes are fully readable (environ and fd
/// need ptrace-read access), which is all Page ever asks about.
///
/// Privacy (as ProcArgs on macOS): argv and the environment can hold secrets.
/// Only allowlisted environment keys are decoded; argv is handed back for the
/// caller to derive from and drop.
final class LinuxProcessInspector: ProcessInspector {
    let root: String
    /// Clock ticks per second (`getconf CLK_TCK`), for /proc/<pid>/stat times.
    let ticksPerSecond: Double
    private let bootTime: () -> Double?

    init(root: String = "/proc") {
        self.root = root
        ticksPerSecond = Double(sysconf(Int32(_SC_CLK_TCK)))
        let r = root
        bootTime = { ProcFS.bootTime(fromStat: (try? String(contentsOfFile: r + "/stat", encoding: .utf8)) ?? "") }
    }

    private func read(_ pid: Int32, _ file: String) -> Data? {
        FileManager.default.contents(atPath: "\(root)/\(pid)/\(file)")
    }

    private func pids() -> [Int32] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).compactMap { Int32($0) }.filter { $0 > 0 }.sorted()
    }

    func stat(_ pid: Int32) -> ProcFS.Stat? {
        read(pid, "stat").flatMap { ProcFS.parseStat(String(decoding: $0, as: UTF8.self)) }
    }

    // MARK: ProcessInspector

    func processTable() -> [ProcessRunner.ProcessInfoRow] {
        pids().compactMap { pid in
            guard let st = stat(pid) else { return nil }
            var argv = read(pid, "cmdline").map(ProcFS.parseNulList) ?? []
            if argv.isEmpty { argv = ["[\(st.comm)]"] } // kernel threads, zombies: as ps shows them
            return ProcessRunner.ProcessInfoRow(pid: pid, ppid: st.ppid,
                                                tty: ProcFS.ttyName(device: st.ttyNr) ?? "??", // as core (and macOS ps) spell "none"
                                                command: argv.joined(separator: " "))
        }
    }

    func arguments(pid: Int32, envKeys: Set<String>) -> ProcArgs.Info? {
        guard pid > 0, let cmd = read(pid, "cmdline") else { return nil }
        let argv = ProcFS.parseNulList(cmd)
        guard !argv.isEmpty else { return nil }
        let env = read(pid, "environ").map { ProcFS.parseEnviron($0, keys: envKeys) } ?? [:]
        return ProcArgs.Info(argv: argv, env: env)
    }

    func startSeconds(pid: Int32) -> Int? {
        guard let st = stat(pid), let boot = bootTime() else { return nil }
        return Int(boot + Double(st.startTicks) / ticksPerSecond)
    }

    func allProcesses() -> [LocalProcInfo.Entry] {
        let boot = bootTime() ?? 0
        return pids().compactMap { pid in
            guard let st = stat(pid) else { return nil }
            let start = boot + Double(st.startTicks) / ticksPerSecond
            let whole = UInt64(max(0, start))
            return LocalProcInfo.Entry(
                pid: pid,
                info: LocalProcInfo.BSDInfo(ppid: st.ppid, tdev: st.ttyNr == 0 ? UInt32.max : UInt32(bitPattern: st.ttyNr),
                                            startSeconds: whole),
                startMicros: Int32((start - Double(whole)) * 1_000_000),
                comm: st.comm)
        }
    }

    func execPath(pid: Int32) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "\(root)/\(pid)/exe")
    }

    func ttyName(device: UInt32) -> String? {
        guard device != UInt32.max, device != 0 else { return nil }
        return ProcFS.ttyName(device: Int32(bitPattern: device))
    }

    func ttyModified(_ ttyName: String) -> Date? {
        // "pts/3" or "tty1": a path under /dev, nothing else.
        guard !ttyName.isEmpty, !ttyName.contains(".."), !ttyName.hasPrefix("/"),
              ttyName.matchesEntirely(#"^(pts/[0-9]+|tty[A-Za-z]*[0-9]+)$"#) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: "/dev/" + ttyName))?[.modificationDate] as? Date
    }

    func listeningTCPPorts(pid: Int32) -> Set<Int>? {
        guard let inodes = socketInodes(pid) else { return nil }
        var ports = Set<Int>()
        for file in ["net/tcp", "net/tcp6"] {
            // The process's own network namespace.
            guard let text = read(pid, file).map({ String(decoding: $0, as: UTF8.self) }) else { continue }
            for l in ProcFS.parseTCPListeners(text) where inodes.contains(l.inode) { ports.insert(l.port) }
        }
        return ports
    }

    func foregroundState(pid: Int32) -> ProcessRunner.ForegroundState {
        guard pid > 0, let st = stat(pid) else { return .unknown }
        return ProcFS.foregroundState(st)
    }

    func lsof(_ args: [String], timeout: TimeInterval) -> ProcessRunner.Result {
        ProcFS.emulateLsof(args, pids: pids(), openFiles: { [weak self] pid in self?.openFiles(pid) },
                           command: { [weak self] pid in self?.stat(pid)?.comm })
    }

    // MARK: fds

    /// Targets of /proc/<pid>/fd/* by descriptor number; nil when unreadable.
    func openFiles(_ pid: Int32) -> [(fd: Int, path: String)]? {
        let dir = "\(root)/\(pid)/fd"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        return names.compactMap { name in
            guard let fd = Int(name), let target = try? FileManager.default.destinationOfSymbolicLink(atPath: dir + "/" + name) else { return nil }
            return (fd, target)
        }.sorted { $0.fd < $1.fd }
    }

    private func socketInodes(_ pid: Int32) -> Set<UInt64>? {
        guard let files = openFiles(pid) else { return nil }
        return Set(files.compactMap { ProcFS.socketInode($0.path) })
    }
}

/// Pure parsers for /proc files, tested against fixtures.
enum ProcFS {
    struct Stat: Equatable {
        let pid: Int32
        let comm: String
        let state: Character
        let ppid: Int32
        let pgrp: Int32
        let session: Int32
        let ttyNr: Int32
        let tpgid: Int32
        let startTicks: UInt64
    }

    /// `/proc/<pid>/stat`. The command name is in parentheses and may itself
    /// hold spaces and ")" — the fields after it start at the LAST ")".
    static func parseStat(_ text: String) -> Stat? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close,
              let pid = Int32(text[..<open].trimmingCharacters(in: .whitespaces)) else { return nil }
        let comm = String(text[text.index(after: open)..<close])
        let rest = text[text.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
        // rest[0] = state (field 3), rest[1] = ppid (4) … rest[19] = starttime (22)
        guard rest.count >= 20, let state = rest[0].first,
              let ppid = Int32(rest[1]), let pgrp = Int32(rest[2]), let session = Int32(rest[3]),
              let tty = Int32(rest[4]), let tpgid = Int32(rest[5]), let start = UInt64(rest[19]) else { return nil }
        return Stat(pid: pid, comm: comm, state: state, ppid: ppid, pgrp: pgrp, session: session,
                    ttyNr: tty, tpgid: tpgid, startTicks: start)
    }

    /// `btime` from /proc/stat: boot time, seconds since the epoch.
    static func bootTime(fromStat text: String) -> Double? {
        for line in text.split(separator: "\n") where line.hasPrefix("btime ") {
            return Double(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// NUL-separated strings (cmdline). A trailing NUL ends the last one.
    static func parseNulList(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
            .reversed().drop { $0.isEmpty }.reversed()
    }

    /// Only `keys` are decoded from /proc/<pid>/environ; the rest is dropped unread.
    static func parseEnviron(_ data: Data, keys: Set<String>) -> [String: String] {
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let eq = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = String(decoding: entry[entry.startIndex..<eq], as: UTF8.self)
            guard keys.contains(key) else { continue }
            env[key] = String(decoding: entry[entry.index(after: eq)...], as: UTF8.self)
        }
        return env
    }

    /// The device number in /proc/<pid>/stat's `tty_nr` as ps names it:
    /// "pts/3" (Unix 98 pseudo-terminals, majors 136–143), "tty1" (major 4),
    /// "ttyS0" (major 4, minors 64+). nil for none or unknown majors.
    static func ttyName(device: Int32) -> String? {
        guard device != 0 else { return nil }
        let d = UInt32(bitPattern: device)
        let major = (d >> 8) & 0xFFF
        let minor = (d & 0xFF) | ((d >> 12) & 0xFFF00)
        switch major {
        case 136...143: return "pts/\((major - 136) * 256 + minor)"
        case 4: return minor < 64 ? "tty\(minor)" : "ttyS\(minor - 64)"
        default: return nil
        }
    }

    /// Job control from stat: stopped (T/t) or zombie/dead (Z/X) is "stopped".
    static func foregroundState(_ st: Stat) -> ProcessRunner.ForegroundState {
        switch st.state {
        case "T", "t", "Z", "X", "x": return .stopped
        default: return ProcessRunner.foregroundState(stat: 0, pgid: st.pgrp, tpgid: st.tpgid, hasTTY: st.ttyNr != 0)
        }
    }

    struct TCPListener: Equatable {
        let port: Int
        let inode: UInt64
    }

    /// Listening sockets (state 0A) from /proc/net/tcp or tcp6.
    static func parseTCPListeners(_ text: String) -> [TCPListener] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 10, cols[3] == "0A" else { return nil }
            let local = cols[1].split(separator: ":")
            guard local.count == 2, let port = Int(local[1], radix: 16), let inode = UInt64(cols[9]) else { return nil }
            return TCPListener(port: port, inode: inode)
        }
    }

    /// "socket:[12345]" → 12345.
    static func socketInode(_ target: String) -> UInt64? {
        guard target.hasPrefix("socket:["), target.hasSuffix("]") else { return nil }
        return UInt64(target.dropFirst(8).dropLast())
    }

    /// The two lsof calls CodexInjector makes, answered from /proc in lsof's
    /// `-F` field format so its parsers stay as they are:
    ///   `-a -p 1,2 -F fn`           → p<pid> / f<fd> / n<path> for the pids' open files
    ///   `-w -F pc -- <path>`        → p<pid> / c<command> for processes holding <path>
    /// Exit 1 with empty output means "nobody", as lsof says it.
    static func emulateLsof(_ args: [String], pids: [Int32],
                            openFiles: (Int32) -> [(fd: Int, path: String)]?,
                            command: (Int32) -> String?) -> ProcessRunner.Result {
        func result(_ out: String, _ status: Int32) -> ProcessRunner.Result {
            ProcessRunner.Result(status: status, stdout: out, stderr: "", timedOut: false, launched: true)
        }
        if let pIndex = args.firstIndex(of: "-p"), pIndex + 1 < args.count {
            let wanted = args[pIndex + 1].split(separator: ",").compactMap { Int32($0) }
            var out = ""
            for pid in wanted {
                guard let files = openFiles(pid) else { continue }
                out += "p\(pid)\n"
                for f in files { out += "f\(f.fd)\nn\(f.path)\n" }
            }
            return result(out, out.isEmpty ? 1 : 0)
        }
        if let dash = args.firstIndex(of: "--"), dash + 1 < args.count {
            let path = args[dash + 1]
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var out = ""
            for pid in pids {
                guard let files = openFiles(pid), files.contains(where: { $0.path == path || $0.path == resolved }) else { continue }
                out += "p\(pid)\nc\(command(pid) ?? "")\n"
            }
            return result(out, out.isEmpty ? 1 : 0)
        }
        return ProcessRunner.Result(status: 1, stdout: "", stderr: "unsupported lsof arguments", timedOut: false, launched: true)
    }
}
