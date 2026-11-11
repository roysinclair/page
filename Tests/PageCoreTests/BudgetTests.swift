import XCTest
@testable import PageCore

/// The pure part of budget caps (Designs/budget-caps.md §2–§5): the ledger and its
/// estimate, the caps and which one binds, the words, the page texts, the gate's
/// file formats, and the phone's `budget` op as it arrives on the wire.
final class BudgetStateAndCopyTests: XCTestCase {
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }

    func testStateEdges() {
        XCTAssertEqual(BudgetState(used: 500, cap: nil), .ok, "no cap is always ok")
        XCTAssertEqual(BudgetState(used: 500, cap: 0), .ok, "a zero cap is no cap")
        XCTAssertEqual(BudgetState(used: 19.99, cap: 25), .ok)
        XCTAssertEqual(BudgetState(used: 20, cap: 25), .warn, "warns from 80% of the cap, inclusive")
        XCTAssertEqual(BudgetState(used: 24.99, cap: 25), .warn)
        XCTAssertEqual(BudgetState(used: 25, cap: 25), .over, "at the cap is over")
        XCTAssertEqual(BudgetState(used: 79.99, cap: 100), .ok)
        XCTAssertEqual(BudgetState(used: 80, cap: 100), .warn)
        XCTAssertLessThan(BudgetState.ok, .warn)
        XCTAssertLessThan(BudgetState.warn, .over)
    }

    func testWarnAndRaiseNumbers() {
        XCTAssertEqual(BudgetCopy.warnAt(25), 20)
        XCTAssertEqual(BudgetCopy.warnAt(1), 1, "never below 1")
        XCTAssertEqual(BudgetCopy.warnAt(10), 8)
        XCTAssertEqual(BudgetPercent.raised(25), 35)
        XCTAssertEqual(BudgetPercent.raised(95), 100, "at most 100")
        XCTAssertEqual(BudgetPercent.raised(100), 100)
    }

    func testPercentWords() {
        XCTAssertEqual(BudgetCopy.pct(0), "0%")
        XCTAssertEqual(BudgetCopy.pct(0.4), "<1%")
        XCTAssertEqual(BudgetCopy.pct(18.4), "18%")
        XCTAssertEqual(BudgetCopy.pct(100), "100%")
        XCTAssertEqual(BudgetCopy.wholePct(0.2), 1, "never below 1 in a page")
        XCTAssertEqual(BudgetCopy.wholePct(26.4), 26)
        XCTAssertEqual(BudgetPercent.text(nil), "Off")
        XCTAssertEqual(BudgetPercent.text(25), "25%")
    }

    func testResetsReadsWeekdayAndTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        // 2026-11-09 is a Monday.
        let monday9 = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9, minute: 5))!
        XCTAssertEqual(BudgetCopy.resets(monday9, timeZone: utc), "Mon 09:05")
    }

    func testLineWords() {
        XCTAssertEqual(BudgetCopy.line(used: 18.4, cap: 25, state: .ok), "18% of 25%")
        XCTAssertEqual(BudgetCopy.line(used: 18.4, cap: nil, state: .ok), "18% · no budget")
        XCTAssertEqual(BudgetCopy.line(used: 26, cap: 25, state: .over), "26% of 25% · stopped")
        XCTAssertEqual(BudgetCopy.line(used: 4, cap: 10, state: .ok, isDefault: true), "4% of 10% · default budget")
        XCTAssertEqual(BudgetCopy.line(used: 26, cap: 25, state: .over, isDefault: true), "26% of 25% · stopped",
                       "stopped wins over default")
    }

    func testPreviewSentences() {
        let reset = "Resets Mon 09:00."
        let monday = { () -> Date in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = self.utc
            return cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9))!
        }()
        XCTAssertEqual(BudgetCopy.preview(name: "Night Owl", cap: 25, session: false, resetsAt: monday, timeZone: utc),
                       "Page warns at 20% and stops Night Owl at 25% of the week. \(reset)")
        XCTAssertEqual(BudgetCopy.preview(name: "Night Owl", cap: 25, session: true, resetsAt: monday, timeZone: utc),
                       "Page warns at 20% and stops this session at 25% of the week. \(reset)")
        XCTAssertEqual(BudgetCopy.preview(name: "Night Owl", cap: nil, session: false, resetsAt: nil, timeZone: utc),
                       "No budget: Night Owl can use any share of the week.")
        XCTAssertEqual(BudgetCopy.preview(name: "Night Owl", cap: nil, session: true, resetsAt: nil, timeZone: utc),
                       "No budget of its own: this session shares Night Owl's.")
        XCTAssertEqual(BudgetCopy.defaultPreview(cap: 15, resetsAt: nil, timeZone: utc),
                       "Every project without its own budget stops at 15% of the week, with a warning at 12%.")
        XCTAssertEqual(BudgetCopy.defaultPreview(cap: nil, resetsAt: nil, timeZone: utc),
                       "No default: projects without a budget can use any share of the week.")
    }

    func testFixedCopy() {
        XCTAssertEqual(BudgetCopy.footnote,
                       "Estimated from Claude Code on this Mac. Chats elsewhere count toward the week, so shares can read a little high.")
        XCTAssertEqual(BudgetCopy.captureOff, "Turn on usage tracking in Page Studio ▸ Budget to set budgets.")
        XCTAssertEqual(BudgetCopy.warnShare, 0.8)
    }

    func testPickerSteps() {
        XCTAssertEqual(BudgetPercent.presets, [nil, 10, 25, 50])
        XCTAssertEqual(BudgetPercent.up(nil), 5, "Off steps to 5")
        XCTAssertEqual(BudgetPercent.up(23), 25)
        XCTAssertEqual(BudgetPercent.up(25), 30)
        XCTAssertEqual(BudgetPercent.up(100), 100, "never past 100")
        XCTAssertEqual(BudgetPercent.up(99), 100)
        XCTAssertNil(BudgetPercent.down(5), "5 steps down to Off")
        XCTAssertNil(BudgetPercent.down(3))
        XCTAssertEqual(BudgetPercent.down(27), 25)
        XCTAssertEqual(BudgetPercent.down(25), 20)
        XCTAssertNil(BudgetPercent.down(nil))
        XCTAssertTrue(BudgetPercent.isValid(1))
        XCTAssertTrue(BudgetPercent.isValid(100))
        XCTAssertFalse(BudgetPercent.isValid(0))
        XCTAssertFalse(BudgetPercent.isValid(101))
    }
}

final class BudgetKeysTests: XCTestCase {
    func testHashIsFNV1a64WithSixteenDigits() {
        XCTAssertEqual(BudgetHash.hex(""), "cbf29ce484222325", "FNV-1a offset basis")
        XCTAssertEqual(BudgetHash.hex("a"), "af63dc4c8601ec8c", "FNV-1a of \"a\"")
        XCTAssertEqual(BudgetHash.hex("p:/x/p").count, 16)
        XCTAssertEqual(BudgetHash.project("/x/p"), BudgetHash.hex("p:/x/p"))
        XCTAssertEqual(BudgetHash.session("s1"), BudgetHash.hex("s:s1"))
        XCTAssertNotEqual(BudgetHash.project("s1"), BudgetHash.session("s1"), "a project and a session never share a hash")
    }

