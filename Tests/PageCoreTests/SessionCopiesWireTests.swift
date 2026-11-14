import XCTest
@testable import PageCore

/// What copies and renamed sessions look like on the wire and on the Mac's cards (Designs/session-copies.md §A, §C):
/// the row's optional `copies`, the lead-moved probe, the card names, and the target check that accepts a name.
final class SessionCopiesWireTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_761_300_000)
    private let cmux = SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true)
    private let home = "/Users/me"

    private func row(copies: Int?) -> RemoteSessionRow {
        var r = RemoteSessionRow(id: "s1", backend: "claude", title: "Workspace-App", cwd: "~/projects/page",
                                 state: .idle, host: cmux, lastActivityAt: now, interventionId: nil, preview: nil)
        r.copies = copies
        return r
    }

    // MARK: - copies on the row

    func testTheRowCarriesCopiesOnlyWhenThereAreTwoOrMore() {
        XCTAssertEqual(row(copies: 2).jsonObject["copies"] as? Int, 2)
        XCTAssertEqual(row(copies: 3).jsonObject["copies"] as? Int, 3)
    }

    func testOneOrNoCopyLeavesTheKeyOut() {
        XCTAssertNil(row(copies: nil).jsonObject["copies"])
        XCTAssertNil(row(copies: 1).jsonObject["copies"], "one terminal is not a copy")
        XCTAssertNil(row(copies: 0).jsonObject["copies"])
    }

    func testTheRowsOtherFieldsAreUnchangedByCopies() {
        let o = row(copies: 2).jsonObject
        XCTAssertEqual(o["title"] as? String, "Workspace-App")
        XCTAssertEqual(o["state"] as? String, "idle")
        XCTAssertEqual(o["host"] as? String, "cmux")
        XCTAssertEqual(row(copies: 2).jsonObject.count, row(copies: nil).jsonObject.count + 1)
    }

    // MARK: - the lead moved

    func testTheLeadMovedWhenTheProbedProcessIsNoLongerTheLead() {
        XCTAssertTrue(SessionRemote.leadMoved(known: 10, now: 20))
    }

    func testTheLeadHasNotMovedWhenItIsTheSameOrUnknown() {
        XCTAssertFalse(SessionRemote.leadMoved(known: 10, now: 10))
        XCTAssertFalse(SessionRemote.leadMoved(known: nil, now: 10), "never probed: nothing to compare")
        XCTAssertFalse(SessionRemote.leadMoved(known: 10, now: nil), "no lead now: nothing to say")
        XCTAssertFalse(SessionRemote.leadMoved(known: nil, now: nil))
    }

    // MARK: - names on the Mac's cards

    private func claude(_ id: String, cwd: String? = "/Users/roy/projects/page", name: String? = nil) -> AgentSession {
        AgentSession(backend: .claude, sessionId: id, cwd: cwd, title: nil, source: .terminal, state: .idle,
                     lastActivityAt: now.addingTimeInterval(-120), activeFlags: [], supportsRemoteReply: true,
                     customName: name)
    }

    func testTheCardNameIsTheCustomNameAndTheFolderIsItsRouteOnlyWithoutOne() {
        XCTAssertEqual(NowModel.displayName(of: claude("a", name: "Workspace-App")), "Workspace-App")
        XCTAssertEqual(NowModel.displayName(of: claude("b")), "page", "no name: the folder")
        XCTAssertEqual(NowModel.projectName(of: claude("a", name: "Workspace-App")), "page",
                       "the folder stays on the second line")
    }

    func testAPageNamesItsFolderForTheRouteNotItsName() {
        let event = InterventionEvent(id: "p", sessionId: "a", cwd: "/Users/roy/projects/page", projectName: "Workspace-App",
                                      kind: .idle, openedAt: now, context: "Done.", transcriptPath: "")
        XCTAssertEqual(NowModel.folderName(of: event), "page")
        let noCwd = InterventionEvent(id: "q", sessionId: "a", cwd: "", projectName: "Workspace-App",
                                      kind: .idle, openedAt: now, context: "Done.", transcriptPath: "")
        XCTAssertEqual(NowModel.folderName(of: noCwd), "Workspace-App", "no folder known: what the page has")
    }

    private func snapshot(_ sessions: [AgentSession]) -> Coordinator.Snapshot {
        Coordinator.Snapshot(
            sessions: sessions, power: PowerSnapshot(percent: 100, onAC: true, hasBattery: true, isCharging: false),
            awake: AwakeAssertions(preventIdleSleep: true, preventSystemSleep: true), lidClosedOnBattery: false,
            lidClosedOnBatteryBlocker: nil, battery: .normal, activeRateLimit: nil, scheduledResumes: [],
            pendingInterventions: [], relayState: .connected, backends: [], configProblem: nil,
            batteryForecast: nil, usage: nil, usageHitAt: nil)
    }

    func testAWorkingCardShowsTheCustomNameWithTheFolderOnItsRoute() {
        var s = claude("a", name: "Workspace-App")
        s = AgentSession(backend: s.backend, sessionId: s.sessionId, cwd: s.cwd, title: nil, source: .terminal,
                         state: .active, lastActivityAt: now, activeFlags: ["busy"], supportsRemoteReply: true,
                         customName: "Workspace-App")
        let rows = InFlightRows.build(snapshot([s]), hosts: ["a": cmux], activity: [:], now: now)
        let row = try? XCTUnwrap(rows.first)
        XCTAssertEqual(row?.project, "Workspace-App")
        XCTAssertTrue(row?.route?.hasSuffix("› page") ?? false, "route: \(row?.route ?? "nil")")
    }

    func testAnIdleCardShowsTheCustomNameWithTheFolderOnItsRoute() {
        let rows = InFlightRows.buildIdle(snapshot([claude("a", name: "Workspace-App")]), hosts: ["a": cmux],
                                          facts: [:], now: now)
        XCTAssertEqual(rows.first?.project, "Workspace-App")
        XCTAssertTrue(rows.first?.route?.hasSuffix("› page") ?? false, "route: \(rows.first?.route ?? "nil")")
    }

    func testACardWithNoNameKeepsTheFolderAsItsTitle() {
        let rows = InFlightRows.buildIdle(snapshot([claude("a")]), hosts: ["a": cmux], facts: [:], now: now)
        XCTAssertEqual(rows.first?.project, "page")
    }

    // MARK: - the target check accepts the name the phone may show

    func testTheTargetCheckAcceptsTheCustomNameAsWellAsTheFolder() {
        XCTAssertNil(SessionTargetCheck.verify(expectCwd: nil, expectTitle: "Workspace-App", cwd: "/Users/me/projects/page",
                                               title: "page", home: home, alsoTitle: "Workspace-App"))
        XCTAssertNil(SessionTargetCheck.verify(expectCwd: nil, expectTitle: "page", cwd: "/Users/me/projects/page",
                                               title: "page", home: home, alsoTitle: "Workspace-App"),
                     "the folder the row showed before the rename still matches")
    }

    func testTheTargetCheckStillRefusesAnotherName() {
        XCTAssertNotNil(SessionTargetCheck.verify(expectCwd: nil, expectTitle: "Other", cwd: "/Users/me/projects/page",
                                                  title: "page", home: home, alsoTitle: "Workspace-App"))
        XCTAssertNotNil(SessionTargetCheck.verify(expectCwd: nil, expectTitle: "Workspace-App", cwd: "/Users/me/projects/page",
                                                  title: "page", home: home, alsoTitle: nil),
                        "without the custom name in play, the phone's name is not the session's")
    }

    func testTheCommandOverloadUsesTheSessionsCustomName() {
        var command = SessionCommand(op: "input", clientId: "c1", ts: 1_000, viewer: nil, sessionId: "a", text: "hi")
        command.expectTitle = "Workspace-App"
        let renamed = AgentSession(backend: .claude, sessionId: "a", cwd: "/Users/me/projects/page", title: nil,
                                   source: .terminal, state: .active, lastActivityAt: nil, activeFlags: [],
                                   supportsRemoteReply: true, customName: "Workspace-App")
        XCTAssertNil(SessionTargetCheck.verify(command, against: renamed, home: home))
        let plain = AgentSession(backend: .claude, sessionId: "a", cwd: "/Users/me/projects/page", title: nil,
                                 source: .terminal, state: .active, lastActivityAt: nil, activeFlags: [],
                                 supportsRemoteReply: true)
        XCTAssertNotNil(SessionTargetCheck.verify(command, against: plain, home: home))
    }
}
