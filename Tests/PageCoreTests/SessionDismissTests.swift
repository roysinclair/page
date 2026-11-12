import XCTest
@testable import PageCore

/// The panel's "put a finished session away" rules (Designs/panel-sessions.md):
/// the ledger that hides a session until its next turn, its file, the five
/// seconds of Undo, which cards can be put away, the IDLE group's contents, the
/// swipe's thresholds and the words the status line says.
final class SessionDismissTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)

    private func session(_ id: String, _ state: AgentSessionState, backend: AgentBackendID = .claude) -> AgentSession {
        AgentSession(backend: backend, sessionId: id, cwd: "/Users/roy/projects/\(id)", title: nil, source: .terminal,
                     state: state, lastActivityAt: t0, activeFlags: [], supportsRemoteReply: true)
    }

    /// An open page for a session (an idle page by default: a finished turn).
    private func page(_ id: String, session: String, kind: InterventionKind = .idle) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: session, cwd: "/Users/roy/projects/\(session)", projectName: session,
                          kind: kind, openedAt: t0, context: "Done.", transcriptPath: "")
    }

    private func dismissal(_ id: String, page: String? = nil, backend: AgentBackendID = .claude) -> SessionDismissal {
        SessionDismissal(sessionId: id, backend: backend, at: t0, pageId: page)
    }

    private func idleRow(_ session: String, project: String? = nil) -> InFlightRow {
        InFlightRow(id: InFlightRow.idlePrefix + session, sessionId: session, kind: .session, project: project ?? session,
                    backend: .claude, route: nil, doing: "idle", since: t0, elapsed: nil, actions: .none, target: nil,
                    working: false)
    }

    // MARK: - The ledger: hides

    func testHidesAnIdleSessionWhoseOnlyOpenPageIsTheDismissedOne() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        XCTAssertTrue(d.hides(session("s1", .idle), openPageIds: ["p1"]))
    }

    func testHidesAWaitingOnUserSessionWithOnlyTheDismissedPage() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        XCTAssertTrue(d.hides(session("s1", .waitingOnUser), openPageIds: ["p1"]))
    }

    func testAnIdleSessionWithNoPageAtAllIsHidden() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: nil))
        XCTAssertTrue(d.hides(session("s1", .idle), openPageIds: []))
    }

    func testNothingHidesWithoutAnEntry() {
        let d = SessionDismissals()
        XCTAssertFalse(d.hides(session("s1", .idle), openPageIds: []))
    }

    func testStopsHidingWhenTheSessionIsActive() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        XCTAssertFalse(d.hides(session("s1", .active), openPageIds: []), "a new turn shows it again")
    }

    func testStopsHidingWhenTheSessionWaitsForAnApproval() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        XCTAssertFalse(d.hides(session("s1", .waitingOnApproval), openPageIds: ["p1"]))
    }

    func testStopsHidingWhenADifferentPageOpensForIt() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        XCTAssertFalse(d.hides(session("s1", .idle), openPageIds: ["p2"]))
        XCTAssertFalse(d.hides(session("s1", .idle), openPageIds: ["p1", "p2"]))
    }

    func testHiddenSessionIdsOnlyNamesTheSessionsTheLedgerHides() {
        var d = SessionDismissals()
        d.dismiss(dismissal("quiet", page: "q1"))
        d.dismiss(dismissal("busy", page: "b1"))
        d.dismiss(dismissal("newPage", page: "n1"))
        let live = [session("quiet", .idle), session("busy", .active), session("newPage", .idle), session("untouched", .idle)]
        let pages = [page("q1", session: "quiet"), page("n1", session: "newPage"), page("n2", session: "newPage")]
        XCTAssertEqual(d.hiddenSessionIds(live: live, openPages: pages), ["quiet"])
    }

    // MARK: - The ledger: prune

    func testPruneDropsAnEntryWhoseSessionIsGone() {
        var d = SessionDismissals()
        d.dismiss(dismissal("gone", page: nil))
        XCTAssertTrue(d.prune(live: [], openPages: []))
        XCTAssertTrue(d.isEmpty)
    }

    func testPruneDropsEntriesOfActiveAndWaitingOnApprovalSessions() {
        var d = SessionDismissals()
        d.dismiss(dismissal("working", page: nil))
        d.dismiss(dismissal("approval", page: nil))
        d.dismiss(dismissal("parked", page: nil))
        let changed = d.prune(live: [session("working", .active), session("approval", .waitingOnApproval),
                                     session("parked", .idle)], openPages: [])
        XCTAssertTrue(changed)
        XCTAssertEqual(Set(d.entries.keys), ["parked"])
    }

    func testPruneDropsTheEntryWhenADifferentPageOpens() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        XCTAssertTrue(d.prune(live: [session("s1", .idle)], openPages: [page("p2", session: "s1")]))
        XCTAssertTrue(d.isEmpty, "the next finished turn shows again")
    }

    func testPruneKeepsTheEntryWhenItsOwnPageIsStillTheOnlyOne() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        XCTAssertFalse(d.prune(live: [session("s1", .idle)], openPages: [page("p1", session: "s1")]))
        XCTAssertFalse(d.isEmpty)
    }

    func testPruneReturnsFalseWhenNothingIsDropped() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: nil))
        XCTAssertFalse(d.prune(live: [session("s1", .idle)], openPages: []))
        XCTAssertFalse(d.isEmpty)
    }

    func testPruneKeepsEntriesOfABackendThatHasNotReportedYet() {
        var d = SessionDismissals()
        d.dismiss(dismissal("codex-thread", page: nil, backend: .codex))
        // Codex scans on its own queue: nothing listed yet is not a reason to forget the entry.
        XCTAssertFalse(d.prune(live: [], openPages: [], reported: [.claude]))
        XCTAssertFalse(d.isEmpty)
    }

    func testPruneDropsAMissingSessionOnceItsBackendHasReported() {
        var d = SessionDismissals()
        d.dismiss(dismissal("codex-thread", page: nil, backend: .codex))
        XCTAssertTrue(d.prune(live: [], openPages: [], reported: [.claude, .codex]))
        XCTAssertTrue(d.isEmpty)
    }

    func testPruneKeepsAnUnreportedBackendsEntryWhileItsSessionIsListedAndIdle() {
        var d = SessionDismissals()
        d.dismiss(dismissal("codex-thread", page: nil, backend: .codex))
        XCTAssertFalse(d.prune(live: [session("codex-thread", .idle, backend: .codex)], openPages: [], reported: [.claude]))
        XCTAssertFalse(d.isEmpty)
    }

    // MARK: - The ledger: value behaviour

    func testDismissingAgainReplacesTheEntryForTheSameSession() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        d.dismiss(dismissal("s1", page: "p9"))
        XCTAssertEqual(d.entries.count, 1)
        XCTAssertEqual(d.entries["s1"]?.pageId, "p9")
    }

    func testClearEmptiesTheLedger() {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: nil))
        d.dismiss(dismissal("s2", page: "p2"))
        d.clear()
        XCTAssertTrue(d.isEmpty)
        XCTAssertTrue(d.hiddenSessionIds(live: [session("s1", .idle)], openPages: []).isEmpty)
    }

    func testOpenPageIdsAreOnlyThatSessionsPages() {
        let pages = [page("a1", session: "a"), page("a2", session: "a"), page("b1", session: "b")]
        XCTAssertEqual(SessionDismissals.openPageIds(for: "a", in: pages), ["a1", "a2"])
        XCTAssertEqual(SessionDismissals.openPageIds(for: "none", in: pages), [])
    }

    func testCodableRoundTrip() throws {
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        d.dismiss(dismissal("s2", page: nil, backend: .codex))
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(SessionDismissals.self, from: data)
        XCTAssertEqual(back, d)
        XCTAssertEqual(back.entries["s2"]?.backend, .codex)
        XCTAssertNil(back.entries["s2"]?.pageId)
    }

    // MARK: - The file

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dismiss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStoreSaveAndLoadRoundTrip() {
        let store = SessionDismissalStore(support: dir)
        XCTAssertEqual(store.url.lastPathComponent, SessionDismissalStore.fileName)
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        d.dismiss(dismissal("s2", page: nil, backend: .codex))
        XCTAssertTrue(store.save(d))
        XCTAssertEqual(store.load(), d)
    }

    func testStoreLoadOfAMissingFileIsEmpty() {
        let store = SessionDismissalStore(url: dir.appendingPathComponent("nothing-here.json"))
        XCTAssertTrue(store.load().isEmpty)
    }

    func testStoreFileIsOwnerOnly0600() throws {
        let store = SessionDismissalStore(support: dir)
        var d = SessionDismissals()
        d.dismiss(dismissal("s1", page: "p1"))
        XCTAssertTrue(store.save(d))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        let mode = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    // MARK: - Undo window

    private func pending(closes: Bool, noun: String? = "cmux tab") -> PendingDismissal {
        PendingDismissal(target: DismissTarget(rowId: "idle-s1", sessionId: "s1", backend: .claude, pageId: nil,
                                               project: "payments-api"),
                         startedAt: t0, closesTerminal: closes, closeNoun: noun)
    }

    func testTheUndoWindowIsFiveSeconds() {
        XCTAssertEqual(PendingDismissal.window, 5)
        XCTAssertEqual(pending(closes: false).commitAt, t0.addingTimeInterval(5))
    }

    func testSecondsLeftCountDownAndRoundUp() {
        let p = pending(closes: false)
        XCTAssertEqual(p.secondsLeft(now: t0), 5)
        XCTAssertEqual(p.secondsLeft(now: t0.addingTimeInterval(0.5)), 5, "4.5s left reads as 5")
        XCTAssertEqual(p.secondsLeft(now: t0.addingTimeInterval(1)), 4)
        XCTAssertEqual(p.secondsLeft(now: t0.addingTimeInterval(4.5)), 1, "0.5s left reads as 1")
        XCTAssertEqual(p.secondsLeft(now: t0.addingTimeInterval(5)), 0)
        XCTAssertEqual(p.secondsLeft(now: t0.addingTimeInterval(60)), 0, "never negative")
    }

    func testIsDueOnlyOnceTheWindowHasPassed() {
        let p = pending(closes: false)
        XCTAssertFalse(p.isDue(now: t0))
        XCTAssertFalse(p.isDue(now: t0.addingTimeInterval(4.99)))
        XCTAssertTrue(p.isDue(now: t0.addingTimeInterval(5)))
        XCTAssertTrue(p.isDue(now: t0.addingTimeInterval(9)))
    }

    func testTheLineNamesTheTerminalWhenItWillClose() {
        XCTAssertEqual(pending(closes: true).line(now: t0), "Closing payments-api's cmux tab in 5s")
        XCTAssertEqual(pending(closes: true).line(now: t0.addingTimeInterval(3)), "Closing payments-api's cmux tab in 2s")
    }

    func testTheLineIsPlainWhenTheTerminalStaysOpen() {
        XCTAssertEqual(pending(closes: false).line(now: t0), "Dismissed payments-api")
        XCTAssertEqual(pending(closes: true, noun: nil).line(now: t0), "Dismissed payments-api", "no known host, nothing promised")
    }

    func testPendingIdentifiesByTheSession() {
        XCTAssertEqual(pending(closes: false).id, "s1")
    }

    // MARK: - What can be dismissed

    func testAnIdleCardIsADismissTarget() throws {
        let target = try XCTUnwrap(DismissTarget.of(idleRow("s1")))
        XCTAssertEqual(target.sessionId, "s1")
        XCTAssertEqual(target.rowId, "idle-s1")
        XCTAssertEqual(target.backend, .claude)
        XCTAssertNil(target.pageId, "an idle session has no page to close")
        XCTAssertEqual(target.project, "s1")
    }

    func testAWorkingCardIsNotADismissTarget() {
        var row = idleRow("s1")
        row = InFlightRow(id: InFlightRow.idPrefix + "s1", sessionId: "s1", kind: .session, project: "s1", backend: .claude,
                          route: nil, doing: "working", since: t0, elapsed: nil, actions: .none, target: nil, working: true)
        XCTAssertNil(DismissTarget.of(row))
    }

    func testALocalModelIsNotADismissTarget() {
        let row = InFlightRow(id: InFlightRow.idPrefix + "local-m", sessionId: "m", kind: .localModel, project: "Qwen",
                              backend: nil, route: nil, doing: "working", since: nil, elapsed: nil, actions: .localModel,
                              target: nil, working: false)
        XCTAssertNil(DismissTarget.of(row))
    }

    func testAFinishedTurnPageIsADismissTarget() throws {
        let row = try XCTUnwrap(NowModel.row(for: page("turn-1", session: "s2"), macName: "Studio MBP", route: "cmux › s2"))
        XCTAssertEqual(row.section, .review)
        let target = try XCTUnwrap(DismissTarget.of(row))
        XCTAssertEqual(target.pageId, row.id, "the page closes with the session")
        XCTAssertEqual(target.sessionId, "s2")
        XCTAssertEqual(target.backend, .claude)
    }

    func testDecideAndLookRowsAreNotDismissTargets() throws {
        let decide = try XCTUnwrap(NowModel.row(for: page("perm-1", session: "s3", kind: .permission),
                                                macName: "Studio MBP", route: nil))
        XCTAssertEqual(decide.section, .decide)
        XCTAssertNil(DismissTarget.of(decide))

        var stuck = page("stuck-1", session: "s4")
        stuck.subtype = "looping"
        let look = try XCTUnwrap(NowModel.row(for: stuck, macName: "Studio MBP", route: nil))
        XCTAssertEqual(look.section, .look)
        XCTAssertNil(DismissTarget.of(look))
    }

    // MARK: - The IDLE group

    func testIdleGroupContentsDropsSessionsWithARowHiddenOrInFlight() {
        let idle = [idleRow("a"), idleRow("b"), idleRow("c"), idleRow("d")]
        let review = NowModel.row(for: page("turn-b", session: "b"), macName: "Studio MBP", route: nil)!
        let working = InFlightRow(id: InFlightRow.idPrefix + "c", sessionId: "c", kind: .session, project: "c", backend: .claude,
                                  route: nil, doing: "working", since: nil, elapsed: nil, actions: .none, target: nil, working: true)
        let shown = IdleGroup.contents(idle: idle, rows: [review], flights: [working], hidden: ["d"])
        XCTAssertEqual(shown.map(\.sessionId), ["a"])
    }

    func testIdleGroupContentsKeepsTheModelsOrder() {
        let idle = [idleRow("z"), idleRow("m"), idleRow("a")]
        XCTAssertEqual(IdleGroup.contents(idle: idle, rows: [], hidden: []).map(\.sessionId), ["z", "m", "a"])
    }

    func testIdleGroupWordsAndAnchor() {
        XCTAssertEqual(IdleGroup.title(count: 9), "Idle · 9")
        XCTAssertEqual(IdleGroup.dismissedTitle(count: 2), "2 dismissed · Show")
        XCTAssertEqual(IdleGroup.anchorId, "idle-group")
    }

    // MARK: - The swipe

    func testADragPastThirtyFivePercentOfTheWidthDismisses() {
        XCTAssertTrue(SwipeDismissModel.shouldDismiss(offset: 70, width: 200, velocity: 0), "exactly 0.35 × width")
        XCTAssertTrue(SwipeDismissModel.shouldDismiss(offset: 150, width: 200, velocity: 0))
        XCTAssertFalse(SwipeDismissModel.shouldDismiss(offset: 69, width: 200, velocity: 0))
    }

    func testTheSwipeDismissesInBothDirections() {
        XCTAssertTrue(SwipeDismissModel.shouldDismiss(offset: -70, width: 200, velocity: 0))
        XCTAssertTrue(SwipeDismissModel.shouldDismiss(offset: -40, width: 200, velocity: -900))
    }

    func testAFastFlickNeedsBothItsSpeedAndItsDistance() {
        XCTAssertTrue(SwipeDismissModel.shouldDismiss(offset: 40, width: 200, velocity: 900), "900 pt/s and 40 pt")
        XCTAssertFalse(SwipeDismissModel.shouldDismiss(offset: 39, width: 200, velocity: 900), "not far enough")
        XCTAssertFalse(SwipeDismissModel.shouldDismiss(offset: 40, width: 200, velocity: 899), "not fast enough")
        XCTAssertFalse(SwipeDismissModel.shouldDismiss(offset: 40, width: 200, velocity: 0))
    }

    func testBelowEveryThresholdTheCardStays() {
        XCTAssertFalse(SwipeDismissModel.shouldDismiss(offset: 10, width: 200, velocity: 100))
        XCTAssertFalse(SwipeDismissModel.shouldDismiss(offset: 0, width: 200, velocity: 0))
    }

    func testACardWithNoWidthNeverDismisses() {
        XCTAssertFalse(SwipeDismissModel.shouldDismiss(offset: 1000, width: 0, velocity: 5000))
        XCTAssertFalse(SwipeDismissModel.shouldDismiss(offset: 1000, width: -10, velocity: 0))
    }

    func testSidewaysIsDecidedByTheFirstScrollEvent() {
        XCTAssertTrue(SwipeDismissModel.isSideways(deltaX: 3, deltaY: 1), "3 > 1.5 × 1")
        XCTAssertTrue(SwipeDismissModel.isSideways(deltaX: -4, deltaY: 2))
        XCTAssertFalse(SwipeDismissModel.isSideways(deltaX: 1, deltaY: 1), "a diagonal is the list scrolling")
        XCTAssertFalse(SwipeDismissModel.isSideways(deltaX: 0, deltaY: 5))
        XCTAssertFalse(SwipeDismissModel.isSideways(deltaX: 0, deltaY: 0))
    }

    func testRubberBandNeverGoesPastItsLimit() {
        XCTAssertEqual(SwipeDismissModel.rubberBand(offset: 0), 0)
        XCTAssertLessThan(SwipeDismissModel.rubberBand(offset: 100), SwipeDismissModel.rubberBand(offset: 200))
        XCTAssertLessThan(SwipeDismissModel.rubberBand(offset: 1_000_000), 80)
        XCTAssertGreaterThan(SwipeDismissModel.rubberBand(offset: 1_000_000), 79, "it resists, it does not stop dead")
        XCTAssertGreaterThan(-SwipeDismissModel.rubberBand(offset: -1_000_000), -80)
        XCTAssertLessThan(SwipeDismissModel.rubberBand(offset: -1_000_000), -79)
        XCTAssertEqual(SwipeDismissModel.rubberBand(offset: -50), -SwipeDismissModel.rubberBand(offset: 50))
        XCTAssertLessThan(SwipeDismissModel.rubberBand(offset: 50, limit: 40), 40)
    }

    func testProgressRunsFromZeroToOneAndClamps() {
        XCTAssertEqual(SwipeDismissModel.progress(offset: 0, width: 200), 0)
        XCTAssertEqual(SwipeDismissModel.progress(offset: -35, width: 100), 1, "the threshold is 1")
        XCTAssertEqual(SwipeDismissModel.progress(offset: 17.5, width: 100), 0.5)
        XCTAssertEqual(SwipeDismissModel.progress(offset: 500, width: 100), 1)
        XCTAssertEqual(SwipeDismissModel.progress(offset: 50, width: 0), 0)
    }

    func testVelocityIsPointsPerSecond() {
        XCTAssertEqual(SwipeDismissModel.velocity(delta: 100, seconds: 0.5), 200)
        XCTAssertEqual(SwipeDismissModel.velocity(delta: 100, seconds: 0), 0)
    }

    // MARK: - Words

    func testTheTooltipWithTheSettingOff() {
        XCTAssertEqual(DismissCopy.tooltip(closesTerminal: false, noun: nil), "Dismiss · ⌫ · hides it until its next turn")
        XCTAssertEqual(DismissCopy.tooltip(closesTerminal: false, noun: "cmux tab"), "Dismiss · ⌫ · hides it until its next turn",
                       "the host never changes the words when the setting is off")
    }

    func testTheTooltipWithTheSettingOnAndAKnownHost() {
        XCTAssertEqual(DismissCopy.tooltip(closesTerminal: true, noun: "cmux tab"), "Dismiss · ⌫ · also closes its cmux tab")
        XCTAssertEqual(DismissCopy.tooltip(closesTerminal: true, noun: "tmux pane"), "Dismiss · ⌫ · also closes its tmux pane")
    }

    func testTheTooltipWithTheSettingOnAndAnUnknownHost() {
        XCTAssertEqual(DismissCopy.tooltip(closesTerminal: true, noun: nil),
                       "Dismiss · ⌫ · hides it until its next turn · Page can't close this terminal")
    }

    func testTheSwipeLabelFollowsTheSetting() {
        XCTAssertEqual(DismissCopy.swipeLabel, "Dismiss")
        XCTAssertEqual(DismissCopy.swipeCloseLabel, "Dismiss · close tab")
        XCTAssertEqual(DismissCopy.undoTitle, "Undo")
        XCTAssertEqual(DismissCopy.accessibilityAction, "Dismiss")
    }

    func testThePendingLineCountsDownWithItsTerminal() {
        XCTAssertEqual(DismissCopy.pending(project: "payments-api", closeNoun: "cmux tab", secondsLeft: 5),
                       "Closing payments-api's cmux tab in 5s")
        XCTAssertEqual(DismissCopy.pending(project: "payments-api", closeNoun: nil, secondsLeft: 5), "Dismissed payments-api")
    }

    func testTheOutcomeLineForAClosedTerminal() {
        let o = DismissCopy.outcome(project: "payments-api", .closed(noun: "cmux tab"))
        XCTAssertEqual(o.text, "Closed payments-api's cmux tab")
        XCTAssertFalse(o.failed)
    }

    func testTheOutcomeLineWhenTheTerminalWasUsedAgain() {
        let o = DismissCopy.outcome(project: "payments-api", .refused(.usedAgain))
        XCTAssertEqual(o.text, "Dismissed payments-api · didn't close its tab: it was used again")
        XCTAssertTrue(o.failed)
    }

    func testTheOutcomeLineForAPageLimitIsSaidBare() {
        let ghostty = DismissCopy.outcome(project: "payments-api", .refused(.plan("Page can't close Ghostty tabs")))
        XCTAssertEqual(ghostty.text, "Dismissed payments-api · Page can't close Ghostty tabs")
        XCTAssertTrue(ghostty.failed)

        let codex = DismissCopy.outcome(project: "payments-api", .refused(.codex))
        XCTAssertEqual(codex.text, "Dismissed payments-api · " + TerminalClose.codexRefusal)
    }

    func testTheOutcomeLineWhenTheTerminalCouldNotBeClosed() {
        let o = DismissCopy.outcome(project: "payments-api", .failed("tmux didn't close it"))
        XCTAssertEqual(o.text, "Dismissed payments-api · didn't close its tab: tmux didn't close it")
        XCTAssertTrue(o.failed)
    }
}