    func testProjectKeyValidity() {
        XCTAssertTrue(BudgetProjectKey.isValid("/Users/me/p"))
        XCTAssertTrue(BudgetProjectKey.isValid("/"))
        XCTAssertFalse(BudgetProjectKey.isValid(""))
        XCTAssertFalse(BudgetProjectKey.isValid("relative/p"))
        XCTAssertFalse(BudgetProjectKey.isValid("/a\nb"), "a newline would break the gate's key=value file")
        XCTAssertFalse(BudgetProjectKey.isValid("/a\tb"))
        XCTAssertFalse(BudgetProjectKey.isValid("/a\u{7f}b"))
        XCTAssertTrue(BudgetProjectKey.isValid("/" + String(repeating: "a", count: 1023)), "1024 characters is the limit")
        XCTAssertFalse(BudgetProjectKey.isValid("/" + String(repeating: "a", count: 1024)))
    }

    func testKeyPrefersProjectDirThenCwdAndSkipsRelativePaths() {
        let identity: (String) -> String = { $0 }
        XCTAssertEqual(BudgetProjectKey.key(projectDir: "/x/p", cwd: "/x/q", resolve: identity), "/x/p")
        XCTAssertEqual(BudgetProjectKey.key(projectDir: "rel", cwd: "/x/q", resolve: identity), "/x/q")
        XCTAssertEqual(BudgetProjectKey.key(projectDir: nil, cwd: "/x/q", resolve: identity), "/x/q")
        XCTAssertEqual(BudgetProjectKey.key(projectDir: "", cwd: "/x/q", resolve: identity), "/x/q")
        XCTAssertNil(BudgetProjectKey.key(projectDir: "rel", cwd: "also/rel", resolve: identity))
        XCTAssertNil(BudgetProjectKey.key(projectDir: nil, cwd: nil, resolve: identity))
    }

    func testKeyIsNormalisedThenResolved() {
        var seen: [String] = []
        let key = BudgetProjectKey.key(projectDir: "//x/./p/sub/../", cwd: nil) { path in
            seen.append(path)
            return path == "/x/p" ? "/private/x/p" : path
        }
        XCTAssertEqual(seen, ["/x/p"], "resolve sees the normalised path")
        XCTAssertEqual(key, "/private/x/p")
    }

    func testKeyFallsBackToCwdWhenResolvedProjectDirIsUnusable() {
        let key = BudgetProjectKey.key(projectDir: "/x/p", cwd: "/x/q") { $0 == "/x/p" ? "not-absolute" : $0 }
        XCTAssertEqual(key, "/x/q")
    }

    func testNormalisation() {
        XCTAssertEqual(BudgetProjectKey.normalized("/a/./b/../c/"), "/a/c")
        XCTAssertEqual(BudgetProjectKey.normalized("//a///b"), "/a/b")
        XCTAssertEqual(BudgetProjectKey.normalized("/a/.."), "/")
        XCTAssertEqual(BudgetProjectKey.normalized("/../a"), "/a")
        XCTAssertEqual(BudgetProjectKey.normalized("/"), "/")
    }

    func testLastComponent() {
        XCTAssertEqual(BudgetProjectKey.lastComponent("/Users/me/night-owl"), "night-owl")
        XCTAssertEqual(BudgetProjectKey.lastComponent("/"), "root")
    }

    func testSessionIdSanitising() {
        XCTAssertEqual(BudgetProjectKey.sanitizedSessionId("abc_123 /x-9"), "abc123x-9")
        XCTAssertTrue(BudgetProjectKey.isSaneSessionId("s1"))
        XCTAssertTrue(BudgetProjectKey.isSaneSessionId(String(repeating: "a", count: 128)))
        XCTAssertFalse(BudgetProjectKey.isSaneSessionId(String(repeating: "a", count: 129)))
        XCTAssertFalse(BudgetProjectKey.isSaneSessionId(""))
        XCTAssertFalse(BudgetProjectKey.isSaneSessionId("a b"))
        XCTAssertFalse(BudgetProjectKey.isSaneSessionId("../x"))
    }
}

final class BudgetSampleParseTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private let identity: (String) -> String = { $0 }

    private func parse(_ object: Any) -> BudgetSample? {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return BudgetSample.parse(data, at: at, resolve: identity)
    }

    private func fullPayload(extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = [
            "session_id": "s-1",
            "workspace": ["project_dir": "/x/p", "current_dir": "/x/p/sub"],
            "cost": ["total_cost_usd": 2.5],
            "rate_limits": ["seven_day": ["used_percentage": 12.5, "resets_at": 1_800_500_000]]
        ]
        for (k, v) in extra { o[k] = v }
        return o
    }

    func testFullPayload() {
        let s = parse(fullPayload())
        XCTAssertEqual(s?.sessionId, "s-1")
        XCTAssertEqual(s?.projectKey, "/x/p", "workspace.project_dir wins")
        XCTAssertEqual(s?.cost, 2.5)
        XCTAssertEqual(s?.weekPct, 12.5)
        XCTAssertEqual(s?.resetsAt, Date(timeIntervalSince1970: 1_800_500_000))
        XCTAssertEqual(s?.at, at)
    }

    func testRejectsWhatIsNotASessionPayload() {
        XCTAssertNil(parse(["cost": ["total_cost_usd": 1]]), "no session_id")
        XCTAssertNil(parse(["session_id": ""]))
        XCTAssertNil(parse(["session_id": "a b"]), "a session id outside [A-Za-z0-9-]")
        XCTAssertNil(BudgetSample.parse(Data("[]".utf8), at: at, resolve: identity))
        XCTAssertNil(BudgetSample.parse(Data("garbage".utf8), at: at, resolve: identity))
    }

    func testProjectKeyFallbacks() {
        // cwd when there is no project_dir.
        XCTAssertEqual(parse(["session_id": "a", "cwd": "/x/q", "workspace": ["project_dir": "rel"]])?.projectKey, "/x/q")
        // workspace.current_dir when there is no cwd either.
        XCTAssertEqual(parse(["session_id": "a", "workspace": ["current_dir": "/x/c"]])?.projectKey, "/x/c")
        // No absolute folder at all: the sample still parses, with no key (its cost can't be counted).
        let none = parse(["session_id": "a", "cost": ["total_cost_usd": 1]])
        XCTAssertNotNil(none)
        XCTAssertNil(none?.projectKey)
    }

    func testProjectKeyIsResolved() {
        let data = try! JSONSerialization.data(withJSONObject: ["session_id": "a", "workspace": ["project_dir": "/tmp/x/"]])
        let s = BudgetSample.parse(data, at: at) { $0 == "/tmp/x" ? "/private/tmp/x" : $0 }
        XCTAssertEqual(s?.projectKey, "/private/tmp/x")
    }

    func testCostMustBeANonNegativeNumber() {
        XCTAssertNil(parse(["session_id": "a", "cost": ["total_cost_usd": -1]])?.cost)
        XCTAssertNil(parse(["session_id": "a", "cost": ["total_cost_usd": "3"]])?.cost)
        XCTAssertNil(parse(["session_id": "a"])?.cost)
        XCTAssertEqual(parse(["session_id": "a", "cost": ["total_cost_usd": 0]])?.cost, 0)
    }

    func testWeeklyWindowRules() {
        XCTAssertNil(parse(["session_id": "a", "rate_limits": ["five_hour": ["used_percentage": 40, "resets_at": 1_800_500_000]]])?.weekPct,
                     "only the weekly window is used")
        XCTAssertEqual(parse(["session_id": "a", "rate_limits": ["seven_day": ["utilization": 40]]])?.weekPct, 40,
                       "utilization is accepted as well")
        XCTAssertEqual(parse(["session_id": "a", "rate_limits": ["seven_day": ["used_percentage": 150]]])?.weekPct, 100,
                       "clamped to 0…100")
        XCTAssertNil(parse(["session_id": "a"])?.weekPct)
    }
}

