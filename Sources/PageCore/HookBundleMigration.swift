import Foundation

/// The app's bundle folder was renamed from Page.app to Page Studio.app. Hook
/// entries the in-app installer wrote before that run the script inside the
/// old folder, which install.sh removes. This points exactly those entries at
/// the script in the installed Page Studio.app, the same way an install does:
/// a backup next to the file first, an atomic write, and a refusal if the
/// file changes underneath. It runs from install.sh (`--migrate-hook-paths`)
/// and again at every launch, where it is a no-op once nothing matches.
///
/// It only ever acts for an installed copy (/Applications or ~/Applications),
/// so a build folder or a download never takes the hooks over.
enum HookBundleMigration {
    struct Outcome: Equatable {
        var agent: HookAgent
        /// The file that was changed (or that couldn't be).
        var path: String
        /// The backup of the previous file, when one was written.
        var backup: String?
        /// Why it couldn't be changed; nil on success.
        var error: String?
    }

    /// The command-line flag install.sh passes to the installed app.
    static let flag = "--migrate-hook-paths"

    /// Moves the entries for each agent whose file names the old bundle.
    /// Returns one outcome per file it changed or failed to change; empty
    /// when there was nothing to do (or this isn't an installed copy).
    static func run(installer: HookInstaller, now: Date = Date()) -> [Outcome] {
        let home = installer.homeDirectory.path
        guard HookInstaller.isInstalledBundleScript(installer.scriptPath, home: home) else { return [] }
        let olds = HookInstaller.legacyScriptPaths(home: home)
        var out: [Outcome] = []
        for agent in HookAgent.allCases {
            let path = installer.fileURL(for: agent).path
            do {
                let plan = try installer.planBundleMove(agent, from: olds)
                guard plan.changed else { continue }
                let backup = try installer.apply(plan, now: now)
                out.append(Outcome(agent: agent, path: path, backup: backup?.path))
            } catch HookInstallerError.agentNotInstalled {
                continue
            } catch {
                let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Logger.shared.log("HookBundleMigration: \(agent.rawValue) hooks not moved: \(why)")
                out.append(Outcome(agent: agent, path: path, error: why))
            }
        }
        return out
    }

    /// `run` for this app's own hook script.
    static func runForThisApp(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Outcome] {
        guard let script = HookInstaller.locateScript() else { return [] }
        return run(installer: HookInstaller(homeDirectory: home, scriptPath: script))
    }

    /// Pure. One line per outcome, for the terminal and the notification.
    static func describe(_ o: Outcome) -> String {
        if let error = o.error {
            return "Couldn't point the \(o.agent.displayName) hooks in \(o.path) at Page Studio.app: \(error)"
        }
        var line = "Pointed the \(o.agent.displayName) hooks in \(o.path) at Page Studio.app."
        if let backup = o.backup { line += " Backup: \(backup)" }
        if o.agent == .codex {
            line += " Open Codex and run /hooks to trust the updated hook; Codex skips a changed hook until you do."
        }
        return line
    }
}
