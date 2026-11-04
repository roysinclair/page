import Foundation

// The macOS `WakeScheduler`. Foundation only, so its tests run everywhere;
// only macOS uses it (Platform.mac).

/// One-shot LaunchAgents (StartCalendarInterval) and `sudo -n pmset schedule
/// wake`. Moved from ResumeScheduler unchanged.
final class LaunchdWakeScheduler: WakeScheduler {
    private let launchctlPath: String
    private let runCommand: ResumeScheduler.CommandRunner
    private let pmsetPath = "/usr/bin/pmset"

    init(launchctlPath: String, runCommand: @escaping ResumeScheduler.CommandRunner) {
        self.launchctlPath = launchctlPath
        self.runCommand = runCommand
    }

    func jobFileURL(label: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(label).plist")
    }

    var jobFileExtension: String { "plist" }

    var selfUnloadShell: String { "\"$LAUNCHCTL\" bootout \"gui/$(/usr/bin/id -u)/$LABEL\" >/dev/null 2>&1" }

    func install(label: String, jobFile: URL, scriptPath: String, fireAt: Date, logPath: String) throws {
        try writePlist(label: label, plistURL: jobFile, scriptPath: scriptPath, fireAt: fireAt, logPath: logPath)
        try bootstrap(label: label, plistPath: jobFile.path)
    }

    func remove(label: String) -> Bool { bootout(label: label) }

    func loadedJobs(prefixes: [String]) -> [(label: String, pid: Int32?)]? {
        let listing = runCommand(launchctlPath, ["list"])
        return listing.succeeded ? ResumeScheduler.loadedJobs(fromLaunchctlList: listing.stdout, prefixes: prefixes) : nil
    }

    // MARK: - launchd

    private func writePlist(label: String, plistURL: URL, scriptPath: String, fireAt: Date, logPath: String) throws {
        let comps = ResumeScheduler.calendar.dateComponents([.month, .day, .hour, .minute], from: fireAt)
        var seen = Set<String>()
        let path = (ProcessRunner.developerBinDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", scriptPath],
            "RunAtLoad": false,
            // No Year key exists; the script's year guard covers re-firing a
            // year later if cleanup ever failed.
            "StartCalendarInterval": [
                "Month": comps.month ?? 1,
                "Day": comps.day ?? 1,
                "Hour": comps.hour ?? 0,
                "Minute": comps.minute ?? 0
            ],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "LimitLoadToSessionType": "Aqua",
            // Node-based installs need `node` on PATH even when claude is
            // launched by absolute path.
            "EnvironmentVariables": ["PATH": path]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private func bootstrap(label: String, plistPath: String) throws {
        // Bootout first in case a stale job with this label is loaded; the
        // unload completes asynchronously, so retry "already loaded" errors.
        _ = bootout(label: label)
        var last = ProcessRunner.Result.notLaunched
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            last = runCommand(launchctlPath, ["bootstrap", "gui/\(getuid())", plistPath])
            if last.succeeded { return }
            if !last.launched { break }
        }
        let msg = (last.stderr + last.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ResumeScheduler.ScheduleError.launchctlFailed(msg.isEmpty ? "exit \(last.status)" : String(msg.prefix(200)))
    }

    @discardableResult
    private func bootout(label: String) -> Bool {
        runCommand(launchctlPath, ["bootout", "gui/\(getuid())/\(label)"]).succeeded
    }

    // MARK: - pmset wake (needs `./install.sh --enable-power-helpers`)

    /// Returns the stamp on success so `cancel` can remove exactly this wake.
    func scheduleWake(at wakeAt: Date) -> String? {
        let stamp = ResumeScheduler.pmsetFormatter.string(from: wakeAt)
        let r = runCommand("/usr/bin/sudo", ["-n", pmsetPath, "schedule", "wake", stamp])
        if r.succeeded {
            Logger.shared.log("pmset schedule wake \(stamp) — OK")
            return stamp
        }
        let output = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.shared.log("pmset schedule wake failed (\(r.status)). Output: \(output). Hint: install the power helper (Preferences ▸ Power ▸ Install…) to allow passwordless pmset.")
        return nil
    }

    func cancelWake(stamp: String) {
        // Best effort: a leftover wake only wakes the Mac briefly.
        let r = runCommand("/usr/bin/sudo", ["-n", pmsetPath, "schedule", "cancel", "wake", stamp])
        if !r.succeeded {
            Logger.shared.log("pmset schedule cancel wake \(stamp) failed (\(r.status)) — the Mac may wake once unnecessarily")
        }
    }
}