final class BudgetLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var resets: Date { t0.addingTimeInterval(5 * 86400) }
    private let proj = "/x/p"

    private func sample(_ sid: String = "s1", project: String? = "/x/p", cost: Double? = 0, week: Double? = 10,
                        resets r: Date? = nil, at: Date) -> BudgetSample {
        BudgetSample(sessionId: sid, projectKey: project, cost: cost, weekPct: week, resetsAt: r ?? resets, at: at)
    }

    @discardableResult
    private func observe(_ l: inout BudgetLedger, _ s: BudgetSample, now: Date? = nil) -> BudgetLedger.Outcome {
        l.observe(s, now: now ?? s.at, name: { _ in "Night Owl" })
    }

    // MARK: first sighting, increments, /clear

    func testFirstSightingCountsNothing() {
        var l = BudgetLedger()
        XCTAssertEqual(observe(&l, sample(cost: 3, week: 10, at: t0)), .newWindow)
        XCTAssertEqual(l.sessions["s1"]?.spent, 0, "spend from before Page saw the session is not counted")
        XCTAssertEqual(l.sessions["s1"]?.lastCost, 3)
        XCTAssertEqual(l.startPct, 10)
        XCTAssertEqual(l.used(session: "s1"), 0)
        XCTAssertEqual(l.used(project: proj), 0)
        XCTAssertTrue(l.estimate.measuring)
    }

    func testIncrementsAndClearAddTheNewCost() {
        var l = BudgetLedger()
        observe(&l, sample(cost: 3, week: 10, at: t0))
        XCTAssertEqual(observe(&l, sample(cost: 5, week: 10, at: t0.addingTimeInterval(60))), .counted)
        XCTAssertEqual(l.sessions["s1"]?.spent, 2)
        XCTAssertEqual(l.sessions["s1"]?.lastCost, 5)
        // /clear: the counter drops to 1, so the 1 is the new spend.
        observe(&l, sample(cost: 1, week: 10, at: t0.addingTimeInterval(120)))
        XCTAssertEqual(l.sessions["s1"]?.spent, 3)
        XCTAssertEqual(l.sessions["s1"]?.lastCost, 1)
    }

    func testIgnoredSamples() {
        var l = BudgetLedger()
        XCTAssertEqual(observe(&l, sample(cost: 1, week: nil, at: t0)), .ignored, "no weekly figure")
        XCTAssertEqual(l.observe(BudgetSample(sessionId: "s1", projectKey: proj, cost: 1, weekPct: 10, resetsAt: nil, at: t0),
                                 now: t0, name: { _ in "Night Owl" }), .ignored, "no reset time")
        XCTAssertEqual(observe(&l, sample(cost: 1, week: 10, resets: t0, at: t0)), .ignored, "a window already over")
        XCTAssertEqual(observe(&l, sample(cost: 1, week: 10, at: t0.addingTimeInterval(-7 * 3600)), now: t0), .ignored,
                       "older than 6 hours")
        XCTAssertEqual(observe(&l, sample(cost: 1, week: 10, at: t0.addingTimeInterval(-6 * 3600)), now: t0), .newWindow,
                       "exactly 6 hours is still fresh")
    }

    func testSampleWithoutProjectKeyStartsWindowButCountsNoSpend() {
        var l = BudgetLedger()
        XCTAssertEqual(observe(&l, sample(project: nil, cost: 3, week: 10, at: t0)), .newWindow)
        XCTAssertNil(l.sessions["s1"])
        XCTAssertTrue(l.projectKeys.isEmpty)
    }

    // MARK: windows

    func testWindowChangeResetsSpentAndCountsTheCrossingSpend() {
        var l = BudgetLedger()
        observe(&l, sample(cost: 3, week: 10, at: t0))
        observe(&l, sample(cost: 5, week: 12, at: t0.addingTimeInterval(60)))
        XCTAssertEqual(l.sessions["s1"]?.spent, 2)
        let next = resets.addingTimeInterval(3 * 86400)
        // The reset moved by days: a new window. The sample's own spend (cost 6 against the baseline 5) counts in it.
        XCTAssertEqual(observe(&l, sample(cost: 6, week: 15, resets: next, at: t0.addingTimeInterval(120))), .newWindow)
        XCTAssertEqual(l.startPct, 15)
        XCTAssertEqual(l.resetsAt, next)
        XCTAssertEqual(l.sessions["s1"]?.spent, 1, "the spend across the boundary is in the new window")
        XCTAssertEqual(l.sessions["s1"]?.lastCost, 6)
        observe(&l, sample(cost: 6.5, week: 16, resets: next, at: t0.addingTimeInterval(180)))
        XCTAssertEqual(l.sessions["s1"]?.spent ?? -1, 1.5, accuracy: 1e-9)
    }

    func testResetJitterUnderAnHourIsTheSameWindow() {
        var l = BudgetLedger()
        observe(&l, sample(cost: 3, week: 10, at: t0))
        let jitter = resets.addingTimeInterval(1800)
        XCTAssertEqual(observe(&l, sample(cost: 3, week: 11, resets: jitter, at: t0.addingTimeInterval(60))), .counted)
        XCTAssertEqual(l.startPct, 10, "still the same window")
        XCTAssertEqual(l.resetsAt, jitter, "the latest value is kept")
        XCTAssertEqual(l.weekPct, 11)
    }

    func testFileShowingAnOlderWindowMovesItsBaselineOnly() {
        var l = BudgetLedger()
        observe(&l, sample(cost: 3, week: 10, at: t0))
        let older = resets.addingTimeInterval(-2 * 86400)
        XCTAssertEqual(observe(&l, sample(cost: 9, week: 10, resets: older, at: t0.addingTimeInterval(60))), .counted)
        XCTAssertEqual(l.sessions["s1"]?.spent, 0, "no spend from an older window")
        XCTAssertEqual(l.sessions["s1"]?.lastCost, 9)
        observe(&l, sample(cost: 10, week: 11, at: t0.addingTimeInterval(120)))
        XCTAssertEqual(l.sessions["s1"]?.spent, 1, "the next sighting is measured from that baseline")
        XCTAssertEqual(l.resetsAt, resets, "the window never moves backwards")
    }

    func testWeeklyPercentFallingBelowStartStartsANewWindow() {
        var l = BudgetLedger()
        observe(&l, sample(cost: 3, week: 10, at: t0))
        XCTAssertEqual(observe(&l, sample(cost: 3, week: 9.5, at: t0.addingTimeInterval(60))), .newWindow)
        XCTAssertEqual(l.startPct, 9.5)
        XCTAssertEqual(l.sessions["s1"]?.spent, 0)
    }

    // MARK: estimate

    func testMeasuringUntilTheRiseIsAPoint() {
        var l = BudgetLedger()
        observe(&l, sample(cost: 0, week: 10, at: t0))
        observe(&l, sample(cost: 4, week: 10.5, at: t0.addingTimeInterval(60)))
        XCTAssertTrue(l.estimate.measuring)
        XCTAssertEqual(l.used(session: "s1"), 0, "nothing is shared out while measuring")
        XCTAssertEqual(l.used(project: proj), 0)
        observe(&l, sample(cost: 4, week: 11, at: t0.addingTimeInterval(120)))
        XCTAssertFalse(l.estimate.measuring)
        XCTAssertEqual(l.used(session: "s1"), 1, accuracy: 1e-9, "the rise of 1 goes to the one session that spent")
    }

    func testShareIsRiseTimesSpendOverTotal() {
        var l = BudgetLedger()
        observe(&l, sample("s1", project: "/x/a", cost: 0, week: 10, at: t0))
        observe(&l, sample("s2", project: "/x/b", cost: 0, week: 10, at: t0))
        observe(&l, sample("s1", project: "/x/a", cost: 3, week: 12, at: t0.addingTimeInterval(60)))
        observe(&l, sample("s2", project: "/x/b", cost: 1, week: 14, at: t0.addingTimeInterval(120)))
        // rise 4, spent 3 of 4 in /x/a and 1 of 4 in /x/b.
        XCTAssertEqual(l.used(project: "/x/a"), 3, accuracy: 1e-9)
        XCTAssertEqual(l.used(project: "/x/b"), 1, accuracy: 1e-9)
        XCTAssertEqual(l.used(session: "s1"), 3, accuracy: 1e-9)
        XCTAssertEqual(l.used(project: "/x/none"), 0)
        XCTAssertEqual(l.projectKeys, ["/x/a", "/x/b"])
    }

    func testEstimateEdges() {
        XCTAssertEqual(BudgetEstimate(rise: 50, total: 0, hasWeek: true).share(of: 0), 0, "no total, no share")
        XCTAssertEqual(BudgetEstimate(rise: 50, total: 10, hasWeek: true).share(of: 0), 0)
        XCTAssertEqual(BudgetEstimate(rise: 50, total: 10, hasWeek: true).share(of: 10), 50)
        XCTAssertEqual(BudgetEstimate(rise: 50, total: 10, hasWeek: true).share(of: 5), 25)
        XCTAssertEqual(BudgetEstimate(rise: 0.5, total: 10, hasWeek: true).share(of: 10), 0, "measuring")
        XCTAssertEqual(BudgetEstimate(rise: 100, total: 10, hasWeek: true).share(of: 10), 100)
    }

    // MARK: pruning

    func testSessionUnseenFor8DaysIsClosedIntoItsProject() {
        // A window that runs far past the 8 days, so pruning is about the sessions only.
        let far = t0.addingTimeInterval(30 * 86400)
        var l = BudgetLedger()
        observe(&l, sample("s1", project: "/x/a", cost: 0, week: 10, resets: far, at: t0))
        observe(&l, sample("s2", project: "/x/b", cost: 0, week: 10, resets: far, at: t0))
        observe(&l, sample("s1", project: "/x/a", cost: 3, week: 12, resets: far, at: t0.addingTimeInterval(60)))
        observe(&l, sample("s2", project: "/x/b", cost: 1, week: 14, resets: far, at: t0.addingTimeInterval(120)))
        let before = (l.used(project: "/x/a"), l.used(project: "/x/b"))

        XCTAssertFalse(l.prune(now: t0.addingTimeInterval(60 + 8 * 86400)), "exactly 8 days is not yet over")
        XCTAssertTrue(l.prune(now: t0.addingTimeInterval(60 + 8 * 86400 + 1)))
        XCTAssertNil(l.sessions["s1"])
        XCTAssertEqual(l.closedSpent["/x/a"], 3)
        XCTAssertEqual(l.used(project: "/x/a"), before.0, accuracy: 1e-9, "the closed spend still counts for its project")
        XCTAssertEqual(l.used(project: "/x/b"), before.1, accuracy: 1e-9)
        XCTAssertEqual(l.sessions["s2"]?.spent, 1, "s2 was seen 59 seconds later, so it stays live")
        XCTAssertFalse(l.prune(now: t0.addingTimeInterval(60 + 8 * 86400 + 2)), "a second prune changes nothing")
    }

    func testWindowThatEndedTenMinutesAgoIsDropped() {
        var l = BudgetLedger()
        observe(&l, sample(cost: 0, week: 10, at: t0))
        observe(&l, sample(cost: 4, week: 12, at: t0.addingTimeInterval(60)))
        l.warned = ["abc"]
        XCTAssertFalse(l.prune(now: resets.addingTimeInterval(599)), "still inside the grace")
        XCTAssertEqual(l.sessions["s1"]?.spent, 4)
        XCTAssertTrue(l.prune(now: resets.addingTimeInterval(601)))
        XCTAssertEqual(l.sessions["s1"]?.spent, 0)
        XCTAssertEqual(l.warned, [])
    }

    func testNamesAreKeptForProjectsWithSpend() {
        var l = BudgetLedger()
        observe(&l, sample(cost: 0, week: 10, at: t0))
        XCTAssertEqual(l.name(of: proj), "Night Owl", "the name is taken once, from the first sample")
    }

    // MARK: codable

    func testLedgerRoundTripsThroughJSON() throws {
        var l = BudgetLedger()
        observe(&l, sample(cost: 0, week: 10, at: t0))
        observe(&l, sample(cost: 2, week: 12, at: t0.addingTimeInterval(60)))
        l.warned = ["0123456789abcdef"]
        let data = try BudgetFiles.encoder().encode(l)
        let back = try BudgetFiles.decoder().decode(BudgetLedger.self, from: data)
        XCTAssertEqual(back, l)
    }
}

