import XCTest
@testable import ClaudePowerMode
@testable import PageCore

/// The budget row on a session card in the menu-bar panel (Designs/budget-caps.md §6):
/// the line, the editor's state and what Save sends, and NowStore's budget flows.
final class NowBudgetTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let resets: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 2026-11-09 is a Monday.
        return cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9))!
    }()

    private func row(used: Double, cap: Int?, state: BudgetState, projectCap: Int? = nil, sessionCap: Int? = nil,
                     defaultCap: Int? = nil, scope: BudgetScope = .project, sessionUsed: Double = 0) -> BudgetStatus.Row {
        BudgetStatus.Row(projectKey: "/x/night-owl", projectName: "Night Owl", used: used, cap: cap, scope: scope, state: state,
                         sessionUsed: sessionUsed, sessionCap: sessionCap, projectCap: projectCap, defaultCap: defaultCap)
    }

    private func status(_ rows: [String: BudgetStatus.Row] = [:], capture: Bool = true, measuring: Bool = false) -> BudgetStatus {
        BudgetStatus(capture: capture, measuring: measuring, weekPct: 30, resetsAt: resets, defaultCap: nil, projects: [], sessions: rows)
    }

    // MARK: the card's line

    func testCaptureOffLeavesOnlyTheButton() {
        let line = NowBudgetLine.build(status: .off, sessionId: "s1")
        XCTAssertEqual(line?.captureOn, false)
        XCTAssertEqual(line?.text, "")
        XCTAssertEqual(line?.hasBudget, false)
        XCTAssertEqual(line?.accessibilityText, "Budget, usage tracking is off")
    }

    func testNoLineForASessionBudgetsDoNotCover() {
        XCTAssertNil(NowBudgetLine.build(status: status(), sessionId: "unknown"))
    }

    func testBudgetedRowFillsAgainstItsBudgetAndWarms() {
        let line = NowBudgetLine.build(status: status(["s1": row(used: 21, cap: 25, state: .warn, projectCap: 25)]), sessionId: "s1")
        XCTAssertEqual(line?.text, "21% of 25%")
        XCTAssertEqual(line?.fraction ?? -1, 0.84, accuracy: 1e-9)
        XCTAssertEqual(line?.hasBudget, true)
        XCTAssertEqual(line?.warm, true, "amber from 80%")
        XCTAssertEqual(line?.state, .warn)
        XCTAssertEqual(line?.accessibilityText, "Budget, 21% of 25%")
    }

    func testOverBudgetIsAFullBarAndStopped() {
        let line = NowBudgetLine.build(status: status(["s1": row(used: 26, cap: 25, state: .over, projectCap: 25)]), sessionId: "s1")
        XCTAssertEqual(line?.text, "stopped at 25%")
        XCTAssertEqual(line?.fraction, 1)
        XCTAssertEqual(line?.warm, true)
    }

    func testNoBudgetFillsTheWholeWeekFaintly() {
        let line = NowBudgetLine.build(status: status(["s1": row(used: 2, cap: nil, state: .ok)]), sessionId: "s1")
        XCTAssertEqual(line?.text, "2% · no budget")
        XCTAssertEqual(line?.fraction ?? -1, 0.02, accuracy: 1e-9, "the whole week is the bar")
        XCTAssertEqual(line?.hasBudget, false)
        XCTAssertEqual(line?.warm, false)
    }

    func testTheDefaultBudgetSaysSo() {
        let line = NowBudgetLine.build(status: status(["s1": row(used: 4, cap: 10, state: .ok, defaultCap: 10)]), sessionId: "s1")
        XCTAssertEqual(line?.text, "4% of 10% · default budget")
        XCTAssertEqual(line?.hasBudget, true)
    }

    func testASessionCapReadsAsItsOwn() {
        let line = NowBudgetLine.build(status: status(["s1": row(used: 12, cap: 10, state: .over, scope: .session, sessionUsed: 12)]),
                                       sessionId: "s1")
        XCTAssertEqual(line?.text, "stopped at 10%")
    }

    func testMeasuringShowsNoBar() {
        let line = NowBudgetLine.build(status: status(["s1": row(used: 0, cap: 25, state: .ok, projectCap: 25)], measuring: true),
                                       sessionId: "s1")
        XCTAssertEqual(line?.text, "Measuring…")
        XCTAssertEqual(line?.fraction, 0)
        XCTAssertEqual(line?.hasBudget, false)
        XCTAssertEqual(line?.warm, false)
    }

    // MARK: the editor

    private func editor(projectCap: Int? = 25, sessionCap: Int? = nil) -> BudgetEditor {
        BudgetEditor(rowId: "row-s1", sessionId: "s1", row: row(used: 5, cap: projectCap, state: .ok, projectCap: projectCap, sessionCap: sessionCap),
                     resetsAt: resets)
    }

    func testEditorStartsOnTheProjectsOwnCap() {
        let e = editor()
        XCTAssertEqual(e.scope, .project)
        XCTAssertEqual(e.value, 25)
        XCTAssertEqual(e.seed, 25)
        XCTAssertFalse(e.changed)
        XCTAssertEqual(e.op, BudgetOp(target: .project("/x/night-owl"), pct: 25))
        XCTAssertEqual(e.projectName, "Night Owl")
    }

    func testEditorStartsWithNoBudgetAsOff() {
        let e = editor(projectCap: nil)
        XCTAssertNil(e.value, "the default is not shown as the project's own")
        XCTAssertFalse(e.changed)
    }

    func testScopeSwitchReseedsFromThatScopesCap() {
        var e = editor(projectCap: 25, sessionCap: nil)
        e.setScope(.session)
        XCTAssertEqual(e.scope, .session)
        XCTAssertNil(e.value, "this session has no cap of its own yet")
        XCTAssertEqual(e.op, BudgetOp(target: .session("s1"), pct: nil))
        e.choose(10)
        XCTAssertTrue(e.changed)
        e.setScope(.project)
        XCTAssertEqual(e.value, 25, "back to the project's cap")
        XCTAssertFalse(e.changed)
    }

    func testSettingTheSameScopeKeepsTheEdit() {
        var e = editor()
        e.choose(30)
        e.setScope(.project)
        XCTAssertEqual(e.value, 30)
    }

    func testChooseRefusesOutOfRangeValues() {
        var e = editor()
        e.choose(30)
        e.choose(0)
        XCTAssertEqual(e.value, 30)
        e.choose(101)
        XCTAssertEqual(e.value, 30)
        e.choose(nil)
        XCTAssertNil(e.value, "Off")
    }

    func testStepsMoveInFives() {
        var e = editor()
        e.step(up: true)
        XCTAssertEqual(e.value, 30)
        e.step(up: false)
        XCTAssertEqual(e.value, 25)
        e.step(up: false)
        XCTAssertEqual(e.value, 20)
        e.choose(nil)
        e.step(up: true)
        XCTAssertEqual(e.value, 5, "Off steps up to 5")
        e.step(up: false)
        XCTAssertNil(e.value, "and 5 steps down to Off")
    }

    func testPreviewInPlainWords() {
        var e = editor()
        XCTAssertEqual(e.preview(timeZone: utc), "Page warns at 20% and stops Night Owl at 25% of the week. Resets Mon 09:00.")
        e.setScope(.session)
        e.choose(10)
        XCTAssertEqual(e.preview(timeZone: utc), "Page warns at 8% and stops this session at 10% of the week. Resets Mon 09:00.")
    }

    func testSessionOpTargetsTheSession() {
        var e = editor()
        e.setScope(.session)
        e.choose(10)
        XCTAssertEqual(e.op, BudgetOp(target: .session("s1"), pct: 10))
    }

    func testScopeTitles() {
        XCTAssertEqual(BudgetEditor.Scope.project.title, "Project (all its sessions)")
        XCTAssertEqual(BudgetEditor.Scope.session.title, "This session only")
    }

    func testCaptureOffEditorHasNothingToSave() {
        var e = BudgetEditor(captureOffRowId: "row-s1", sessionId: "s1")
        XCTAssertTrue(e.captureOff)
        XCTAssertNil(e.op)
        e.choose(10)
        XCTAssertFalse(e.changed, "nothing can change while capture is off")
        XCTAssertNil(e.op)
    }

    // MARK: NowStore

    // The panel only keeps an editor whose card it draws (NowKeys.reconcile), so these are the cards
    // of the cards fixture: the In-flight rows for "sess-page" and "sess-llm-play".
    private let page = InFlightRow.idPrefix + "sess-page"
    private let llm = InFlightRow.idPrefix + "sess-llm-play"

    private func store(_ budget: BudgetStatus?) -> (NowStore, () -> [NowEffect]) {
        let inputs = NightWatchFixtures.cardsScene()
        let st = NowStore(model: NowModel.build(inputs), prefs: .ephemeral())
        st.now = { inputs.now }
        st.updateBudget(budget)
        var effects: [NowEffect] = []
        st.perform = { effects.append($0) }
        return (st, { effects })
    }

    private var budgeted: BudgetStatus {
        status(["sess-page": row(used: 21, cap: 25, state: .warn, projectCap: 25), "sess-llm-play": row(used: 3, cap: nil, state: .ok)])
    }

    func testBudgetLineIsForClaudeSessionsOnly() {
        let (st, _) = store(budgeted)
        XCTAssertNotNil(st.budgetLine(sessionId: "sess-page", backend: .claude))
        XCTAssertNil(st.budgetLine(sessionId: "sess-page", backend: .codex))
        XCTAssertNil(store(nil).0.budgetLine(sessionId: "sess-page", backend: .claude), "nothing until the Mac has said")
    }

    func testSetBudgetOpensOneEditorInItsCard() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        XCTAssertEqual(st.budgetEditor?.rowId, page)
        XCTAssertEqual(st.budgetEditor?.value, 25)
        XCTAssertEqual(st.selectedId, page)
        XCTAssertTrue(effects().isEmpty, "opening sends nothing")

        // Another card, nothing changed: the one editor moves there.
        st.clickSetBudget(rowId: llm, sessionId: "sess-llm-play", backend: .claude)
        XCTAssertEqual(st.budgetEditor?.rowId, llm)
        XCTAssertNil(st.budgetEditor?.value, "this session has no cap")
    }

    func testSetBudgetOnTheSameCardCloses() {
        let (st, _) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        XCTAssertNil(st.budgetEditor)
    }

    func testAChangedEditorIsNotThrownAwayByAnotherCard() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        st.setBudgetValue(30)
        st.clickSetBudget(rowId: llm, sessionId: "sess-llm-play", backend: .claude)
        XCTAssertEqual(st.budgetEditor?.rowId, page, "the unsaved change stays")
        XCTAssertEqual(st.budgetEditor?.value, 30)
        XCTAssertTrue(st.notice?.text.contains("Save or cancel your budget change first") == true)
        XCTAssertTrue(effects().isEmpty)
    }

    func testNoEditorWithoutBudgetsOrForAnotherBackend() {
        XCTAssertNil(store(nil).0.budgetEditor)
        let (st, _) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .codex)
        XCTAssertNil(st.budgetEditor)
        st.clickSetBudget(rowId: page, sessionId: "unknown", backend: .claude)
        XCTAssertNil(st.budgetEditor, "a session the Mac doesn't cover has no editor")
    }

    func testSetBudgetClosesAComposerThatHoldsNoText() {
        let (st, _) = store(budgeted)
        st.hoverFlight(page)
        st.handle(NowKeyPress(key: .char("t")))
        XCTAssertNotNil(st.composer, "the composer is open")
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        XCTAssertNil(st.composer, "one editor or composer at a time")
        XCTAssertEqual(st.budgetEditor?.rowId, page)
    }

    func testCancelSendsNothing() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        st.setBudgetValue(30)
        st.cancelBudgetEditor()
        XCTAssertNil(st.budgetEditor)
        XCTAssertTrue(effects().isEmpty)
    }

    func testEscClosesTheEditorAndSendsNothing() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        st.setBudgetValue(30)
        _ = st.handle(NowKeyPress(key: .esc))
        XCTAssertNil(st.budgetEditor)
        XCTAssertTrue(effects().isEmpty, "Esc closes the editor, not the panel")
    }

    func testAKeyUnderTheEditorIsNeverAnApproval() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        _ = st.handle(NowKeyPress(key: .char("1")))
        _ = st.handle(NowKeyPress(key: .char("o")))
        XCTAssertEqual(st.budgetEditor?.rowId, page, "the editor stays open")
        XCTAssertTrue(effects().isEmpty, "a 1 is not an approval under the editor")
    }

    func testSaveProjectBudgetSendsTheProjectOp() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        st.setBudgetValue(30)
        st.saveBudget()
        XCTAssertNil(st.budgetEditor, "Save closes the editor")
        XCTAssertEqual(effects(), [.setBudget(BudgetOp(target: .project("/x/night-owl"), pct: 30))])
    }

    func testReturnSavesToo() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        st.setBudgetValue(50)
        _ = st.handle(NowKeyPress(key: .ret))
        XCTAssertNil(st.budgetEditor)
        XCTAssertEqual(effects(), [.setBudget(BudgetOp(target: .project("/x/night-owl"), pct: 50))])
    }

    func testSaveSessionBudgetSendsTheSessionOp() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        st.setBudgetScope(.session)
        st.setBudgetValue(10)
        st.saveBudget()
        XCTAssertEqual(effects(), [.setBudget(BudgetOp(target: .session("sess-page"), pct: 10))])
    }

    func testSavingOffSendsAClear() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        st.setBudgetValue(nil)
        st.saveBudget()
        XCTAssertEqual(effects(), [.setBudget(BudgetOp(target: .project("/x/night-owl"), pct: nil))])
    }

    func testSavingAnUnchangedBudgetSendsNothing() {
        let (st, effects) = store(budgeted)
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        st.saveBudget()
        XCTAssertNil(st.budgetEditor)
        XCTAssertTrue(effects().isEmpty)
    }

    func testCaptureOffEditorCannotSave() {
        let (st, effects) = store(status(capture: false))
        st.clickSetBudget(rowId: page, sessionId: "sess-page", backend: .claude)
        XCTAssertEqual(st.budgetEditor?.captureOff, true, "it says how to turn usage tracking on")
        st.setBudgetValue(30)
        st.saveBudget()
        XCTAssertNil(st.budgetEditor)
        XCTAssertTrue(effects().isEmpty)
    }
}
