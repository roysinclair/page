import XCTest
@testable import ClaudePowerMode
@testable import PageCore

/// Putting a finished session away from the keyboard (Designs/panel-sessions.md):
/// ⌫ on a card, the arrows across the IDLE group, the selection's reconcile, the
/// shortcut sheet's line, the `dismissClosesTerminal` setting, and the detector's
/// `dismiss(id:)`.
final class PanelSessionKeysTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_761_300_000)

    private func idleCard(_ session: String) -> InFlightRow {
        InFlightRow(id: InFlightRow.idlePrefix + session, sessionId: session, kind: .session, project: session,
                    backend: .claude, route: nil, doing: "idle", since: now.addingTimeInterval(-600), elapsed: "10m",
                    actions: .none, target: nil, working: false)
    }

    private func workingCard(_ session: String) -> InFlightRow {
        InFlightRow(id: InFlightRow.idPrefix + session, sessionId: session, kind: .session, project: session,
                    backend: .claude, route: nil, doing: "Running swift test", since: now, elapsed: "1m",
                    actions: .none, target: nil, working: true)
    }

    private func event(_ id: String, kind: InterventionKind, session: String = "s-decide") -> InterventionEvent {
        InterventionEvent(id: id, sessionId: session, cwd: "/Users/roy/projects/\(session)", projectName: session, kind: kind,
                          openedAt: now.addingTimeInterval(-60), context: "[Bash] swift test\nRun the tests",
                          transcriptPath: "", subtype: nil)
    }

    private func decideRow() -> DecideRow {
        NowModel.row(for: event("perm-1", kind: .permission), macName: "Studio MBP", route: "cmux › s-decide")!
    }

    private func reviewRow() -> DecideRow {
        NowModel.row(for: event("turn-1", kind: .idle, session: "s-review"), macName: "Studio MBP", route: "cmux › s-review")!
    }

    private func press(_ k: NowKeyPress.Key, repeating: Bool = false) -> NowKeyPress {
        NowKeyPress(key: k, phase: .down, isRepeat: repeating)
    }

    private func state(selected: String?, idleCollapsed: Bool = false) -> NowPanelState {
        var s = NowPanelState()
        s.selectedId = selected
        s.idleCollapsed = idleCollapsed
        return s
    }

    // MARK: - ⌫

    func testDeleteOnASelectedIdleCardDismissesIt() {
        let card = idleCard("s1")
        let r = NowKeys.handle(press(.delete), state: state(selected: card.id), rows: [], flights: [], idle: [card], now: now)
        XCTAssertEqual(r.effect, .dismiss(rowId: "idle-s1"))
    }

    func testDeleteOnAFinishedCardDismissesIt() {
        let finished = workingCard("w1").finished
        let r = NowKeys.handle(press(.delete), state: state(selected: finished.id), rows: [], flights: [finished], idle: [], now: now)
        XCTAssertEqual(r.effect, .dismiss(rowId: finished.id))
    }

    func testDeleteOnAFinishedTurnRowDismissesIt() {
        let review = reviewRow()
        let r = NowKeys.handle(press(.delete), state: state(selected: review.id), rows: [review], flights: [], idle: [], now: now)
        XCTAssertEqual(r.effect, .dismiss(rowId: review.id))
    }

    func testDeleteOnAWorkingCardDoesNothing() {
        let working = workingCard("w1")
        let r = NowKeys.handle(press(.delete), state: state(selected: working.id), rows: [], flights: [working], idle: [], now: now)
        XCTAssertEqual(r.effect, NowEffect.none)
    }

    func testDeleteOnADecideRowDoesNothing() {
        let decide = decideRow()
        let r = NowKeys.handle(press(.delete), state: state(selected: decide.id), rows: [decide], flights: [], idle: [], now: now)
        XCTAssertEqual(r.effect, NowEffect.none)
    }

    func testDeleteWithNothingSelectedDoesNothing() {
        let r = NowKeys.handle(press(.delete), state: state(selected: nil), rows: [reviewRow()], flights: [], idle: [workingCard("w").finished], now: now)
        XCTAssertEqual(r.effect, NowEffect.none)
    }

    func testARepeatedDeleteDismissesOnce() {
        let card = idleCard("s1")
        let r = NowKeys.handle(press(.delete, repeating: true), state: state(selected: card.id), rows: [], flights: [], idle: [card], now: now)
        XCTAssertEqual(r.effect, NowEffect.none)
    }

    // MARK: - ↑ and ↓ reach the IDLE rows after the in-flight rows

    func testArrowsGoPagesThenWorkingThenIdle() {
        let decide = decideRow()
        let working = workingCard("w1")
        let idle = idleCard("s1")
        var s = state(selected: nil)
        s = NowKeys.handle(press(.down), state: s, rows: [decide], flights: [working], idle: [idle], now: now).state
        XCTAssertEqual(s.selectedId, decide.id)
        s = NowKeys.handle(press(.down), state: s, rows: [decide], flights: [working], idle: [idle], now: now).state
        XCTAssertEqual(s.selectedId, working.id)
        s = NowKeys.handle(press(.down), state: s, rows: [decide], flights: [working], idle: [idle], now: now).state
        XCTAssertEqual(s.selectedId, idle.id, "the idle card comes after the working cards")
        s = NowKeys.handle(press(.down), state: s, rows: [decide], flights: [working], idle: [idle], now: now).state
        XCTAssertEqual(s.selectedId, idle.id, "the last row stops the arrow")
    }

    func testUpFromTheTopReachesTheLastIdleCard() {
        let idle = idleCard("s1")
        let r = NowKeys.handle(press(.up), state: state(selected: nil), rows: [], flights: [], idle: [idle], now: now)
        XCTAssertEqual(r.state.selectedId, idle.id)
    }

    func testArrowsSkipTheIdleGroupWhileItIsCollapsed() {
        let working = workingCard("w1")
        let idle = idleCard("s1")
        let r = NowKeys.handle(press(.down), state: state(selected: working.id, idleCollapsed: true),
                               rows: [], flights: [working], idle: [idle], now: now)
        XCTAssertEqual(r.state.selectedId, working.id, "a collapsed group has no rows to reach")
    }

    // MARK: - Reconcile

    func testReconcileDropsASelectionWhoseIdleCardDisappeared() {
        let s = state(selected: "idle-gone")
        XCTAssertNil(NowKeys.reconcile(s, rows: [], flights: [], idle: [idleCard("s1")]).selectedId)
    }

    func testReconcileKeepsTheSelectionOfAnIdleCardThatStillExists() {
        let s = state(selected: "idle-s1")
        XCTAssertEqual(NowKeys.reconcile(s, rows: [], flights: [], idle: [idleCard("s1")]).selectedId, "idle-s1")
    }

    func testReconcileDropsAnOpenComposerForAVanishedIdleCard() {
        var s = state(selected: nil)
        s.composer = NowPanelState.Composer(rowId: "idle-gone", kind: .type)
        XCTAssertNil(NowKeys.reconcile(s, rows: [], flights: [], idle: [idleCard("s1")]).composer)
    }

    // MARK: - The shortcut sheet

    func testTheShortcutSheetListsDelete() {
        let items = ShortcutCatalog.groups.flatMap(\.items)
        let delete = items.first { $0.keys == ["⌫"] }
        XCTAssertNotNil(delete, "⌫ must be in the shortcut sheet")
        XCTAssertEqual(delete?.title, "Dismiss a finished or idle session")
    }

    // MARK: - The setting

    func testDismissClosesTerminalDefaultsOff() throws {
        XCTAssertFalse(Config().dismissClosesTerminal)
        XCTAssertFalse(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).dismissClosesTerminal)
    }

    func testDismissClosesTerminalDecodesWhenSet() throws {
        XCTAssertTrue(try JSONDecoder().decode(Config.self, from: Data(#"{"dismissClosesTerminal": true}"#.utf8)).dismissClosesTerminal)
        var c = Config()
        c.dismissClosesTerminal = true
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(back.dismissClosesTerminal)
    }

    func testDismissClosesTerminalFallsBackToOffOnAWrongType() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"dismissClosesTerminal": "yes"}"#.utf8))
        XCTAssertFalse(c.dismissClosesTerminal)
    }
}