final class BudgetCapsTests: XCTestCase {
    func testInitDropsWhatCannotBeStored() {
        let caps = BudgetCaps(projects: ["/x/p": 25, "rel": 10, "/x/zero": 0, "/x/big": 101, "/x/ok": 1],
                              defaultPct: 0, sessions: ["s1": 10, "bad id": 10, "s2": 200])
        XCTAssertEqual(caps.projects, ["/x/p": 25, "/x/ok": 1])
        XCTAssertNil(caps.defaultPct, "a default of 0 is no default")
        XCTAssertEqual(caps.sessions, ["s1": 10])
        XCTAssertEqual(BudgetCaps(projects: [:], defaultPct: 100).defaultPct, 100)
    }

    func testProjectCapOwnElseDefault() {
        let caps = BudgetCaps(projects: ["/x/p": 25], defaultPct: 15)
        XCTAssertEqual(caps.projectCap("/x/p")?.cap, 25)
        XCTAssertEqual(caps.projectCap("/x/p")?.isDefault, false)
        XCTAssertEqual(caps.projectCap("/x/q")?.cap, 15)
        XCTAssertEqual(caps.projectCap("/x/q")?.isDefault, true)
        XCTAssertNil(BudgetCaps().projectCap("/x/q"))
    }

    func testBindingWithOneOrNoCap() {
        XCTAssertNil(BudgetCaps.binding(project: nil, session: nil))
        let p = BudgetCaps.binding(project: (25, 21), session: nil)
        XCTAssertEqual(p?.scope, .project)
        XCTAssertEqual(p?.cap, 25)
        XCTAssertEqual(p?.state, .warn)
        let s = BudgetCaps.binding(project: nil, session: (10, 12))
        XCTAssertEqual(s?.scope, .session)
        XCTAssertEqual(s?.state, .over)
        XCTAssertEqual(s?.used, 12)
    }

