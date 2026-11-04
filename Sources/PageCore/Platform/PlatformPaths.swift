import Foundation

/// Where Page keeps its files.
///
/// macOS (unchanged from before the split):
///   support  ~/Library/Application Support/ClaudePowerMode   (config.json, relay_token.txt, session_key.txt, sockets, hook holds)
///   config   = support
///   logs     ~/Library/Logs
///
/// Linux (XDG Base Directory):
///   config   $XDG_CONFIG_HOME/page   (~/.config/page: config.json)
///   support  $XDG_DATA_HOME/page     (~/.local/share/page: relay_token.txt, session_key.txt, aura.sock, orbit.sock, hook holds)
///   logs     $XDG_STATE_HOME/page    (~/.local/state/page: paged.log, page-hook.log)
///
/// Secrets (relay_token.txt, session_key.txt) are 0600 files in `support` on
/// both systems; the directory is 0700 on Linux.
struct PlatformPaths: Equatable {
    /// Page's private data folder.
    var support: URL
    /// Where config.json lives.
    var config: URL
    /// The folder for Page's log files.
    var logs: URL
    /// The log file's name in `logs`.
    var logFileName: String
    /// The user's home.
    var home: URL

    var configFile: URL { config.appendingPathComponent("config.json") }

    static var current: PlatformPaths {
        #if os(macOS)
        return .mac
        #else
        return .xdg(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        #endif
    }

    #if os(macOS)
    static var mac: PlatformPaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePowerMode", isDirectory: true)
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        return PlatformPaths(support: support, config: support, logs: logs,
                             logFileName: "ClaudePowerMode.log", home: fm.homeDirectoryForCurrentUser)
    }
    #endif

    /// Pure: the XDG layout for `environment` (relative or empty XDG values are
    /// ignored, as the spec says).
    static func xdg(environment env: [String: String], home: String) -> PlatformPaths {
        func base(_ key: String, _ fallback: String) -> URL {
            if let v = env[key], v.hasPrefix("/") { return URL(fileURLWithPath: v, isDirectory: true) }
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(fallback, isDirectory: true)
        }
        let config = base("XDG_CONFIG_HOME", ".config").appendingPathComponent("page", isDirectory: true)
        let data = base("XDG_DATA_HOME", ".local/share").appendingPathComponent("page", isDirectory: true)
        let state = base("XDG_STATE_HOME", ".local/state").appendingPathComponent("page", isDirectory: true)
        return PlatformPaths(support: data, config: config, logs: state, logFileName: "paged.log",
                             home: URL(fileURLWithPath: home, isDirectory: true))
    }

    /// `support/<name>`.
    func supportFile(_ name: String) -> URL { support.appendingPathComponent(name) }
}
