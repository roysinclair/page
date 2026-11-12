import Foundation

/// "Dismiss closes the terminal" (Designs/panel-sessions.md §4): when the person
/// has turned that on, putting a finished session away also closes the exact
/// terminal tab it runs in. Closing a tab ends the agent there, so this is the
/// most careful path Page has:
///   - exact target only. The host is resolved again at the moment of closing,
///     with the same resolution as Open and Steer, and there is no fallback
///     ("bring any terminal forward" belongs to Open, never here);
///   - only a Claude Code session whose own process is at its prompt: status
///     `.idle` or `.shell`, read again just before and just after the host is
///     found, the same process as when the card was put away, and the only one
///     claiming that session id;
///   - a plan per host that names one pane, window or session, or refuses in words.
/// Nothing here types a key, signals a process or closes anything but that one
/// terminal. `plan(for:)`, `eligible(_:)` and the scripts are pure; `close` is
/// blocking (ps, tmux, the cmux socket, AppleScript): run it off the main thread,
/// and only when a dismissal commits.
enum TerminalClose {
    /// Said for a Codex session: its dismissal still commits, its terminal stays.
    static let codexRefusal = "Page can close only Claude Code terminals for now"
    /// Terminal.app closes windows, not tabs: a tab that shares its window stays.
    static let sharedWindowRefusal = "Terminal can only close whole windows, and this tab shares one"

    /// What the Terminal and iTerm2 scripts answer.
    static let scriptClosed = "closed"
    static let scriptShared = "shared"
    static let scriptNone = "none"

    // MARK: who may be closed

    /// Pure. Only a session sitting at its prompt: `.idle`, or `.shell` (a turn that
    /// ended with a background shell still running). Never a busy one, one with a
    /// prompt on screen, or one whose state is unknown.
    static func eligible(_ status: ClaudeSessionStatus) -> Bool {
        status == .idle || status == .shell
    }

    // MARK: the plan

    /// Pure. How to close the exact terminal behind a resolved host, or why not.
    static func plan(for host: InjectionExecutor.TerminalHost) -> TerminalClosePlan {
        switch host {
        case .cmux(let target):
            // cmux won't close the last tab of a workspace, so which command closes this tab
            // depends on what else is in its workspace: `cmuxCloseArgs` decides at run time.
            guard isSafeId(target.surfaceId), let ws = target.workspaceId, isSafeId(ws) else {
                return .refuse("Page can't tell which cmux tab this is")
            }
            return .cmux(cliPath: target.cliPath, surfaceId: target.surfaceId, workspaceId: ws)

        case .tmux(let path, let pane, _, let session):
            // A Claude Squad agent is a tmux pane Squad manages: it is closed from Squad.
            if let session, ClaudeSquad.isSquadSession(session) { return .refuse("Page can't close Claude Squad sessions") }
            guard TerminalFocus.isSafePane(pane) else { return .refuse("Page can't tell which tmux pane this is") }
            return .tmux(path: path, args: ["kill-pane", "-t", pane])

        case .terminalApp(let tty):
            guard TerminalFocus.isSafeTTY(tty) else { return .refuse("Page can't tell which Terminal window this is") }
            return .appleScript(app: "Terminal", source: terminalScript(tty: tty))

        case .iTerm(let tty):
            guard TerminalFocus.isSafeTTY(tty) else { return .refuse("Page can't tell which iTerm2 session this is") }
            return .appleScript(app: "iTerm2", source: iTermScript(tty: tty))

        case .wezterm(let target):
            guard isSafeNumber(target.paneId) else { return .refuse("Page can't tell which WezTerm pane this is") }
            return .wezterm(target, args: ["cli", "kill-pane", "--pane-id", target.paneId])

        case .kitty(let target):
            guard isSafeNumber(target.windowId), isSafeSocket(target.socket) else {
                return .refuse("Page can't tell which kitty window this is")
            }
            return .kitty(path: target.kittenPath,
                          args: ["@", "--to", target.socket, "close-window", "--match", "id:\(target.windowId)"])

        case .herdr:
            return .refuse("Page can't close herdr tabs")
        case .unsupported(let app):
            return .refuse("Page can't close \(app) tabs")
        case .unreachable, .unknown:
            return .refuse("Page can't close unknown terminal tabs")
        }
    }