    func testFurtherAlongWins() {
        // The project is warn; the session has room. The project binds.
        XCTAssertEqual(BudgetCaps.binding(project: (25, 21), session: (10, 2))?.scope, .project)
        // The project is over: a session cap with room doesn't make the row read ok.
        let overProject = BudgetCaps.binding(project: (25, 26), session: (10, 2))
        XCTAssertEqual(overProject?.scope, .project)
        XCTAssertEqual(overProject?.state, .over)
        // The session is warn and the project ok: the session binds.
        let sessionWarn = BudgetCaps.binding(project: (25, 10), session: (10, 9))
        XCTAssertEqual(sessionWarn?.scope, .session)
        XCTAssertEqual(sessionWarn?.cap, 10)
        XCTAssertEqual(sessionWarn?.state, .warn)
    }

    func testTiesGoToTheLowerCapThenTheProject() {
        // Both ok: the lower cap (the session's 10) binds.
        XCTAssertEqual(BudgetCaps.binding(project: (25, 5), session: (10, 1))?.scope, .session)
        // Both over: the lower cap binds.
        let bothOver = BudgetCaps.binding(project: (25, 30), session: (10, 12))
        XCTAssertEqual(bothOver?.scope, .session)
        XCTAssertEqual(bothOver?.cap, 10)
        // Equal caps and states: the project's.
        XCTAssertEqual(BudgetCaps.binding(project: (25, 5), session: (25, 5))?.scope, .project)
    }

    func testStatusBuildShowsTheBindingCapForASession() {
        var ledger = BudgetLedger()
        ledger.observe(BudgetSample(sessionId: "s1", projectKey: "/x/p", cost: 0, weekPct: 10,
                                    resetsAt: Date(timeIntervalSince1970: 1_800_500_000), at: Date(timeIntervalSince1970: 1_800_000_000)),
                       now: Date(timeIntervalSince1970: 1_800_000_000), name: { _ in "Night Owl" })
        ledger.observe(BudgetSample(sessionId: "s1", projectKey: "/x/p", cost: 4, weekPct: 14,
                                    resetsAt: Date(timeIntervalSince1970: 1_800_500_000), at: Date(timeIntervalSince1970: 1_800_000_060)),
                       now: Date(timeIntervalSince1970: 1_800_000_060), name: { _ in "Night Owl" })
        let caps = BudgetCaps(projects: ["/x/p": 25], sessions: ["s1": 3])
        let row = BudgetStatus.build(ledger: ledger, caps: caps, capture: true).sessions["s1"]
        XCTAssertEqual(row?.scope, .session)
        XCTAssertEqual(row?.cap, 3)
        XCTAssertEqual(row?.state, .over)
        XCTAssertEqual(row?.line, "4% of 3% · stopped")
    }
}

final class BudgetStatusWireTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let resets = Date(timeIntervalSince1970: 1_800_500_000)

    /// Night Owl: s1 has spent 20 of a rise of 20 (used 20); the weekly % is 30.
    private func fixture(caps: BudgetCaps, live: [String: String] = ["s1": "/x/p"], capture: Bool = true) -> BudgetStatus {
        var ledger = BudgetLedger()
        ledger.observe(BudgetSample(sessionId: "s1", projectKey: "/x/p", cost: 0, weekPct: 10, resetsAt: resets, at: t0), now: t0,
                       name: { _ in "Night Owl" })
        ledger.observe(BudgetSample(sessionId: "s1", projectKey: "/x/p", cost: 20, weekPct: 30, resetsAt: resets, at: t0.addingTimeInterval(60)),
                       now: t0.addingTimeInterval(60), name: { _ in "Night Owl" })
        return BudgetStatus.build(ledger: ledger, caps: caps, capture: capture, live: live)
    }

    func testHeaderWire() {
        let status = fixture(caps: BudgetCaps(projects: ["/x/p": 25]))
        let h = status.headerWire
        XCTAssertEqual(h["window"] as? String, "week")
        XCTAssertEqual(h["capture"] as? Bool, true)
        XCTAssertEqual(h["measuring"] as? Bool, false)
        XCTAssertTrue(h["defaultCap"] is NSNull, "no default is null")
        XCTAssertEqual(h["resetsAt"] as? Int, Int(resets.timeIntervalSince1970))
        XCTAssertEqual(h["weekPct"] as? Double, 30)
        let projects = h["projects"] as? [[String: Any]]
        XCTAssertEqual(projects?.count, 1)
        XCTAssertEqual(projects?.first?["key"] as? String, "/x/p")
        XCTAssertEqual(projects?.first?["name"] as? String, "Night Owl")
        XCTAssertEqual(projects?.first?["used"] as? Double, 20)
        XCTAssertEqual(projects?.first?["cap"] as? Int, 25)
        XCTAssertEqual(projects?.first?["state"] as? String, "warn")
    }

    func testHeaderWireWithCaptureOffCarriesNoProjects() {
        let h = BudgetStatus.off.headerWire
        XCTAssertEqual(h["capture"] as? Bool, false)
        XCTAssertEqual((h["projects"] as? [Any])?.count, 0)
        XCTAssertNil(BudgetStatus.off.rowWire(sessionId: "s1"))
    }

    func testHeaderWireListsAtMostSixtyProjects() {
        var projects: [String: Int] = [:]
        for i in 0..<70 { projects["/x/p\(i)"] = 10 }
        let status = fixture(caps: BudgetCaps(projects: projects), live: [:])
        XCTAssertEqual(status.projects.count, 71)
        XCTAssertEqual((status.headerWire["projects"] as? [Any])?.count, BudgetStatus.maxWireProjects)
        XCTAssertEqual(BudgetStatus.maxWireProjects, 60)
    }

    func testRowWire() {
        let status = fixture(caps: BudgetCaps(projects: ["/x/p": 25]))
        let r = status.rowWire(sessionId: "s1")
        XCTAssertEqual(r?["projectKey"] as? String, "/x/p")
        XCTAssertEqual(r?["used"] as? Double, 20)
        XCTAssertEqual(r?["cap"] as? Int, 25)
        XCTAssertEqual(r?["scope"] as? String, "project")
        XCTAssertEqual(r?["state"] as? String, "warn")
        XCTAssertEqual(r?["sessionUsed"] as? Double, 20)
        XCTAssertTrue(r?["sessionCap"] is NSNull)
        XCTAssertNil(status.rowWire(sessionId: "unknown"))
    }

    func testLiveSessionWithoutSpendStillGetsARow() {
        let status = fixture(caps: BudgetCaps(projects: ["/x/p": 25]), live: ["s9": "/x/p"])
        let row = status.sessions["s9"]
        XCTAssertEqual(row?.projectKey, "/x/p", "the folder's project, before the status line has reported")
        XCTAssertEqual(row?.used ?? -1, 20, accuracy: 1e-9, "the project's share")
        XCTAssertEqual(row?.sessionUsed, 0)
    }

    func testRowLineUsesTheDefaultWhenTheProjectHasNoCap() {
        var ledger = BudgetLedger()
        ledger.observe(BudgetSample(sessionId: "s1", projectKey: "/x/p", cost: 0, weekPct: 10, resetsAt: resets, at: t0), now: t0,
                       name: { _ in "Night Owl" })
        ledger.observe(BudgetSample(sessionId: "s1", projectKey: "/x/p", cost: 4, weekPct: 14, resetsAt: resets, at: t0.addingTimeInterval(60)),
                       now: t0.addingTimeInterval(60), name: { _ in "Night Owl" })
        let status = BudgetStatus.build(ledger: ledger, caps: BudgetCaps(defaultPct: 10), capture: true, live: ["s1": "/x/p"])
        XCTAssertEqual(status.sessions["s1"]?.line, "4% of 10% · default budget")
        XCTAssertEqual(status.project("/x/p")?.state, .ok)
        XCTAssertEqual(status.project("/x/p")?.cap, nil, "its own cap is still none")
    }

    func testProjectStateAgainstTheDefaultWhenItHasNoCap() {
        let status = fixture(caps: BudgetCaps(defaultPct: 22))
        XCTAssertEqual(status.project("/x/p")?.state, .warn, "20 of 22 is past 80%")
    }

    func testRoundingToOneDecimal() {
        XCTAssertEqual(BudgetStatus.rounded1(18.44), 18.4)
        XCTAssertEqual(BudgetStatus.rounded1(18.46), 18.5)
        XCTAssertEqual(BudgetStatus.rounded1(0.0123), 0)
    }

    func testBoardForThePageStudioCard() {
        let board = fixture(caps: BudgetCaps(projects: ["/x/p": 25])).board(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(board.captureOn)
        XCTAssertEqual(board.rows.first?.key, "/x/p")
        XCTAssertTrue(board.resetText?.hasPrefix("resets ") == true)
        XCTAssertEqual(BudgetStatus.off.board().captureOn, false)
    }
}

