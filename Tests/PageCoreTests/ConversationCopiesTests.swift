import XCTest
@testable import PageCore

/// One conversation open in several terminals (Designs/session-copies.md §A): the lead pick, who counts as a
/// copy, what the phone is shown (`leads`), when "Close the other" is offered, the Mac's once-only notice and
/// the words it uses. Everything here is pure; no process, cmux or tmux is touched.
final class ConversationCopiesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)
    private let sid = "5e55a0f1-7c2b-4d3e-8a9f-0b1c2d3e4f50"
    private let otherSid = "b7d1c9e3-4a2f-4e6b-9c8d-1f2e3a4b5c6d"

    /// A live interactive copy on a terminal, by default idle since `t0`.
    private func copy(_ pid: Int32, _ status: ClaudeSessionStatus = .idle, since: Date? = nil,
                      started: Date? = nil, session: String? = nil, print: Bool = false, tty: String? = "ttys0\(0)") -> ClaudeLiveSession {
        ClaudeLiveSession(pid: pid, sessionId: session ?? sid, cwd: "/Users/me/proj", status: status,
                          statusUpdatedAt: since ?? t0, tty: print ? nil : tty, hasSessionFile: true,
                          startedAt: started, isPrint: print)
    }

    // MARK: status order

    func testStatusOrderIsWaitingBusyShellIdleUnknown() {
        XCTAssertEqual(ConversationCopies.statusRank(.waiting), 4)
        XCTAssertEqual(ConversationCopies.statusRank(.busy), 3)
        XCTAssertEqual(ConversationCopies.statusRank(.shell), 2)
        XCTAssertEqual(ConversationCopies.statusRank(.idle), 1)
        XCTAssertEqual(ConversationCopies.statusRank(.unknown), 0)
    }

    func testEachStatusLeadsTheOneBelowIt() {
        let order: [ClaudeSessionStatus] = [.waiting, .busy, .shell, .idle, .unknown]
        for (i, high) in order.enumerated() where i + 1 < order.count {
            // The lower one is newer and has the higher pid, so only the status can decide.
            let a = copy(10, high, since: t0)
            let b = copy(99, order[i + 1], since: t0.addingTimeInterval(500))
            XCTAssertTrue(ConversationCopies.leads(a, over: b), "\(high) leads \(order[i + 1])")
            XCTAssertFalse(ConversationCopies.leads(b, over: a), "\(order[i + 1]) doesn't lead \(high)")
            XCTAssertEqual(ConversationCopies.lead(of: [b, a])?.pid, 10)
        }
    }

    // MARK: ties

    func testSameStatusTheLaterStatusChangeLeads() {
        let older = copy(10, .busy, since: t0)
        let newer = copy(20, .busy, since: t0.addingTimeInterval(30))
        XCTAssertTrue(ConversationCopies.leads(newer, over: older))
        XCTAssertEqual(ConversationCopies.lead(of: [older, newer])?.pid, 20)
    }

    func testAMissingStatusTimeLosesToASetOne() {
        let unset = ClaudeLiveSession(pid: 30, sessionId: sid, cwd: nil, status: .idle, statusUpdatedAt: nil,
                                      tty: "ttys030", hasSessionFile: true)
        let set = copy(10, .idle, since: t0)
        XCTAssertEqual(ConversationCopies.lead(of: [unset, set])?.pid, 10)
    }

    func testEqualStatusTimesTheLaterStartLeads() {
        let early = copy(30, .idle, since: t0, started: t0.addingTimeInterval(-600))
        let late = copy(10, .idle, since: t0, started: t0.addingTimeInterval(-60))
        XCTAssertEqual(ConversationCopies.lead(of: [early, late])?.pid, 10, "the later start, even with the lower pid")
    }

    func testEverythingEqualTheHighestPidLeads() {
        let a = copy(10, .idle, since: t0, started: t0)
        let b = copy(20, .idle, since: t0, started: t0)
        let c = copy(15, .idle, since: t0, started: t0)
        XCTAssertEqual(ConversationCopies.lead(of: [a, b, c])?.pid, 20)
        XCTAssertEqual(ConversationCopies.lead(of: [c, a, b])?.pid, 20, "the input's order doesn't matter")
    }

    // MARK: who counts as a copy

    func testAPrintRunIsNotACopy() {
        let print = copy(40, .busy, since: t0.addingTimeInterval(900), print: true)
        let terminal = copy(10, .idle, since: t0)
        XCTAssertFalse(ConversationCopies.isCopy(print))
        XCTAssertEqual(ConversationCopies.lead(of: [print, terminal])?.pid, 10,
                       "a busy print run doesn't lead an idle terminal copy")
        XCTAssertNil(ConversationCopies.lead(of: [print]))
    }

    func testAProcessWithoutATTYIsNotACopy() {
        let headless = copy(40, .busy, since: t0.addingTimeInterval(900), tty: nil)
        XCTAssertFalse(ConversationCopies.isCopy(headless))
        XCTAssertNil(ConversationCopies.lead(of: [headless]))
        XCTAssertTrue(ConversationCopies.others(of: [headless]).isEmpty)
        XCTAssertTrue(ConversationCopies.counts(in: [headless]).isEmpty)
    }

    func testNoCopiesHasNoLead() {
        XCTAssertNil(ConversationCopies.lead(of: []))
    }

    // MARK: others

    func testOthersAreTheCopiesExceptTheLeadByPid() {
        let lead = copy(30, .busy, since: t0)
        let b = copy(20, .idle, since: t0)
        let a = copy(10, .idle, since: t0)
        let print = copy(5, .idle, since: t0, print: true)
        XCTAssertEqual(ConversationCopies.others(of: [b, lead, a, print]).map(\.pid), [10, 20], "by pid, no print run")
    }

    func testOthersOfASingleCopyIsEmpty() {
        XCTAssertTrue(ConversationCopies.others(of: [copy(10)]).isEmpty)
    }

    // MARK: grouping and counts

    func testCopiesGroupTerminalProcessesByConversation() {
        let sessions = [copy(10), copy(20), copy(30, session: otherSid), copy(40, print: true)]
        let groups = ConversationCopies.copies(in: sessions)
        XCTAssertEqual(Set(groups.keys), [sid, otherSid])
        XCTAssertEqual(groups[sid]?.map(\.pid).sorted(), [10, 20])
        XCTAssertEqual(groups[otherSid]?.map(\.pid), [30])
    }

    func testCountsKeepOnlyConversationsWithMoreThanOneTerminal() {
        let sessions = [copy(10), copy(20), copy(30, session: otherSid), copy(40, session: otherSid, print: true)]
        XCTAssertEqual(ConversationCopies.counts(in: sessions), [sid: 2])
        XCTAssertEqual(ConversationCopies.counts(in: [copy(10), copy(20), copy(21)]), [sid: 3])
        XCTAssertTrue(ConversationCopies.counts(in: [copy(10), copy(30, session: otherSid)]).isEmpty)
    }

    // MARK: what Page follows

    func testOnlyTheLeadOfAConversationIsFollowed() {
        let idle = copy(10, .idle, since: t0)
        let busy = copy(20, .busy, since: t0)
        let followed = ConversationCopies.leads([idle, busy])
        XCTAssertEqual(followed.map(\.pid), [20])
    }

    func testAHeadlessTwinIsDroppedWhenATerminalCopyExists() {
        let terminal = copy(10, .idle, since: t0)
        let headless = copy(20, .busy, since: t0.addingTimeInterval(60), print: true)
        XCTAssertEqual(ConversationCopies.leads([headless, terminal]).map(\.pid), [10])
    }

    func testASingleSessionPassesThroughUnchanged() {
        let alone = copy(10, .busy, since: t0)
        let print = copy(20, .busy, since: t0, session: otherSid, print: true)
        XCTAssertEqual(ConversationCopies.leads([alone]), [alone])
        XCTAssertEqual(ConversationCopies.leads([print]), [print], "a print run with no terminal copy is kept as before")
        XCTAssertEqual(ConversationCopies.leads([]), [])
    }

    func testTheFollowedListKeepsItsOrderAndOtherConversations() {
        let a1 = copy(11, .idle, since: t0)
        let b = copy(30, .idle, since: t0, session: otherSid)
        let a2 = copy(12, .busy, since: t0)
        let c = copy(40, .waiting, since: t0, session: "c0ffee00-0000-4000-8000-000000000000")
        XCTAssertEqual(ConversationCopies.leads([a1, b, a2, c]).map(\.pid), [30, 12, 40])
    }

    // MARK: close the other

    func testCloseOtherNeedsAnotherCopyAllIdleOrShellInCmux() {
        let idle = copy(10, .idle)
        let shell = copy(20, .shell)
        XCTAssertFalse(ConversationCopies.canCloseOther(others: [], inCmux: { _ in true }))
        XCTAssertTrue(ConversationCopies.canCloseOther(others: [idle], inCmux: { _ in true }))
        XCTAssertTrue(ConversationCopies.canCloseOther(others: [idle, shell], inCmux: { _ in true }),
                      "a turn that ended with a background shell is still at its prompt")
    }

    func testCloseOtherIsNotOfferedForABusyOrWaitingOrUnknownCopyOrOneOutsideCmux() {
        let busy = copy(10, .busy)
        let waiting = copy(20, .waiting)
        let unknown = copy(30, .unknown)
        let idle = copy(40, .idle)
        XCTAssertFalse(ConversationCopies.canCloseOther(others: [idle, busy], inCmux: { _ in true }))
        XCTAssertFalse(ConversationCopies.canCloseOther(others: [idle, waiting], inCmux: { _ in true }))
        XCTAssertFalse(ConversationCopies.canCloseOther(others: [unknown], inCmux: { _ in true }))
        XCTAssertFalse(ConversationCopies.canCloseOther(others: [idle, copy(50, .idle)], inCmux: { $0.pid != 50 }),
                       "every other copy has to be in cmux")
    }

    // MARK: the movedMessage

    func testMovedMessageIsTheSpecWording() {
        XCTAssertEqual(ConversationCopies.movedMessage,
                       "This conversation moved to another terminal — check it on your Mac")
    }
}

