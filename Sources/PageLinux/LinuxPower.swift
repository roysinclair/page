import Foundation
@testable import PageCore
#if canImport(Glibc)
import Glibc
#endif

// Keep-awake on Linux: logind inhibitors.
//
// An inhibitor is a file descriptor logind hands out; it lasts until it is
// closed. `systemd-inhibit --what=… --mode=block <command>` holds one for as
// long as <command> runs, and the command here is
// `tail --pid=<paged's pid> -f /dev/null`, which exits the moment paged does,
// however it ends (crash, SIGKILL). Under the systemd user unit the whole
// control group is also stopped with the service. So nothing persists the way
// macOS's `pmset disablesleep` does: no marker, no watchdog, no sudo.

/// One logind inhibitor of one kind, held by a `systemd-inhibit` child.
final class LogindInhibitor {
    /// "idle:sleep" (agents working) or "handle-lid-switch" (lid closed).
    let what: String
    private let tool: String?
    private let lock = NSLock()
    private var process: Process?
    private var lastFailure: (at: Date, message: String)?
    /// After a failure, don't respawn every tick.
    static let retryAfter: TimeInterval = 300

    init(what: String, tool: String? = LogindInhibitor.findTool()) {
        self.what = what
        self.tool = tool
    }

    static func findTool() -> String? {
        ["/usr/bin/systemd-inhibit", "/bin/systemd-inhibit"].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? ProcessRunner.findExecutable("systemd-inhibit")
    }

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }

    /// Why the last attempt failed, if it did.
    var failure: String? {
        lock.lock(); defer { lock.unlock() }
        return lastFailure?.message
    }

    /// Takes the inhibitor. True when held. Blocks ~0.3 s on the first take
    /// to catch an immediate refusal (no logind, polkit said no).
    @discardableResult
    func acquire(why: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning == true { return true }
        process = nil
        if let f = lastFailure, now.timeIntervalSince(f.at) < Self.retryAfter { return false }
        guard let tool else {
            lastFailure = (now, Self.unavailableMessage)
            Logger.shared.log("Keep-awake: \(Self.unavailableMessage)")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        // An argument array, never a shell string.
        p.arguments = Self.arguments(what: what, why: why, parentPid: getpid())
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            lastFailure = (now, "couldn't run systemd-inhibit: \(error.localizedDescription)")
            Logger.shared.log("Keep-awake: \(lastFailure!.message)")
            return false
        }
        // A refusal comes back at once; a held inhibitor just keeps running.
        let deadline = Date().addingTimeInterval(0.3)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if !p.isRunning {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let message = Self.explainFailure(stderr: text)
            lastFailure = (now, message)
            Logger.shared.log("Keep-awake (\(what)): \(message)")
            return false
        }
        process = p
        lastFailure = nil
        return true
    }

    func release() {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
    }

    static let unavailableMessage = "systemd-inhibit isn't installed, so this system has no logind to ask: Page Studio can't keep it awake. Paging still works. (Install systemd or elogind.)"

    /// Pure: the child's argv.
    static func arguments(what: String, why: String, parentPid: Int32) -> [String] {
        ["--what=\(what)", "--who=Page Studio", "--why=\(why)", "--mode=block",
         "/usr/bin/env", "tail", "--pid=\(parentPid)", "-f", "/dev/null"]
    }

    /// Pure: a plain sentence for systemd-inhibit's refusal.
    static func explainFailure(stderr: String) -> String {
        let s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.contains("system has not been booted with systemd") || lower.contains("failed to connect to bus")
            || lower.contains("no such file or directory") || lower.contains("could not activate") || lower.contains("not provided by any .service") {
            return "logind isn't running here (\(s.isEmpty ? "no system bus" : s)): Page Studio can't keep this machine awake. Paging still works."
        }
        if lower.contains("access denied") || lower.contains("interactive authentication required") || lower.contains("permission") {
            return "logind refused the inhibitor (\(s)): this user may not block sleep (polkit). Paging still works."
        }
        return s.isEmpty ? "systemd-inhibit exited at once" : s
    }
}

/// The Linux `PowerBackend`: logind inhibitors and the battery.
final class LinuxPowerBackend: PowerBackend {
    private let idle: LogindInhibitor
    private let lid: LogindInhibitor
    private let battery: () -> PowerSnapshot
    private let lock = NSLock()
    private var reported = AwakeAssertions.none

    init(idle: LogindInhibitor = LogindInhibitor(what: "idle:sleep"),
         lid: LogindInhibitor = LogindInhibitor(what: "handle-lid-switch"),
         battery: @escaping () -> PowerSnapshot = { LinuxBattery.read() }) {
        self.idle = idle
        self.lid = lid
        self.battery = battery
    }

