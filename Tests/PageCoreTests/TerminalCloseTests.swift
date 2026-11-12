import XCTest
@testable import PageCore

/// "Dismiss closes the terminal" (Designs/panel-sessions.md §4): who may be
/// closed, the plan per host, the scripts and their answers, and `close` run
/// against a fake `TerminalCloseIO`. No test runs a process, AppleScript or the
/// cmux socket: `runLive` is never called, and every fake `run` is recorded.
final class TerminalCloseTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)
    private let cmuxCli = "/Applications/cmux.app/Contents/Resources/bin/cmux"

    private let cmuxHost = InjectionExecutor.TerminalHost.cmux(
        CmuxBridge.Target(surfaceId: "surface-7", workspaceId: "ws-2", cliPath: "/Applications/cmux.app/Contents/Resources/bin/cmux",
                          source: "hook-sessions"))

    /// Records every plan the fake `run` receives, and serves the statuses in order (the last one repeats).
    private final class Fake {
        var runs: [TerminalClosePlan] = []
        var statuses: [ClaudeSessionStatus?]
        private var calls = 0

        init(statuses: [ClaudeSessionStatus?]) { self.statuses = statuses }

        func status() -> ClaudeSessionStatus? {
            defer { calls += 1 }
            guard !statuses.isEmpty else { return nil }
            return statuses[min(calls, statuses.count - 1)]
        }
    }

    private func live(pid: Int32 = 42, sessionId: String = "sess-1", since: Date? = nil) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: pid, sessionId: sessionId, cwd: "/Users/roy/projects/page", status: .idle,
                          statusUpdatedAt: since ?? t0, tty: "ttys003", hasSessionFile: true)
    }

    private func io(_ sessions: [ClaudeLiveSession], fake: Fake, host: InjectionExecutor.TerminalHost? = nil,
                    result: TerminalCloseRunResult = .closed) -> TerminalCloseIO {
        let h = host ?? cmuxHost
        return TerminalCloseIO(
            liveSessions: { sessions },
            currentStatus: { _ in fake.status() },
            processTable: { [] },
            resolveHost: { _, _ in h },
            run: { plan in
                fake.runs.append(plan)
                return result
            })
    }

    private func assertRefused(_ outcome: TerminalCloseOutcome, _ expected: TerminalCloseRefusal,
                               fake: Fake, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome, .refused(expected), file: file, line: line)
        XCTAssertTrue(fake.runs.isEmpty, "the terminal must never be touched when Page refuses", file: file, line: line)
    }

    // MARK: - Who may be closed

    func testOnlyAnIdleOrShellSessionIsEligible() {
        XCTAssertTrue(TerminalClose.eligible(.idle))
        XCTAssertTrue(TerminalClose.eligible(.shell), "a turn that ended with a background shell still running")
        XCTAssertFalse(TerminalClose.eligible(.busy))
        XCTAssertFalse(TerminalClose.eligible(.waiting))
        XCTAssertFalse(TerminalClose.eligible(.unknown))
    }

    // MARK: - Plans, host by host

    func testCmuxClosesTheSurfaceInItsWorkspace() {
        XCTAssertEqual(TerminalClose.plan(for: cmuxHost),
                       .cmux(cliPath: cmuxCli, surfaceId: "surface-7", workspaceId: "ws-2"))
        XCTAssertEqual(TerminalClose.plan(for: cmuxHost).noun, "cmux tab")
    }

    func testCmuxWithoutAWorkspaceIsRefused() {
        let noWorkspace = InjectionExecutor.TerminalHost.cmux(
            CmuxBridge.Target(surfaceId: "surface-7", workspaceId: nil, cliPath: cmuxCli, source: "hook-sessions"))
        XCTAssertEqual(TerminalClose.plan(for: noWorkspace), .refuse("Page can't tell which cmux tab this is"))
        let emptyWorkspace = InjectionExecutor.TerminalHost.cmux(
            CmuxBridge.Target(surfaceId: "surface-7", workspaceId: "", cliPath: cmuxCli, source: "hook-sessions"))
        XCTAssertEqual(TerminalClose.plan(for: emptyWorkspace), .refuse("Page can't tell which cmux tab this is"))
    }

    func testCmuxRefusesUnsafeIds() {
        let dashSurface = InjectionExecutor.TerminalHost.cmux(
            CmuxBridge.Target(surfaceId: "-rf", workspaceId: "ws-2", cliPath: cmuxCli, source: "hook-sessions"))
        XCTAssertEqual(TerminalClose.plan(for: dashSurface), .refuse("Page can't tell which cmux tab this is"))
        let spacedWorkspace = InjectionExecutor.TerminalHost.cmux(
            CmuxBridge.Target(surfaceId: "surface-7", workspaceId: "ws 2; rm", cliPath: cmuxCli, source: "hook-sessions"))
        XCTAssertEqual(TerminalClose.plan(for: spacedWorkspace), .refuse("Page can't tell which cmux tab this is"))
    }

    func testTmuxKillsTheExactPane() {
        let host = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/opt/tmux", paneId: "%12", inMode: false, session: nil)
        XCTAssertEqual(TerminalClose.plan(for: host), .tmux(path: "/opt/tmux", args: ["kill-pane", "-t", "%12"]))
        XCTAssertEqual(TerminalClose.plan(for: host).noun, "tmux pane")
    }

    func testTmuxRefusesAnUnsafePaneAndClaudeSquadSessions() {
        let bad = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/opt/tmux", paneId: "12", inMode: false, session: nil)
        XCTAssertEqual(TerminalClose.plan(for: bad), .refuse("Page can't tell which tmux pane this is"))
        let squad = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/opt/tmux", paneId: "%12", inMode: false,
                                                        session: ClaudeSquad.sessionPrefix + "payments")
        XCTAssertEqual(TerminalClose.plan(for: squad), .refuse("Page can't close Claude Squad sessions"))
    }

    func testTerminalAppClosesTheWindowWithThatTTY() {
        let plan = TerminalClose.plan(for: .terminalApp(tty: "/dev/ttys003"))
        XCTAssertEqual(plan, .appleScript(app: "Terminal", source: TerminalClose.terminalScript(tty: "/dev/ttys003")))
        guard case .appleScript(_, let source) = plan else { return XCTFail("expected AppleScript") }
        XCTAssertTrue(source.contains("/dev/ttys003"))
        XCTAssertEqual(plan.noun, "Terminal window")
    }

    func testTerminalAppRefusesABareOrInjectedTTY() {
        XCTAssertEqual(TerminalClose.plan(for: .terminalApp(tty: "ttys003")),
                       .refuse("Page can't tell which Terminal window this is"))
        XCTAssertEqual(TerminalClose.plan(for: .terminalApp(tty: "/dev/ttys1\" & do shell script \"x")),
                       .refuse("Page can't tell which Terminal window this is"))
    }

    func testITermClosesTheSessionWithThatTTY() {
        let plan = TerminalClose.plan(for: .iTerm(tty: "/dev/ttys004"))
        XCTAssertEqual(plan, .appleScript(app: "iTerm2", source: TerminalClose.iTermScript(tty: "/dev/ttys004")))
        XCTAssertEqual(plan.noun, "iTerm2 session")
        XCTAssertEqual(TerminalClose.plan(for: .iTerm(tty: "ttys004")),
                       .refuse("Page can't tell which iTerm2 session this is"))
    }

    func testWezTermKillsThePane() {
        let target = WezTermBridge.Target(cliPath: "/opt/wezterm", paneId: "7", socket: "/tmp/wez.sock")
        XCTAssertEqual(TerminalClose.plan(for: .wezterm(target)),
                       .wezterm(target, args: ["cli", "kill-pane", "--pane-id", "7"]))
        XCTAssertEqual(TerminalClose.plan(for: .wezterm(target)).noun, "WezTerm pane")
        let bad = WezTermBridge.Target(cliPath: "/opt/wezterm", paneId: "7a", socket: nil)
        XCTAssertEqual(TerminalClose.plan(for: .wezterm(bad)), .refuse("Page can't tell which WezTerm pane this is"))
    }

    func testKittyClosesTheWindowById() {
        let target = KittyBridge.Target(kittenPath: "/opt/kitten", socket: "unix:/tmp/kitty-1", windowId: "4")
        XCTAssertEqual(TerminalClose.plan(for: .kitty(target)),
                       .kitty(path: "/opt/kitten", args: ["@", "--to", "unix:/tmp/kitty-1", "close-window", "--match", "id:4"]))
        XCTAssertEqual(TerminalClose.plan(for: .kitty(target)).noun, "kitty window")
        let badWindow = KittyBridge.Target(kittenPath: "/opt/kitten", socket: "unix:/tmp/kitty-1", windowId: "x")
        XCTAssertEqual(TerminalClose.plan(for: .kitty(badWindow)), .refuse("Page can't tell which kitty window this is"))
        let badSocket = KittyBridge.Target(kittenPath: "/opt/kitten", socket: "-x", windowId: "4")
        XCTAssertEqual(TerminalClose.plan(for: .kitty(badSocket)), .refuse("Page can't tell which kitty window this is"))
    }

    func testHerdrUnsupportedUnreachableAndUnknownAreRefused() {
        let herdr = HerdrBridge.Target(socketPath: "/tmp/herdr.sock", paneId: "p1", terminalId: "t1", sessionPid: 42)
        XCTAssertEqual(TerminalClose.plan(for: .herdr(herdr)), .refuse("Page can't close herdr tabs"))
        XCTAssertEqual(TerminalClose.plan(for: .unsupported("Ghostty")), .refuse("Page can't close Ghostty tabs"))
        XCTAssertEqual(TerminalClose.plan(for: .unreachable("no window")), .refuse("Page can't close unknown terminal tabs"))
        XCTAssertEqual(TerminalClose.plan(for: .unknown), .refuse("Page can't close unknown terminal tabs"))
        XCTAssertNil(TerminalClose.plan(for: .unknown).noun, "a refusal has no noun")
    }

    // MARK: - cmux helpers

    func testCmuxListsTheWorkspaceAsUUIDs() {
        XCTAssertEqual(TerminalClose.cmuxListArgs(workspaceId: "ws-2"),
                       ["--json", "--id-format", "uuids", "list-panels", "--workspace", "ws-2"])
    }

    func testCmuxSurfaceIdsReadsTheListJSON() {
        XCTAssertEqual(TerminalClose.cmuxSurfaceIds(fromListJSON: #"{"surfaces":[{"id":"a"},{"id":"b"}]}"#), ["a", "b"])
        XCTAssertEqual(TerminalClose.cmuxSurfaceIds(fromListJSON: #"{"surfaces":[]}"#), [])
        XCTAssertNil(TerminalClose.cmuxSurfaceIds(fromListJSON: "not json"))
        XCTAssertNil(TerminalClose.cmuxSurfaceIds(fromListJSON: #"{"panels":[]}"#), "no surfaces key: nothing can be vouched for")
    }

    func testCmuxClosesTheWorkspaceWhenTheTabIsAloneInIt() {
        XCTAssertEqual(TerminalClose.cmuxCloseArgs(surfaceId: "a", workspaceId: "ws-2", surfacesInWorkspace: ["a"]),
                       ["close-workspace", "--workspace", "ws-2", "--force"])
    }

    func testCmuxClosesOnlyTheSurfaceWhenOthersShareTheWorkspace() {
        XCTAssertEqual(TerminalClose.cmuxCloseArgs(surfaceId: "a", workspaceId: "ws-2", surfacesInWorkspace: ["a", "b"]),
                       ["close-surface", "--surface", "a", "--workspace", "ws-2", "--force"])
    }

    func testCmuxCloseMatchesTheSurfaceIgnoringCase() {
        XCTAssertEqual(TerminalClose.cmuxCloseArgs(surfaceId: "ABC", workspaceId: "ws-2", surfacesInWorkspace: ["abc", "def"]),
                       ["close-surface", "--surface", "ABC", "--workspace", "ws-2", "--force"])
    }

    func testCmuxCloseDoesNothingWhenTheTabIsNoLongerThere() {
        XCTAssertNil(TerminalClose.cmuxCloseArgs(surfaceId: "gone", workspaceId: "ws-2", surfacesInWorkspace: ["a", "b"]))
        XCTAssertNil(TerminalClose.cmuxCloseArgs(surfaceId: "a", workspaceId: "ws-2", surfacesInWorkspace: []))
    }

    func testCmuxCloseDoesNothingWhenTheTabAppearsTwice() {
        XCTAssertNil(TerminalClose.cmuxCloseArgs(surfaceId: "a", workspaceId: "ws-2", surfacesInWorkspace: ["a", "b", "a"]))
    }

    // MARK: - Names and route labels

    func testHostNamesGiveTheNounsTheWordsUse() {
        XCTAssertEqual(TerminalClose.noun(forHostName: "cmux"), "cmux tab")
        XCTAssertEqual(TerminalClose.noun(forHostName: "tmux"), "tmux pane")
        XCTAssertEqual(TerminalClose.noun(forHostName: "Terminal"), "Terminal window")
        XCTAssertEqual(TerminalClose.noun(forHostName: "iTerm"), "iTerm2 session")
        XCTAssertEqual(TerminalClose.noun(forHostName: "iTerm2"), "iTerm2 session")
        XCTAssertEqual(TerminalClose.noun(forHostName: "WezTerm"), "WezTerm pane")
        XCTAssertEqual(TerminalClose.noun(forHostName: "kitty"), "kitty window")
        XCTAssertNil(TerminalClose.noun(forHostName: "Ghostty"))
        XCTAssertNil(TerminalClose.noun(forHostName: "herdr"))
    }

    func testTheHostIsReadFromARouteLabel() {
        XCTAssertEqual(TerminalClose.hostName(fromRoute: "cmux › payments-api"), "cmux")
        XCTAssertEqual(TerminalClose.noun(forRoute: "cmux › payments-api"), "cmux tab")
        XCTAssertNil(TerminalClose.hostName(fromRoute: nil))
        XCTAssertNil(TerminalClose.hostName(fromRoute: ""))
        XCTAssertNil(TerminalClose.noun(forRoute: "Ghostty › payments-api"))
    }

    // MARK: - Scripts and their answers

    func testTheTerminalScriptNamesTheTTYAndClosesOnlyAWindowWithOneTab() {
        let s = TerminalClose.terminalScript(tty: "/dev/ttys003")
        XCTAssertTrue(s.contains(ProcessRunner.appleScriptQuote("/dev/ttys003")))
        XCTAssertTrue(s.contains("close w"))
        XCTAssertTrue(s.contains("count of tabList"), "a tab that shares its window is left alone")
    }

    func testTheITermScriptNamesTheTTY() {
        let s = TerminalClose.iTermScript(tty: "/dev/ttys004")
        XCTAssertTrue(s.contains(ProcessRunner.appleScriptQuote("/dev/ttys004")))
        XCTAssertTrue(s.contains("tell s to close"))
    }

    func testAScriptAnswerMeansWhatItSays() {
        typealias R = (value: String?, error: String?, errorNumber: Int?)
        XCTAssertEqual(TerminalClose.scriptResult(R(value: "closed", error: nil, errorNumber: nil), app: "Terminal"), .closed)
        XCTAssertEqual(TerminalClose.scriptResult(R(value: "shared", error: nil, errorNumber: nil), app: "Terminal"),
                       .refused(TerminalClose.sharedWindowRefusal))
        XCTAssertEqual(TerminalClose.scriptResult(R(value: "none", error: nil, errorNumber: nil), app: "Terminal"),
                       .failed("Page couldn't find that tab any more"))
    }

    func testAScriptErrorIsSaidInPlainWords() {
        typealias R = (value: String?, error: String?, errorNumber: Int?)
        guard case .failed(let denied) = TerminalClose.scriptResult(R(value: nil, error: "not allowed", errorNumber: -1743), app: "iTerm2") else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(denied.contains("Automation"))
        XCTAssertTrue(denied.contains("iTerm2"))
        XCTAssertEqual(TerminalClose.scriptResult(R(value: nil, error: "x", errorNumber: -600), app: "Terminal"),
                       .failed("Terminal isn't running"))
        XCTAssertEqual(TerminalClose.scriptResult(R(value: nil, error: "boom", errorNumber: 7), app: "Terminal"),
                       .failed("boom"))
    }

    // MARK: - close, against a fake

    func testClosesTheExactTerminalAndNamesWhatWasClosed() {
        let fake = Fake(statuses: [.idle])
        let outcome = TerminalClose.close(sessionId: "sess-1", backend: .claude, expectedPid: 42, expectedSince: t0,
                                          io: io([live()], fake: fake))
        XCTAssertEqual(outcome, .closed(noun: "cmux tab"))
        XCTAssertEqual(fake.runs, [.cmux(cliPath: cmuxCli, surfaceId: "surface-7", workspaceId: "ws-2")])
    }

    func testAShellSessionCanBeClosed() {
        let fake = Fake(statuses: [.shell])
        XCTAssertEqual(TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake)), .closed(noun: "cmux tab"))
    }

    func testTheNounComesFromThePlanForAnotherHost() {
        let fake = Fake(statuses: [.idle])
        let host = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/opt/tmux", paneId: "%3", inMode: false, session: nil)
        XCTAssertEqual(TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake, host: host)),
                       .closed(noun: "tmux pane"))
        XCTAssertEqual(fake.runs, [.tmux(path: "/opt/tmux", args: ["kill-pane", "-t", "%3"])])
    }

    func testCodexIsRefusedAndItsTerminalStaysOpen() {
        let fake = Fake(statuses: [.idle])
        assertRefused(TerminalClose.close(sessionId: "sess-1", backend: .codex, io: io([live()], fake: fake)), .codex, fake: fake)
    }

    func testASessionThatIsGoneIsRefused() {
        let fake = Fake(statuses: [.idle])
        assertRefused(TerminalClose.close(sessionId: "sess-1", io: io([], fake: fake)), .sessionGone, fake: fake)
        assertRefused(TerminalClose.close(sessionId: "sess-1", io: io([live(sessionId: "other")], fake: fake)), .sessionGone, fake: fake)
    }

    func testAProcessThatRestartedIsRefused() {
        let fake = Fake(statuses: [.idle])
        assertRefused(TerminalClose.close(sessionId: "sess-1", expectedPid: 99, io: io([live(pid: 42)], fake: fake)),
                      .restarted, fake: fake)
    }

    func testTheSameProcessIsNotRefusedForRestarting() {
        let fake = Fake(statuses: [.idle])
        XCTAssertEqual(TerminalClose.close(sessionId: "sess-1", expectedPid: 42, io: io([live(pid: 42)], fake: fake)),
                       .closed(noun: "cmux tab"))
    }

    func testASessionUsedAgainSinceTheCardWasPutAwayIsRefused() {
        let fake = Fake(statuses: [.idle])
        assertRefused(TerminalClose.close(sessionId: "sess-1", expectedSince: t0.addingTimeInterval(-60),
                                          io: io([live(since: t0)], fake: fake)),
                      .usedAgain, fake: fake)
    }

    func testABusySessionIsRefused() {
        let fake = Fake(statuses: [.busy])
        let outcome = TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake))
        assertRefused(outcome, .notIdle(.busy), fake: fake)
        XCTAssertEqual(TerminalCloseRefusal.notIdle(.busy).text, "it started working again")
    }

    func testAWaitingSessionIsRefused() {
        let fake = Fake(statuses: [.waiting])
        let outcome = TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake))
        assertRefused(outcome, .notIdle(.waiting), fake: fake)
        XCTAssertEqual(TerminalCloseRefusal.notIdle(.waiting).text, "it is waiting for an answer again")
    }

    func testAStatusThatCannotBeReadIsASessionThatCannotBeVouchedFor() {
        let fake = Fake(statuses: [nil])
        assertRefused(TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake)), .sessionGone, fake: fake)
    }

    func testASessionThatStartsWorkingWhileThePaneIsFoundIsRefused() {
        // Idle when read first, busy when read again after the host was resolved.
        let fake = Fake(statuses: [.idle, .busy])
        assertRefused(TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake)), .notIdle(.busy), fake: fake)
    }

    func testMoreThanOneProcessWithTheSameSessionIdIsAmbiguous() {
        let fake = Fake(statuses: [.idle])
        let twins = [live(pid: 42), live(pid: 43)]
        assertRefused(TerminalClose.close(sessionId: "sess-1", io: io(twins, fake: fake)), .ambiguous, fake: fake)
    }

    func testAPlanThatRefusesIsRefusedWithItsWords() {
        let fake = Fake(statuses: [.idle])
        let herdr = InjectionExecutor.TerminalHost.herdr(HerdrBridge.Target(socketPath: "/tmp/h", paneId: "p", terminalId: "t", sessionPid: 42))
        assertRefused(TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake, host: herdr)),
                      .plan("Page can't close herdr tabs"), fake: fake)
    }

    func testAnUnknownHostIsRefusedBeforeAnythingRuns() {
        let fake = Fake(statuses: [.idle])
        assertRefused(TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake, host: .unknown)),
                      .plan("Page can't close unknown terminal tabs"), fake: fake)
    }

    func testAnUnsafeCmuxTargetIsRefusedBeforeAnythingRuns() {
        let fake = Fake(statuses: [.idle])
        let noWorkspace = InjectionExecutor.TerminalHost.cmux(
            CmuxBridge.Target(surfaceId: "surface-7", workspaceId: nil, cliPath: cmuxCli, source: "hook-sessions"))
        assertRefused(TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake, host: noWorkspace)),
                      .plan("Page can't tell which cmux tab this is"), fake: fake)
    }

    func testAFailedRunIsReportedAsFailedAndWasTried() {
        let fake = Fake(statuses: [.idle])
        let outcome = TerminalClose.close(sessionId: "sess-1",
                                          io: io([live()], fake: fake, host: .tmux(tmuxPath: "/opt/tmux", paneId: "%3", inMode: false, session: nil),
                                                 result: .failed("tmux didn't close it")))
        XCTAssertEqual(outcome, .failed("tmux didn't close it"))
        XCTAssertEqual(fake.runs.count, 1, "this one did run")
    }

    func testAScriptThatLeftATabOpenOnPurposeIsRefusedWithItsWords() {
        let fake = Fake(statuses: [.idle])
        let term = InjectionExecutor.TerminalHost.terminalApp(tty: "/dev/ttys003")
        let outcome = TerminalClose.close(sessionId: "sess-1", io: io([live()], fake: fake, host: term,
                                                                       result: .refused(TerminalClose.sharedWindowRefusal)))
        XCTAssertEqual(outcome, .refused(.plan(TerminalClose.sharedWindowRefusal)))
        XCTAssertEqual(fake.runs.count, 1)
    }
}
