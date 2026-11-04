import Foundation
import PageCore
import PageLinux

// paged: Page Power's headless daemon and CLI for Linux. Everything lives in
// PageLinux (PagedCLI, PagedDaemon) so it can be tested.
PageLinuxBootstrap.installLinuxPlatform()
exit(PagedCLI.main(CommandLine.arguments))