    var held: AwakeAssertions {
        AwakeAssertions(preventIdleSleep: idle.isHeld, preventSystemSleep: lid.isHeld)
    }

    var isBoosting: Bool { held.preventIdleSleep }

    func snapshot() -> PowerSnapshot { battery() }

    func apply(_ want: AwakeAssertions, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        if want.preventIdleSleep { idle.acquire(why: reason) } else { idle.release() }
        // Lid closed on AC: logind's lid switch inhibitor (the Mac's PreventSystemSleep).
        if want.preventSystemSleep { lid.acquire(why: reason + " — lid may be closed on AC") } else { lid.release() }
        let now = held
        guard now != reported else { return }
        reported = now
        switch (now.preventIdleSleep, now.preventSystemSleep) {
        case (false, false): Logger.shared.log("Keep-awake OFF")
        case (true, true): Logger.shared.log("Keep-awake ON (idle + lid closed on AC) — \(reason)")
        case (true, false): Logger.shared.log("Keep-awake ON (idle only; keep the lid open) — \(reason)")
        case (false, true): Logger.shared.log("Keep-awake: lid inhibitor only — \(reason)")
        }
    }

    func releaseAll() { apply(.none, reason: "release") }

    /// For `paged status`.
    var problem: String? { idle.failure ?? lid.failure }
}

/// The Linux `LidGuard`: lid closed on battery is a logind
/// `handle-lid-switch` inhibitor, gated by the same `SleepGuardPolicy`
/// blockers (battery margin, heat) the Coordinator applies on macOS. Unlike
/// pmset it can't outlive paged, so there is nothing to clean up and no
/// watchdog.
final class LinuxLidGuard: LidGuard {
    private let inhibitor: LogindInhibitor
    private let lock = NSLock()
    private var sealed = false

    init(inhibitor: LogindInhibitor = LogindInhibitor(what: "handle-lid-switch")) {
        self.inhibitor = inhibitor
    }

    var isActive: Bool { inhibitor.isHeld }
    var cleanupPending: Bool { false }
    var watchdogLoaded: Bool { true }
    var cachedHelperStatus: SleepGuard.HelperStatus { helperStatus(refresh: false) }

    func helperStatus(refresh: Bool) -> SleepGuard.HelperStatus {
        LogindInhibitor.findTool() == nil ? .missing : .available
    }

    func update(shouldDisableSleep: Bool, reason: String) {
        lock.lock(); let isSealed = sealed; lock.unlock()
        if shouldDisableSleep && !isSealed {
            if !inhibitor.isHeld, inhibitor.acquire(why: reason) {
                Logger.shared.log("Lid closed on battery: logind lid inhibitor ON — \(reason)")
            }
        } else if inhibitor.isHeld {
            inhibitor.release()
            Logger.shared.log("Lid closed on battery: logind lid inhibitor OFF — \(reason)")
        }
    }

    func forceDisable(reason: String) -> Bool {
        update(shouldDisableSleep: false, reason: reason)
        return true
    }

    func sealAndDisable(reason: String) -> Bool {
        lock.lock(); sealed = true; lock.unlock()
        return forceDisable(reason: reason)
    }

    func syncWatchdog(enabled: Bool) {}
}

// MARK: - battery

/// Battery and mains from /sys/class/power_supply, with UPower as the
/// fallback when sysfs shows no battery (a USB UPS that only UPower sees).
enum LinuxBattery {
    static func read(sysfs: String = "/sys/class/power_supply") -> PowerSnapshot {
        let supplies = readSupplies(sysfs)
        let fromSysfs = snapshot(from: supplies)
        if fromSysfs.hasBattery { return fromSysfs }
        if let upower = ProcessRunner.findExecutable("upower"),
           let out = ProcessRunner.stdout(upower, ["-i", "/org/freedesktop/UPower/devices/DisplayDevice"], timeout: 3),
           let snap = parseUPower(out) {
            return snap
        }
        return fromSysfs
    }

