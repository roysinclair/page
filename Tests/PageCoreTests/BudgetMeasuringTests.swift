import XCTest
@testable import PageCore

/// The work so far, while measuring (Designs/budget-caps.md §2, "The work so far, while measuring"):
/// the share of the spend each project and session has, shown while the week is still being measured.
/// Covers the estimate, the status rows, the wire keys, the words and the Mac's budget line.
final class BudgetMeasuringTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var resets: Date { t0.addingTimeInterval(5 * 86400) }

    /// The week opens at 10%, then rises to 10% + `rise` once each session has spent its dollars.
    /// Spends: s1 $3 and s2 $1 in /x/a, s3 $4 in /x/b (total $8).
    private let spends: [(sid: String, project: String, dollars: Double)] = [("s1", "/x/a", 3), ("s2", "/x/a", 1), ("s3", "/x/b", 4)]

    private func ledger(rise: Double, spends: [(sid: String, project: String, dollars: Double)]? = nil) -> BudgetLedger {
        let spends = spends ?? self.spends
        var l = BudgetLedger()
        var at = t0
        for s in spends {
            l.observe(BudgetSample(sessionId: s.sid, projectKey: s.project, cost: 0, weekPct: 10, resetsAt: resets, at: at),
                      now: at, name: { BudgetProjectKey.lastComponent($0) })
            at = at.addingTimeInterval(1)
        }
        for s in spends {
            at = at.addingTimeInterval(60)
            l.observe(BudgetSample(sessionId: s.sid, projectKey: s.project, cost: s.dollars, weekPct: 10 + rise, resetsAt: resets, at: at),
                      now: at, name: { BudgetProjectKey.lastComponent($0) })
        }
        return l
    }

    private func status(_ l: BudgetLedger, caps: BudgetCaps = BudgetCaps(projects: ["/x/a": 25]),
                        live: [String: String] = [:]) -> BudgetStatus {
        BudgetStatus.build(ledger: l, caps: caps, capture: true, live: live)
    }

    private func assertNear(_ a: Double?, _ b: Double, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil, expected \(b). \(message)", file: file, line: line) }
        XCTAssertEqual(a, b, accuracy: 1e-9, message, file: file, line: line)
    }

    // MARK: measuring or not

    func testMeasuringUntilTheRiseIsAPoint() {
        XCTAssertTrue(BudgetEstimate(rise: 0, total: 10, hasWeek: true).measuring)
        XCTAssertTrue(BudgetEstimate(rise: 0.9, total: 10, hasWeek: true).measuring)
        XCTAssertFalse(BudgetEstimate(rise: 1.0, total: 10, hasWeek: true).measuring)

        XCTAssertTrue(ledger(rise: 0).estimate.measuring)
        XCTAssertTrue(ledger(rise: 0.9).estimate.measuring)
        XCTAssertFalse(ledger(rise: 1.0).estimate.measuring)
    }

    func testWorkIsThereWhileMeasuringAndGoneAfter() {
        let measuring = ledger(rise: 0.5)
        assertNear(measuring.work(project: "/x/a"), 50)
        XCTAssertNotNil(status(measuring).project("/x/a")?.work)

        let done = ledger(rise: 1.0)
        XCTAssertNil(done.work(project: "/x/a"), "no work share once the week has risen a point")
        XCTAssertNil(done.work(session: "s1"))
        XCTAssertNil(status(done).project("/x/a")?.work)
        XCTAssertEqual(status(done).project("/x/a")?.used ?? -1, 0.5, accuracy: 1e-9, "used takes over: a rise of 1 × 4/8")
    }

    // MARK: nothing to show

    func testNoWorkWithoutATotalOrASpend() {
        XCTAssertNil(BudgetEstimate(rise: 0.5, total: 0, hasWeek: true).workShare(of: 5), "no total, no share")
        XCTAssertNil(BudgetEstimate(rise: 0.5, total: 0, hasWeek: true).workShare(of: 0))
        XCTAssertNil(BudgetEstimate(rise: 0.5, total: 10, hasWeek: true).workShare(of: 0), "no spend, no share")
        XCTAssertNil(BudgetEstimate(rise: 0.5, total: 10, hasWeek: true).workShare(of: -2))

        let idle = ledger(rise: 0.5, spends: [("s1", "/x/a", 0)])
        XCTAssertNil(idle.work(project: "/x/a"), "zero spend this window")
        XCTAssertNil(idle.work(session: "s1"))
        XCTAssertNil(ledger(rise: 0.5).work(session: "unknown"))
        XCTAssertNil(ledger(rise: 0.5).work(project: "/x/none"))
    }

    // MARK: the share

    func testWorkShareIsSpendOverTotal() {
        let e = BudgetEstimate(rise: 0.5, total: 8, hasWeek: true)
        assertNear(e.workShare(of: 3), 37.5)
        assertNear(e.workShare(of: 4), 50)
        assertNear(e.workShare(of: 8), 100, "all the spend is all the work")
        assertNear(e.workShare(of: 0.01), 0.125)
    }

    func testWorkShareIsClampedTo0Through100() {
        XCTAssertEqual(BudgetEstimate(rise: 0.5, total: 8, hasWeek: true).workShare(of: 20), 100, "spend above the total")
        XCTAssertEqual(BudgetEstimate(rise: -3, total: 8, hasWeek: true).workShare(of: 4), 50, "a negative rise is still measuring")
    }

    func testSharesSumAcrossProjects() {
        let l = ledger(rise: 0.5)
        assertNear(l.work(project: "/x/a"), 50)
        assertNear(l.work(project: "/x/b"), 50)
        assertNear(l.work(project: "/x/a").map { $0 + (l.work(project: "/x/b") ?? 0) }, 100, "the projects' shares add to 100")
        assertNear(l.work(session: "s1"), 37.5)
        assertNear(l.work(session: "s2"), 12.5)
        assertNear(l.work(session: "s1").map { $0 + (l.work(session: "s2") ?? 0) }, 50, "a project's sessions add to its share")
    }

    // MARK: rows and scope

    func testRowWorkIsTheProjectsWhenTheProjectsCapBinds() {
        // Both caps are at 0 used while measuring, so the lower cap wins the tie: a session cap of 30 loses to the project's 25.
        let st = status(ledger(rise: 0.5), caps: BudgetCaps(projects: ["/x/a": 25], sessions: ["s1": 30]))
        XCTAssertEqual(st.sessions["s1"]?.scope, .project)
        assertNear(st.sessions["s1"]?.work, 50, "the project's share, not the session's")
    }

    func testRowWorkIsTheSessionsWhenTheSessionCapBinds() {
        let st = status(ledger(rise: 0.5), caps: BudgetCaps(projects: ["/x/a": 25], sessions: ["s1": 3]))
        XCTAssertEqual(st.sessions["s1"]?.scope, .session, "a lower session cap binds on the tie")
        assertNear(st.sessions["s1"]?.work, 37.5, "the session's own share")
        assertNear(st.sessions["s2"]?.work, 50, "a session with no cap of its own shows its project's")
        XCTAssertEqual(st.sessions["s2"]?.scope, .project)
        assertNear(st.sessions["s3"]?.work, 50, "/x/b's share")
    }

    func testRowWithNoCapsStillShowsTheProjectsShare() {
        let st = status(ledger(rise: 0.5), caps: BudgetCaps())
        XCTAssertEqual(st.sessions["s3"]?.scope, .project)
        assertNear(st.sessions["s3"]?.work, 50)
        assertNear(st.sessions["s1"]?.work, 50, "the project's, since no session cap")
    }

    func testLiveSessionWithNoLedgerEntryGetsItsProjectsShare() {
        let st = status(ledger(rise: 0.5), live: ["s9": "/x/a"])
        let row = st.sessions["s9"]
        XCTAssertEqual(row?.projectKey, "/x/a")
        XCTAssertEqual(row?.sessionUsed, 0)
        assertNear(row?.work, 50, "the folder's project, which has spend")
        XCTAssertNotNil(st.rowWire(sessionId: "s9")?["work"], "the row carries the project's work")
    }

    func testLiveSessionInAProjectWithNoSpendHasNoWork() {
        let st = status(ledger(rise: 0.5), caps: BudgetCaps(projects: ["/x/c": 10]), live: ["s9": "/x/c"])
        XCTAssertNil(st.sessions["s9"]?.work)
        XCTAssertNil(st.rowWire(sessionId: "s9")?["work"])
    }

    // MARK: wire

    func testWireKeysArePresentWhileMeasuring() {
        let st = status(ledger(rise: 0.5), caps: BudgetCaps(projects: ["/x/a": 25], sessions: ["s1": 3]))
        let projects = st.headerWire["projects"] as? [[String: Any]] ?? []
        let a = projects.first { $0["key"] as? String == "/x/a" }
        XCTAssertEqual(a?["work"] as? Double, 50)
        XCTAssertEqual((projects.first { $0["key"] as? String == "/x/b" })?["work"] as? Double, 50)

        let row = st.rowWire(sessionId: "s1")
        XCTAssertEqual(row?["scope"] as? String, "session")
        XCTAssertEqual(row?["work"] as? Double, 37.5, "the binding session's share")
        XCTAssertEqual(st.rowWire(sessionId: "s3")?["work"] as? Double, 50)
    }

    func testWireKeysAreAbsentAfterMeasuring() {
        let st = status(ledger(rise: 1.0), caps: BudgetCaps(projects: ["/x/a": 25], sessions: ["s1": 3]))
        XCTAssertEqual(st.headerWire["measuring"] as? Bool, false)
        for p in st.headerWire["projects"] as? [[String: Any]] ?? [] {
            XCTAssertNil(p["work"], "no work key for \(p["key"] ?? "")")
        }
        XCTAssertNil(st.rowWire(sessionId: "s1")?["work"])
        XCTAssertNil(st.rowWire(sessionId: "s3")?["work"])
    }

    func testWireKeyAbsentWhenProjectHasNoWorkYet() {
        let st = status(ledger(rise: 0.5), caps: BudgetCaps(projects: ["/x/c": 10]))
        let projects = st.headerWire["projects"] as? [[String: Any]] ?? []
        let c = projects.first { $0["key"] as? String == "/x/c" }
        XCTAssertNotNil(c, "a capped project with no spend is listed")
        XCTAssertNil(c?["work"], "and carries no work key while it has none")
    }

    func testWorkWireEdges() {
        XCTAssertEqual(BudgetStatus.workWire(0.01), 0.1, "never 0 for a share above 0")
        XCTAssertEqual(BudgetStatus.workWire(0.04), 0.1)
        XCTAssertEqual(BudgetStatus.workWire(63.44), 63.4, "one decimal")
        XCTAssertEqual(BudgetStatus.workWire(63.46), 63.5)
        XCTAssertEqual(BudgetStatus.workWire(0), 0)
        XCTAssertEqual(BudgetStatus.workWire(-4), 0, "below 0 is 0")
        XCTAssertEqual(BudgetStatus.workWire(100), 100)
    }

    // MARK: words

    func testFixedCopy() {
        XCTAssertEqual(BudgetCopy.measuring,
                       "Measuring until the week rises one whole point. Meanwhile each project shows its share of the work so far.")
        XCTAssertEqual(BudgetCopy.measuringPlain, "Measuring…")
        XCTAssertEqual(BudgetCopy.measuringHelp,
                       "Its share of the work this week's sessions have done so far. It becomes a share of your week once the week has risen one whole point.")
    }

    func testWorkPercentWords() {
        XCTAssertEqual(BudgetCopy.workPct(63), "63%")
        XCTAssertEqual(BudgetCopy.workPct(63.44), "63%")
        XCTAssertEqual(BudgetCopy.workPct(0.4), "<1%")
        XCTAssertEqual(BudgetCopy.workPct(0.01), "<1%")
        XCTAssertEqual(BudgetCopy.workPct(10.5), "11%", "halves round up")
        XCTAssertEqual(BudgetCopy.workPct(99.6), "100%")
        XCTAssertEqual(BudgetCopy.workPct(100), "100%")
        XCTAssertEqual(BudgetCopy.workPct(140), "100%", "capped at 100")
    }

    func testWorkPercentIsNilWithNoWork() {
        XCTAssertNil(BudgetCopy.workPct(nil))
        XCTAssertNil(BudgetCopy.workPct(0))
        XCTAssertNil(BudgetCopy.workPct(-1))
        XCTAssertNil(BudgetCopy.workPct(.nan))
        XCTAssertNil(BudgetCopy.workPct(.infinity))
    }

    func testMeasuringLongAndShortWords() {
        XCTAssertEqual(BudgetCopy.measuringLong(work: 63), "Measuring · 63% of the work so far")
        XCTAssertEqual(BudgetCopy.measuringShort(work: 63), "Measuring · 63% of work")
        XCTAssertEqual(BudgetCopy.measuringLong(work: 0.4), "Measuring · <1% of the work so far")
        XCTAssertEqual(BudgetCopy.measuringShort(work: 99.6), "Measuring · 100% of work")
        XCTAssertEqual(BudgetCopy.measuringLong(work: nil), "Measuring…")
        XCTAssertEqual(BudgetCopy.measuringLong(work: 0), "Measuring…")
        XCTAssertEqual(BudgetCopy.measuringShort(work: nil), "Measuring…")
        XCTAssertEqual(BudgetCopy.measuringShort(work: 0), "Measuring…")
    }

    // MARK: the Budget page's board

    func testBoardRowsCarryWorkOnlyWhileMeasuring() {
        let measuring = status(ledger(rise: 0.5)).board(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(measuring.measuring)
        XCTAssertTrue(measuring.captureOn)
        XCTAssertEqual(measuring.rows.first { $0.key == "/x/a" }?.work, 50)
        XCTAssertEqual(measuring.rows.first { $0.key == "/x/a" }?.cap, 25)

        let done = status(ledger(rise: 1.0)).board(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertFalse(done.measuring)
        XCTAssertTrue(done.rows.allSatisfy { $0.work == nil })
    }

    func testBoardWithCaptureOffSaysSo() {
        let board = BudgetStatus.off.board()
        XCTAssertFalse(board.captureOn)
        XCTAssertTrue(board.rows.isEmpty)
    }
}

/// The Mac's budget line on a session card while measuring (NowBudgetLine is pure, in PageCore).
final class NowBudgetMeasuringTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var resets: Date { t0.addingTimeInterval(5 * 86400) }

    /// The week opens at 10% and rises by `rise`. s1 $3 and s2 $1 in /x/a; s3 $4 in /x/b.
    private func status(rise: Double, caps: BudgetCaps = BudgetCaps(projects: ["/x/a": 25]), live: [String: String] = [:]) -> BudgetStatus {
        var l = BudgetLedger()
        let spends: [(String, String, Double)] = [("s1", "/x/a", 3), ("s2", "/x/a", 1), ("s3", "/x/b", 4)]
        var at = t0
        for s in spends {
            l.observe(BudgetSample(sessionId: s.0, projectKey: s.1, cost: 0, weekPct: 10, resetsAt: resets, at: at), now: at, name: { _ in "Night Owl" })
            at = at.addingTimeInterval(1)
        }
        for s in spends {
            at = at.addingTimeInterval(60)
            l.observe(BudgetSample(sessionId: s.0, projectKey: s.1, cost: s.2, weekPct: 10 + rise, resetsAt: resets, at: at),
                      now: at, name: { _ in "Night Owl" })
        }
        return BudgetStatus.build(ledger: l, caps: caps, capture: true, live: live)
    }

    func testMeasuringLineShowsTheShareOfWork() {
        let line = NowBudgetLine.build(status: status(rise: 0.5), sessionId: "s1")
        XCTAssertEqual(line?.measuring, true)
        XCTAssertEqual(line?.text, "Measuring · 50% of work", "s1's project share (no session cap)")
        XCTAssertEqual(line?.work, 50)
        XCTAssertEqual(line?.help, BudgetCopy.measuringHelp)
        XCTAssertEqual(line?.accessibilityText, "Budget, Measuring · 50% of the work so far")
        XCTAssertEqual(line?.fraction, 0, "the bar is empty: work never fills it")
        XCTAssertEqual(line?.hasBudget, false)
        XCTAssertEqual(line?.warm, false)
        XCTAssertEqual(line?.state, .ok)
    }

    func testMeasuringLineForASessionCapShowsTheSessionsShare() {
        let line = NowBudgetLine.build(status: status(rise: 0.5, caps: BudgetCaps(projects: ["/x/a": 25], sessions: ["s1": 3])), sessionId: "s1")
        XCTAssertEqual(line?.text, "Measuring · 38% of work", "37.5 rounds to 38")
        XCTAssertEqual(line?.work ?? -1, 37.5, accuracy: 1e-9)
    }

    func testMeasuringWithNoWorkYetIsPlain() {
        let line = NowBudgetLine.build(status: status(rise: 0.5, caps: BudgetCaps(projects: ["/x/c": 10]), live: ["s9": "/x/c"]), sessionId: "s9")
        XCTAssertEqual(line?.measuring, true)
        XCTAssertNil(line?.work)
        XCTAssertEqual(line?.text, "Measuring…")
        XCTAssertEqual(line?.accessibilityText, "Budget, Measuring…")
        XCTAssertEqual(line?.help, BudgetCopy.measuringHelp, "the help goes whenever measuring")
    }

    func testNotMeasuringLineIsTheBudgetAsBefore() {
        let line = NowBudgetLine.build(status: status(rise: 4), sessionId: "s1")
        XCTAssertEqual(line?.measuring, false)
        XCTAssertNil(line?.work)
        XCTAssertEqual(line?.text, "2% of 25%", "/x/a spent $4 of $8: a rise of 4 gives it 4 × 4/8 = 2")
        XCTAssertNil(line?.help)
        XCTAssertEqual(line?.accessibilityText, "Budget, 2% of 25%")
        XCTAssertEqual(line?.hasBudget, true)
    }

    func testCaptureOffHasNoHelpEvenWhenMeasuring() {
        let off = BudgetStatus(capture: false, measuring: true, weekPct: nil, resetsAt: nil, defaultCap: nil, projects: [], sessions: [:])
        let line = NowBudgetLine.build(status: off, sessionId: "s1")
        XCTAssertEqual(line?.captureOn, false)
        XCTAssertNil(line?.help)
        XCTAssertEqual(line?.accessibilityText, "Budget, usage tracking is off")
    }
}