/// The detector's `dismiss(id:)`: a finished-turn page put away leaves the open
/// set and does not come back for the same turn. Real temp transcripts, the
/// foreground check injected, the hook-hold folder in a temp directory.
final class PanelSessionDetectorDismissTests: XCTestCase {
    private let sid = "5e55a0f1-7c2b-4d3e-8a9f-0b1c2d3e4f50"
    private var dir: URL!
    private var transcript: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dismiss-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        transcript = dir.appendingPathComponent("session.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func write(_ lines: [String]) throws {
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
    }

    private func userLine(_ text: String) -> String {
        json(["type": "user", "cwd": "/Users/me/proj", "timestamp": "2026-10-24T10:00:00.000Z", "isSidechain": false,
              "message": ["role": "user", "content": text]])
    }

    private func assistantText(_ text: String) -> String {
        json(["type": "assistant", "timestamp": "2026-10-24T10:00:05.000Z", "isSidechain": false,
              "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    private func toolUse(_ id: String, _ command: String) -> String {
        json(["type": "assistant", "timestamp": "2026-10-24T10:00:06.000Z", "isSidechain": false,
              "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": "Bash", "input": ["command": command]]]]])
    }

    private func live(_ status: ClaudeSessionStatus, since: Date) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 42, sessionId: sid, cwd: "/tmp", status: status, statusUpdatedAt: since,
                          tty: "ttys001", hasSessionFile: true)
    }

    private func detector() -> InterventionDetector {
        InterventionDetector(hookHoldsDirectory: dir, isForeground: { _ in true })
    }

    func testADismissedFinishedTurnLeavesTheOpenPagesAndDoesNotReturn() throws {
        try write([userLine("go"), assistantText("done")])
        let det = detector()
        let since = Date().addingTimeInterval(-120)
        let opened = det.scan(sessions: [live(.idle, since: since)], transcriptFor: { _ in self.transcript },
                              settings: DetectorSettings())
        let page = try XCTUnwrap(opened.opened.first, "a finished turn past the idle delay opens a page")
        XCTAssertEqual(page.kind, .idle)
        XCTAssertNil(page.subtype)

        let put = try XCTUnwrap(det.dismiss(id: page.id))
        XCTAssertEqual(put, page, "dismiss returns the page it put away")
        XCTAssertNil(det.pendingEvent(id: page.id))
        XCTAssertTrue(det.currentlyPending.isEmpty)

        let again = det.scan(sessions: [live(.idle, since: since)], transcriptFor: { _ in self.transcript },
                             settings: DetectorSettings())
        XCTAssertTrue(again.opened.isEmpty, "the same turn does not page again")
        XCTAssertTrue(det.currentlyPending.isEmpty)
    }

    func testANewTurnPagesAgain() throws {
        try write([userLine("go"), assistantText("done")])
        let det = detector()
        let first = Date().addingTimeInterval(-120)
        let page = try XCTUnwrap(det.scan(sessions: [live(.idle, since: first)], transcriptFor: { _ in self.transcript },
                                          settings: DetectorSettings()).opened.first)
        det.dismiss(id: page.id)
        let next = det.scan(sessions: [live(.idle, since: Date().addingTimeInterval(-90))], transcriptFor: { _ in self.transcript },
                            settings: DetectorSettings())
        XCTAssertEqual(next.opened.count, 1, "a later idle state is a new turn, so a new page")
    }

    func testOnlyAFinishedTurnPageCanBeDismissedThisWay() throws {
        try write([userLine("go"), toolUse("toolu_1", "swift test")])
        let det = detector()
        let page = try XCTUnwrap(det.scan(sessions: [live(.waiting, since: Date().addingTimeInterval(-30))],
                                          transcriptFor: { _ in self.transcript }, settings: DetectorSettings()).opened.first)
        XCTAssertEqual(page.kind, .permission)
        XCTAssertNil(det.dismiss(id: page.id), "an approval is never put away")
        XCTAssertNotNil(det.pendingEvent(id: page.id), "and it stays open")
    }

    func testDismissingAnUnknownPageDoesNothing() {
        XCTAssertNil(detector().dismiss(id: "no-such-page"))
    }

    // An idle card put away before its finished-turn page opened: that turn never pages.

    func testAQuietedSessionDoesNotOpenItsFinishedTurnPage() throws {
        try write([userLine("go"), assistantText("done")])
        let det = detector()
        det.quietFinishedTurn(sessionId: sid)
        let since = Date().addingTimeInterval(-120)
        let r = det.scan(sessions: [live(.idle, since: since)], transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertTrue(r.opened.isEmpty, "no page for a session put away at the Mac")
        XCTAssertTrue(det.currentlyPending.isEmpty)
    }

    func testAQuietedSessionStillPagesForAnApproval() throws {
        try write([userLine("go"), toolUse("toolu_1", "swift test")])
        let det = detector()
        det.quietFinishedTurn(sessionId: sid)
        let r = det.scan(sessions: [live(.waiting, since: Date().addingTimeInterval(-30))],
                         transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertEqual(r.opened.first?.kind, .permission, "only finished-turn pages are held back")
    }

    func testAQuietedSessionPagesAgainAfterItWorks() throws {
        try write([userLine("go"), assistantText("done")])
        let det = detector()
        det.quietFinishedTurn(sessionId: sid)
        // It works again (a new turn): the quiet is forgotten...
        _ = det.scan(sessions: [live(.busy, since: Date().addingTimeInterval(-100))], transcriptFor: { _ in self.transcript },
                     settings: DetectorSettings())
        // ...so when that turn finishes, its page opens.
        let r = det.scan(sessions: [live(.idle, since: Date().addingTimeInterval(-90))], transcriptFor: { _ in self.transcript },
                         settings: DetectorSettings())
        XCTAssertEqual(r.opened.count, 1)
    }

    // After a relaunch: the saved ledger quiets its Claude sessions before the first scan.

    func testQuietOnLaunchNamesTheLedgersClaudeSessions() {
        var ledger = SessionDismissals()
        ledger.dismiss(SessionDismissal(sessionId: "b-claude", backend: .claude, at: Date(), pageId: "b-claude-idle-1"))
        ledger.dismiss(SessionDismissal(sessionId: "a-claude", backend: .claude, at: Date(), pageId: nil))
        ledger.dismiss(SessionDismissal(sessionId: "codex-1", backend: .codex, at: Date(), pageId: nil))
        XCTAssertEqual(Coordinator.quietOnLaunch(ledger), ["a-claude", "b-claude"])
        XCTAssertEqual(Coordinator.quietOnLaunch(SessionDismissals()), [])
    }

    func testAfterARelaunchADismissedSessionStaysQuietAndHidden() throws {
        try write([userLine("go"), assistantText("done")])
        var ledger = SessionDismissals()
        ledger.dismiss(SessionDismissal(sessionId: sid, backend: .claude, at: Date(), pageId: nil))
        // A fresh detector, as at launch, quieted from the saved ledger.
        let det = detector()
        for id in Coordinator.quietOnLaunch(ledger) { det.quietFinishedTurn(sessionId: id) }
        let r = det.scan(sessions: [live(.idle, since: Date().addingTimeInterval(-120))], transcriptFor: { _ in self.transcript },
                         settings: DetectorSettings())
        XCTAssertTrue(r.opened.isEmpty, "no page, so the phone isn't paged for a session put away before the relaunch")
        let session = AgentSession(backend: .claude, sessionId: sid, cwd: "/tmp", title: "proj", source: .terminal, state: .idle,
                                   lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
        XCTAssertTrue(ledger.hides(session, openPageIds: Set(det.currentlyPending.values.filter { $0.sessionId == sid }.map(\.id))),
                      "and with no new page the ledger keeps it hidden")
    }

    func testAQuietLeavesAnAlreadyOpenPageAlone() throws {
        try write([userLine("go"), assistantText("done")])
        let det = detector()
        let since = Date().addingTimeInterval(-120)
        let page = try XCTUnwrap(det.scan(sessions: [live(.idle, since: since)], transcriptFor: { _ in self.transcript },
                                          settings: DetectorSettings()).opened.first)
        det.quietFinishedTurn(sessionId: sid)
        let r = det.scan(sessions: [live(.idle, since: since)], transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertTrue(r.resolved.isEmpty, "a page already open is closed only by dismissing it")
        XCTAssertNotNil(det.pendingEvent(id: page.id))
    }
}
