import Foundation
@testable import PageCore
#if canImport(Glibc)
import Glibc
#endif

/// `paged <command>`.
public enum PagedCLI {
    static let usage = """
    paged \(PagedVersion.string) — Page Power for Linux (headless)

    usage: paged <command> [options]

      run                     Run the daemon in the foreground (what the systemd unit runs)
      start                   Start the daemon (systemctl --user start paged, or in the background)
      stop                    Stop it
      status                  What the daemon is doing
      pair [--png FILE] [--regenerate] [--plain]
                              Show the pairing QR for the Page phone app (and write a PNG)
      install-hooks [--agent claude|codex|all] [--uninstall] [--yes] [--script PATH]
                              Add Page's hook to Claude Code / Codex (shows the change first)
      logs [-f] [-n LINES]    Show the log
      config [path | show | get KEY | set KEY VALUE]
                              Read or change config.json (the daemon reloads it)
      version

    Files: config \(PlatformPaths.current.configFile.path)
           data   \(PlatformPaths.current.support.path) (relay token, session key, sockets; 0700)
           logs   \(PlatformPaths.current.logs.path)
    """

    public static func main(_ arguments: [String]) -> Int32 {
        let files = DaemonFiles(paths: Platform.current.paths)
        var args = Array(arguments.dropFirst())
        let command = args.isEmpty ? "help" : args.removeFirst()
        switch command {
        case "run":
            let daemon = PagedDaemon(files: files)
            daemon.run()
        case "start": return start(files)
        case "stop": return stop(files)
        case "status": return status(files)
        case "pair": return pair(files, args)
        case "install-hooks": return installHooks(files, args)
        case "logs": return logs(files, args)
        case "config": return config(files, args)
        case "version", "--version", "-v":
            print("paged \(PagedVersion.string)")
            return 0
        case "help", "--help", "-h":
            print(usage)
            return 0
        default:
            err("paged: unknown command '\(command)'\n\n\(usage)")
            return 2
        }
    }

    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    // MARK: start / stop

    static func systemctl() -> String? { ProcessRunner.findExecutable("systemctl") }

    static func unitInstalled(_ files: DaemonFiles) -> Bool {
        FileManager.default.fileExists(atPath: files.unitFile.path) && systemctl() != nil
    }

    static func start(_ files: DaemonFiles) -> Int32 {
        if let pid = InstanceLock.runningPid(at: files.pidFile) {
            print("paged is already running (pid \(pid))")
            return 0
        }
        if unitInstalled(files), let sc = systemctl() {
            let r = ProcessRunner.run(sc, ["--user", "start", "paged.service"], timeout: 15)
            if r.succeeded { print("Started paged (systemd user unit)"); return 0 }
            err("systemctl --user start paged failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) — starting it directly")
        }
        guard let exe = URL(string: "file:///proc/self/exe").flatMap({ try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path) }) else {
            err("paged: can't find its own executable"); return 1
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["run"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { err("paged: couldn't start: \(error.localizedDescription)"); return 1 }
        for _ in 0..<30 {
            if InstanceLock.runningPid(at: files.pidFile) != nil { print("Started paged (pid \(p.processIdentifier))"); return 0 }
            Thread.sleep(forTimeInterval: 0.1)
        }
        err("paged didn't come up — see `paged logs`")
        return 1
    }

    static func stop(_ files: DaemonFiles) -> Int32 {
        if unitInstalled(files), let sc = systemctl(),
           ProcessRunner.run(sc, ["--user", "is-active", "--quiet", "paged.service"], timeout: 5).succeeded {
            let r = ProcessRunner.run(sc, ["--user", "stop", "paged.service"], timeout: 30)
            print(r.succeeded ? "Stopped paged (systemd user unit)" : "systemctl --user stop paged failed")
            return r.succeeded ? 0 : 1
        }
        guard let pid = InstanceLock.runningPid(at: files.pidFile) else { print("paged isn't running"); return 0 }
        kill(pid, SIGTERM)
        for _ in 0..<50 where InstanceLock.runningPid(at: files.pidFile) != nil { Thread.sleep(forTimeInterval: 0.1) }
        let gone = InstanceLock.runningPid(at: files.pidFile) == nil
        print(gone ? "Stopped paged (pid \(pid))" : "paged (pid \(pid)) is still stopping")
        return gone ? 0 : 1
    }

    /// Tells the running daemon (if any) to act on a change.
    static func signalDaemon(_ files: DaemonFiles, _ sig: Int32) -> Bool {
        guard let pid = InstanceLock.runningPid(at: files.pidFile) else { return false }
        return kill(pid, sig) == 0
    }

    // MARK: status

    static func status(_ files: DaemonFiles) -> Int32 {
        let cfg = Config.loadResult(from: files.paths.configFile)
        let config = cfg.config ?? Config()
        guard let pid = InstanceLock.runningPid(at: files.pidFile) else {
            print("paged: not running")
            print("  relay:  \(config.relayEnabled ? (config.relayBaseURL?.absoluteString ?? "misconfigured") : "off")")
            if let p = cfg.problem { print("  config: \(p)") }
            print("  Start it with `paged start` (or `systemctl --user start paged`).")
            return 3
        }
        print("paged: running (pid \(pid))")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: files.statusFile), let s = try? dec.decode(DaemonStatus.self, from: data) else {
            print("  (starting — no status yet)")
            return 0
        }
        print(render(s, relayURL: config.relayBaseURL?.absoluteString))
        return 0
    }