    /// Each supply's attribute files ("type", "capacity", …), by supply name.
    static func readSupplies(_ dir: String) -> [String: [String: String]] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [:] }
        var out: [String: [String: String]] = [:]
        for name in names.sorted() {
            var attrs: [String: String] = [:]
            for key in ["type", "scope", "present", "online", "status", "capacity",
                        "energy_now", "energy_full", "charge_now", "charge_full"] {
                if let v = try? String(contentsOfFile: "\(dir)/\(name)/\(key)", encoding: .utf8) {
                    attrs[key] = v.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            out[name] = attrs
        }
        return out
    }

    /// Pure. The system battery (or batteries, combined by energy) wins; a UPS
    /// counts only when there is none, as on macOS. Device-scoped batteries
    /// (a mouse, a headset) never count.
    static func snapshot(from supplies: [String: [String: String]]) -> PowerSnapshot {
        let present = supplies.values.filter { ($0["present"] ?? "1") != "0" && $0["scope"]?.lowercased() != "device" }
        let batteries = present.filter { $0["type"] == "Battery" }
        let chosen = batteries.isEmpty ? present.filter { $0["type"] == "UPS" } : batteries
        guard !chosen.isEmpty else { return .noBattery }

        var now = 0.0, full = 0.0
        var capacities: [Int] = []
        for b in chosen {
            if let n = Double(b["energy_now"] ?? b["charge_now"] ?? ""), let f = Double(b["energy_full"] ?? b["charge_full"] ?? ""), f > 0 {
                now += n; full += f
            }
            if let c = Int(b["capacity"] ?? "") { capacities.append(c) }
        }
        let percent: Int
        if full > 0 {
            percent = Int((now / full * 100).rounded())
        } else if !capacities.isEmpty {
            percent = capacities.reduce(0, +) / capacities.count
        } else {
            return .noBattery
        }
        let statuses = chosen.compactMap { $0["status"] }
        let mains = present.filter { ["Mains", "USB", "USB_C", "USB_PD"].contains($0["type"] ?? "") }
        let onAC: Bool
        if mains.contains(where: { $0["online"] == "1" }) {
            onAC = true
        } else if !mains.isEmpty {
            onAC = false
        } else {
            onAC = !statuses.contains("Discharging")
        }
        return PowerSnapshot(percent: min(100, max(0, percent)), onAC: onAC, hasBattery: true,
                             isCharging: statuses.contains("Charging"))
    }

    /// Pure. `upower -i …/DisplayDevice` output.
    static func parseUPower(_ text: String) -> PowerSnapshot? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        guard fields["present"] != "no", fields["power supply"] != "no",
              let pctText = fields["percentage"], let pct = Double(pctText.replacingOccurrences(of: "%", with: "")) else { return nil }
        let state = fields["state"] ?? "unknown"
        // An empty display device (a desktop without battery) reads 0% "unknown".
        if state == "unknown" && pct == 0 { return nil }
        return PowerSnapshot(percent: Int(pct.rounded()), onAC: state != "discharging" && state != "pending-discharge",
                             hasBattery: true, isCharging: state == "charging")
    }
}

// MARK: - heat

/// The SleepGuard heat blocker's input: the hottest thermal zone against its
/// own trip points (/sys/class/thermal). `.nominal` when unreadable.
enum LinuxThermal {
    static func read(root: String = "/sys/class/thermal") -> ThermalState {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return .nominal }
        var zones: [Zone] = []
        for name in names where name.hasPrefix("thermal_zone") {
            func text(_ f: String) -> String? {
                (try? String(contentsOfFile: "\(root)/\(name)/\(f)", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let t = text("temp").flatMap(Int.init) else { continue }
            var trips: [(type: String, temp: Int)] = []
            for i in 0..<16 {
                guard let type = text("trip_point_\(i)_type"), let temp = text("trip_point_\(i)_temp").flatMap(Int.init) else { break }
                trips.append((type, temp))
            }
            zones.append(Zone(milliCelsius: t, trips: trips))
        }
        return state(zones)
    }

    struct Zone {
        let milliCelsius: Int
        let trips: [(type: String, temp: Int)]
    }

    /// Pure. critical/hot trip reached → critical/serious; passive → fair.
    /// Without trip points: 95 °C critical, 90 serious, 80 fair.
    static func state(_ zones: [Zone]) -> ThermalState {
        var worst = ThermalState.nominal
        for z in zones {
            var s = ThermalState.nominal
            let valid = z.trips.filter { $0.temp > 0 }
            if valid.isEmpty {
                if z.milliCelsius >= 95_000 { s = .critical } else if z.milliCelsius >= 90_000 { s = .serious } else if z.milliCelsius >= 80_000 { s = .fair }
            } else {
                for trip in valid where z.milliCelsius >= trip.temp {
                    switch trip.type {
                    case "critical": s = max(s, .critical)
                    case "hot": s = max(s, .serious)
                    case "passive": s = max(s, .fair)
                    default: break
                    }
                }
            }
            worst = max(worst, s)
        }
        return worst
    }
}

extension ThermalState: Comparable {
    public static func < (a: ThermalState, b: ThermalState) -> Bool { a.rawValue < b.rawValue }
}