/// The Mac notice: once per conversation when a second terminal appears, and again only after the conversation
/// has been back to one terminal for 60 s (Designs/session-copies.md §A).
final class CopiesNoticeTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)
    private let sid = "5e55a0f1-7c2b-4d3e-8a9f-0b1c2d3e4f50"

    func testFiresWhenASecondTerminalAppears() {
        var tracker = CopiesNoticeTracker()
        XCTAssertEqual(tracker.step(counts: [:], now: t0), [])
        XCTAssertEqual(tracker.step(counts: [sid: 2], now: t0.addingTimeInterval(1)), [sid])
    }

    func testNotAgainWhileItStaysAtTwo() {
        var tracker = CopiesNoticeTracker()
        _ = tracker.step(counts: [sid: 2], now: t0)
        XCTAssertEqual(tracker.step(counts: [sid: 2], now: t0.addingTimeInterval(10)), [])
        XCTAssertEqual(tracker.step(counts: [sid: 2], now: t0.addingTimeInterval(600)), [])
    }

    func testGoingBackToTwoWithinSixtySecondsDoesNotNotifyAgain() {
        var tracker = CopiesNoticeTracker()
        _ = tracker.step(counts: [sid: 2], now: t0)
        XCTAssertEqual(tracker.step(counts: [:], now: t0.addingTimeInterval(10)), [])
        XCTAssertEqual(tracker.step(counts: [sid: 2], now: t0.addingTimeInterval(40)), [], "a flicker, not a new terminal")
    }

    func testRearmsAfterSixtySecondsAtOneCopy() {
        var tracker = CopiesNoticeTracker()
        _ = tracker.step(counts: [sid: 2], now: t0)
        XCTAssertEqual(tracker.step(counts: [sid: 1], now: t0.addingTimeInterval(10)), [])
        XCTAssertEqual(tracker.step(counts: [sid: 1], now: t0.addingTimeInterval(69)), [], "59 s at one copy: not yet")
        XCTAssertEqual(tracker.step(counts: [sid: 1], now: t0.addingTimeInterval(70)), [], "60 s at one copy: re-armed, no notice at one")
        XCTAssertEqual(tracker.step(counts: [sid: 2], now: t0.addingTimeInterval(80)), [sid])
    }

    func testAConversationThatEndsCountsAsOneCopy() {
        var tracker = CopiesNoticeTracker()
        _ = tracker.step(counts: [sid: 2], now: t0)
        _ = tracker.step(counts: [:], now: t0.addingTimeInterval(5))
        _ = tracker.step(counts: [:], now: t0.addingTimeInterval(65))
        XCTAssertEqual(tracker.step(counts: [sid: 2], now: t0.addingTimeInterval(66)), [sid],
                       "gone for 60 s, then back with two terminals: a new notice")
    }

    func testThreeTerminalsNotifyOnceAsWell() {
        var tracker = CopiesNoticeTracker()
        XCTAssertEqual(tracker.step(counts: [sid: 3], now: t0), [sid])
        XCTAssertEqual(tracker.step(counts: [sid: 2], now: t0.addingTimeInterval(5)), [])
    }

    func testSeveralConversationsAreReportedSortedByID() {
        var tracker = CopiesNoticeTracker()
        let b = "b7d1c9e3-4a2f-4e6b-9c8d-1f2e3a4b5c6d"
        XCTAssertEqual(tracker.step(counts: [sid: 2, b: 2], now: t0), [b, sid].sorted())
    }
}