    /// Pure: the status text.
    static func render(_ s: DaemonStatus, relayURL: String?) -> String {
        var lines = ["  \(s.statusLine)"]
        lines.append("  relay:       \(s.relay)\(relayURL.map { " (\($0))" } ?? "")")
        lines.append("  sessions:    \(s.sessions.isEmpty ? "none" : s.sessions.map { "\($0.agent) \($0.project.isEmpty ? "" : $0.project + " ")[\($0.state)]" }.joined(separator: ", "))")
        lines.append("  pages:       \(s.pendingPages) waiting")
        lines.append("  keep-awake:  \(s.keepAwake)\(s.keepAwakeProblem.map { " — \($0)" } ?? "")")
        if s.lidClosedOnBattery { lines.append("  lid:         kept awake with the lid closed on battery") }
        lines.append("  battery:     \(s.battery)")
        lines.append("  presence:    \(s.presence)")
        if let p = s.configProblem { lines.append("  config:      \(p)") }
        lines.append("  updated:     \(ISO8601DateFormatter().string(from: s.updatedAt)) (version \(s.version))")
        return lines.joined(separator: "\n")
    }

    // MARK: pair

    static func pair(_ files: DaemonFiles, _ args: [String]) -> Int32 {
        let cfg = Config.loadResult(from: files.paths.configFile).config ?? Config()
        guard cfg.relayEnabled, let base = cfg.relayBaseURL else {
            err("""
            paged: no relay configured. Deploy the Worker (docs/SELF-HOSTING.md), then:
              paged config set relayURL https://<your-worker>.workers.dev
              paged config set relayEnabled true
            """)
            return 1
        }
        do { try files.prepareDirectories() } catch { err("paged: \(error.localizedDescription)"); return 1 }
        if args.contains("--regenerate") {
            _ = PairingTokenManager.regenerate()
            print(signalDaemon(files, SIGUSR1)
                  ? "New pairing token: the daemon retired the old one and reconnected. Re-scan on the phone."
                  : "New pairing token written. Start paged to connect with it; re-scan on the phone.")
        }
        let payload = PairingTokenManager.pairingPayloadJSON(relayBaseURL: base, sessionKey: PairingTokenManager.currentSessionKey())
        guard let matrix = Platform.current.qr.modules(for: payload) else { err("paged: couldn't make a QR code"); return 1 }
        let ansi = !args.contains("--plain") && isatty(STDOUT_FILENO) != 0
        print("Scan this with the Page app on your phone (Pair with a Mac ▸ Scan):\n")
        print(QRRender.terminal(matrix, quietZone: 2, ansi: ansi))
        var pngURL = files.pairingPNG
        if let i = args.firstIndex(of: "--png"), i + 1 < args.count { pngURL = URL(fileURLWithPath: args[i + 1]) }
        do {
            try PrivateFile.write(QRRender.png(matrix), to: pngURL)
            print("Also saved as \(pngURL.path) (0600).")
        } catch {
            err("Couldn't write \(pngURL.path): \(error.localizedDescription)")
        }
        print("Relay: \(base.absoluteString)")
        print("The code holds your pairing token and session key: don't share it. `paged pair --regenerate` replaces both.")
        return 0
    }

    // MARK: hooks

