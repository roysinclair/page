import Foundation
@testable import PageCore
#if canImport(Glibc)
import Glibc
#endif

// MARK: - presence

/// The Linux `PresenceSource`: seconds since the user last touched a
/// graphical session, from the first source that answers:
///   1. X11: `xprintidle` (the XScreenSaver extension), when DISPLAY is set
///   2. GNOME (X11 or Wayland): Mutter's IdleMonitor over the session bus
///   3. logind: the graphical session's IdleHint / IdleSinceHint
/// With no graphical session at all (a server, ssh, a TTY) nobody is at a
/// screen to see a terminal, so the answer is "away" (`.infinity`): pages go
/// to the phone. Results are cached for 2 s.
final class LinuxPresence: PresenceSource {
    typealias Runner = (_ tool: String, _ args: [String]) -> String?
    private let environment: () -> [String: String]
    private let run: Runner
    private let find: (String) -> String?
    private let lock = NSLock()
    private var cache: (at: Date, value: TimeInterval, source: String)?

    init(environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         run: @escaping Runner = { tool, args in ProcessRunner.stdout(tool, args, timeout: 2) },
         find: @escaping (String) -> String? = { ProcessRunner.findExecutable($0) }) {
        self.environment = environment
        self.run = run
        self.find = find
    }

    func rawSecondsSinceLastInput() -> TimeInterval { reading().seconds }

    /// The idle time and which source said so (for `paged status`).
    func reading(now: Date = Date()) -> (seconds: TimeInterval, source: String) {
        lock.lock()
        if let c = cache, now.timeIntervalSince(c.at) < 2 { lock.unlock(); return (c.value, c.source) }
        lock.unlock()
        let r = measure(now: now)
        lock.lock(); cache = (now, r.seconds, r.source); lock.unlock()
        return r
    }

    private func measure(now: Date) -> (seconds: TimeInterval, source: String) {
        let env = environment()
        let hasDisplay = !(env["DISPLAY"] ?? "").isEmpty
        let hasWayland = !(env["WAYLAND_DISPLAY"] ?? "").isEmpty
        if hasDisplay, let tool = find("xprintidle"), let out = run(tool, []), let s = Self.parseXprintidle(out) {
            return (s, "xprintidle")
        }
        if (hasDisplay || hasWayland || env["DBUS_SESSION_BUS_ADDRESS"] != nil), let gdbus = find("gdbus"),
           let out = run(gdbus, ["call", "--session", "--dest", "org.gnome.Mutter.IdleMonitor",
                                 "--object-path", "/org/gnome/Mutter/IdleMonitor/Core",
                                 "--method", "org.gnome.Mutter.IdleMonitor.GetIdletime"]),
           let s = Self.parseMutterIdle(out) {
            return (s, "gnome-mutter")
        }
        if let loginctl = find("loginctl"),
           let user = run(loginctl, ["show-user", String(getuid()), "-p", "Display", "--value"]),
           let session = Self.sessionId(user),
           let out = run(loginctl, ["show-session", session, "-p", "Type", "-p", "IdleHint", "-p", "IdleSinceHint"]),
           let s = Self.parseLogindIdle(out, now: now) {
            return (s, "logind")
        }
        return (.infinity, hasDisplay || hasWayland ? "unknown (treated as away)" : "no graphical session (away)")
    }

    /// Pure. xprintidle prints milliseconds.
    static func parseXprintidle(_ out: String) -> TimeInterval? {
        guard let ms = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)), ms >= 0 else { return nil }
        return ms / 1000
    }

    /// Pure. gdbus prints "(uint64 12345,)" — milliseconds.
    static func parseMutterIdle(_ out: String) -> TimeInterval? {
        let digits = out.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard out.contains("uint64"), let ms = Double(digits) else { return nil }
        return ms / 1000
    }

    /// Pure. `loginctl show-user -p Display --value`: the graphical session's id.
    static func sessionId(_ out: String) -> String? {
        let id = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    /// Pure. `loginctl show-session -p Type -p IdleHint -p IdleSinceHint`:
    /// only an x11/wayland/mir session counts; IdleHint=no is "here now";
    /// IdleSinceHint is microseconds since the epoch.
    static func parseLogindIdle(_ out: String, now: Date) -> TimeInterval? {
        var f: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { f[String(parts[0])] = String(parts[1]) }
        }
        guard let type = f["Type"], ["x11", "wayland", "mir"].contains(type) else { return nil }
        guard let hint = f["IdleHint"] else { return nil }
        if hint == "no" { return 0 }
        guard let since = Double(f["IdleSinceHint"] ?? ""), since > 0 else { return nil }
        return max(0, now.timeIntervalSince1970 - since / 1_000_000)
    }
}