final class BudgetPageTests: XCTestCase {
    private let digest = "0123456789abcdef"

    func testPageIdsRoundTrip() {
        let id = BudgetPages.pageId(hash: digest, kind: .stop, window: 1_800_500_000)
        XCTAssertEqual(id, "page-budget-0123456789abcdef-stop-1800500000")
        XCTAssertTrue(BudgetPages.isPageId(id))
        XCTAssertFalse(BudgetPages.isPageId("page-other-1"))
        let parsed = BudgetPages.parse(id)
        XCTAssertEqual(parsed?.hash, digest)
        XCTAssertEqual(parsed?.kind, .stop)
        XCTAssertEqual(parsed?.window, 1_800_500_000)
        XCTAssertEqual(BudgetPages.parse(BudgetPages.pageId(hash: digest, kind: .warn, window: 5))?.kind, .warn)
        XCTAssertEqual(BudgetPages.pageSessionId(hash: digest), "page-budget-" + digest)
    }

    func testMalformedPageIdsAreRejected() {
        XCTAssertNil(BudgetPages.parse("page-budget-abc-stop-1"), "a short hash")
        XCTAssertNil(BudgetPages.parse("page-budget-0123456789abcdef-raise-1"), "an unknown kind")
        XCTAssertNil(BudgetPages.parse("page-budget-0123456789abcdef-stop-x"), "a window that isn't a number")
        XCTAssertNil(BudgetPages.parse("page-budget-0123456789abcdef-stop-1-extra"))
        XCTAssertNil(BudgetPages.parse("page-budget-0123456789abcdef"))
        XCTAssertNil(BudgetPages.parse("other-0123456789abcdef-stop-1"))
    }

    func testWarningTextIsWordForWord() {
        XCTAssertEqual(BudgetPages.warningText(subject: "Night Owl", used: 19.6, cap: 25),
                       "Night Owl has used about 20% of the week (budget 25%). Page stops it at 25%.")
    }

    func testReachedTextIsWordForWord() {
        XCTAssertEqual(BudgetPages.reachedText(subject: "Night Owl", used: 25.6, cap: 25, stopped: 2),
                       "Night Owl reached its budget: about 26% of the week (budget 25%). Page stopped 2 sessions.")
        XCTAssertEqual(BudgetPages.reachedText(subject: "Night Owl", used: 25.6, cap: 25, stopped: 1),
                       "Night Owl reached its budget: about 26% of the week (budget 25%). Page stopped 1 session.")
    }

    func testTextsCarryWhatThePhonesParse() {
        let reached = BudgetPages.reachedText(subject: "A session in Night Owl", used: 26, cap: 25, stopped: 2)
        XCTAssertTrue(reached.contains("about 26%"))
        XCTAssertTrue(reached.contains("budget 25%"))
        XCTAssertTrue(reached.contains("stopped 2 session"))
        let warn = BudgetPages.warningText(subject: "Night Owl", used: 20, cap: 25)
        XCTAssertTrue(warn.contains("about 20%"))
        XCTAssertTrue(warn.contains("budget 25%"))
    }

    func testSubjects() {
        XCTAssertEqual(BudgetPages.subject(name: "Night Owl", session: false), "Night Owl")
        XCTAssertEqual(BudgetPages.subject(name: "Night Owl", session: true), "A session in Night Owl")
    }

    func testReplyDecisions() {
        XCTAssertEqual(BudgetPages.decision(action: "approve", text: ""), .raise)
        XCTAssertEqual(BudgetPages.decision(action: "carry_on", text: ""), .carryOn)
        XCTAssertEqual(BudgetPages.decision(action: "deny", text: ""), .keepStopped)
        XCTAssertEqual(BudgetPages.decision(action: "custom", text: "yes"), .keepStopped)
        XCTAssertEqual(BudgetPages.decision(action: nil, text: "1"), .keepStopped, "typed text never approves")
        XCTAssertEqual(BudgetPages.decision(action: nil, text: "approve"), .keepStopped)
        XCTAssertEqual(BudgetPages.decision(action: "approve", text: "typed"), .raise, "the action decides")
    }

    func testReplyDetailsAreReceiptSentences() {
        XCTAssertEqual(BudgetPages.raisedDetail(name: "Night Owl", cap: 35), "Raised Night Owl to 35%")
        XCTAssertEqual(BudgetPages.carryOnDetail(name: "Night Owl"), "Night Owl can finish this turn")
        XCTAssertEqual(BudgetPages.keptStoppedDetail(name: "Night Owl"), "Kept Night Owl stopped")
        XCTAssertEqual(BudgetPages.raisedMessage(cap: 35), "Page: budget raised to 35% — carry on where you left off.")
        XCTAssertEqual(BudgetPages.finishTurnMessage, "Page: you can finish this turn — carry on where you left off.")
    }
}

