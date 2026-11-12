import XCTest
@testable import PageCore

/// The IDLE group's cards (Designs/panel-sessions.md): which sessions get a card,
/// their ids and what the person can do with them, their order, and the card's
/// words ("idle 12m · session 6h 45m").
final class IdleRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_761_300_000)
    private let cmux = SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true)

    private func session(_ id: String, _ state: AgentSessionState, backend: AgentBackendID = .claude,
                         idleFor: TimeInterval? = 120) -> AgentSession {
        AgentSession(backend: backend, sessionId: id, cwd: "/Users/roy/projects/\(id)", title: nil, source: .terminal,
                     state: state, lastActivityAt: idleFor.map { now.addingTimeInterval(-$0) },
                     activeFlags: [], supportsRemoteReply: true)
    }

    /// A finished-turn page (an idle page with no subtype) for a session.
    private func turnPage(_ id: String, session: String) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: session, cwd: "/Users/roy/projects/\(session)", projectName: session,
                          kind: .idle, openedAt: now, context: "Done.", transcriptPath: "")
    }

    /// A permission page: a decision, not a finished turn.
    private func decidePage(_ id: String, session: String) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: session, cwd: "/Users/roy/projects/\(session)", projectName: session,
                          kind: .permission, openedAt: now, context: "[Bash] swift test", transcriptPath: "")
    }

    /// A snapshot as the Coordinator builds it (the same initializer the render fixtures use).
    private func snapshot(_ sessions: [AgentSession], pending: [InterventionEvent] = []) -> Coordinator.Snapshot {
        Coordinator.Snapshot(
            sessions: sessions, power: PowerSnapshot(percent: 100, onAC: true, hasBattery: true, isCharging: false),
            awake: AwakeAssertions(preventIdleSleep: true, preventSystemSleep: true), lidClosedOnBattery: false,
            lidClosedOnBatteryBlocker: nil, battery: .normal, activeRateLimit: nil, scheduledResumes: [],
            pendingInterventions: pending, relayState: .connected, backends: [], configProblem: nil,
            batteryForecast: nil, usage: nil, usageHitAt: nil)
    }

    private func idleRows(_ sessions: [AgentSession], pending: [InterventionEvent] = [],
                          hosts: [String: SessionHostInfo] = [:], facts: [String: InFlightFacts] = [:]) -> [InFlightRow] {
        InFlightRows.buildIdle(snapshot(sessions, pending: pending), hosts: hosts, facts: facts, now: now)
    }

    // MARK: - Which sessions get a card

    func testAnIdleSessionGetsACard() {
        XCTAssertEqual(idleRows([session("a", .idle)]).map(\.sessionId), ["a"])
    }

    func testAWaitingSessionWithOnlyFinishedTurnPagesGetsACard() {
        let rows = idleRows([session("b", .waitingOnUser)], pending: [turnPage("turn-b", session: "b")])
        XCTAssertEqual(rows.map(\.sessionId), ["b"])
    }

    func testWorkingAndApprovalSessionsAreNotIdle() {
        let rows = idleRows([session("active", .active), session("approval", .waitingOnApproval)])
        XCTAssertTrue(rows.isEmpty)
    }

    func testAWaitingSessionWithADecisionPageIsNotIdle() {
        let rows = idleRows([session("q", .waitingOnUser)], pending: [decidePage("perm-q", session: "q")])
        XCTAssertTrue(rows.isEmpty)
    }

    func testAWaitingSessionWithNoPagesIsNotIdle() {
        XCTAssertTrue(idleRows([session("q", .waitingOnUser)]).isEmpty)
    }

    func testAWaitingSessionWithAFinishedPageAndADecisionPageIsNotIdle() {
        let rows = idleRows([session("m", .waitingOnUser)],
                            pending: [turnPage("turn-m", session: "m"), decidePage("perm-m", session: "m")])
        XCTAssertTrue(rows.isEmpty, "every open page must be a finished turn")
    }

    func testTheSyntheticClaudeCliSessionIsLeftOut() {
        XCTAssertTrue(idleRows([session(InFlightRows.aggregateSessionId, .idle)]).isEmpty)
    }

    func testOtherBackendsAreLeftOut() {
        XCTAssertTrue(idleRows([session("aura-1", .idle, backend: .aura), session("orbit-1", .idle, backend: .orbit)]).isEmpty)
    }

    func testABackgroundRunWithNoFinishedPageIsLeftOut() {
        let background = SessionHostInfo(host: "background", canType: false, typeBlocker: nil, canInterrupt: false)
        XCTAssertTrue(idleRows([session("bg", .idle)], hosts: ["bg": background]).isEmpty)
    }

    func testACodexThreadWithNoTerminalIsLeftOutButOneWithATerminalIsKept() {
        let rows = idleRows([session("codex-ghost", .idle, backend: .codex),
                             session("codex-term", .idle, backend: .codex)],
                            hosts: ["codex-term": cmux])
        XCTAssertEqual(rows.map(\.sessionId), ["codex-term"])
    }

    // MARK: - The card

    func testIdCarriesTheIdlePrefixAndTheCardIsNotWorking() throws {
        let row = try XCTUnwrap(idleRows([session("a", .idle)]).first)
        XCTAssertEqual(row.id, InFlightRow.idlePrefix + "a")
        XCTAssertEqual(row.id, "idle-a")
        XCTAssertTrue(row.isIdle)
        XCTAssertFalse(row.working)
        XCTAssertTrue(row.dismissable)
        XCTAssertEqual(DismissTarget.of(row)?.pageId, nil, "an idle card carries no page")
    }

    func testTheCardsWhoLineAndTimeComeFromTheSession() throws {
        let row = try XCTUnwrap(idleRows([session("payments", .idle, idleFor: 720)], hosts: ["payments": cmux]).first)
        XCTAssertEqual(row.project, "payments")
        XCTAssertEqual(row.route, "cmux › payments")
        XCTAssertEqual(row.card.idleFor, "12m")
        XCTAssertEqual(row.elapsed, "12m")
        XCTAssertEqual(row.doing, "idle", "no last turn known: the word is idle")
    }

    func testTheLastTurnIsWhatTheCardSays() throws {
        let facts = ["a": InFlightFacts(model: "claude-opus-4-7", lastTurn: "Changed 3 files (+12 −4) · tests passed")]
        let row = try XCTUnwrap(idleRows([session("a", .idle)], facts: facts).first)
        XCTAssertEqual(row.doing, "Changed 3 files (+12 −4) · tests passed")
        XCTAssertEqual(row.card.lastTurn, "Changed 3 files (+12 −4) · tests passed")
        XCTAssertEqual(row.card.model, "Opus 4.7")
    }

    // MARK: - Order

    func testMostRecentActivityFirstThenProjectThenId() {
        let rows = idleRows([
            session("a", .idle, idleFor: 600),
            session("d", .idle, idleFor: 300),
            session("b", .idle, idleFor: 300),
            session("c", .idle, idleFor: nil),
        ])
        XCTAssertEqual(rows.map(\.sessionId), ["b", "d", "a", "c"],
                       "newest first; the same time by project; a card with no time last")
    }

    // MARK: - The card's words

    func testMakeIdleGivesTheIdleAndSessionTimes() {
        let facts = InFlightFacts(model: "claude-opus-4-7", startedAt: now.addingTimeInterval(-(6 * 3600 + 45 * 60)),
                                  lastTurn: "  Changed 3 files (+12 −4) · tests passed \n")
        let card = InFlightCardInfo.makeIdle(facts: facts, backend: .claude, idleSince: now.addingTimeInterval(-720), now: now)
        XCTAssertEqual(card.idleFor, "12m")
        XCTAssertEqual(card.sessionAge, "6h 45m")
        XCTAssertEqual(card.idleTimeLine, "idle 12m · session 6h 45m")
        XCTAssertEqual(card.backendName, AgentDisplay.agentName(.claude))
        XCTAssertEqual(card.model, "Opus 4.7")
        XCTAssertEqual(card.lastTurn, "Changed 3 files (+12 −4) · tests passed", "trimmed")
        XCTAssertEqual(card.now, InFlightRows.idleText)
        XCTAssertNil(card.workingFor, "an idle card has no working time")
        XCTAssertTrue(card.workflows.isEmpty)
        XCTAssertEqual(card.health, .normal)
        XCTAssertNil(card.healthLine)
    }

    func testTheSessionPartIsOmittedWhenTheStartIsUnknown() {
        let card = InFlightCardInfo.makeIdle(facts: InFlightFacts(model: nil), backend: .claude,
                                             idleSince: now.addingTimeInterval(-720), now: now)
        XCTAssertNil(card.sessionAge)
        XCTAssertEqual(card.idleTimeLine, "idle 12m")
    }

    func testTheIdlePartIsOmittedWhenItsTimeIsUnknown() {
        let card = InFlightCardInfo.makeIdle(facts: InFlightFacts(startedAt: now.addingTimeInterval(-3600)),
                                             backend: .claude, idleSince: nil, now: now)
        XCTAssertNil(card.idleFor)
        XCTAssertEqual(card.idleTimeLine, "session 1h")
    }

    func testNoFactsAndNoTimeMeansNoLine() {
        let card = InFlightCardInfo.makeIdle(facts: nil, backend: nil, idleSince: nil, now: now)
        XCTAssertNil(card.idleTimeLine)
        XCTAssertNil(card.lastTurn)
        XCTAssertNil(card.backendName)
    }

    func testABlankLastTurnIsNoLastTurn() {
        let card = InFlightCardInfo.makeIdle(facts: InFlightFacts(lastTurn: "   "), backend: .claude, idleSince: nil, now: now)
        XCTAssertNil(card.lastTurn)
    }
}