// MARK: - resume jobs

/// The Linux `WakeScheduler`: a systemd user timer and service per resume.
/// Units are named after the label (`local.Page.resume.<session>.timer` and
/// `.service`) in ~/.config/systemd/user. Waking from suspend needs a system
/// timer (`WakeSystem=`), which a user service can't create, so
/// `scheduleWake` reports that it can't; the timer is `Persistent=` and fires
/// as soon as the machine is up again (the job's own lateness check decides).
final class SystemdTimerScheduler: WakeScheduler {
    let unitDirectory: URL
    private let runCommand: ResumeScheduler.CommandRunner
    private let systemctl: String
    private var warnedWake = false

    init(unitDirectory: URL, runCommand: @escaping ResumeScheduler.CommandRunner,
         systemctl: String = ProcessRunner.findExecutable("systemctl") ?? "/usr/bin/systemctl") {
        self.unitDirectory = unitDirectory
        self.runCommand = runCommand
        self.systemctl = systemctl
    }

    func jobFileURL(label: String, in directory: URL) -> URL { directory.appendingPathComponent("\(label).timer") }
    var jobFileExtension: String { "timer" }

    var selfUnloadShell: String {
        // The service finishes by itself (oneshot); drop its timer and unit files.
        #"systemctl --user stop "$LABEL.timer" >/dev/null 2>&1; /bin/rm -f "$(dirname "$PLIST")/$LABEL.service"; systemctl --user daemon-reload >/dev/null 2>&1"#
    }

    func install(label: String, jobFile: URL, scriptPath: String, fireAt: Date, logPath: String) throws {
        let dir = jobFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = dir.appendingPathComponent("\(label).service")
        try Data(Self.serviceUnit(scriptPath: scriptPath, path: Self.searchPath()).utf8).write(to: service, options: .atomic)
        try Data(Self.timerUnit(label: label, fireAt: fireAt).utf8).write(to: jobFile, options: .atomic)
        _ = runCommand(systemctl, ["--user", "daemon-reload"])
        let r = runCommand(systemctl, ["--user", "start", "\(label).timer"])
        guard r.succeeded else {
            let msg = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: service)
            throw ResumeScheduler.ScheduleError.launchctlFailed(msg.isEmpty ? "systemctl --user start: exit \(r.status)" : String(msg.prefix(200)))
        }
    }

    func remove(label: String) -> Bool {
        let r = runCommand(systemctl, ["--user", "stop", "\(label).timer"])
        try? FileManager.default.removeItem(at: unitDirectory.appendingPathComponent("\(label).service"))
        _ = runCommand(systemctl, ["--user", "daemon-reload"])
        return r.succeeded
    }

    func loadedJobs(prefixes: [String]) -> [(label: String, pid: Int32?)]? {
        let r = runCommand(systemctl, ["--user", "list-units", "--all", "--plain", "--no-legend", "--no-pager"]
                           + prefixes.map { "\($0)*" })
        guard r.succeeded else { return nil }
        return Self.parseListUnits(r.stdout, prefixes: prefixes)
    }

    func scheduleWake(at: Date) -> String? {
        if !warnedWake {
            warnedWake = true
            Logger.shared.log("Resume: waking a suspended machine needs a system timer (WakeSystem=); paged runs as a user service, so the resume runs when the machine is next awake")
        }
        return nil
    }

    func cancelWake(stamp: String) {}

    // MARK: pure

    static func searchPath() -> String {
        var seen = Set<String>()
        return (ProcessRunner.developerBinDirectories + ["/usr/local/bin", "/usr/bin", "/bin"])
            .filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// systemd's quoting for one word in ExecStart=/Environment=: double
    /// quotes, with backslash and quote escaped, `%` doubled (specifiers) and
    /// `$` doubled (no variable expansion).
    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "%": out += "%%"
            case "$": out += "$$"
            case "\n", "\r": out += " "
            default: out.append(c)
            }
        }
        return out + "\""
    }

    static func serviceUnit(scriptPath: String, path: String) -> String {
        """
        # Page scheduled resume — written by paged; removed when it has run.
        [Unit]
        Description=Page: carry on a rate-limited Claude Code session

        [Service]
        Type=oneshot
        Environment=\(quote("PATH=" + path))
        ExecStart=/bin/bash \(quote(scriptPath))

        """
    }

    static func timerUnit(label: String, fireAt: Date) -> String {
        let c = ResumeScheduler.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let when = String(format: "%04d-%02d-%02d %02d:%02d:00", c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
        return """
        # Page scheduled resume — written by paged; removed when it has run.
        [Unit]
        Description=Page: resume timer

        [Timer]
        OnCalendar=\(when)
        AccuracySec=1s
        Persistent=true
        Unit=\(label).service

        """
    }

    /// `systemctl --user list-units --plain --no-legend` lines: "unit load
    /// active sub description…". A timer is a loaded job; a running service
    /// marks its job as running (pid unknown: 0).
    static func parseListUnits(_ out: String, prefixes: [String]) -> [(label: String, pid: Int32?)] {
        var jobs: [String: Int32?] = [:]
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4 else { continue }
            let unit = String(cols[0])
            for ext in [".timer", ".service"] where unit.hasSuffix(ext) {
                let label = String(unit.dropLast(ext.count))
                guard prefixes.contains(where: { label.hasPrefix($0) }) else { continue }
                if ext == ".service", cols[3] == "running" || cols[3] == "start" {
                    jobs[label] = .some(0)
                } else if jobs[label] == nil {
                    jobs[label] = .some(nil)
                }
            }
        }
        return jobs.keys.sorted().map { ($0, jobs[$0] ?? nil) }
    }
}

