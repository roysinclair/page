import Foundation
@testable import PageCore
#if canImport(Glibc)
import Glibc
#endif

public enum PagedVersion {
    public static let string = "0.1.0"
}

/// Where paged keeps its own files, beside the core's (PlatformPaths).
struct DaemonFiles {
    let paths: PlatformPaths
    /// Holds the single-instance lock and the daemon's pid. 0600.
    var pidFile: URL { paths.support.appendingPathComponent("paged.pid") }
    /// What `paged status` reads: written on every state change. 0600.
    var statusFile: URL { paths.logs.appendingPathComponent("status.json") }
    var logFile: URL { paths.logs.appendingPathComponent(paths.logFileName) }
    /// The pairing QR as a picture (it holds the token: 0600).
    var pairingPNG: URL { paths.support.appendingPathComponent("pairing-qr.png") }
    /// Where install-linux.sh puts the hook scripts.
    var hookScript: URL { paths.support.appendingPathComponent("hooks/page-notify.sh") }
    /// The systemd user unit install-linux.sh writes.
    var unitFile: URL {
        let env = ProcessInfo.processInfo.environment
        let config = env["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? paths.home.appendingPathComponent(".config")
        return config.appendingPathComponent("systemd/user/paged.service")
    }

    /// Creates Page's folders owner-only (0700) before anything else writes
    /// into them. Existing folders are tightened too.
    func prepareDirectories() throws {
        let fm = FileManager.default
        for dir in [paths.config, paths.support, paths.logs] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}

/// Owner-only atomic file writes (0600 from creation, then rename).
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent().path
        let tmp = "\(dir)/.\(url.lastPathComponent).\(getpid()).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var ok = true
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Posix.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; ok = false; break }
                off += n
            }
        }
        close(fd)
        guard ok, rename(tmp, url.path) == 0 else {
            unlink(tmp)
            throw POSIXError(.EIO)
        }
    }
}

/// The single-instance lock: an flock on the pid file, held for the
/// daemon's life (the kernel drops it when the process ends).
final class InstanceLock {
    private var fd: Int32 = -1

    /// nil when another paged holds it.
    static func acquire(at url: URL) -> InstanceLock? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        _ = ftruncate(fd, 0)
        let text = Array("\(getpid())\n".utf8)
        _ = text.withUnsafeBytes { Posix.write(fd, $0.baseAddress, $0.count) }
        let lock = InstanceLock()
        lock.fd = fd
        return lock
    }

    /// The running daemon's pid, if the pid file names a live `paged`.
    static func runningPid(at url: URL, procRoot: String = "/proc") -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        // A pid can be reused: it must still be paged, and still hold the lock.
        let comm = (try? String(contentsOfFile: "\(procRoot)/\(pid)/comm", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard comm == "paged" else { return nil }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return nil // nobody holds it: a stale file
        }
        return pid
    }
}

/// What `paged status` shows, as the daemon last wrote it.
struct DaemonStatus: Codable, Equatable {
    var version: String
    var pid: Int32
    var startedAt: Date
    var updatedAt: Date
    var relay: String
    var sessions: [Session]
    var pendingPages: Int
    var keepAwake: String
    var keepAwakeProblem: String?
    var lidClosedOnBattery: Bool
    var battery: String
    var presence: String
    var configProblem: String?
    var statusLine: String

    struct Session: Codable, Equatable {
        var agent: String
        var state: String
        var project: String
    }

    static func relayText(_ r: Coordinator.RelayState) -> String {
        switch r {
        case .off: return "off"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .misconfigured(let why): return "misconfigured: \(why)"
        }
    }

    static func batteryText(_ p: PowerSnapshot) -> String {
        guard p.hasBattery else { return "no battery (on AC)" }
        return "\(p.percent)% \(p.isCharging ? "charging" : (p.onAC ? "on AC" : "on battery"))"
    }

    static func awakeText(_ a: AwakeAssertions) -> String {
        switch (a.preventIdleSleep, a.preventSystemSleep) {
        case (false, false): return "off"
        case (true, false): return "on (idle:sleep inhibitor)"
        case (true, true): return "on (idle:sleep + lid switch inhibitors)"
        case (false, true): return "lid switch inhibitor only"
        }
    }
}

/// Is logind there to hand out inhibitors? Checked once at start so the
/// log and `paged status` can say so plainly.
enum LogindProbe {
    static func check() -> String? {
        guard let tool = LogindInhibitor.findTool() else { return LogindInhibitor.unavailableMessage }
        let r = ProcessRunner.run(tool, ["--list", "--no-pager", "--no-legend"], timeout: 3)
        if r.succeeded { return nil }
        return LogindInhibitor.explainFailure(stderr: r.stderr.isEmpty ? r.stdout : r.stderr)
    }
}