final class BudgetGateFormatTests: XCTestCase {
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }

    func testStopReasonNamesTheBudgetAndTheReset() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let monday9 = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9))!
        XCTAssertEqual(BudgetGate.stopReason(subject: "Night Owl", cap: 25, resetsAt: monday9, timeZone: utc),
                       "Page: Night Owl reached its budget (25% of the week). Raise it in Page, or wait for the reset on Mon 09:00.")
        XCTAssertEqual(BudgetGate.stopReason(subject: "this session", cap: 10, resetsAt: nil, timeZone: utc),
                       "Page: this session reached its budget (10% of the week). Raise it in Page.")
    }

    func testStopLineIsTheHookJSON() throws {
        let line = BudgetGate.stopLine(reason: "Page: Night Owl reached its budget (25% of the week).")
        XCTAssertEqual(line, #"{"continue":false,"stopReason":"Page: Night Owl reached its budget (25% of the week)."}"#)
        let back = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(back?["continue"] as? Bool, false)
    }

    func testStopLineReplacesControlCharacters() throws {
        let line = BudgetGate.stopLine(reason: "two\nlines\tand\u{7f}more")
        XCTAssertFalse(line.contains("\n"))
        let back = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(back?["stopReason"] as? String, "two lines and more")
    }

    func testGateFileFormat() {
        let stop = BudgetGate.stopLine(reason: "r")
        XCTAssertEqual(BudgetGate.gateFile(project: "/x/p", session: nil, expires: 1_800_500_000, stopLine: stop),
                       "project=/x/p\nsession=\nexpires=1800500000\nstop=\(stop)\n")
        XCTAssertEqual(BudgetGate.gateFile(project: nil, session: "s1", expires: 7, stopLine: stop),
                       "project=\nsession=s1\nexpires=7\nstop=\(stop)\n")
    }

    func testGateFileRefusesNewlines() {
        let stop = BudgetGate.stopLine(reason: "r")
        XCTAssertNil(BudgetGate.gateFile(project: "/x/a\nb", session: nil, expires: 1, stopLine: stop))
        XCTAssertNil(BudgetGate.gateFile(project: nil, session: "s\r1", expires: 1, stopLine: stop))
        XCTAssertNil(BudgetGate.gateFile(project: nil, session: "s1", expires: 1, stopLine: "x\ny"))
    }

    func testMarkerJSON() throws {
        let data = BudgetGate.markerJSON(project: "/x/p", session: nil, name: "Night Owl", cap: 25, used: 25.44, expiresAt: 1_800_500_000)
        let o = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(o?["project"] as? String, "/x/p")
        XCTAssertTrue(o?["session"] is NSNull)
        XCTAssertEqual(o?["name"] as? String, "Night Owl")
        XCTAssertEqual(o?["cap"] as? Int, 25)
        XCTAssertEqual(o?["used"] as? Double, 25.4)
        XCTAssertEqual(o?["expiresAt"] as? Int, 1_800_500_000)
    }

    func testCoversAtPathBoundaries() {
        XCTAssertTrue(BudgetGate.covers(project: "/x/proj", cwd: "/x/proj"))
        XCTAssertTrue(BudgetGate.covers(project: "/x/proj", cwd: "/x/proj/sub/deeper"))
        XCTAssertFalse(BudgetGate.covers(project: "/x/proj", cwd: "/x/proj2"), "a sibling with the same prefix")
        XCTAssertFalse(BudgetGate.covers(project: "/x/proj", cwd: "/x"))
        XCTAssertTrue(BudgetGate.covers(project: "/", cwd: "/anything"))
    }
}

final class BudgetOpParseTests: XCTestCase {
    private func parse(scope: String?, key: String? = nil, sessionId: String? = nil, pct: BudgetOp.PctField) -> Result<BudgetOp, BudgetOp.Failure> {
        BudgetOp.parse(scope: scope, key: key, sessionId: sessionId, pct: pct)
    }

    private func value(_ r: Result<BudgetOp, BudgetOp.Failure>) -> BudgetOp? {
        if case .success(let op) = r { return op }
        return nil
    }

    func testProjectSetAndClear() {
        XCTAssertEqual(value(parse(scope: "project", key: "/Users/me/p", pct: .int(30))),
                       BudgetOp(target: .project("/Users/me/p"), pct: 30))
        XCTAssertEqual(value(parse(scope: "project", key: "/Users/me/p", pct: .null)),
                       BudgetOp(target: .project("/Users/me/p"), pct: nil))
        XCTAssertEqual(value(parse(scope: "project", key: "/Users/me/p", pct: .absent)),
                       BudgetOp(target: .project("/Users/me/p"), pct: nil), "a missing pct clears, like null")
        XCTAssertEqual(value(parse(scope: "project", key: "/Users/me/p/", pct: .int(5)))?.target, .project("/Users/me/p"),
                       "trailing slashes are dropped")
        XCTAssertEqual(value(parse(scope: "project", key: "/", pct: .int(5)))?.target, .project("/"))
    }

    func testSessionAndDefault() {
        XCTAssertEqual(value(parse(scope: "session", key: "ignored", sessionId: "s1", pct: .int(10))),
                       BudgetOp(target: .session("s1"), pct: 10))
        XCTAssertEqual(value(parse(scope: "default", pct: .null)), BudgetOp(target: .defaultCap, pct: nil))
        XCTAssertEqual(value(parse(scope: "default", pct: .int(15))), BudgetOp(target: .defaultCap, pct: 15))
    }

    func testPercentBounds() {
        XCTAssertEqual(value(parse(scope: "default", pct: .int(1)))?.pct, 1)
        XCTAssertEqual(value(parse(scope: "default", pct: .int(100)))?.pct, 100)
        XCTAssertNil(value(parse(scope: "default", pct: .int(0))))
        XCTAssertNil(value(parse(scope: "default", pct: .int(101))))
        XCTAssertNil(value(parse(scope: "default", pct: .int(-5))))
        XCTAssertNil(value(parse(scope: "default", pct: .invalid)))
    }

    func testKeyRejections() {
        XCTAssertNil(value(parse(scope: "project", key: nil, pct: .int(5))), "no key")
        XCTAssertNil(value(parse(scope: "project", key: "", pct: .int(5))))
        XCTAssertNil(value(parse(scope: "project", key: "Users/me", pct: .int(5))), "relative")
        XCTAssertNil(value(parse(scope: "project", key: "/a\nb", pct: .int(5))), "a newline")
        XCTAssertNil(value(parse(scope: "project", key: "/" + String(repeating: "a", count: 1024), pct: .int(5))), "over 1024")
        XCTAssertNotNil(value(parse(scope: "project", key: "/" + String(repeating: "a", count: 1023), pct: .int(5))))
    }

    func testSessionIdRejections() {
        XCTAssertNil(value(parse(scope: "session", sessionId: nil, pct: .int(10))))
        XCTAssertNil(value(parse(scope: "session", sessionId: "", pct: .int(10))))
        XCTAssertNil(value(parse(scope: "session", sessionId: "s 1", pct: .int(10))))
        XCTAssertNil(value(parse(scope: "session", sessionId: "../s1", pct: .int(10))))
        XCTAssertNil(value(parse(scope: "session", sessionId: String(repeating: "a", count: 129), pct: .int(10))))
    }

    func testUnknownScopeIsRefused() {
        XCTAssertNil(value(parse(scope: "team", pct: .int(10))))
        XCTAssertNil(value(parse(scope: nil, pct: .int(10))))
        let failure = parse(scope: "team", pct: .int(10))
        if case .failure(let f) = failure { XCTAssertFalse(f.detail.isEmpty) } else { XCTFail("expected a failure") }
    }