    /// Pure. What a host's own tab is called, for the tooltip, the status line and
    /// the outcome: "cmux tab", "tmux pane", "Terminal window", "iTerm2 session",
    /// "WezTerm pane", "kitty window". nil where Page can't close it. `hostName` is
    /// the phone's wire name for the host (`SessionHostInfo.host`).
    static func noun(forHostName hostName: String) -> String? {
        switch hostName {
        case "cmux": return "cmux tab"
        case "tmux": return "tmux pane"
        case "Terminal": return "Terminal window"
        case "iTerm", "iTerm2": return "iTerm2 session"
        case "WezTerm": return "WezTerm pane"
        case "kitty": return "kitty window"
        default: return nil
        }
    }

    /// Pure. The host's name in a route label ("cmux › payments-api" → "cmux").
    static func hostName(fromRoute route: String?) -> String? {
        guard let route, let host = route.components(separatedBy: " › ").first, !host.isEmpty else { return nil }
        return host
    }

    /// Pure. The noun for a route label, when the host is one Page can close.
    static func noun(forRoute route: String?) -> String? {
        hostName(fromRoute: route).flatMap(noun(forHostName:))
    }

    // MARK: scripts

    /// Pure. Closes the Terminal.app window whose only tab has `tty`. A tab that
    /// shares its window is left alone and the script says "shared". Answers
    /// "closed", "shared" or "none" (no such tab).
    static func terminalScript(tty: String) -> String {
        """
        with timeout of 10 seconds
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    set tabList to tabs of w
                    repeat with t in tabList
                        set tTTY to ""
                        try
                            set tTTY to (tty of t as string)
                        end try
                        if tTTY is \(ProcessRunner.appleScriptQuote(tty)) then
                            if (count of tabList) is 1 then
                                close w
                                return "\(scriptClosed)"
                            end if
                            return "\(scriptShared)"
                        end if
                    end repeat
                end repeat
                return "\(scriptNone)"
            end tell
        end timeout
        """
    }

    /// Pure. Closes the iTerm2 session whose tty is `tty`. Answers "closed" or "none".
    static func iTermScript(tty: String) -> String {
        """
        with timeout of 10 seconds
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with s in sessions of tb
                            set sTTY to ""
                            try
                                set sTTY to (tty of s as string)
                            end try
                            if sTTY is \(ProcessRunner.appleScriptQuote(tty)) then
                                tell s to close
                                return "\(scriptClosed)"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "\(scriptNone)"
            end tell
        end timeout
        """
    }

    /// Pure. What an AppleScript run of `terminalScript` or `iTermScript` means.
    static func scriptResult(_ r: (value: String?, error: String?, errorNumber: Int?), app: String) -> TerminalCloseRunResult {
        if let err = r.error {
            switch r.errorNumber {
            case .some(-1743): return .failed("allow Page Studio to control \(app) in System Settings → Privacy & Security → Automation")
            case .some(-600): return .failed("\(app) isn't running")
            default: return .failed(err)
            }
        }
        switch r.value {
        case scriptClosed?: return .closed
        case scriptShared?: return .refused(sharedWindowRefusal)
        default: return .failed("Page couldn't find that tab any more")
        }
    }

    // MARK: ids that go into arguments

    // MARK: cmux

    /// cmux's answer to `--json --id-format uuids list-panels --workspace <ws>`.
    static func cmuxListArgs(workspaceId: String) -> [String] {
        ["--json", "--id-format", "uuids", "list-panels", "--workspace", workspaceId]
    }

    /// Pure. The ids of the tabs (surfaces) in a workspace, from `list-panels` JSON;
    /// nil when the answer can't be read.
    static func cmuxSurfaceIds(fromListJSON json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let surfaces = obj["surfaces"] as? [[String: Any]] else { return nil }
        return surfaces.compactMap { $0["id"] as? String }
    }

    /// Pure. The command that closes exactly `surfaceId`, given every tab in its
    /// workspace (checked on 2026-11-12 against cmux 0.65.2):
    ///   - cmux asks before closing a tab or workspace with a process running in it, and
    ///     a Claude session always has one, so both commands carry `--force`;
    ///   - it won't close a workspace's last tab, so a tab alone in its workspace is
    ///     closed by closing that workspace, which holds nothing else;
    ///   - a tab no longer in the workspace is not closed at all (nil).
    static func cmuxCloseArgs(surfaceId: String, workspaceId: String, surfacesInWorkspace: [String]) -> [String]? {
        let mine = surfacesInWorkspace.filter { $0.caseInsensitiveCompare(surfaceId) == .orderedSame }
        guard mine.count == 1 else { return nil }
        if surfacesInWorkspace.count == 1 {
            return ["close-workspace", "--workspace", workspaceId, "--force"]
        }
        return ["close-surface", "--surface", surfaceId, "--workspace", workspaceId, "--force"]
    }

