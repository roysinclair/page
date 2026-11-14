import XCTest
@testable import PageCore

/// The detector with copies and renamed sessions (Designs/session-copies.md §A, §B, §C): the scan is fed only
/// each conversation's lead (`ConversationCopies.leads`), a page follows the process that is the lead now, a new
/// page carries the session's name, and a process reopened on an old conversation doesn't page idle until it
/// has finished a turn of its own (rule B).
final class InterventionCopiesTests: XCTestCase {
    typealias F = TranscriptFixture
    typealias D = InterventionDetector

    private let sid = "5e55a0f1-7c2b-4d3e-8a9f-0b1c2d3e4f50"
    /// The fixture's assistant reply is stamped 10:00:05Z, its user turn 10:00:00Z.
    private let replyAt = TranscriptParser.parseISODate("2026-10-24T10:00:05.000Z")!
    private var files: [URL] = []

    override func tearDown() {
        for f in files { try? FileManager.default.removeItem(at: f) }
        files = []
        super.tearDown()
    }

    /// A transcript file with these lines, unique to the test.
    private func transcript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("copies-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        files.append(url)
        return url
    }

    /// A finished turn: the user asked, Claude replied and the turn ended.
    private var finishedTurn: [String] {
        [F.user("add a test"), F.assistantText("Done. Want me to run the suite?"), F.turnDuration()]
    }

    /// A transcript that ends with a Bash tool call still waiting for approval.
    private var pendingApproval: [String] {
        [F.user("deploy"), F.toolUse("toolu_1", "Bash", ["command": "make deploy"])]
    }

    private func detector() -> InterventionDetector {
        InterventionDetector(hookHoldsDirectory: FileManager.default.temporaryDirectory
                                .appendingPathComponent("copies-holds-\(UUID().uuidString)"),
                             isForeground: { _ in true })
    }