/// The words the Mac shows for copies (Designs/session-copies.md §A). Curly apostrophes and the dashes are the
/// spec's own characters.
final class SessionCopiesCopyTests: XCTestCase {
    func testTheCardLine() {
        XCTAssertEqual(SessionCopiesCopy.line(count: 2), "Open in 2 terminals · close one")
        XCTAssertEqual(SessionCopiesCopy.line(count: 3), "Open in 3 terminals · close one")
    }

    func testTheCloseButtonAndConfirm() {
        XCTAssertEqual(SessionCopiesCopy.closeButton, "Close the other")
        XCTAssertEqual(SessionCopiesCopy.confirmQuestion(project: "Workspace-App"), "Close the other Workspace-App terminal?")
        XCTAssertEqual(SessionCopiesCopy.confirmDetail,
                       "Claude there is idle. Its part of the conversation stays in the history.")
        XCTAssertEqual(SessionCopiesCopy.confirmCancel, "Cancel")
        XCTAssertEqual(SessionCopiesCopy.confirmClose, "Close")
    }

    func testNotificationTitleForTwoAndMore() {
        XCTAssertEqual(SessionCopiesCopy.notificationTitle(name: "Workspace-App", count: 2),
                       "Workspace-App is open twice")
        XCTAssertEqual(SessionCopiesCopy.notificationTitle(name: "Workspace-App", count: 3),
                       "Workspace-App is open in 3 terminals")
    }