    /// Pure. A cmux surface or workspace id as a command-line value: no leading dash.
    static func isSafeId(_ id: String) -> Bool {
        id.matchesEntirely(#"^[A-Za-z0-9][A-Za-z0-9_.:-]*$"#)
    }

    /// Pure. kitty's `KITTY_LISTEN_ON` ("unix:/tmp/kitty-1234") as a command-line value.
    static func isSafeSocket(_ socket: String) -> Bool {
        socket.matchesEntirely(#"^[A-Za-z0-9][A-Za-z0-9_.:/@-]*$"#)
    }

    /// Pure. A WezTerm pane or kitty window id.
    static func isSafeNumber(_ id: String) -> Bool {
        id.matchesEntirely(#"^[0-9]+$"#)
    }

    // MARK: closing (blocking)

    /// Blocking: ps, tmux, the cmux socket and AppleScript. Never on main, and only
    /// when a dismissal commits. Re-reads the live sessions and resolves the host
    /// again, then refuses when the session is gone, is not at its prompt, is a
    /// different process from the one dismissed (`expectedPid`), has had activity
    /// since (`expectedSince`, its status time when the card was put away), shares its
    /// id with another process, or the plan refuses. `io` is the live read in the app and
    /// a fake in tests.
    static func close(sessionId: String, backend: AgentBackendID = .claude, expectedPid: Int32? = nil,
                      expectedSince: Date? = nil, io: TerminalCloseIO) -> TerminalCloseOutcome {
        guard backend == .claude else { return .refused(.codex) }
        let candidates = io.liveSessions().filter { $0.sessionId == sessionId }
        guard !candidates.isEmpty else { return .refused(.sessionGone) }
        guard candidates.count == 1, let session = candidates.first else { return .refused(.ambiguous) }
        if let expectedPid, session.pid != expectedPid { return .refused(.restarted) }
        // Its status changed since the card was put away: it was used again in between, even if it is
        // at its prompt once more.
        if let expectedSince, session.statusUpdatedAt != expectedSince { return .refused(.usedAgain) }
        // A status that can't be read now is a session that can't be vouched for.
        guard let status = io.currentStatus(session.pid) else { return .refused(.sessionGone) }
        guard eligible(status) else { return .refused(.notIdle(status)) }

        let host = io.resolveHost(session, io.processTable())
        let plan = plan(for: host)
        if case .refuse(let why) = plan { return .refused(.plan(why)) }

        // Finding the pane takes a moment: it may have started working in it.
        guard let again = io.currentStatus(session.pid) else { return .refused(.sessionGone) }
        guard eligible(again) else { return .refused(.notIdle(again)) }

        switch io.run(plan) {
        case .closed: return .closed(noun: plan.noun ?? "terminal")
        case .refused(let why): return .refused(.plan(why))
        case .failed(let why): return .failed(why)
        }
    }

    /// The real runner for a plan that is not a refusal. Blocking. Not run by
    /// tests: they pass a fake `TerminalCloseIO.run`.
    static func runLive(_ plan: TerminalClosePlan) -> TerminalCloseRunResult {
        func outcome(_ r: ProcessRunner.Result, _ what: String) -> TerminalCloseRunResult {
            r.succeeded ? .closed : .failed("\(what) didn't close it")
        }
        switch plan {
        case .cmux(let cliPath, let surfaceId, let workspaceId):
            switch CmuxBridge.connect(cliPath: cliPath) {
            case .failure(let f): return .failed(f.detail)
            case .success(let client):
                let listed: [String]?
                switch client.run(cmuxListArgs(workspaceId: workspaceId), timeout: 4, fallback: "cmux didn't list the workspace") {
                case .success(let json): listed = cmuxSurfaceIds(fromListJSON: json)
                case .failure(let f): return .failed(f.detail)
                }
                guard let surfaces = listed else { return .failed("Page couldn't read cmux's list of tabs") }
                guard let args = cmuxCloseArgs(surfaceId: surfaceId, workspaceId: workspaceId, surfacesInWorkspace: surfaces) else {
                    return .failed("Page couldn't find that cmux tab any more")
                }
                switch client.run(args, timeout: 4, fallback: "cmux didn't close it") {
                case .success: return .closed
                case .failure(let f): return .failed(f.detail)
                }
            }
        case .tmux(let path, let args):
            return outcome(ProcessRunner.run(path, args, timeout: 3), "tmux")
        case .appleScript(let app, let source):
            return scriptResult(InjectionExecutor.runAppleScript(source), app: app)
        case .wezterm(let target, let args):
            return outcome(ProcessRunner.run(target.cliPath, args, timeout: 3, environment: WezTermBridge.environment(socket: target.socket)),
                           "WezTerm")
        case .kitty(let path, let args):
            return outcome(ProcessRunner.run(path, args, timeout: 3), "kitty")
        case .refuse(let why):
            return .refused(why)
        }
    }
}

// MARK: - Plans and outcomes

/// How to close one terminal, host by host, or why not.
enum TerminalClosePlan: Equatable {
    /// One cmux tab in one workspace, through `CmuxBridge`; `cmuxCloseArgs` picks the
    /// command once the workspace's tabs are listed.
    case cmux(cliPath: String, surfaceId: String, workspaceId: String)
    /// `kill-pane -t %N`.
    case tmux(path: String, args: [String])
    /// AppleScript that closes one Terminal window or iTerm2 session.
    case appleScript(app: String, source: String)
    /// `cli kill-pane --pane-id <id>`.
    case wezterm(WezTermBridge.Target, args: [String])
    /// `@ --to <socket> close-window --match id:<id>`.
    case kitty(path: String, args: [String])
    /// Page won't close it, and says why: "Page can't close Ghostty tabs".
    case refuse(String)

    /// "cmux tab", "tmux pane", "Terminal window", "iTerm2 session", "WezTerm pane",
    /// "kitty window"; nil for a refusal.
    var noun: String? {
        switch self {
        case .cmux: return "cmux tab"
        case .tmux: return "tmux pane"
        case .appleScript(let app, _): return TerminalClose.noun(forHostName: app)
        case .wezterm: return "WezTerm pane"
        case .kitty: return "kitty window"
        case .refuse: return nil
        }
    }
}

/// What running a plan came to.
enum TerminalCloseRunResult: Equatable {
    case closed
    /// The script left it open on purpose (a Terminal tab that shares its window).
    case refused(String)
    case failed(String)
}

/// Why Page left a terminal open, as the status line says it.
enum TerminalCloseRefusal: Equatable {
    case codex
    case sessionGone
    case ambiguous
    case restarted
    /// Its status changed after the card was put away: someone worked in it again.
    case usedAgain
    case notIdle(ClaudeSessionStatus)
    /// The plan's own refusal.
    case plan(String)

    var text: String {
        switch self {
        case .codex: return TerminalClose.codexRefusal
        case .sessionGone: return "its session has ended"
        case .ambiguous: return "more than one process claims this session"
        case .restarted: return "it was restarted"
        case .usedAgain: return "it was used again"
        case .notIdle(let status):
            switch status {
            case .busy: return "it started working again"
            case .waiting: return "it is waiting for an answer again"
            default: return "Page can't tell what it is doing"
            }
        case .plan(let why): return why
        }
    }

    /// A limit of Page's own ("Page can't close Ghostty tabs"), said bare after
    /// "Dismissed …"; the rest follow "didn't close its tab:".
    var isPageLimit: Bool {
        switch self {
        case .codex: return true
        case .plan(let why): return why.hasPrefix("Page can")
        default: return false
        }
    }
}

enum TerminalCloseOutcome: Equatable {
    /// `noun`: "cmux tab".
    case closed(noun: String)
    case refused(TerminalCloseRefusal)
    /// It was tried and did not work.
    case failed(String)
}

/// What `TerminalClose.close` reads and runs. The live version is built in the
/// Coordinator; tests pass fakes, so no terminal is ever closed by a test.
struct TerminalCloseIO {
    /// Claude Code processes running now (the registry's list, read again).
    var liveSessions: () -> [ClaudeLiveSession]
    /// One process's status from its own session file, read now; nil when it can't be.
    var currentStatus: (Int32) -> ClaudeSessionStatus?
    var processTable: () -> [ProcessRunner.ProcessInfoRow]
    var resolveHost: (ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> InjectionExecutor.TerminalHost
    /// Runs a plan that is not a refusal.
    var run: (TerminalClosePlan) -> TerminalCloseRunResult
}
