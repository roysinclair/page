import Foundation
#if canImport(Glibc)
import Glibc
#endif
@testable import PageCore

// The Linux implementations of PageCore's platform protocols, assembled.
// `paged` installs this before it builds the Coordinator.

extension Platform {
    static var linux: Platform {
        Platform(
            name: "linux",
            paths: .current,
            makePower: { LinuxPowerBackend() },
            makeLidGuard: { LinuxLidGuard() },
            makeWakeScheduler: { SystemdTimerScheduler(unitDirectory: ResumeScheduler.launchAgentsDir, runCommand: $0) },
            presence: LinuxPresence(),
            processes: LinuxProcessInspector(),
            terminalHost: LinuxTerminalHost(),
            notifier: NotifySendNotifier(),
            qr: PortableQRRenderer(),
            imageSniffer: HeaderImageSniffer(),
            makeRelayTransport: { NIORelayTransport(queue: $0) },
            thermalState: { LinuxThermal.read() }
        )
    }
}

/// Called first thing by paged's main: from here on the core sees Linux.
public enum PageLinuxBootstrap {
    public static func installLinuxPlatform() {
        ensureUTF8Locale()
        Platform.current = .linux
    }

    /// A service can start with no locale at all (or LANG=C). tmux then
    /// writes control characters in `list-panes -F` output as "_", so the
    /// tab-separated pane listing doesn't parse and no pane is found, and
    /// non-ASCII text in a reply would be mangled on its way in. paged and
    /// every tool it runs get a UTF-8 character type unless one is set.
    static func ensureUTF8Locale(environment env: [String: String] = ProcessInfo.processInfo.environment) {
        if let v = needsUTF8Locale(env) { setenv("LC_CTYPE", v, 1) }
    }

    /// Pure: the LC_CTYPE to set, or nil when the effective one is UTF-8
    /// (or LC_ALL is set, which would override it anyway).
    static func needsUTF8Locale(_ env: [String: String]) -> String? {
        if let all = env["LC_ALL"], !all.isEmpty { return nil }
        let effective = [env["LC_CTYPE"], env["LANG"]].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let lower = effective.lowercased()
        return lower.contains("utf-8") || lower.contains("utf8") ? nil : "C.UTF-8"
    }
}