    func testNotificationBodyForTwoAndMore() {
        XCTAssertEqual(SessionCopiesCopy.notificationBody(count: 2),
                       "Two terminals are running the same Claude conversation. Each remembers only its own part. Close the one you\u{2019}re not using.")
        XCTAssertEqual(SessionCopiesCopy.notificationBody(count: 3),
                       "3 terminals are running the same Claude conversation. Each remembers only its own part. Close the one you\u{2019}re not using.")
    }

    func testTheCloseOutcomeWordsForAClosedCount() {
        XCTAssertEqual(SessionCopiesCopy.closeOutcome(project: "page", .closed(count: 1, noun: "cmux tab")).text,
                       "Closed the other page terminal")
        let one = SessionCopiesCopy.closeOutcome(project: "page", .closed(count: 1, noun: "cmux tab"))
        XCTAssertFalse(one.failed)
        let two = SessionCopiesCopy.closeOutcome(project: "page", .closed(count: 2, noun: "cmux tab"))
        XCTAssertEqual(two.text, "Closed the other 2 page terminals")
        XCTAssertFalse(two.failed)
    }

    func testTheCloseOutcomeWordsForARefusal() {
        let idle = SessionCopiesCopy.closeOutcome(project: "page", .refused(.notIdle(.busy)))
        XCTAssertEqual(idle.text, "Left the other page terminal open: it started working")
        XCTAssertTrue(idle.failed)
        let waiting = SessionCopiesCopy.closeOutcome(project: "page", .refused(.notIdle(.waiting)))
        XCTAssertEqual(waiting.text, "Left the other page terminal open: it is waiting for an answer")
        let unknown = SessionCopiesCopy.closeOutcome(project: "page", .refused(.notIdle(.unknown)))
        XCTAssertEqual(unknown.text, "Left the other page terminal open: Page can't tell what it is doing")
        let gone = SessionCopiesCopy.closeOutcome(project: "page", .refused(.noOther))
        XCTAssertEqual(gone.text, "Left the other page terminal open: there's no other terminal open any more")
        XCTAssertTrue(gone.failed)
        let moved = SessionCopiesCopy.closeOutcome(project: "page", .refused(.leadChanged))
        XCTAssertEqual(moved.text, "Left the other page terminal open: the working terminal changed, look again")
    }

    func testTheCloseOutcomeWordsForAFailure() {
        let failed = SessionCopiesCopy.closeOutcome(project: "page", .failed("one started working after 1 closed"))
        XCTAssertEqual(failed.text, "Didn't close the other page terminal: one started working after 1 closed")
        XCTAssertTrue(failed.failed)
    }
}
