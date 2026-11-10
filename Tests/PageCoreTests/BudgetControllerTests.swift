import XCTest
@testable import PageCore

/// The budget controller (Designs/budget-caps.md §4) against a temp folder: the
/// warning once per window, the cap-reached markers and their files, the Esc
/// once per marker, raises and replies, allow files, session caps, and what a
/// restart and a reset do. Status line files are written with their mtimes set,
/// since the scanner reads those.
final class BudgetControllerTests: XCTestCase {
    private var base: URL!
    private var files: BudgetFiles!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var resets: Date { t0.addingTimeInterval(5 * 86400) }
    private var window: Int { Int(resets.timeIntervalSince1970) }
    /// A folder that doesn't exist, so symlink resolution leaves it as written.
    private let project = "/budgettest-no-such-folder/night-owl"
    private var projectName: String { BudgetProjectKey.displayName(forKey: project) }
    private var h: String { BudgetHash.project(project) }
    private var warnId: String { BudgetPages.pageId(hash: h, kind: .warn, window: window) }
    private var stopId: String { BudgetPages.pageId(hash: h, kind: .stop, window: window) }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("budget-ctl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        files = BudgetFiles(support: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: helpers

    private func ctl() -> BudgetController { BudgetController(files: files) }

    private func config(projects: [String: Int] = [:], defaultPct: Int? = nil) -> BudgetConfig {
        var b = BudgetConfig()
        b.projects = projects
        b.defaultPct = defaultPct
        return b
    }

    private func live(_ sid: String, busy: Bool, cwd: String? = nil) -> BudgetLiveSession {
        BudgetLiveSession(sessionId: sid, cwd: cwd, busy: busy)
    }

    /// Writes a status line file the way the wrapper does, with its mtime set to `at`.
    private func writeStatus(_ sid: String, cwd: String?, cost: Double, week: Double, resets r: Date? = nil, at: Date) {
        var obj: [String: Any] = [
            "session_id": sid,
            "cost": ["total_cost_usd": cost],
            "rate_limits": ["seven_day": ["used_percentage": week, "resets_at": Int((r ?? resets).timeIntervalSince1970)]]
        ]
        if let cwd {
            obj["cwd"] = cwd
            obj["workspace"] = ["project_dir": cwd, "current_dir": cwd]
        }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        try! FileManager.default.createDirectory(at: files.statusline, withIntermediateDirectories: true)
        let url = files.statusline.appendingPathComponent("\(sid).json")
        try! data.write(to: url)
        try! FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
    }

    private func opens(_ effects: [BudgetEffect]) -> [InterventionEvent] {
        effects.compactMap { effect -> InterventionEvent? in
            if case .openPage(let ev) = effect { return ev }
            return nil
        }
    }

    /// The sessions of the over-budget scene: s1 and s4 are busy and covered (s4's ledger key is the
    /// project, with no folder of its own), s2 is idle inside the folder, s3 is in another project.
    private var overLive: [BudgetLiveSession] {
        [live("s1", busy: true, cwd: project),
         live("s2", busy: false, cwd: project + "/sub"),
         live("s3", busy: true, cwd: "/budgettest-no-such-folder/other"),
         live("s4", busy: true)]
    }

    /// Four passes: first sight at 10% of the week, 10 of the rise at 20%, the warning at 30%, and over
    /// at 40% (cap 25 unless `cfg` says otherwise). Returns the controller and the over pass's effects.
    private func overBudget(_ cfg: BudgetConfig? = nil) -> (BudgetController, [BudgetEffect]) {
        let c = ctl()
        let budget = cfg ?? config(projects: [project: 25])
        writeStatus("s1", cwd: project, cost: 0, week: 10, at: t0)
        writeStatus("s4", cwd: project, cost: 0, week: 10, at: t0)
        c.refresh(now: t0, budget: budget, captureOn: true, live: overLive)
        writeStatus("s1", cwd: project, cost: 5, week: 20, at: t0.addingTimeInterval(60))
        c.refresh(now: t0.addingTimeInterval(60), budget: budget, captureOn: true, live: overLive)
        writeStatus("s1", cwd: project, cost: 10, week: 30, at: t0.addingTimeInterval(120))
        c.refresh(now: t0.addingTimeInterval(120), budget: budget, captureOn: true, live: overLive)
        writeStatus("s1", cwd: project, cost: 15, week: 40, at: t0.addingTimeInterval(240))
        let effects = c.refresh(now: t0.addingTimeInterval(240), budget: budget, captureOn: true, live: overLive)
        return (c, effects)
    }

    // MARK: warning

    func testWarnsOnceAtEightyPercentOfTheCap() {
        let c = ctl()
        let cfg = config(projects: [project: 25])
        let busy = [live("s1", busy: true, cwd: project)]
        writeStatus("s1", cwd: project, cost: 0, week: 10, at: t0)
        XCTAssertEqual(c.refresh(now: t0, budget: cfg, captureOn: true, live: busy), [])

        writeStatus("s1", cwd: project, cost: 5, week: 20, at: t0.addingTimeInterval(60))
        XCTAssertEqual(c.refresh(now: t0.addingTimeInterval(60), budget: cfg, captureOn: true, live: busy), [], "10% of 25% is not a warning")

        writeStatus("s1", cwd: project, cost: 10, week: 30, at: t0.addingTimeInterval(120))
        let effects = c.refresh(now: t0.addingTimeInterval(120), budget: cfg, captureOn: true, live: busy)
        XCTAssertEqual(effects.count, 1, "\(effects)")
        let ev = opens(effects).first
        XCTAssertEqual(ev?.id, warnId)
        XCTAssertEqual(ev?.subtype, BudgetPages.warningSubtype)
        XCTAssertEqual(ev?.sessionId, BudgetPages.pageSessionId(hash: h))
        XCTAssertEqual(ev?.context, BudgetPages.warningText(subject: projectName, used: 20, cap: 25))
        XCTAssertEqual(ev?.context, "\(projectName) has used about 20% of the week (budget 25%). Page stops it at 25%.")
        XCTAssertEqual(c.status.project(project)?.used ?? -1, 20, accuracy: 1e-9)

        XCTAssertEqual(c.refresh(now: t0.addingTimeInterval(180), budget: cfg, captureOn: true, live: busy), [], "once per window")
    }

    // MARK: over

    func testOverBudgetWritesMarkersAndInterruptsOnlyTheBusyCoveredSessions() throws {
        let (c, effects) = overBudget()
        XCTAssertEqual(effects.count, 3, "\(effects)")
        XCTAssertEqual(effects[0], .closePage(id: warnId, reason: "resolved"), "the warning gives way to the stop page")
        // s1 and s4 are busy and covered; s2 is covered but idle; s3 is another project.
        XCTAssertEqual(effects[1], .interrupt(sessionIds: ["s1", "s4"]))
        guard case .openPage(let ev) = effects[2] else { return XCTFail("expected the cap-reached page") }
        XCTAssertEqual(ev.id, stopId)
        XCTAssertEqual(ev.subtype, BudgetPages.reachedSubtype)
        XCTAssertEqual(ev.context, BudgetPages.reachedText(subject: projectName, used: 30, cap: 25, stopped: 2))
        XCTAssertEqual(ev.context, "\(projectName) reached its budget: about 30% of the week (budget 25%). Page stopped 2 sessions.")

        XCTAssertEqual(files.markerHashes(), [h])
        let gate = try String(contentsOf: files.overDirectory.appendingPathComponent(h + ".gate"), encoding: .utf8)
        let lines = gate.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 5, "four key=value lines and a trailing newline: \(lines)")
        XCTAssertEqual(lines[0], "project=\(project)")
        XCTAssertEqual(lines[1], "session=")
        XCTAssertEqual(lines[2], "expires=\(window)")
        XCTAssertTrue(lines[3].hasPrefix("stop={\"continue\":false,\"stopReason\":\"Page: \(projectName) reached its budget (25% of the week). "
                                        + "Raise it in Page, or wait for the reset on "), lines[3])
        XCTAssertEqual(lines[4], "")
        let stopJSON = try JSONSerialization.jsonObject(with: Data(lines[3].dropFirst("stop=".count).utf8)) as? [String: Any]
        XCTAssertEqual(stopJSON?["continue"] as? Bool, false)

        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: files.overDirectory.appendingPathComponent(h + ".json"))) as? [String: Any]
        XCTAssertEqual(marker?["project"] as? String, project)
        XCTAssertTrue(marker?["session"] is NSNull)
        XCTAssertEqual(marker?["name"] as? String, projectName)
        XCTAssertEqual(marker?["cap"] as? Int, 25)
        XCTAssertEqual(marker?["used"] as? Double, 30)
        XCTAssertEqual(marker?["expiresAt"] as? Int, window)

        XCTAssertEqual(c.openPageIds, [stopId])
        XCTAssertEqual(c.state.markers[h]?.affected, ["s1", "s4"])
    }

    func testTheSameOverBudgetIsNotInterruptedAgain() {
        let (c, _) = overBudget()
        let again = c.refresh(now: t0.addingTimeInterval(300), budget: config(projects: [project: 25]), captureOn: true, live: overLive)
        XCTAssertEqual(again, [], "Esc is sent once per marker")
    }

    func testRaisingTheCapPastUsedClosesThePageAndRemovesTheMarker() {
        let (c, _) = overBudget()
        let effects = c.reevaluate(now: t0.addingTimeInterval(300), budget: config(projects: [project: 35]), captureOn: true, live: overLive)
        XCTAssertEqual(effects, [.closePage(id: stopId, reason: "resolved")],
                       "30% is still a warning at 35%, and that one was already sent, so nothing reopens")
        XCTAssertEqual(files.markerHashes(), [])
        XCTAssertEqual(c.openPageIds, [])
        XCTAssertTrue(c.state.isEmpty)
    }

    func testWindowResetClosesThePageAndRemovesTheMarker() {
        let (c, _) = overBudget()
        let next = resets.addingTimeInterval(7 * 86400)
        writeStatus("s1", cwd: project, cost: 15, week: 5, resets: next, at: t0.addingTimeInterval(400))
        let effects = c.refresh(now: t0.addingTimeInterval(400), budget: config(projects: [project: 25]), captureOn: true, live: overLive)
        XCTAssertEqual(effects, [.closePage(id: stopId, reason: "resolved")])
        XCTAssertEqual(c.ledger.startPct, 5)
        XCTAssertEqual(c.ledger.resetsAt, next)
        XCTAssertEqual(c.status.project(project)?.used, 0)
        XCTAssertEqual(files.markerHashes(), [])
    }

    func testRestartKeepsTheMarkerAndRereadingTheSameFilesAddsNothing() {
        _ = overBudget()
        let c2 = ctl()
        let effects = c2.refresh(now: t0.addingTimeInterval(300), budget: config(projects: [project: 25]), captureOn: true, live: overLive)
        XCTAssertEqual(effects, [], "nothing is paged or interrupted again after a restart")
        XCTAssertEqual(c2.openPageIds, [stopId])
        XCTAssertEqual(c2.ledger.used(project: project), 30, accuracy: 1e-9, "the same files don't count twice")
        XCTAssertEqual(files.markerHashes(), [h])
    }

    func testLedgerIsSavedAndReadBack() {
        let (c, _) = overBudget()
        XCTAssertEqual(ctl().ledger, c.ledger)
    }

    func testCaptureOffClosesEverythingAndRemovesTheFiles() {
        let (c, _) = overBudget()
        let effects = c.refresh(now: t0.addingTimeInterval(300), budget: config(projects: [project: 25]), captureOn: false, live: overLive)
        XCTAssertEqual(effects, [.closePage(id: stopId, reason: "resolved")])
        XCTAssertEqual(files.markerHashes(), [])
        XCTAssertEqual(c.status, BudgetStatus.off)
        XCTAssertTrue(c.state.isEmpty)
    }

    func testNothingIsEnforcedWhileMeasuring() {
        let c = ctl()
        let cfg = config(projects: [project: 1])
        let busy = [live("s1", busy: true, cwd: project)]
        writeStatus("s1", cwd: project, cost: 0, week: 10, at: t0)
        c.refresh(now: t0, budget: cfg, captureOn: true, live: busy)
        writeStatus("s1", cwd: project, cost: 4, week: 10.5, at: t0.addingTimeInterval(60))
        let effects = c.refresh(now: t0.addingTimeInterval(60), budget: cfg, captureOn: true, live: busy)
        XCTAssertEqual(effects, [], "a rise under 1 point shares nothing out, so no cap can trigger")
        XCTAssertTrue(c.status.measuring)
        XCTAssertEqual(files.markerHashes(), [])
    }

    func testDefaultCapEnforcesEveryProjectWithoutItsOwn() {
        let (c, effects) = overBudget(config(defaultPct: 25))
        XCTAssertEqual(opens(effects).first?.context, BudgetPages.reachedText(subject: projectName, used: 30, cap: 25, stopped: 2))
        XCTAssertEqual(c.state.markers[h]?.cap, 25)
    }

    func testLiveSessionInTheProjectRootGetsARowBeforeItsFirstStatusLine() {
        let c = ctl()
        c.refresh(now: t0, budget: config(projects: [project: 25]), captureOn: true, live: [live("s9", busy: true, cwd: project)])
        let row = c.status.sessions["s9"]
        XCTAssertEqual(row?.projectKey, project)
        XCTAssertEqual(row?.used, 0)
        XCTAssertEqual(row?.cap, 25)
        XCTAssertEqual(c.status.capture, true)
    }

    func testAStaleStatusFileIsNotCounted() {
        let c = ctl()
        writeStatus("s6", cwd: project, cost: 3, week: 10, at: t0.addingTimeInterval(-7 * 3600))
        c.refresh(now: t0, budget: config(), captureOn: true, live: [])
        XCTAssertNil(c.ledger.sessions["s6"])
    }

    // MARK: session caps

    func testSessionCapStopsOnlyThatSession() throws {
        let c = ctl()
        c.setSessionCap("s1", pct: 10, now: t0)
        c.setSessionCap("bad id", pct: 5, now: t0)
        XCTAssertEqual(ctl().sessionCaps.caps, ["s1": 10], "saved, read back, and a bad id is refused")

        let busy = [live("s1", busy: true, cwd: project)]
        writeStatus("s1", cwd: project, cost: 0, week: 10, at: t0)
        c.refresh(now: t0, budget: config(), captureOn: true, live: busy)
        writeStatus("s1", cwd: project, cost: 5, week: 20, at: t0.addingTimeInterval(60))
        let effects = c.refresh(now: t0.addingTimeInterval(60), budget: config(), captureOn: true, live: busy)
        XCTAssertEqual(effects.count, 2, "\(effects)")
        XCTAssertEqual(effects[0], .interrupt(sessionIds: ["s1"]))
        let ev = opens(effects).first
        XCTAssertEqual(ev?.id, BudgetPages.pageId(hash: BudgetHash.session("s1"), kind: .stop, window: window))
        XCTAssertEqual(ev?.sessionId, "page-budget-" + BudgetHash.session("s1"))
        XCTAssertEqual(ev?.context, BudgetPages.reachedText(subject: "A session in \(projectName)", used: 10, cap: 10, stopped: 1))

        let gate = try String(contentsOf: files.overDirectory.appendingPathComponent(BudgetHash.session("s1") + ".gate"), encoding: .utf8)
        XCTAssertTrue(gate.hasPrefix("project=\nsession=s1\nexpires=\(window)\n"), gate)
        XCTAssertTrue(gate.contains("Page: this session reached its budget (10% of the week)."), gate)

        // Clearing the session cap lifts its marker and closes its page.
        c.setSessionCap("s1", pct: nil, now: t0)
        XCTAssertEqual(ctl().sessionCaps.caps, [:])
        let lifted = c.refresh(now: t0.addingTimeInterval(120), budget: config(), captureOn: true, live: busy)
        XCTAssertEqual(lifted, [.closePage(id: ev?.id ?? "", reason: "resolved")])
        XCTAssertEqual(files.markerHashes(), [])
    }

    // MARK: pages and replies

    func testApproveRaisesTheCapByTenAndNamesTheProject() {
        let (c, _) = overBudget()
        guard let plan = c.plan(pageId: stopId, action: "approve", text: "", live: overLive) else { return XCTFail("the page is open") }
        XCTAssertEqual(plan.decision, .raise)
        XCTAssertEqual(plan.kind, .stop)
        XCTAssertEqual(plan.hash, h)
        XCTAssertEqual(plan.name, projectName)
        XCTAssertEqual(plan.target, .project(project))
        XCTAssertEqual(plan.currentCap, 25)
        XCTAssertEqual(plan.raisedCap, 35)
        XCTAssertEqual(plan.affected, ["s1", "s4"])
        XCTAssertEqual(Set(plan.covered), ["s1", "s2", "s4"], "the busy and idle sessions the marker covers, not s3")
        XCTAssertEqual(plan.openedAt, t0.addingTimeInterval(240))
    }

    func testApproveOnADefaultCapTargetsTheProjectAndRaisesTheDefault() {
        let (c, _) = overBudget(config(defaultPct: 25))
        guard let plan = c.plan(pageId: stopId, action: "approve", text: "", live: overLive) else { return XCTFail("the page is open") }
        XCTAssertEqual(plan.target, .project(project), "the raise becomes the project's own cap")
        XCTAssertEqual(plan.currentCap, 25, "the default in force")
        XCTAssertEqual(plan.raisedCap, 35)
    }

    func testAHundredPercentBudgetCannotBeRaised() {
        let c = ctl()
        let busy = [live("s1", busy: true, cwd: project)]
        writeStatus("s1", cwd: project, cost: 0, week: 0, at: t0)
        c.refresh(now: t0, budget: config(projects: [project: 100]), captureOn: true, live: busy)
        writeStatus("s1", cwd: project, cost: 10, week: 100, at: t0.addingTimeInterval(60))
        let effects = c.refresh(now: t0.addingTimeInterval(60), budget: config(projects: [project: 100]), captureOn: true, live: busy)
        XCTAssertTrue(opens(effects).contains { $0.subtype == BudgetPages.reachedSubtype })
        let plan = c.plan(pageId: BudgetPages.pageId(hash: h, kind: .stop, window: window), action: "approve", text: "", live: busy)
        XCTAssertEqual(plan?.currentCap, 100)
        XCTAssertNil(plan?.raisedCap, "at most 100")
    }

    func testStaleAndForeignPageIdsAreRejected() {
        let (c, _) = overBudget()
        XCTAssertNil(c.plan(pageId: "page-budget-0000000000000000-stop-\(window)", action: "approve", text: "", live: overLive))
        XCTAssertNil(c.plan(pageId: BudgetPages.pageId(hash: h, kind: .stop, window: window - 1), action: "approve", text: "", live: overLive),
                     "an earlier week's page")
        XCTAssertNil(c.plan(pageId: "some-other-page", action: "approve", text: "", live: overLive))
        XCTAssertNil(c.plan(pageId: warnId, action: "approve", text: "", live: overLive), "no warning is open any more")

        c.pageAnswered(hash: h, kind: .stop)
        XCTAssertNil(c.plan(pageId: stopId, action: "approve", text: "", live: overLive), "answered without a raise")
        XCTAssertEqual(c.openPageIds, [])
        XCTAssertEqual(files.markerHashes(), [h], "the marker stays while the budget is over")
    }

    func testDenyAndTypedTextKeepItStopped() {
        let (c, _) = overBudget()
        XCTAssertEqual(c.plan(pageId: stopId, action: "deny", text: "", live: overLive)?.decision, .keepStopped)
        XCTAssertEqual(c.plan(pageId: stopId, action: nil, text: "1", live: overLive)?.decision, .keepStopped, "a typed 1 is not an approval")
        XCTAssertEqual(c.plan(pageId: stopId, action: nil, text: "approve", live: overLive)?.decision, .keepStopped)
    }

    func testCarryOnPlanNamesTheSessionsThatWerePaused() {
        let (c, _) = overBudget()
        guard let plan = c.plan(pageId: stopId, action: "carry_on", text: "", live: overLive) else { return XCTFail("the page is open") }
        XCTAssertEqual(plan.decision, .carryOn)
        let paused = c.pausedSessions(plan.affected, plan: plan, live: overLive, now: t0.addingTimeInterval(300))
        XCTAssertEqual(paused.map(\.sessionId), ["s1", "s4"])
        XCTAssertEqual(paused.first?.detail, "Stopped at its budget")
        XCTAssertEqual(paused.first?.pausedAt, t0.addingTimeInterval(240))
        XCTAssertEqual(paused.first?.cwd, project)
        XCTAssertEqual(paused.first?.projectName, projectName)
        XCTAssertEqual(paused.first?.backend, .claude)
    }

    func testWarningPlanRaisesFromTheBindingCapAndClosesOnAnyOtherReply() {
        let c = ctl()
        let cfg = config(projects: [project: 25])
        let busy = [live("s1", busy: true, cwd: project)]
        writeStatus("s1", cwd: project, cost: 0, week: 10, at: t0)
        c.refresh(now: t0, budget: cfg, captureOn: true, live: busy)
        writeStatus("s1", cwd: project, cost: 5, week: 20, at: t0.addingTimeInterval(60))
        c.refresh(now: t0.addingTimeInterval(60), budget: cfg, captureOn: true, live: busy)
        writeStatus("s1", cwd: project, cost: 10, week: 30, at: t0.addingTimeInterval(120))
        c.refresh(now: t0.addingTimeInterval(120), budget: cfg, captureOn: true, live: busy)

        guard let plan = c.plan(pageId: warnId, action: "approve", text: "", live: busy) else { return XCTFail("the warning is open") }
        XCTAssertEqual(plan.kind, .warn)
        XCTAssertEqual(plan.decision, .raise)
        XCTAssertEqual(plan.currentCap, 25)
        XCTAssertEqual(plan.raisedCap, 35)

        c.pageAnswered(hash: h, kind: .warn)
        XCTAssertNil(c.plan(pageId: warnId, action: "approve", text: "", live: busy))
        XCTAssertEqual(c.openPageIds, [])
        XCTAssertEqual(c.refresh(now: t0.addingTimeInterval(180), budget: cfg, captureOn: true, live: busy), [],
                       "answered, so the warning doesn't come back this window")
    }

    // MARK: allow files

    func testCarryOnAllowsTheTurnUntilItStopsAgain() {
        let (c, _) = overBudget()
        let now = t0.addingTimeInterval(300)
        guard let plan = c.plan(pageId: stopId, action: "carry_on", text: "", live: overLive) else { return XCTFail("the page is open") }
        c.allowSessions(plan.affected, now: now, live: overLive)
        XCTAssertEqual(files.allowNames(), ["s1", "s4"])
        XCTAssertEqual(c.state.allow["s1"]?.sawBusy, true)

        // Still working: nothing is interrupted and the allow stays.
        XCTAssertEqual(c.refresh(now: now.addingTimeInterval(10), budget: config(projects: [project: 25]), captureOn: true, live: overLive), [])
        XCTAssertEqual(files.allowNames(), ["s1", "s4"])

        // It has worked and stopped: the allow ends, so its next turn is gated.
        let idle = overLive.map { live($0.sessionId, busy: false, cwd: $0.cwd) }
        c.refresh(now: now.addingTimeInterval(400), budget: config(projects: [project: 25]), captureOn: true, live: idle)
        XCTAssertEqual(files.allowNames(), [])
        XCTAssertEqual(c.state.allow, [:])
        XCTAssertEqual(c.openPageIds, [stopId], "the page itself stays until it is answered")
    }

    func testAllowEndsAfterThirtyMinutesIfTheSessionNeverGotGoing() {
        let (c, _) = overBudget()
        let now = t0.addingTimeInterval(300)
        let idle2 = [live("s2", busy: false, cwd: project + "/sub")]
        c.allowSessions(["s2"], now: now, live: idle2)
        XCTAssertEqual(files.allowNames(), ["s2"])
        c.refresh(now: now.addingTimeInterval(29 * 60), budget: config(projects: [project: 25]), captureOn: true, live: idle2)
        XCTAssertEqual(files.allowNames(), ["s2"], "still inside its 30 minutes")
        c.refresh(now: now.addingTimeInterval(31 * 60), budget: config(projects: [project: 25]), captureOn: true, live: idle2)
        XCTAssertEqual(files.allowNames(), [])
    }

    func testAllowEndsWhenItsSessionIsGone() {
        let (c, _) = overBudget()
        c.allowSessions(["s1"], now: t0.addingTimeInterval(300), live: overLive)
        c.refresh(now: t0.addingTimeInterval(310), budget: config(projects: [project: 25]), captureOn: true, live: [live("s4", busy: true)])
        XCTAssertEqual(files.allowNames(), [])
    }

    func testAllowRejectsUnusableSessionIds() {
        let c = ctl()
        c.allowSessions(["bad id", "../x", ""], now: t0, live: [])
        XCTAssertEqual(files.allowNames(), [])
        XCTAssertEqual(c.state.allow, [:])
    }
}
