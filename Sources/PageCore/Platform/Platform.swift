import Foundation

// The seams between Page's portable core and the operating system.
//
// Everything below is what macOS and Linux do differently. The core talks to
// these protocols only; `Platform.current` holds the implementations in use.
// On macOS it defaults to the Mac implementations (the code that was here
// before the split, unchanged: `Platform.mac` in Platform+Mac.swift), so the
// menu-bar app needs no setup. On Linux `paged` installs `Platform.linux`
// (Sources/PageLinux) before it builds the Coordinator; until then the core
// sees `Platform.inert`, which reads as "unknown" everywhere and changes
// nothing on the machine (what the portable tests run against).

/// Keep-awake assertions and the battery reading.
///
/// macOS: IOKit power assertions and IOPS. Linux: logind inhibitors and
/// UPower or /sys/class/power_supply.
protocol PowerBackend: AnyObject {
    /// What is actually held (an assertion that failed to take is false).
    var held: AwakeAssertions { get }
    var isBoosting: Bool { get }
    func snapshot() -> PowerSnapshot
    /// Reconciles the held assertions with `want`. Idempotent; called every
    /// tick, from the tick queue and at shutdown.
    func apply(_ want: AwakeAssertions, reason: String)
    func releaseAll()
}

/// Keeping the machine awake with the lid closed on battery: an opt-in with
/// its own blockers (`SleepGuardPolicy`).
///
/// macOS: `SleepGuard` (pmset disablesleep, a marker and a launchd watchdog).
/// Linux: a logind `handle-lid-switch` inhibitor, which dies with the process.
protocol LidGuard: AnyObject {
    var isActive: Bool { get }
    var cleanupPending: Bool { get }
    var watchdogLoaded: Bool { get }
    var cachedHelperStatus: SleepGuard.HelperStatus { get }
    func helperStatus(refresh: Bool) -> SleepGuard.HelperStatus
    func update(shouldDisableSleep: Bool, reason: String)
    @discardableResult func forceDisable(reason: String) -> Bool
    @discardableResult func sealAndDisable(reason: String) -> Bool
    func syncWatchdog(enabled: Bool)
}

extension LidGuard {
    func helperStatus() -> SleepGuard.HelperStatus { helperStatus(refresh: false) }
}

/// One-shot jobs that carry on a rate-limited session after its reset, and
/// the optional wake from sleep before them.
///
/// macOS: LaunchAgents with StartCalendarInterval, `pmset schedule wake`.
/// Linux: systemd user timers (`OnCalendar=`); waking needs a system timer,
/// so `scheduleWake` reports that it can't.
protocol WakeScheduler: AnyObject {
    /// The job's definition file for `label` (a plist, a .timer).
    func jobFileURL(label: String, in directory: URL) -> URL
    /// File extension of job definitions, for the orphan sweep.
    var jobFileExtension: String { get }
    /// Writes and loads a job that runs `/bin/bash scriptPath` at `fireAt`
    /// (whole minute, local time).
    func install(label: String, jobFile: URL, scriptPath: String, fireAt: Date, logPath: String) throws
    /// Unloads the job. True when the scheduler confirmed it.
    @discardableResult func remove(label: String) -> Bool
    /// Loaded jobs whose label starts with one of `prefixes`; `pid` is set
    /// while one runs. nil when the scheduler couldn't be asked.
    func loadedJobs(prefixes: [String]) -> [(label: String, pid: Int32?)]?
    /// The line the job script runs last, to unload itself. Shell code; may
    /// use `$LABEL`.
    var selfUnloadShell: String { get }
    /// Schedules a wake a minute before `at`. Returns a stamp for `cancelWake`.
    func scheduleWake(at: Date) -> String?
    func cancelWake(stamp: String)
}

/// Is the user at this machine? Seconds since the last real input.
///
/// macOS: CGEventSource. Linux: X11 idle (xprintidle), GNOME Mutter's
/// IdleMonitor, logind IdleHint; no graphical session reads as away.
protocol PresenceSource: AnyObject {
    /// `.infinity` when unknown or nobody is at a screen.
    func rawSecondsSinceLastInput() -> TimeInterval
}