// MARK: - notifications

/// org.freedesktop.Notifications through `notify-send`, when there is a
/// desktop session to show them in. Optional: without one it does nothing.
final class NotifySendNotifier: Notifier {
    private let tool: String?
    private let environment: [String: String]

    init(tool: String? = ProcessRunner.findExecutable("notify-send"),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.tool = tool
        self.environment = environment
    }

    var available: Bool {
        tool != nil && (environment["DBUS_SESSION_BUS_ADDRESS"] != nil || environment["DISPLAY"] != nil
                        || environment["WAYLAND_DISPLAY"] != nil)
    }

    func notify(title: String, body: String, identifier: String) {
        guard available, let tool else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = ProcessRunner.run(tool, Self.arguments(title: title, body: body), timeout: 5)
        }
    }

    /// Pure. `--` ends the options, so a title starting with "-" stays text.
    static func arguments(title: String, body: String) -> [String] {
        ["--app-name=Page", "--icon=dialog-information", "--", String(title.prefix(200)), String(body.prefix(1000))]
    }
}

// MARK: - terminals

/// The Linux `TerminalHostPlatform`: selects the session's tmux pane, WezTerm
/// pane or kitty window through their CLIs (TerminalFocus's commands). There
/// is no portable way to raise another app's window, so it says what it
/// selected.
final class LinuxTerminalHost: TerminalHostPlatform {
    func focus(candidates: [ClaudeLiveSession], table: [ProcessRunner.ProcessInfoRow]) -> TerminalFocusOutcome {
        guard case .success(let session) = InjectionExecutor.pickSession(candidates, pagePid: nil, pageStateStart: nil),
              session.tty != nil else {
            return TerminalFocusOutcome(ok: false, detail: "Couldn't tell which pane")
        }
        switch InjectionExecutor.resolveHost(for: session, processTable: table) {
        case .tmux(let tmux, let pane, _, _):
            for args in TerminalFocus.tmuxCommands(paneId: pane) {
                guard ProcessRunner.run(tmux, args, timeout: 3).succeeded else {
                    return TerminalFocusOutcome(ok: false, detail: "Couldn't select the tmux pane")
                }
            }
            return TerminalFocusOutcome(ok: true, detail: "Selected tmux pane \(pane)")
        case .wezterm(let target):
            _ = WezTermBridge.run(target, Array(TerminalFocus.weztermArgs(paneId: target.paneId).dropFirst()))
            return TerminalFocusOutcome(ok: true, detail: "Selected the WezTerm pane")
        case .kitty(let target):
            let r = ProcessRunner.run(target.kittenPath, TerminalFocus.kittyArgs(socket: target.socket, windowId: target.windowId), timeout: 3)
            return TerminalFocusOutcome(ok: r.succeeded, detail: r.succeeded ? "Selected the kitty window" : "Couldn't select the kitty window")
        default:
            return TerminalFocusOutcome(ok: false, detail: "Page can only select tmux, WezTerm and kitty panes on Linux")
        }
    }

    func activateAnyTerminal() -> TerminalFocusOutcome {
        TerminalFocusOutcome(ok: false, detail: "Page can't bring windows forward on Linux")
    }

    func activate(appNamed name: String) -> TerminalFocusOutcome {
        TerminalFocusOutcome(ok: false, detail: "Page can't bring \(name) forward on Linux")
    }
}
