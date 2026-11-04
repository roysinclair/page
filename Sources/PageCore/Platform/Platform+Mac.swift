#if os(macOS)
import Foundation
import CoreGraphics

// The macOS implementations of the platform protocols. Each wraps the code
// that was there before the split (moved, not rewritten): IOKit power
// assertions (PowerManager), pmset and its watchdog (SleepGuard), launchd and
// pmset wakes (LaunchdWakeScheduler, below), CGEventSource idle time, sysctl
// and libproc process reads, AppleScript and NSWorkspace focus, ImageIO.

extension Platform {
    static var mac: Platform {
        Platform(
            name: "macos",
            paths: .mac,
            makePower: { PowerManager() },
            makeLidGuard: { SleepGuard() },
            makeWakeScheduler: { LaunchdWakeScheduler(launchctlPath: "/bin/launchctl", runCommand: $0) },
            presence: MacPresence(),
            processes: MacProcessInspector(),
            terminalHost: MacTerminalHost(),
            // The app posts its own notifications (AppDelegate, with actions).
            notifier: nil,
            qr: PortableQRRenderer(),
            imageSniffer: MacImageSniffer(),
            makeRelayTransport: { URLSessionRelayTransport(configuration: .default, queue: $0) },
            thermalState: { ProcessInfo.processInfo.thermalState }
        )
    }
}

extension SleepGuard: LidGuard {}

/// CGEventSource: seconds since the last input in the login session.
final class MacPresence: PresenceSource {
    func rawSecondsSinceLastInput() -> TimeInterval {
        // `kCGAnyInputEventType` is ~0 as UInt32; the overlay doesn't export it.
        guard let anyInput = CGEventType(rawValue: ~0) else { return .infinity }
        let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return s.isFinite && s >= 0 ? s : .infinity
    }
}

/// ps, sysctl(KERN_PROCARGS2), libproc and lsof.
final class MacProcessInspector: ProcessInspector {
    func processTable() -> [ProcessRunner.ProcessInfoRow] { ProcessRunner.processTableViaPS() }
    func arguments(pid: Int32, envKeys: Set<String>) -> ProcArgs.Info? { ProcArgs.readSysctl(pid: pid, envKeys: envKeys) }
    func startSeconds(pid: Int32) -> Int? { CmuxBridge.processStartSecondsSysctl(pid) }
    func allProcesses() -> [LocalProcInfo.Entry] { LocalProcInfo.allProcesses() }
    func execPath(pid: Int32) -> String? { LocalProcInfo.execPath(pid) }
    func ttyName(device: UInt32) -> String? { LocalProcInfo.ttyName(tdev: device) }
    func ttyModified(_ ttyName: String) -> Date? { LocalProcInfo.ttyModified(ttyName) }
    func listeningTCPPorts(pid: Int32) -> Set<Int>? { LocalProcInfo.listeningTCPPorts(pid) }
    func foregroundState(pid: Int32) -> ProcessRunner.ForegroundState { ProcessRunner.foregroundStateSysctl(pid: pid) }
    func lsof(_ args: [String], timeout: TimeInterval) -> ProcessRunner.Result {
        ProcessRunner.run("/usr/sbin/lsof", args, timeout: timeout)
    }
}

/// AppleScript, NSWorkspace and the terminal CLIs (TerminalFocus).
final class MacTerminalHost: TerminalHostPlatform {
    func focus(candidates: [ClaudeLiveSession], table: [ProcessRunner.ProcessInfoRow]) -> TerminalFocusOutcome {
        TerminalFocus.focus(candidates: candidates, table: table)
    }
    func activateAnyTerminal() -> TerminalFocusOutcome { TerminalFocus.activateAnyTerminal() }
    func activate(appNamed name: String) -> TerminalFocusOutcome { TerminalFocus.activate(appNamed: name, shown: nil) }
}

/// ImageIO decodes the photo (ImageCheck.checkWithImageIO).
struct MacImageSniffer: ImageSniffer {
    func check(_ data: Data) -> Result<ImageCheck.Kind, ImageCheck.Failure> { ImageCheck.checkWithImageIO(data) }
}

#endif