    private func session(_ pid: Int32, _ status: ClaudeSessionStatus, since: Date, started: Date? = nil,
                         session: String? = nil) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: pid, sessionId: session ?? sid, cwd: "/Users/me/proj", status: status,
                          statusUpdatedAt: since, tty: "ttys0\(pid % 100)", hasSessionFile: true, startedAt: started)
    }

    /// Ten minutes after the reply: the idle delay has long passed and the page is still fresh.
    private var later: Date { replyAt.addingTimeInterval(600) }

    private func scan(_ d: InterventionDetector, _ sessions: [ClaudeLiveSession], at now: Date? = nil,
                      transcripts: @escaping (ClaudeLiveSession) -> URL?, name: ((ClaudeLiveSession) -> String?)? = nil) -> InterventionDetector.ScanResult {
        d.scan(sessions: sessions, transcriptFor: transcripts, settings: DetectorSettings(),
               nameFor: name ?? { _ in nil }, now: now ?? later)
    }

    // MARK: no idle page from a copy that isn't the lead

    func testAnIdleCopyBehindABusyLeadOpensNoPage() throws {
        let url = try transcript(finishedTurn)
        let idle = session(10, .idle, since: replyAt)
        let busy = session(20, .busy, since: replyAt.addingTimeInterval(60))

        // Without the lead pick the idle copy would page (the same state, on its own).
        let raw = scan(detector(), [idle, busy], transcripts: { _ in url })
        XCTAssertEqual(raw.opened.map(\.kind), [.idle], "fixture check: the idle copy alone would page")

        let followed = scan(detector(), ConversationCopies.leads([idle, busy]), transcripts: { _ in url })
        XCTAssertTrue(followed.opened.isEmpty, "the idle copy is not the lead: no page")
    }

    func testTheLeadsIdlePageIsRaisedForTheLeadProcess() throws {
        let url = try transcript(finishedTurn)
        let older = session(10, .idle, since: replyAt)
        let newer = session(20, .idle, since: replyAt.addingTimeInterval(30))
        let d = detector()
        let r = scan(d, ConversationCopies.leads([older, newer]), transcripts: { _ in url })
        XCTAssertEqual(r.opened.map(\.kind), [.idle])
        XCTAssertEqual(r.opened.first?.pid, 20, "the page belongs to the lead, the later change")
    }

    // MARK: the lead changes

    func testAPageHeldByACopyThatStopsLeadingIsResolved() throws {
        let url = try transcript(finishedTurn)
        let d = detector()
        let first = scan(d, [session(10, .idle, since: replyAt)], transcripts: { _ in url })
        XCTAssertEqual(first.opened.count, 1)

        // Another copy starts working and now leads: the idle page of the old lead closes.
        let second = scan(d, ConversationCopies.leads([session(10, .idle, since: replyAt),
                                                       session(20, .busy, since: later.addingTimeInterval(-5))]),
                          transcripts: { _ in url })
        XCTAssertEqual(second.resolved.map(\.pid), [10])
        XCTAssertTrue(d.currentlyPending.isEmpty)
    }

    func testTheNewLeadsOwnPromptDoesNotCascadeIntoTheOldPage() throws {
        let idleURL = try transcript(finishedTurn)
        let approvalURL = try transcript(pendingApproval)
        let d = detector()
        let first = scan(d, [session(10, .idle, since: replyAt)], transcripts: { _ in idleURL })
        XCTAssertEqual(first.opened.map(\.kind), [.idle])

        // The other copy is now at an approval. Its page opens; the old idle page closes; nothing else changes.
        let waiting = session(20, .waiting, since: later.addingTimeInterval(-10))
        let second = scan(d, ConversationCopies.leads([session(10, .idle, since: replyAt), waiting]),
                          transcripts: { $0.pid == 10 ? idleURL : approvalURL })
        XCTAssertEqual(second.resolved.map(\.kind), [.idle], "the old copy's page closes")
        XCTAssertEqual(second.opened.map(\.kind), [.permission], "the lead's own prompt is paged")
        XCTAssertEqual(second.opened.first?.pid, 20)
        XCTAssertEqual(d.currentlyPending.values.map(\.kind), [.permission])
    }

    func testAPageReproposedByAnotherProcessMovesToThatProcess() throws {
        let url = try transcript(finishedTurn)
        let d = detector()
        let first = scan(d, [session(10, .idle, since: replyAt)], transcripts: { _ in url })
        let id = try XCTUnwrap(first.opened.first?.id)

        // The same state, now seen through another process (the lead changed back and forth): same page, new pid.
        let again = scan(d, [session(20, .idle, since: replyAt)], transcripts: { _ in url })
        XCTAssertTrue(again.opened.isEmpty)
        XCTAssertTrue(again.resolved.isEmpty, "the page stays open")
        let kept = try XCTUnwrap(d.currentlyPending[id])
        XCTAssertEqual(kept.pid, 20, "replies go to the process that leads now")
    }

    // MARK: names on a new page

    func testANewPageCarriesTheNameTheSessionWasGiven() throws {
        let url = try transcript(finishedTurn)
        let r = scan(detector(), [session(10, .idle, since: replyAt)], transcripts: { _ in url },
                     name: { _ in "Workspace-App" })
        XCTAssertEqual(r.opened.first?.projectName, "Workspace-App")
    }

    func testAnOpenPageKeepsTheTitleItWasSentWith() throws {
        let url = try transcript(finishedTurn)
        let d = detector()
        _ = scan(d, [session(10, .idle, since: replyAt)], transcripts: { _ in url }, name: { _ in "Workspace-App" })
        let again = scan(d, [session(10, .idle, since: replyAt)], transcripts: { _ in url }, name: { _ in "Renamed again" })
        XCTAssertTrue(again.opened.isEmpty)
        XCTAssertEqual(d.currentlyPending.values.map(\.projectName), ["Workspace-App"])
    }

    func testWithoutAGivenNameANewPageIsNamedByItsFolder() throws {
        let url = try transcript(finishedTurn)
        let r = scan(detector(), [session(10, .idle, since: replyAt)], transcripts: { _ in url })
        XCTAssertEqual(r.opened.first?.projectName, "proj", "the folder /Users/me/proj")
    }

    // MARK: rule B, decided

    private enum Outcome: Equatable { case none, notYet, open(InterventionKind) }

    private func decide(_ s: ClaudeLiveSession, _ lines: [String], now: Date? = nil) throws -> Outcome {
        let tail = D.parseTranscriptTail(lines.joined(separator: "\n"))
        switch D.decide(session: s, tail: tail, transcriptModifiedAt: nil, now: now ?? later, settings: DetectorSettings()) {
        case .none: return .none
        case .notYet: return .notYet
        case .open(let p): return .open(p.kind)
        }
    }

    func testAReopenedIdleProcessWhoseLastTurnEndedBeforeItStartedDoesNotPage() throws {
        // --resume at 10:01:00, the last reply ended at 10:00:05: nothing has been done in this run.
        let started = replyAt.addingTimeInterval(55)
        let s = session(10, .idle, since: started, started: started)
        XCTAssertEqual(try decide(s, finishedTurn), .none)
    }

    func testAnIdleProcessWhoseTurnEndedAfterItStartedPagesAfterTheDelay() throws {
        let started = replyAt.addingTimeInterval(-300)
        let s = session(10, .idle, since: replyAt, started: started)
        XCTAssertEqual(try decide(s, finishedTurn), .open(.idle))
        XCTAssertEqual(try decide(s, finishedTurn, now: replyAt.addingTimeInterval(10)), .notYet,
                       "the turn ended after the process started, but the idle delay hasn't passed")
    }

    func testATurnEndingExactlyAtTheStartCountsAsThisRun() throws {
        let s = session(10, .idle, since: replyAt, started: replyAt)
        XCTAssertEqual(try decide(s, finishedTurn), .open(.idle))
    }

    func testAShellStatusFollowsTheSameRule() throws {
        let reopened = session(10, .shell, since: replyAt, started: replyAt.addingTimeInterval(55))
        XCTAssertEqual(try decide(reopened, finishedTurn), .none)
        let ran = session(10, .shell, since: replyAt, started: replyAt.addingTimeInterval(-300))
        XCTAssertEqual(try decide(ran, finishedTurn), .open(.idle))
    }

    func testUnknownTimesKeepTheOldBehaviour() throws {
        // No process start: judged as before.
        XCTAssertEqual(try decide(session(10, .idle, since: replyAt, started: nil), finishedTurn), .open(.idle))
        // A reply with no timestamp: judged as before.
        let untimed = [F.user("hi"),
                       #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#]
        XCTAssertEqual(try decide(session(10, .idle, since: replyAt, started: replyAt.addingTimeInterval(55)), untimed),
                       .open(.idle))
    }

    func testAWaitingPromptIsNotAffectedByRuleB() throws {
        // The approval is asked after the process started; the rule never looks at approvals or questions.
        let started = replyAt.addingTimeInterval(55)
        let s = session(10, .waiting, since: started.addingTimeInterval(1), started: started)
        XCTAssertEqual(try decide(s, pendingApproval), .open(.permission))
    }

    func testAPromptFromBeforeTheProcessStartedStillPages() throws {
        // A waiting prompt whose transcript is older than the process (resumed while already waiting) pages as before.
        let started = replyAt.addingTimeInterval(55)
        let s = session(10, .waiting, since: started, started: started)
        XCTAssertEqual(try decide(s, pendingApproval), .open(.permission))
    }

    func testReopenedThenAFinishedTurnPagesAsUsual() throws {
        let url = try transcript(finishedTurn)
        let d = detector()
        // Reopened after the reply: nothing to page.
        let reopened = scan(d, [session(10, .idle, since: replyAt.addingTimeInterval(55), started: replyAt.addingTimeInterval(55))],
                            transcripts: { _ in url })
        XCTAssertTrue(reopened.opened.isEmpty)

        // The person types, and Claude finishes a turn of its own.
        let turnEnd = replyAt.addingTimeInterval(180)
        let grown = try transcript(finishedTurn + [F.user("again", ts: "2026-10-24T10:02:00.000Z"),
                                                    F.assistantText("Second done.", ts: "2026-10-24T10:03:00.000Z"),
                                                    F.turnDuration()])
        let r = scan(d, [session(10, .idle, since: turnEnd, started: replyAt.addingTimeInterval(55))],
                     at: turnEnd.addingTimeInterval(600), transcripts: { _ in grown })
        XCTAssertEqual(r.opened.map(\.kind), [.idle], "a turn that ended after this run's start pages as usual")
    }

    func testTheTurnTimeComparisonIsPureAndUnknownIsTrue() {
        XCTAssertTrue(D.turnEndedInThisRun(lastAssistantAt: nil, processStartedAt: replyAt))
        XCTAssertTrue(D.turnEndedInThisRun(lastAssistantAt: replyAt, processStartedAt: nil))
        XCTAssertTrue(D.turnEndedInThisRun(lastAssistantAt: nil, processStartedAt: nil))
        XCTAssertTrue(D.turnEndedInThisRun(lastAssistantAt: replyAt, processStartedAt: replyAt), "equal: this run")
        XCTAssertTrue(D.turnEndedInThisRun(lastAssistantAt: replyAt.addingTimeInterval(1), processStartedAt: replyAt))
        XCTAssertFalse(D.turnEndedInThisRun(lastAssistantAt: replyAt, processStartedAt: replyAt.addingTimeInterval(1)))
    }

    // MARK: lastAssistantAt from the transcript

    func testTheLastAssistantTimeIsTheLastAssistantLinesStamp() {
        let text = [F.user("add a test", ts: "2026-10-24T10:00:00.000Z"),
                    F.assistantText("Looking.", ts: "2026-10-24T10:00:02.000Z"),
                    F.assistantText("Done.", ts: "2026-10-24T10:00:05.000Z"),
                    F.user("thanks", ts: "2026-10-24T10:04:00.000Z")].joined(separator: "\n")
        let tail = D.parseTranscriptTail(text)
        XCTAssertEqual(tail.lastAssistantAt, replyAt, "the user's later line doesn't move it")
        XCTAssertEqual(tail.lastMeaningfulRole, .user)
    }

    func testNoAssistantLineMeansNoLastAssistantTime() {
        let tail = D.parseTranscriptTail([F.user("hello")].joined(separator: "\n"))
        XCTAssertNil(tail.lastAssistantAt)
    }

    func testAnAssistantLineWithoutATimestampLeavesItNil() {
        let text = #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#
        XCTAssertNil(D.parseTranscriptTail(text).lastAssistantAt)
    }
}
