import Foundation
import SwiftUI
@testable import PageCore

// Fixtures and surfaces for budgets in the menu-bar panel: the slim "BUDGET"
// line under Open and Steer on the In-flight cards and the finished-turn row,
// and its inline editor. Run through the same `NowModel.build` as live data.

extension NightWatchFixtures {
    /// Two sessions working (payments-api: 21% of a 25% budget; llm-play: no budget) and a finished turn
    /// (sensor-hub, 3% of its 10%), as the panel shows them. Demo names only: these renders feed the README images.
    static func budgetScene(now: Date = boardNow()) -> NowInputs {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func claude(_ name: String, state: AgentSessionState) -> AgentSession {
            AgentSession(backend: .claude, sessionId: "sess-\(name)", cwd: "/Users/studio/projects/\(name)", title: nil,
                         source: .terminal, state: state, lastActivityAt: at(1), activeFlags: [], supportsRemoteReply: true)
        }
        let sessions = [claude("payments-api", state: .active), claude("llm-play", state: .active), claude("sensor-hub", state: .idle)]
        let facts: [String: InFlightFacts] = [
            "sess-payments-api": InFlightFacts(
                steps: [InFlightStep(text: "Edit: /Users/studio/projects/payments-api/src/refunds.ts", at: at(9)),
                        InFlightStep(text: "Bash: npm test -- refunds", at: at(0.6))],
                currentStepIsNewest: true, model: "claude-opus-4-7", startedAt: at(130), busySince: at(12)),
            "sess-llm-play": InFlightFacts(
                steps: [InFlightStep(text: "Edit: Sources/Agent/Planner.swift", at: at(5)),
                        InFlightStep(text: "Bash: cargo test", at: at(1))],
                currentStepIsNewest: true, model: "claude-sonnet-4-5-20250929", startedAt: at(310), busySince: at(20))
        ]
        let hosts: [String: SessionHostInfo] = [
            "sess-payments-api": SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true),
            "sess-llm-play": SessionHostInfo(host: "tmux", canType: true, typeBlocker: nil, canInterrupt: true),
            "sess-sensor-hub": SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true)
        ]
        let finished = event("sensor-hub", kind: .idle, context: "Finished the sensor calibration: 14 readings saved", openedAt: at(3))
        let snap = snapshot(sessions: sessions, pending: [finished])
        var i = NowInputs(snapshot: snap, now: now, macName: "Studio MBP", idleSeconds: 5)
        i.route = route
        i.hosts = hosts
        i.facts = facts
        return i
    }

    /// The Mac's budgets for that scene. `over`: payments-api has used its whole 25%. `capture` false: usage tracking is off.
    /// `measuring`: the week hasn't risen a whole point yet, so each card shows its share of the work so far, with no bar.
    static func budgetStatus(now: Date = boardNow(), over: Bool = false, capture: Bool = true, measuring: Bool = false) -> BudgetStatus {
        guard capture else { return .off }
        if measuring {
            func row(_ name: String, cap: Int?, work: Double) -> BudgetStatus.Row {
                BudgetStatus.Row(projectKey: "/Users/studio/projects/\(name)", projectName: name, used: 0, cap: cap, scope: .project,
                                 state: .ok, sessionUsed: 0, sessionCap: nil, projectCap: cap, defaultCap: nil, work: work)
            }
            return BudgetStatus(
                capture: true, measuring: true, weekPct: 30.4, resetsAt: now.addingTimeInterval(6 * 86400 + 20 * 3600), defaultCap: nil,
                projects: [],
                sessions: ["sess-payments-api": row("payments-api", cap: 25, work: 64.2),
                           "sess-llm-play": row("llm-play", cap: nil, work: 10.5),
                           "sess-sensor-hub": row("sensor-hub", cap: 10, work: 0.4)])
        }
        func row(_ name: String, used: Double, cap: Int?, state: BudgetState, projectCap: Int?) -> BudgetStatus.Row {
            BudgetStatus.Row(projectKey: "/Users/studio/projects/\(name)", projectName: name, used: used, cap: cap, scope: .project,
                             state: state, sessionUsed: used / 2, sessionCap: nil, projectCap: projectCap, defaultCap: nil)
        }
        let payments = over ? row("payments-api", used: 26, cap: 25, state: .over, projectCap: 25) : row("payments-api", used: 21, cap: 25, state: .warn, projectCap: 25)
        let resets = now.addingTimeInterval(3 * 86400 + 5 * 3600)
        return BudgetStatus(
            capture: true, measuring: false, weekPct: 34, resetsAt: resets, defaultCap: nil,
            projects: [],
            sessions: ["sess-payments-api": payments,
                       "sess-llm-play": row("llm-play", used: 2, cap: nil, state: .ok, projectCap: nil),
                       "sess-sensor-hub": row("sensor-hub", used: 3, cap: 10, state: .ok, projectCap: 10)])
    }
}