    func testPctFieldFromJSON() throws {
        func field(_ json: String) throws -> BudgetOp.PctField {
            let o = try JSONSerialization.jsonObject(with: Data("{\(json)}".utf8)) as? [String: Any] ?? [:]
            return BudgetOp.PctField.from(o["pct"], present: o.keys.contains("pct"))
        }
        XCTAssertEqual(try field(#""pct":25"#), .int(25))
        XCTAssertEqual(try field(#""pct":null"#), .null)
        XCTAssertEqual(try field(#""x":1"#), .absent)
        XCTAssertEqual(try field(#""pct":true"#), .invalid, "a boolean is not a percent")
        XCTAssertEqual(try field(#""pct":false"#), .invalid)
        XCTAssertEqual(try field(#""pct":25.5"#), .invalid, "a fraction is not whole")
        XCTAssertEqual(try field(#""pct":"25""#), .invalid, "a string is not a number")
        XCTAssertEqual(try field(#""pct":25.0"#), .int(25), "25.0 is whole")
    }

    func testResultDetailSentences() {
        XCTAssertEqual(BudgetOp(target: .project("/x/p"), pct: 30).resultDetail(projectName: "Night Owl"), "Night Owl’s budget is now 30%")
        XCTAssertEqual(BudgetOp(target: .project("/x/p"), pct: nil).resultDetail(projectName: "Night Owl"), "Night Owl’s budget is off")
        XCTAssertEqual(BudgetOp(target: .project("/x/p"), pct: 30).resultDetail(projectName: nil), "The project’s budget is now 30%")
        XCTAssertEqual(BudgetOp(target: .session("s1"), pct: 10).resultDetail(projectName: nil), "This session’s budget is now 10%")
        XCTAssertEqual(BudgetOp(target: .defaultCap, pct: 15).resultDetail(projectName: nil), "The default budget is now 15%")
        XCTAssertEqual(BudgetOp(target: .defaultCap, pct: nil).resultDetail(projectName: nil), "The default budget is off")
    }

    func testAppliedToConfig() {
        var budget = BudgetConfig()
        budget.projects["/x/p"] = 25
        XCTAssertEqual(BudgetOp(target: .project("/x/q"), pct: 40).applied(to: budget).projects, ["/x/p": 25, "/x/q": 40])
        XCTAssertEqual(BudgetOp(target: .project("/x/p"), pct: nil).applied(to: budget).projects, [:], "clearing removes it")
        XCTAssertEqual(BudgetOp(target: .defaultCap, pct: 15).applied(to: budget).defaultPct, 15)
        XCTAssertEqual(BudgetOp(target: .session("s1"), pct: 10).applied(to: budget), budget, "sessions aren't in config.json")
    }
}

/// The phone's `budget` op as it arrives in an encrypted sessions command (Designs/budget-caps.md §5).
final class BudgetWireCommandTests: XCTestCase {
    private func command(_ body: String) -> SessionCommand? {
        SessionCommand.parse(Data("{\"clientId\":\"c1\",\"ts\":1,\(body)}".utf8))
    }

    private func op(_ body: String) -> Result<BudgetOp, BudgetOp.Failure>? {
        guard let c = command("\"op\":\"budget\"," + body) else { return nil }
        return BudgetOp.parse(scope: c.budgetScope, key: c.budgetKey, sessionId: c.sessionId, pct: c.budgetPct)
    }

    func testPhoneProjectShape() {
        guard case .success(let op)? = op(#""scope":"project","key":"/Users/me/p","pct":30"#) else { return XCTFail("project op") }
        XCTAssertEqual(op, BudgetOp(target: .project("/Users/me/p"), pct: 30))
    }

    func testPhoneClearShapesWithNullAndMissingPct() {
        guard case .success(let a)? = op(#""scope":"project","key":"/Users/me/p","pct":null"#) else { return XCTFail() }
        XCTAssertNil(a.pct)
        guard case .success(let b)? = op(#""scope":"project","key":"/Users/me/p""#) else { return XCTFail() }
        XCTAssertNil(b.pct)
    }

    func testPhoneSessionShapeIgnoresTheKey() {
        guard case .success(let op)? = op(#""scope":"session","sessionId":"s1","key":"/Users/me/p","pct":10"#) else { return XCTFail() }
        XCTAssertEqual(op, BudgetOp(target: .session("s1"), pct: 10))
    }

    func testPhoneDefaultShape() {
        guard case .success(let op)? = op(#""scope":"default","pct":null"#) else { return XCTFail() }
        XCTAssertEqual(op, BudgetOp(target: .defaultCap, pct: nil))
    }

    func testRejectedWireShapes() {
        let bad: [String] = [
            #""scope":"project","key":"/Users/me/p","pct":0"#,
            #""scope":"project","key":"/Users/me/p","pct":101"#,
            #""scope":"project","key":"/Users/me/p","pct":"x""#,
            #""scope":"project","key":"/Users/me/p","pct":true"#,
            #""scope":"project","key":"/Users/me/p","pct":25.5"#,
            #""scope":"project","key":"Users/me/p","pct":25"#,
            #""scope":"project","pct":25"#,
            #""scope":"project","key":"/"# + String(repeating: "a", count: 1025) + #"","pct":25"#,
            #""scope":"session","sessionId":"bad id","pct":10"#,
            #""scope":"session","pct":10"#,
            #""scope":"team","pct":10"#,
            #""pct":10"#,
        ]
        for body in bad {
            guard let result = op(body) else { XCTFail("the command itself should parse: \(body)"); continue }
            if case .success = result { XCTFail("should be refused: \(body)") }
        }
    }

    func testTheBudgetCapabilityIsAdvertised() {
        XCTAssertTrue(SessionRemote.capabilities.contains("budget-v1"), "\(SessionRemote.capabilities)")
    }

    func testBudgetOpCommandNeedsItsClientId() {
        XCTAssertNil(SessionCommand.parse(Data(#"{"op":"budget","ts":1,"scope":"default","pct":5}"#.utf8)))
    }
}

/// `budget` in config.json (Designs/budget-caps.md §3): missing is empty, a bad entry drops only itself,
/// and an old config still decodes.
final class BudgetConfigDecodeTests: XCTestCase {
    private func decodeConfig(_ json: String) throws -> (config: Config, issues: [String]) {
        let issues = Config.DecodeIssues()
        let decoder = JSONDecoder()
        decoder.userInfo[Config.decodeIssuesKey] = issues
        let config = try decoder.decode(Config.self, from: Data(json.utf8))
        return (config, issues.messages)
    }

    func testMissingBudgetDecodesAsEmpty() throws {
        for json in ["{}", #"{"lowBatteryCutoff": 12, "relayEnabled": false}"#] {
            let (config, issues) = try decodeConfig(json)
            XCTAssertEqual(config.budget, BudgetConfig(), json)
            XCTAssertEqual(issues, [], json)
        }
        XCTAssertEqual(try decodeConfig(#"{"lowBatteryCutoff": 12}"#).config.lowBatteryCutoff, 12, "old keys still load")
    }

    func testBadEntriesDropOnlyThemselves() throws {
        let (config, decodeIssues) = try decodeConfig(
            #"{"budget":{"projects":{"/x/p":25,"rel":10,"/x/z":0,"/x/f":"a"},"defaultPct":150}}"#)
        // "a" isn't a whole number: dropped at decode, with an issue. The others decode and are checked by validated().
        XCTAssertEqual(config.budget.projects, ["/x/p": 25, "rel": 10, "/x/z": 0])
        XCTAssertEqual(config.budget.defaultPct, 150)
        XCTAssertEqual(decodeIssues.count, 1, "\(decodeIssues)")
        XCTAssertTrue(decodeIssues[0].contains("/x/f"), decodeIssues[0])

        let (valid, notes) = config.budget.validated()
        XCTAssertEqual(valid.projects, ["/x/p": 25])
        XCTAssertNil(valid.defaultPct)
        XCTAssertEqual(notes.count, 3, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("rel") && $0.contains("isn’t an absolute folder path") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("/x/z") && $0.contains("outside 1…100") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("150") && $0.contains("using none") }, "\(notes)")
    }

    func testWrongTypesFallBackToEmptyAndTheRestStillLoads() throws {
        for json in [#"{"budget":"x","lowBatteryCutoff":12}"#, #"{"budget":{"projects":[]},"lowBatteryCutoff":12}"#] {
            let (config, issues) = try decodeConfig(json)
            XCTAssertEqual(config.budget, BudgetConfig(), json)
            XCTAssertEqual(config.lowBatteryCutoff, 12, "the rest of the config still loads: \(json)")
            XCTAssertFalse(issues.isEmpty, json)
        }
    }
}