/// Reading other (same-user) processes: the process table, argv and a few
/// allowlisted environment variables, open files, listening ports.
///
/// macOS: ps, sysctl(KERN_PROCARGS2), libproc, lsof. Linux: /proc.
protocol ProcessInspector: AnyObject {
    /// Every process: pid, parent, tty ("ttys003"/"pts/3", "??" for none),
    /// full command line. Empty when unreadable.
    func processTable() -> [ProcessRunner.ProcessInfoRow]
    /// argv and the allowlisted environment of `pid`.
    func arguments(pid: Int32, envKeys: Set<String>) -> ProcArgs.Info?
    /// Process start, whole seconds since the epoch.
    func startSeconds(pid: Int32) -> Int?
    /// Every process with its parent, tty device and start time (local-model scan).
    func allProcesses() -> [LocalProcInfo.Entry]
    func execPath(pid: Int32) -> String?
    func ttyName(device: UInt32) -> String?
    func ttyModified(_ ttyName: String) -> Date?
    func listeningTCPPorts(pid: Int32) -> Set<Int>?
    /// Whether `pid` holds its terminal's foreground (job control).
    func foregroundState(pid: Int32) -> ProcessRunner.ForegroundState
    /// `lsof` with the given arguments, in its `-F` field output. Only the
    /// argument shapes CodexInjector uses need to be understood.
    func lsof(_ args: [String], timeout: TimeInterval) -> ProcessRunner.Result
}

/// Bringing a session's terminal to the front. (`TerminalHost`, the enum, is
/// the injection route a session resolves to; this is the OS side of it.)
///
/// macOS: AppleScript (Terminal, iTerm2), NSRunningApplication, the cmux,
/// tmux, WezTerm and kitty CLIs. Linux: the tmux, WezTerm and kitty CLIs.
protocol TerminalHostPlatform: AnyObject {
    func focus(candidates: [ClaudeLiveSession], table: [ProcessRunner.ProcessInfoRow]) -> TerminalFocusOutcome
    func activateAnyTerminal() -> TerminalFocusOutcome
    func activate(appNamed name: String) -> TerminalFocusOutcome
}

/// What a focus request did, for the menu or the CLI.
struct TerminalFocusOutcome: Equatable {
    let ok: Bool
    /// Short and plain: "Brought cmux forward", "Couldn't tell which terminal".
    let detail: String
}

/// Desktop notifications. macOS posts through UserNotifications in the app
/// (AppDelegate); Linux uses org.freedesktop.Notifications (`notify-send`).
protocol Notifier: AnyObject {
    func notify(title: String, body: String, identifier: String)
}

/// Turns the pairing payload into a picture. macOS: CoreImage. Everywhere:
/// `QREncoder` (pure Swift) plus a renderer (terminal half-blocks, PNG).
protocol QRRenderer {
    func modules(for text: String) -> QRMatrix?
}

/// Checks a photo from the phone before it touches disk (ImageCheck's rules).
/// macOS: ImageIO decodes it. Linux: a header-level parser (`HeaderImageSniffer`).
protocol ImageSniffer {
    func check(_ data: Data) -> Result<ImageCheck.Kind, ImageCheck.Failure>
}

/// The implementations in use. Set once at startup, before any other thread
/// runs (the Coordinator reads it in `init`).
struct Platform {
    /// Short name for logs and the relay heartbeat ("macos", "linux").
    var name: String
    var paths: PlatformPaths
    var makePower: () -> PowerBackend
    var makeLidGuard: () -> LidGuard
    /// A scheduler for resume jobs; `runCommand` is ResumeScheduler's
    /// (injectable in tests).
    var makeWakeScheduler: (_ runCommand: @escaping ResumeScheduler.CommandRunner) -> WakeScheduler
    var presence: PresenceSource
    var processes: ProcessInspector
    var terminalHost: TerminalHostPlatform
    var notifier: Notifier?
    var qr: QRRenderer
    var imageSniffer: ImageSniffer
    /// The relay WebSocket for a RelayClient running on `queue`.
    var makeRelayTransport: (_ queue: DispatchQueue) -> RelayTransport
    /// ProcessInfo.thermalState on macOS; /sys/class/thermal on Linux.
    var thermalState: () -> ThermalState