extension RenderSurfaces {
    @MainActor
    private static func budgetStore(_ inputs: NowInputs, status: BudgetStatus?) -> NowStore {
        let prefs = NowPrefs.ephemeral()
        prefs.tipDismissed = true
        let st = NowStore(model: NowModel.build(inputs), prefs: prefs)
        st.now = { inputs.now }
        st.bodyBudget = 1500
        st.updateBudget(status)
        return st
    }

    @MainActor
    static func budgetSurfaces() -> [Surface] {
        let w = NightWatch.Space.popoverWidth + 56
        func popover(_ st: NowStore, name: String) -> Surface {
            Surface(name: name, width: w, view: AnyView(NWNowPopover(store: st).padding(28).background(NWBackdrop())))
        }
        let scene = NightWatchFixtures.budgetScene()
        let status = NightWatchFixtures.budgetStatus(now: scene.now)
        let editRow = InFlightRow.idPrefix + "sess-payments-api"
        let reviewRow = scene.snapshot.pendingInterventions[0].id

        let rest = budgetStore(scene, status: status)

        let project = budgetStore(scene, status: status)
        project.clickSetBudget(rowId: editRow, sessionId: "sess-payments-api", backend: .claude)
        project.setBudgetValue(35)

        let session = budgetStore(scene, status: status)
        session.clickSetBudget(rowId: editRow, sessionId: "sess-payments-api", backend: .claude)
        session.setBudgetScope(.session)
        session.setBudgetValue(10)

        let noBudget = budgetStore(scene, status: status)
        noBudget.clickSetBudget(rowId: InFlightRow.idPrefix + "sess-llm-play", sessionId: "sess-llm-play", backend: .claude)
        noBudget.setBudgetValue(25)

        let review = budgetStore(scene, status: status)
        review.clickSetBudget(rowId: reviewRow, sessionId: "sess-sensor-hub", backend: .claude)

        let over = budgetStore(scene, status: NightWatchFixtures.budgetStatus(now: scene.now, over: true))

        // The first hours of a week: each card says its share of the work so far, and its bar stays empty.
        let measuring = budgetStore(scene, status: NightWatchFixtures.budgetStatus(now: scene.now, measuring: true))

        let off = budgetStore(scene, status: NightWatchFixtures.budgetStatus(now: scene.now, capture: false))
        let offOpen = budgetStore(scene, status: NightWatchFixtures.budgetStatus(now: scene.now, capture: false))
        offOpen.clickSetBudget(rowId: editRow, sessionId: "sess-payments-api", backend: .claude)

        return [
            popover(rest, name: "popover-budget-rest"),
            popover(project, name: "popover-budget-editor"),
            popover(session, name: "popover-budget-editor-session"),
            popover(noBudget, name: "popover-budget-editor-no-budget"),
            popover(review, name: "popover-budget-editor-review"),
            popover(over, name: "popover-budget-over"),
            popover(measuring, name: "popover-budget-measuring"),
            popover(off, name: "popover-budget-capture-off"),
            popover(offOpen, name: "popover-budget-capture-off-open")
        ]
    }
}
