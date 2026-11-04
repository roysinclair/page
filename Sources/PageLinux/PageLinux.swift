import Foundation
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
