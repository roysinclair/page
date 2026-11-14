import XCTest
@testable import PageCore

/// "Close the other" (Designs/session-copies.md §A): `TerminalClose.closeOtherCopies` against a fake
/// `TerminalCloseIO`. Nothing is run: every plan goes to a recording `run`, and no cmux socket or AppleScript is used.
final class TerminalCloseCopiesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)
    private let sid = "5e55a0f1-7c2b-4d3e-8a9f-0b1c2d3e4f50"
    private let cmuxCli = "/Applications/cmux.app/Contents/Resources/bin/cmux"

    /// A copy on a terminal. The lead is the one with the newest status change, so tests make pid 30 the lead
    /// unless they say otherwise.
    private func copy(_ pid: Int32, _ status: ClaudeSessionStatus, since: TimeInterval = 0) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: pid, sessionId: sid, cwd: "/Users/roy/projects/page", status: status,
                          statusUpdatedAt: t0.addingTimeInterval(since), tty: "ttys0\(pid % 100)", hasSessionFile: true)
    }

    private func cmuxHost(for pid: Int32) -> InjectionExecutor.TerminalHost {
        .cmux(CmuxBridge.Target(surfaceId: "surface-\(pid)", workspaceId: "ws-2", cliPath: cmuxCli, source: "hook-sessions"))
    }

    /// Serves each call in order (the last repeats). `liveSessions` takes the lists in order, `currentStatus` the
    /// statuses per pid in order, and `run` the results in order (`.closed` once they run out).
    private final class Fake {
        var lives: [[ClaudeLiveSession]]
        var statuses: [Int32: [ClaudeSessionStatus?]]
        var runResults: [TerminalCloseRunResult]
        var runs: [TerminalClosePlan] = []
        private var liveCalls = 0
        private var statusCalls: [Int32: Int] = [:]

        init(lives: [[ClaudeLiveSession]], statuses: [Int32: [ClaudeSessionStatus?]] = [:],
             runResults: [TerminalCloseRunResult] = []) {
            self.lives = lives
            self.statuses = statuses
            self.runResults = runResults
        }

        func live() -> [ClaudeLiveSession] {
            defer { liveCalls += 1 }
            return lives[min(liveCalls, lives.count - 1)]
        }

        func status(_ pid: Int32) -> ClaudeSessionStatus? {
            let n = statusCalls[pid, default: 0]
            statusCalls[pid] = n + 1
            guard let seq = statuses[pid], !seq.isEmpty else { return nil }
            return seq[min(n, seq.count - 1)]
        }

        func run() -> TerminalCloseRunResult {
            guard !runResults.isEmpty else { return .closed }
            return runResults.removeFirst()
        }
    }

    /// The lead (pid 30, busy-free idle with the newest change) and two idle copies (10 and 20) on cmux tabs.
    private func threeCopies() -> [ClaudeLiveSession] {
        [copy(30, .idle, since: 10), copy(10, .idle), copy(20, .idle)]
    }

    private func io(_ fake: Fake, host: ((ClaudeLiveSession) -> InjectionExecutor.TerminalHost)? = nil) -> TerminalCloseIO {
        TerminalCloseIO(
            liveSessions: { fake.live() },
            currentStatus: { fake.status($0) },
            processTable: { [] },
            resolveHost: { s, _ in host?(s) ?? self.cmuxHost(for: s.pid) },
            run: { plan in
                fake.runs.append(plan)
                return fake.run()
            })
    }

    private func assertRefused(_ outcome: CopiesCloseOutcome, _ expected: CopiesCloseRefusal, _ fake: Fake,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome, .refused(expected), file: file, line: line)
        XCTAssertTrue(fake.runs.isEmpty, "no terminal may be closed when Page refuses", file: file, line: line)
    }

    // MARK: refusals before anything is closed

    func testNoOtherCopyIsRefused() {
        let fake = Fake(lives: [[copy(30, .idle)]], statuses: [30: [.idle]])
        assertRefused(TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake)), .noOther, fake)
    }

    func testAnotherSessionsCopiesAreNotOthers() {
        let other = ClaudeLiveSession(pid: 77, sessionId: "b7d1c9e3-4a2f-4e6b-9c8d-1f2e3a4b5c6d", cwd: nil, status: .idle,
                                      statusUpdatedAt: t0, tty: "ttys077", hasSessionFile: true)
        let fake = Fake(lives: [[copy(30, .idle), other]], statuses: [30: [.idle]])
        assertRefused(TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake)), .noOther, fake)
    }

    func testABusyCopyStopsEverythingAndNothingIsClosed() {
        // Two others: the first is idle and in cmux, the second is busy. Nothing is closed.
        let fake = Fake(lives: [threeCopies()],
                        statuses: [10: [.idle], 20: [.busy]])
        assertRefused(TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake)), .notIdle(.busy), fake)
    }

    func testAWaitingCopyIsRefused() {
        let fake = Fake(lives: [threeCopies()], statuses: [10: [.idle], 20: [.waiting]])
        assertRefused(TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake)), .notIdle(.waiting), fake)
    }

    func testAnUnreadableStatusIsRefusedAsNoOtherNotAsIdle() {
        // A status that can't be read at all means the copy can't be vouched for: the copy is treated as gone.
        let fake = Fake(lives: [threeCopies()], statuses: [10: [nil], 20: [.idle]])
        assertRefused(TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake)), .noOther, fake)
    }

    func testAnUnknownStatusIsNotIdle() {
        let fake = Fake(lives: [threeCopies()], statuses: [10: [.unknown], 20: [.idle]])
        assertRefused(TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake)), .notIdle(.unknown), fake)
    }

    func testACopyOutsideCmuxIsRefusedAndNothingIsClosed() {
        // Pid 20 is in Terminal.app: only cmux is closed from here, so the cmux copy (pid 10) is left alone too.
        let fake = Fake(lives: [threeCopies()], statuses: [10: [.idle], 20: [.idle]])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake) { s in
            s.pid == 20 ? .terminalApp(tty: "/dev/ttys020") : self.cmuxHost(for: s.pid)
        })
        XCTAssertEqual(outcome, .refused(.notCmux("Page closes the other terminal only in cmux")))
        XCTAssertTrue(fake.runs.isEmpty)
    }

    func testAPlanThatRefusesIsRefusedWithItsWords() {
        // A cmux tab whose surface id is unsafe: the plan refuses, before anything runs.
        let fake = Fake(lives: [threeCopies()], statuses: [10: [.idle], 20: [.idle]])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake) { s in
            s.pid == 20 ? .cmux(CmuxBridge.Target(surfaceId: "-rf", workspaceId: "ws-2", cliPath: self.cmuxCli, source: "x"))
                        : self.cmuxHost(for: s.pid)
        })
        XCTAssertEqual(outcome, .refused(.plan("Page can't tell which cmux tab this is")))
        XCTAssertTrue(fake.runs.isEmpty)
    }

    // MARK: the lead moves while Page checks

    func testTheLeadMovingOntoACopyBeforeAnyCloseIsRefused() {
        // Pid 10 becomes busy in the read just before its close: it now leads, so it is the working terminal.
        let movedLive = [copy(30, .idle, since: 10), copy(10, .busy, since: 20), copy(20, .idle)]
        let fake = Fake(lives: [threeCopies(), movedLive], statuses: [10: [.idle, .idle], 20: [.idle]])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake))
        XCTAssertEqual(outcome, .refused(.leadChanged))
        XCTAssertTrue(fake.runs.isEmpty)
    }

    func testACopyThatStartsWorkingBeforeItsCloseIsRefusedAndNothingIsClosed() {
        // Pid 10 was idle at the pre-check; the read just before its close says busy. Nothing has closed yet.
        let fake = Fake(lives: [threeCopies()], statuses: [10: [.idle, .busy], 20: [.idle]])
        assertRefused(TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake)), .notIdle(.busy), fake)
    }

    func testTheLeadMovingAfterOneCopyClosedReportsAFailure() {
        // Pid 10 closes; then pid 20 is busy and leads. Page stops and says what happened.
        let afterFirst = [copy(30, .idle, since: 10), copy(20, .busy, since: 30)]
        let fake = Fake(lives: [threeCopies(), threeCopies(), afterFirst],
                        statuses: [10: [.idle], 20: [.idle]])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake))
        XCTAssertEqual(outcome, .failed("the working terminal changed after 1 closed"))
        XCTAssertEqual(fake.runs.count, 1, "pid 10 closed, pid 20 was left alone")
    }

    func testACopyStartingToWorkAfterOneClosedReportsAFailure() {
        // Pid 20 is idle when read, but its status read just before the close says busy.
        let fake = Fake(lives: [threeCopies()], statuses: [10: [.idle], 20: [.idle, .busy]])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake))
        XCTAssertEqual(outcome, .failed("one started working after 1 closed"))
        XCTAssertEqual(fake.runs.count, 1)
    }

    // MARK: copies that exit

    func testEveryOtherCopyExitingIsNoOther() {
        // Both others are gone from the list on the reads just before each close.
        let onlyLead = [copy(30, .idle, since: 10)]
        let fake = Fake(lives: [threeCopies(), onlyLead], statuses: [10: [.idle], 20: [.idle]])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake))
        XCTAssertEqual(outcome, .refused(.noOther))
        XCTAssertTrue(fake.runs.isEmpty)
    }

    func testAPartialCloseWhenTheRestExitReportsTheCountClosed() {
        // Pid 10 closes; pid 20 has exited by its turn (gone from the read before its close), so the one closed is the outcome.
        let onlyLead = [copy(30, .idle, since: 10)]
        let fake = Fake(lives: [threeCopies(), threeCopies(), onlyLead], statuses: [10: [.idle], 20: [.idle]])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake))
        XCTAssertEqual(outcome, .closed(count: 1, noun: "cmux tab"))
        XCTAssertEqual(fake.runs.count, 1)
    }

    // MARK: closing

    func testTwoOtherCopiesAreClosedAndCounted() {
        let fake = Fake(lives: [threeCopies()], statuses: [10: [.idle], 20: [.idle]])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake))
        XCTAssertEqual(outcome, .closed(count: 2, noun: "cmux tab"))
        XCTAssertEqual(fake.runs, [
            .cmux(cliPath: cmuxCli, surfaceId: "surface-10", workspaceId: "ws-2"),
            .cmux(cliPath: cmuxCli, surfaceId: "surface-20", workspaceId: "ws-2"),
        ], "the others, by pid; never the lead (pid 30)")
    }

    func testASingleOtherCopyIsClosedAndCounted() {
        let two = [copy(30, .idle, since: 10), copy(10, .idle)]
        let fake = Fake(lives: [two], statuses: [10: [.idle]])
        XCTAssertEqual(TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake)), .closed(count: 1, noun: "cmux tab"))
        XCTAssertEqual(fake.runs.map { plan -> String? in
            if case .cmux(_, let surface, _) = plan { return surface }
            return nil
        }, ["surface-10"])
    }

    func testAPartialCloseKeepsWhatWasClosedAndReportsTheRest() {
        // The first close works; the second fails in cmux. The first stays closed and the outcome says it failed.
        let fake = Fake(lives: [threeCopies()], statuses: [10: [.idle], 20: [.idle]],
                        runResults: [.closed, .failed("cmux didn't close it")])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake))
        XCTAssertEqual(outcome, .failed("cmux didn't close it"))
        XCTAssertEqual(fake.runs.count, 2)
    }

    func testARefusedRunBeforeAnyCloseIsRefusedWithItsWords() {
        let fake = Fake(lives: [threeCopies()], statuses: [10: [.idle], 20: [.idle]],
                        runResults: [.refused("the tab shares its window")])
        let outcome = TerminalClose.closeOtherCopies(sessionId: sid, io: io(fake))
        XCTAssertEqual(outcome, .refused(.plan("the tab shares its window")))
        XCTAssertEqual(fake.runs.count, 1)
    }
}
