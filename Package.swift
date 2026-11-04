// swift-tools-version:5.9
import PackageDescription
import Foundation

// Targets:
//  - PageCore: the portable core. The Coordinator, agent backends, relay
//    protocol and client, live sessions and their crypto, intervention
//    detection, transcript parsing, policies, config, the hooks installer, the
//    injection planner (tmux, WezTerm, kitty, Herdr, Claude Squad) and the
//    Aura/Orbit link protocol. Foundation only. The few Mac implementations
//    that are woven into core logic (IOKit power, pmset, AppleScript, cmux's
//    code-signature check) sit behind `#if os(macOS)`; everything the
//    platforms do differently goes through the protocols in
//    Sources/PageCore/Platform.
//
// macOS only:
//  - PageWidgetSupport: what the app and the widget extension share. The
//    snapshot Page writes, the routes a click opens, how widgets are looked up
//    in macOS, and the widget views. Foundation and SwiftUI only (it is linked
//    into an app extension, so nothing here may touch AppKit's app APIs).
//  - PageWidgets: the WidgetKit extension. build.sh wraps its executable as
//    Page.app/Contents/PlugIns/PageWidgets.appex and signs it before the app.
//  - ClaudePowerMode: the menu-bar app (AppKit/SwiftUI UI and widgets).
//
// Linux only:
//  - PageLinux: the Linux implementations of the platform protocols (logind,
//    UPower and sysfs, /proc, XDG paths, systemd timers, a NIO WebSocket).
//  - paged: the headless daemon and its CLI.
//
// The app and paged reach PageCore's internal API with `@testable import`
// (PageCore is built with -enable-testing in every configuration). That keeps
// the split a pure move: no access modifiers changed across ~40k lines. The
// next step is to narrow this to `package` declarations.
//
// The package stays on macOS 12 (the app's deployment target). The extension
// uses macOS 14 APIs (containerBackground) behind `#available`.

let coreSettings: [SwiftSetting] = [.unsafeFlags(["-enable-testing"])]

var packageDependencies: [Package.Dependency] = []
var targets: [Target] = []
var products: [Product] = []

#if os(macOS)
let appExtensionFlag: [SwiftSetting] = [.unsafeFlags(["-application-extension"])]

// The extension must record the SDK it is built with (LC_BUILD_VERSION `sdk`).
// SwiftPM's build links with `-target arm64-apple-macos12.0` and leaves the sdk
// at 12.0, and WidgetKit then treats the widget as built for macOS 12: no system
// content margins and no containerBackground semantics, so faces draw edge to
// edge and are clipped by the widget's rounded corners. The app is left alone
// (an older linked-on SDK keeps AppKit's behaviours as they are today).
//
// minos stays 12.0 here (the Info.plist's LSMinimumSystemVersion is what the
// system reads for an extension; the faces gate macOS 14 APIs themselves).
// The SDK version comes from the toolchain: `xcrun --show-sdk-version`.
func installedSDKVersion() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "--show-sdk-version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return "14.0" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // "27.0", or "15" on an SDK that omits the minor: ld wants major.minor.
    let ok = text.range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil
    guard ok else { return "14.0" }
    return text.contains(".") ? text : text + ".0"
}

targets += [
    .target(
        name: "PageCore",
        path: "Sources/PageCore",
        swiftSettings: coreSettings
    ),
    .target(
        name: "PageWidgetSupport",
        path: "Sources/PageWidgetSupport",
        swiftSettings: appExtensionFlag
    ),
    .executableTarget(
        name: "PageWidgets",
        dependencies: ["PageWidgetSupport"],
        path: "Sources/PageWidgets",
        swiftSettings: appExtensionFlag,
        // What Xcode passes for an app extension: the extension entry point
        // replaces main, and AppKit's app-only API is refused at link time.
        linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension",
                                       "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                                       "-Xlinker", "-platform_version", "-Xlinker", "macos",
                                       "-Xlinker", "12.0", "-Xlinker", installedSDKVersion()])]
    ),
    .executableTarget(
        name: "ClaudePowerMode",
        dependencies: ["PageCore", "PageWidgetSupport"],
        path: "Sources/ClaudePowerMode"
    ),
    .testTarget(
        name: "PageCoreTests",
        dependencies: ["PageCore"],
        path: "Tests/PageCoreTests"
    ),
    .testTarget(
        name: "ClaudePowerModeTests",
        dependencies: ["ClaudePowerMode", "PageCore", "PageWidgetSupport"],
        path: "Tests/ClaudePowerModeTests"
    ),
]
#else
packageDependencies += [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "4.0.0"),
    .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
]
products += [
    .executable(name: "paged", targets: ["paged"]),
]
targets += [
    .target(
        name: "PageCore",
        dependencies: [.product(name: "Crypto", package: "swift-crypto")],
        path: "Sources/PageCore",
        swiftSettings: coreSettings
    ),
    .target(
        name: "PageLinux",
        dependencies: [
            "PageCore",
            .product(name: "WebSocketKit", package: "websocket-kit"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ],
        path: "Sources/PageLinux",
        swiftSettings: coreSettings
    ),
    .executableTarget(
        name: "paged",
        dependencies: ["PageCore", "PageLinux"],
        path: "Sources/paged"
    ),
    .testTarget(
        name: "PageCoreTests",
        // PageLinux only for the few tests that read this very process
        // (TestPlatform.useLiveProcesses); macOS's readers are the default there.
        dependencies: ["PageCore", "PageLinux"],
        path: "Tests/PageCoreTests"
    ),
    .testTarget(
        name: "PageLinuxTests",
        dependencies: ["PageCore", "PageLinux"],
        path: "Tests/PageLinuxTests",
        resources: [.copy("Fixtures")]
    ),
]
#endif

let package = Package(
    name: "ClaudePowerMode",
    platforms: [.macOS(.v12)],
    products: products,
    dependencies: packageDependencies,
    targets: targets
)
