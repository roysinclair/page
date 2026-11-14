import XCTest
@testable import PageCore

/// The registry side of copies (Designs/session-copies.md §A and §C): what a `--print` run looks like, the
/// sessions file's `nameSource`, and what `buildLiveSessions` sets on each process. Then `pickSession`, which
/// decides what a reply is typed into when a conversation is open in several terminals.
final class ConversationCopiesRegistryTests: XCTestCase {
    typealias Reg = ClaudeSessionRegistry
    typealias Row = ProcessRunner.ProcessInfoRow
    typealias IE = InjectionExecutor

    private let sid = "5e55a0f1-7c2b-4d3e-8a9f-0b1c2d3e4f50"
    private let sid2 = "b7d1c9e3-4a2f-4e6b-9c8d-1f2e3a4b5c6d"
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)

    // MARK: --print

    func testPrintFlagsAreRecognised() {
        XCTAssertTrue(Reg.isPrintCommand("claude --resume \(sid) --print hi"))
        XCTAssertTrue(Reg.isPrintCommand("/opt/homebrew/bin/claude -p 'summarise this'"))
        XCTAssertTrue(Reg.isPrintCommand("claude -p"))
    }

    func testAnInteractiveCommandIsNotPrint() {
        XCTAssertFalse(Reg.isPrintCommand("/Users/me/.local/bin/claude --session-id \(sid)"))
        XCTAssertFalse(Reg.isPrintCommand("claude --resume \(sid)"))
        XCTAssertFalse(Reg.isPrintCommand(""))
    }

    func testAPathOrWordThatOnlyContainsPIsNotPrint() {
        XCTAssertFalse(Reg.isPrintCommand("claude --resume \(sid) /Users/me/tools/-p-tool"),
                       "a path that merely contains -p")
        XCTAssertFalse(Reg.isPrintCommand("claude --resume \(sid) --printer"),
                       "a longer flag that starts with --print")
        XCTAssertFalse(Reg.isPrintCommand("claude --resume \(sid) --pr"))
    }

    func testAPromptThatMentionsPrintIsNotPrint() {
        // ps joins argv with spaces, so the command line alone can't tell a prompt that says "--print" from the
        // flag. The sessions file can: a session that says it is interactive is a terminal session.
        let table = [Row(pid: 100, ppid: 1, tty: "ttys001", command: "claude why does --print hang")]
        let live = Reg.buildLiveSessions(records: [record(100, sid)], processTable: table, ownPid: 1,
                                         isAlive: { _ in true })
        XCTAssertEqual(live.map(\.isPrint), [false])
    }

    // MARK: nameSource in the sessions file

    func testParsesTheNameSourceAndTrimsIt() {
        let json = #"{"pid":11,"sessionId":"\#(sid)","name":"Workspace-App","nameSource":" user "}"#
        let r = Reg.parseSessionFile(Data(json.utf8))
        XCTAssertEqual(r?.name, "Workspace-App")
        XCTAssertEqual(r?.nameSource, "user")
    }

    func testAnEmptyOrMissingNameSourceIsNil() {
        XCTAssertNil(Reg.parseSessionFile(Data(#"{"name":"x"}"#.utf8))?.nameSource, "a file from a build that doesn't say")
        XCTAssertNil(Reg.parseSessionFile(Data(#"{"name":"x","nameSource":"   "}"#.utf8))?.nameSource)
        XCTAssertNil(Reg.parseSessionFile(Data(#"{"name":"x","nameSource":true}"#.utf8))?.nameSource)
    }

    func testDerivedIsParsedAsItIs() {
        // The sessions file's own word: the filter that says a name is derived is in SessionNaming, not here.
        XCTAssertEqual(Reg.parseSessionFile(Data(#"{"name":"page","nameSource":"derived"}"#.utf8))?.nameSource, "derived")
    }

    // MARK: buildLiveSessions sets nameSource and isPrint

    private func record(_ pid: Int32, _ session: String, status: String = "idle", name: String? = nil,
                        nameSource: String? = nil) -> ClaudeSessionRecord {
        var r = ClaudeSessionRecord(pid: pid, sessionId: session, cwd: "/Users/me/proj", status: status,
                                    statusUpdatedAt: t0, kind: "interactive", entrypoint: "cli")
        r.name = name
        r.nameSource = nameSource
        return r
    }

    func testBuildCarriesTheNameAndItsSource() {
        let table = [Row(pid: 100, ppid: 1, tty: "ttys001", command: "claude --resume \(sid)")]
        let live = Reg.buildLiveSessions(records: [record(100, sid, name: "Workspace-App", nameSource: "user")],
                                         processTable: table, ownPid: 1, isAlive: { _ in true })
        XCTAssertEqual(live.first?.name, "Workspace-App")
        XCTAssertEqual(live.first?.nameSource, "user")
    }

    func testBuildMarksAPrintRunFromItsCommandLine() {
        // A sessions file with no `kind` (older Claude Code): the command line decides.
        let table = [Row(pid: 100, ppid: 1, tty: "ttys001", command: "claude --resume \(sid)"),
                     Row(pid: 101, ppid: 1, tty: "ttys002", command: "claude --resume \(sid2) --print hi")]
        var noKind = record(101, sid2)
        noKind.kind = nil
        let live = Reg.buildLiveSessions(records: [record(100, sid), noKind],
                                         processTable: table, ownPid: 1, isAlive: { _ in true })
        XCTAssertEqual(live.map(\.isPrint), [false, true])
    }

    func testBuildMarksAPrintRunFoundOnlyByArgv() {
        // No sessions file: found by argv. A print run with a tty is still not a terminal copy.
        let table = [Row(pid: 100, ppid: 1, tty: "ttys001", command: "claude --resume \(sid) -p hi"),
                     Row(pid: 101, ppid: 1, tty: "ttys002", command: "claude --resume \(sid2)")]
        let live = Reg.buildLiveSessions(records: [], processTable: table, ownPid: 1, isAlive: { _ in true })
        XCTAssertEqual(live.map { [$0.pid, $0.isPrint ? 1 : 0] }, [[100, 1], [101, 0]])
        XCTAssertEqual(live.map(\.isPrint), [true, false])
    }

    func testWithoutAProcessTableNothingIsPrint() {
        // Only the kill check is available: the command line isn't known, so nothing can be called a print run.
        let live = Reg.buildLiveSessions(records: [record(100, sid)], processTable: [], ownPid: 1, isAlive: { _ in true })
        XCTAssertEqual(live.map(\.isPrint), [false])
    }

    func testAnAbsentNameSourceStaysNil() {
        let table = [Row(pid: 100, ppid: 1, tty: "ttys001", command: "claude --resume \(sid)")]
        let live = Reg.buildLiveSessions(records: [record(100, sid, name: "page")], processTable: table,
                                         ownPid: 1, isAlive: { _ in true })
        XCTAssertNil(live.first?.nameSource)
        XCTAssertEqual(live.first?.name, "page")
    }

    // MARK: pickSession

    private func copy(_ pid: Int32, _ status: ClaudeSessionStatus = .idle, since: TimeInterval = 0,
                      print: Bool = false, session: String? = nil) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: pid, sessionId: session ?? sid, cwd: "/tmp", status: status,
                          statusUpdatedAt: t0.addingTimeInterval(since), tty: print ? nil : "ttys0\(pid % 100)",
                          hasSessionFile: true, isPrint: print)
    }

    func testWithNoPagePidTheLeadIsTyped() throws {
        // pid 20 is busy, pid 10 idle: the busy copy leads.
        let idle = copy(10, .idle, since: 0)
        let busy = copy(20, .busy, since: 0)
        XCTAssertEqual(try IE.pickSession([idle, busy], pagePid: nil, pageStateStart: nil).get(), busy)
    }

    func testThePagesOwnProcessIsUsedWhenItIsStillTheLead() throws {
        let lead = copy(20, .busy, since: 0)
        let other = copy(10, .idle, since: 0)
        XCTAssertEqual(try IE.pickSession([other, lead], pagePid: 20, pageStateStart: nil).get(), lead)
    }

    func testAPageWhoseProcessIsNoLongerTheLeadIsRefused() {
        // The page was raised for pid 10 (idle); pid 20 is working now and leads. A prompt answered in one copy
        // must not be answered again in another, so the reply is refused with the moved message.
        let idle = copy(10, .idle, since: 0)
        let busy = copy(20, .busy, since: 30)
        XCTAssertEqual(IE.pickSession([idle, busy], pagePid: 10, pageStateStart: nil),
                       .failure(IE.InjectionFailure(ConversationCopies.movedMessage)))
    }

    func testAPageWhoseProcessIsGoneWithTwoCopiesLeftIsRefused() {
        let a = copy(10, .idle, since: 0)
        let b = copy(20, .busy, since: 30)
        XCTAssertEqual(IE.pickSession([a, b], pagePid: 99, pageStateStart: nil),
                       .failure(IE.InjectionFailure(ConversationCopies.movedMessage)))
    }

    func testAPageWhoseProcessIsGoneWithOneCopyLeftTypesIntoThatCopy() throws {
        // A restart, as before: one terminal left, so the reply goes there.
        let only = copy(10, .idle, since: 0)
        XCTAssertEqual(try IE.pickSession([only], pagePid: 99, pageStateStart: nil).get(), only)
    }

    func testAStateStartMatchingANonLeadIsRefused() {
        // The page's state start matches pid 10's status change (not the lead's): it is pid 10's page.
        let nonLead = copy(10, .idle, since: 0)
        let lead = copy(20, .busy, since: 500)
        XCTAssertEqual(IE.pickSession([nonLead, lead], pagePid: nil, pageStateStart: t0),
                       .failure(IE.InjectionFailure(ConversationCopies.movedMessage)))
    }

    func testAStateStartMatchingTheLeadTypesIntoIt() throws {
        let nonLead = copy(10, .idle, since: 0)
        let lead = copy(20, .busy, since: 500)
        let start = t0.addingTimeInterval(500)
        XCTAssertEqual(try IE.pickSession([nonLead, lead], pagePid: nil, pageStateStart: start).get(), lead)
    }

    func testAPrintRunIsNotTheLeadOfTwoTerminals() throws {
        // A busy print run with the same id doesn't lead the terminal copies, and a reply isn't typed into it.
        let print = copy(40, .busy, since: 900, print: true)
        let terminal = copy(10, .idle, since: 0)
        XCTAssertEqual(try IE.pickSession([print, terminal], pagePid: nil, pageStateStart: nil).get(), terminal)
    }

    func testAPageRaisedForAPrintRunStillReachesItWhenItIsTheOnlyProcess() throws {
        // Not copies (no terminal): the page's own process is typed into, as before.
        let print = copy(40, .busy, since: 900, print: true)
        XCTAssertEqual(try IE.pickSession([print], pagePid: 40, pageStateStart: nil).get(), print)
    }
}