    #if os(macOS)
    static var current: Platform = .mac
    #else
    static var current: Platform = .inert
    #endif
}

// MARK: - inert implementations

/// Does nothing and reports "unknown". The portable default off macOS until a
/// real platform is installed; also what the tests run against.
extension Platform {
    static var inert: Platform {
        Platform(
            name: "inert",
            paths: .current,
            makePower: { InertPower() },
            makeLidGuard: { InertLidGuard() },
            makeWakeScheduler: { _ in InertWakeScheduler() },
            presence: InertPresence(),
            processes: InertProcesses(),
            terminalHost: InertTerminalHost(),
            notifier: nil,
            qr: PortableQRRenderer(),
            imageSniffer: HeaderImageSniffer(),
            makeRelayTransport: { UnavailableRelayTransport(queue: $0) },
            thermalState: { .nominal }
        )
    }
}

final class InertPower: PowerBackend {
    private(set) var held = AwakeAssertions.none
    var isBoosting: Bool { held.preventIdleSleep }
    func snapshot() -> PowerSnapshot { .noBattery }
    func apply(_ want: AwakeAssertions, reason: String) {}
    func releaseAll() {}
}

final class InertLidGuard: LidGuard {
    var isActive: Bool { false }
    var cleanupPending: Bool { false }
    var watchdogLoaded: Bool { true }
    var cachedHelperStatus: SleepGuard.HelperStatus { .missing }
    func helperStatus(refresh: Bool) -> SleepGuard.HelperStatus { .missing }
    func update(shouldDisableSleep: Bool, reason: String) {}
    func forceDisable(reason: String) -> Bool { true }
    func sealAndDisable(reason: String) -> Bool { true }
    func syncWatchdog(enabled: Bool) {}
}

final class InertWakeScheduler: WakeScheduler {
    struct Unsupported: LocalizedError {
        var errorDescription: String? { "This system has no job scheduler Page can use" }
    }
    func jobFileURL(label: String, in directory: URL) -> URL { directory.appendingPathComponent(label + ".job") }
    var jobFileExtension: String { "job" }
    func install(label: String, jobFile: URL, scriptPath: String, fireAt: Date, logPath: String) throws { throw Unsupported() }
    func remove(label: String) -> Bool { false }
    func loadedJobs(prefixes: [String]) -> [(label: String, pid: Int32?)]? { nil }
    var selfUnloadShell: String { ":" }
    func scheduleWake(at: Date) -> String? { nil }
    func cancelWake(stamp: String) {}
}

final class InertPresence: PresenceSource {
    func rawSecondsSinceLastInput() -> TimeInterval { .infinity }
}

final class InertProcesses: ProcessInspector {
    func processTable() -> [ProcessRunner.ProcessInfoRow] { [] }
    func arguments(pid: Int32, envKeys: Set<String>) -> ProcArgs.Info? { nil }
    func startSeconds(pid: Int32) -> Int? { nil }
    func allProcesses() -> [LocalProcInfo.Entry] { [] }
    func execPath(pid: Int32) -> String? { nil }
    func ttyName(device: UInt32) -> String? { nil }
    func ttyModified(_ ttyName: String) -> Date? { nil }
    func listeningTCPPorts(pid: Int32) -> Set<Int>? { nil }
    func foregroundState(pid: Int32) -> ProcessRunner.ForegroundState { .unknown }
    func lsof(_ args: [String], timeout: TimeInterval) -> ProcessRunner.Result { .notLaunched }
}

final class InertTerminalHost: TerminalHostPlatform {
    func focus(candidates: [ClaudeLiveSession], table: [ProcessRunner.ProcessInfoRow]) -> TerminalFocusOutcome {
        TerminalFocusOutcome(ok: false, detail: "Page can't bring terminals forward on this system")
    }
    func activateAnyTerminal() -> TerminalFocusOutcome { TerminalFocusOutcome(ok: false, detail: "Page can't bring apps forward on this system") }
    func activate(appNamed name: String) -> TerminalFocusOutcome { TerminalFocusOutcome(ok: false, detail: "Page can't bring apps forward on this system") }
}

struct PortableQRRenderer: QRRenderer {
    func modules(for text: String) -> QRMatrix? { QREncoder.encode(text) }
}
