import Foundation
@testable import PageCore
#if canImport(PageLinux)
@testable import PageLinux
#endif

/// The portable suite runs against `Platform.current`: the real Mac readers
/// on macOS, `Platform.inert` on Linux. Tests that read this very process
/// (its argv, start time, job control, open files) ask for the live readers.
enum TestPlatform {
    static func useLiveProcesses() {
        #if canImport(PageLinux)
        if !(Platform.current.processes is LinuxProcessInspector) {
            Platform.current.processes = LinuxProcessInspector()
        }
        #endif
    }
}