/// `paged run`: the daemon.
final class PagedDaemon {
    private let files: DaemonFiles
    private var coordinator: Coordinator!
    private var lock: InstanceLock?
    private var signalSources: [DispatchSourceSignal] = []
    private let startedAt = Date()
    private var logindProblem: String?
    private var lastToken: String?
    private let statusQueue = DispatchQueue(label: "paged.status")
    private var power: LinuxPowerBackend?

    init(files: DaemonFiles) { self.files = files }

    func run() -> Never {
        // As main.swift on macOS: a write to a dead pipe must fail with EPIPE.
        signal(SIGPIPE, SIG_IGN)
        do { try files.prepareDirectories() } catch {
            FileHandle.standardError.write(Data("paged: can't create \(files.paths.support.path): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        guard let lock = InstanceLock.acquire(at: files.pidFile) else {
            FileHandle.standardError.write(Data("paged is already running (see `paged status`)\n".utf8))
            exit(1)
        }
        self.lock = lock
        RelayClient.agentVersion = PagedVersion.string
        Logger.shared.log("paged \(PagedVersion.string) starting (pid \(getpid()); config \(files.paths.configFile.path); data \(files.paths.support.path))")

        logindProblem = LogindProbe.check()
        if let p = logindProblem { Logger.shared.log("Keep-awake unavailable: \(p)") }

        var platform = Platform.linux
        // Keep a handle on the power backend for `paged status` ("why isn't it awake?").
        let backend = LinuxPowerBackend()
        power = backend
        platform.makePower = { backend }
        coordinator = Coordinator(platform: platform)
        lastToken = PairingTokenManager.currentToken()

        let notifier = platform.notifier
        coordinator.onStateChange = { [weak self] snap in self?.writeStatus(snap) }
        coordinator.onNewIntervention = { event in
            notifier?.notify(title: "\(AgentDisplay.agentName(event.backend)) needs you — \(event.projectName)",
                             body: String(event.context.prefix(240)), identifier: event.id)
        }
        coordinator.onNewRateLimit = { notice in
            let reset = DateFormatter.localizedString(from: notice.event.resetTime, dateStyle: .none, timeStyle: .short)
            notifier?.notify(title: "Rate limited — \(notice.event.projectName)",
                             body: notice.scheduledResume != nil ? "Page Studio will carry on at \(reset)" : "Resets at \(reset)",
                             identifier: "rate-limit")
        }
        coordinator.onBatteryNotice = { notice in
            notifier?.notify(title: notice.title, body: notice.body, identifier: "battery")
        }

        installSignals()
        coordinator.start()
        dispatchMain()
    }

    private func installSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGUSR1] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.handle(sig) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func handle(_ sig: Int32) {
        switch sig {
        case SIGHUP:
            Logger.shared.log("SIGHUP: reloading config")
            coordinator.reloadConfig()
        case SIGUSR1:
            // `paged pair --regenerate` wrote a new token: retire the old one
            // and reconnect, as the app does in-process on macOS.
            let fresh = PairingTokenManager.currentToken()
            let previous = lastToken
            lastToken = fresh
            if previous != fresh {
                Logger.shared.log("Pairing token changed — reconnecting the relay")
                coordinator.reconnectRelay(retiring: previous)
            } else {
                coordinator.nudgeRelay()
            }
        default:
            Logger.shared.log("Received signal \(sig) — releasing inhibitors and stopping")
            coordinator.releaseSleepOverrides(reason: "signal \(sig)")
            coordinator.shutdown()
            try? FileManager.default.removeItem(at: files.statusFile)
            // Give the log queue a moment to flush.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }

    private func writeStatus(_ s: Coordinator.Snapshot) {
        let presence = (Platform.current.presence as? LinuxPresence)?.reading()
        let problem = logindProblem ?? (power?.problem)
        let status = DaemonStatus(
            version: PagedVersion.string, pid: getpid(), startedAt: startedAt, updatedAt: Date(),
            relay: DaemonStatus.relayText(s.relayState),
            sessions: s.sessions.map {
                DaemonStatus.Session(agent: AgentDisplay.agentName($0.backend), state: "\($0.state)",
                                     project: $0.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
            },
            pendingPages: s.pendingInterventions.count,
            keepAwake: DaemonStatus.awakeText(s.awake), keepAwakeProblem: problem,
            lidClosedOnBattery: s.lidClosedOnBattery, battery: DaemonStatus.batteryText(s.power),
            presence: presence.map { $0.seconds.isFinite ? "idle \(Int($0.seconds))s (\($0.source))" : "away (\($0.source))" } ?? "unknown",
            configProblem: s.configProblem, statusLine: s.statusLine)
        statusQueue.async { [files] in
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(status) { try? PrivateFile.write(data, to: files.statusFile) }
        }
    }
}