    static func installHooks(_ files: DaemonFiles, _ args: [String]) -> Int32 {
        var script = FileManager.default.isExecutableFile(atPath: files.hookScript.path) ? files.hookScript.path : HookInstaller.locateScript()
        if let i = args.firstIndex(of: "--script"), i + 1 < args.count { script = args[i + 1] }
        guard let script, FileManager.default.isExecutableFile(atPath: script) else {
            err("paged: can't find hooks/page-notify.sh — run install-linux.sh, or pass --script PATH")
            return 1
        }
        var agents = HookAgent.allCases
        if let i = args.firstIndex(of: "--agent"), i + 1 < args.count, args[i + 1] != "all" {
            guard let a = HookAgent(rawValue: args[i + 1]) else { err("paged: --agent claude|codex|all"); return 2 }
            agents = [a]
        }
        let uninstall = args.contains("--uninstall")
        let installer = HookInstaller(homeDirectory: files.paths.home, scriptPath: script)
        var failed = false
        for agent in agents {
            do {
                let plan = uninstall ? try installer.planUninstall(agent) : try installer.planInstall(agent)
                guard plan.originalText != plan.newText else {
                    print("\(agent.rawValue): already \(uninstall ? "without" : "has") Page's hook")
                    continue
                }
                let file = installer.fileURL(for: agent)
                print(HookInstaller.unifiedDiff(old: plan.originalText, new: plan.newText,
                                                oldLabel: file.path, newLabel: file.path + " (new)"))
                if !args.contains("--yes") {
                    print("Apply this change to \(file.path)? [y/N] ", terminator: "")
                    guard readLine()?.lowercased().hasPrefix("y") == true else { print("Skipped \(agent.rawValue)"); continue }
                }
                let backup = try installer.apply(plan)
                print("\(agent.rawValue): \(uninstall ? "removed" : "installed")\(backup.map { " (backup: \($0.path))" } ?? "")")
            } catch {
                err("\(agent.rawValue): \(error.localizedDescription)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    // MARK: logs

    static func logs(_ files: DaemonFiles, _ args: [String]) -> Int32 {
        var n = "100"
        if let i = args.firstIndex(of: "-n"), i + 1 < args.count, Int(args[i + 1]) != nil { n = args[i + 1] }
        guard FileManager.default.fileExists(atPath: files.logFile.path) else {
            print("No log yet at \(files.logFile.path)")
            return 0
        }
        guard let tail = ProcessRunner.findExecutable("tail") else { err("paged: tail not found"); return 1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tail)
        p.arguments = ["-n", n] + (args.contains("-f") ? ["-F"] : []) + ["--", files.logFile.path]
        do { try p.run() } catch { err("paged: \(error.localizedDescription)"); return 1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: config

    static func config(_ files: DaemonFiles, _ args: [String]) -> Int32 {
        let url = files.paths.configFile
        switch args.first ?? "show" {
        case "path":
            print(url.path)
            return 0
        case "show":
            let r = Config.loadResult(from: url)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(r.config ?? Config()) { print(String(decoding: data, as: UTF8.self)) }
            if let p = r.problem { err("config problem: \(p)") }
            return 0
        case "get":
            guard args.count == 2 else { err("usage: paged config get KEY"); return 2 }
            let enc = JSONEncoder()
            guard let data = try? enc.encode(Config.loadResult(from: url).config ?? Config()),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = obj[args[1]] else {
                err("paged: no setting '\(args[1])'"); return 1
            }
            if let n = v as? NSNumber, n.isJSONBool { print(n.boolValue) } else { print(v) }
            return 0
        case "set":
            guard args.count == 3 else { err("usage: paged config set KEY VALUE"); return 2 }
            do { try files.prepareDirectories() } catch { err("paged: \(error.localizedDescription)"); return 1 }
            switch setValue(args[1], args[2], at: url) {
            case .failure(let e):
                err("paged: \(e.message)")
                return 1
            case .success(let warning):
                if let warning { err("note: \(warning)") }
                print("\(args[1]) = \(args[2])")
                if signalDaemon(files, SIGHUP) { print("The daemon reloaded its config.") }
                return 0
            }
        default:
            err("usage: paged config [path | show | get KEY | set KEY VALUE]")
            return 2
        }
    }

    struct ConfigError: Error { let message: String }

    /// Sets one key in config.json, keeping every other key as it is. The
    /// value is typed from the key's default (Bool, number or string), and the
    /// result must load (`Config.loadResult`) or nothing is written.
    static func setValue(_ key: String, _ raw: String, at url: URL) -> Result<String?, ConfigError> {
        guard let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any],
              let template = defaults[key] else {
            return .failure(ConfigError(message: "no setting '\(key)' (see `paged config show`)"))
        }
        let value: Any
        switch template {
        case let n as NSNumber where n.isJSONBool:
            guard let b = ["true": true, "yes": true, "on": true, "1": true,
                           "false": false, "no": false, "off": false, "0": false][raw.lowercased()] else {
                return .failure(ConfigError(message: "\(key) is true or false"))
            }
            value = b
        case is NSNumber:
            guard let d = Double(raw) else { return .failure(ConfigError(message: "\(key) is a number")) }
            value = d == d.rounded() ? NSNumber(value: Int(d)) : NSNumber(value: d)
        case is String:
            value = raw
        default:
            return .failure(ConfigError(message: "\(key) can't be set from the command line; edit \(url.path)"))
        }
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(ConfigError(message: "\(url.path) isn't valid JSON; fix it first"))
            }
            obj = existing
        }
        obj[key] = value
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(ConfigError(message: "couldn't encode the config"))
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".config.json.check")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try PrivateFile.write(out, to: tmp) } catch { return .failure(ConfigError(message: error.localizedDescription)) }
        let check = Config.loadResult(from: tmp)
        guard check.config != nil else { return .failure(ConfigError(message: check.problem ?? "the result doesn't load")) }
        do { try PrivateFile.write(out, to: url) } catch { return .failure(ConfigError(message: error.localizedDescription)) }
        return .success(check.problem)
    }
}
