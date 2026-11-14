import Foundation
import SwiftUI
@testable import PageCore

// Fixtures and surfaces for every session in the Now panel (Designs/panel-sessions.md): a finished
// turn drawn as an In-flight card is, sessions at their prompt in the IDLE group, the swipe, the
// five seconds of Undo and the Terminals page's toggle. Built as snapshots so they run through the
// same `NowModel.build` as live data. Demo names only: these renders feed the README images.

extension NightWatchFixtures {
    /// One finished turn (sensor-hub, with its page), two sessions in flight (payments-api, llm-play)
    /// and five at their prompt (tokenizer-lab, docs-site, mobile-shell, edge-gateway, infra-notes).
    static func sessionsScene(now: Date = boardNow()) -> NowInputs {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func claude(_ name: String, state: AgentSessionState, active minutes: Double) -> AgentSession {
            AgentSession(backend: .claude, sessionId: "sess-\(name)", cwd: "/Users/studio/projects/\(name)", title: nil,
                         source: .terminal, state: state, lastActivityAt: at(minutes), activeFlags: [], supportsRemoteReply: true)
        }
        let sessions = [
            claude("payments-api", state: .active, active: 1), claude("llm-play", state: .active, active: 1),
            claude("sensor-hub", state: .waitingOnUser, active: 12),
            claude("tokenizer-lab", state: .idle, active: 25), claude("docs-site", state: .idle, active: 47),
            claude("mobile-shell", state: .idle, active: 130), claude("edge-gateway", state: .idle, active: 185),
            claude("infra-notes", state: .idle, active: 240)
        ]
        let working: [String: InFlightFacts] = [
            "sess-payments-api": InFlightFacts(
                steps: [InFlightStep(text: "Edit: /Users/studio/projects/payments-api/src/refunds.ts", at: at(9)),
                        InFlightStep(text: "Bash: npm test -- refunds", at: at(0.6))],
                currentStepIsNewest: true, model: "claude-opus-4-7", startedAt: at(130), busySince: at(12)),
            "sess-llm-play": InFlightFacts(
                steps: [InFlightStep(text: "Edit: Sources/Agent/Planner.swift", at: at(5)),
                        InFlightStep(text: "Bash: cargo test", at: at(1))],
                currentStepIsNewest: true, model: "claude-sonnet-4-5-20250929", startedAt: at(310), busySince: at(20))
        ]
        func idle(model: String, started minutes: Double, turn: String? = nil) -> InFlightFacts {
            InFlightFacts(model: model, startedAt: at(minutes), lastTurn: turn)
        }
        let idleFacts: [String: InFlightFacts] = [
            "sess-sensor-hub": idle(model: "claude-opus-4-7", started: 405),
            "sess-tokenizer-lab": idle(model: "claude-opus-4-7", started: 160, turn: "Changed 3 files (+42 −6) · tests passed"),
            "sess-docs-site": idle(model: "claude-sonnet-4-5-20250929", started: 95, turn: "Changed 1 file (+18 −2)"),
            "sess-mobile-shell": idle(model: "claude-opus-4-7", started: 520),
            "sess-edge-gateway": idle(model: "claude-sonnet-4-5-20250929", started: 260, turn: "Changed 6 files (+210 −58) · tests failed"),
            "sess-infra-notes": idle(model: "claude-haiku-4-5", started: 300)
        ]
        var hosts: [String: SessionHostInfo] = [:]
        for (n, s) in sessions.enumerated() {
            hosts[s.sessionId] = SessionHostInfo(host: n % 3 == 1 ? "tmux" : "cmux", canType: true, typeBlocker: nil, canInterrupt: true)
        }
        let finishedAt = at(12)
        let finished = InterventionEvent(
            id: "sess-sensor-hub-idle-\(Int(finishedAt.timeIntervalSince1970))", sessionId: "sess-sensor-hub",
            cwd: "/Users/studio/projects/sensor-hub", projectName: "sensor-hub", kind: .idle, openedAt: finishedAt,
            context: "Changed 3 files (+120 −14) · tests passed\n\nCalibration now averages five readings per probe.",
            transcriptPath: "", backend: .claude, source: .terminal)
        var i = NowInputs(snapshot: snapshot(sessions: sessions, pending: [finished]), now: now, macName: "Studio MBP", idleSeconds: 5)
        i.route = route
        i.hosts = hosts
        i.facts = working
        i.idleFacts = idleFacts
        return i
    }

    /// One conversation open in two terminals (Designs/session-copies.md): "workspace" working, beside api-server
    /// working and two sessions at their prompt. Demo names only. Used by the popover-sessions-copies renders;
    /// no other scene carries a copy.
    static func copiesScene(now: Date = boardNow()) -> NowInputs {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func claude(_ name: String, state: AgentSessionState, active minutes: Double) -> AgentSession {
            AgentSession(backend: .claude, sessionId: "sess-\(name)", cwd: "/Users/studio/projects/\(name)", title: nil,
                         source: .terminal, state: state, lastActivityAt: at(minutes), activeFlags: [], supportsRemoteReply: true)
        }
        let sessions = [
            claude("workspace", state: .active, active: 1), claude("api-server", state: .active, active: 1),
            claude("docs-site", state: .idle, active: 47), claude("mobile-app", state: .idle, active: 130)
        ]
        let working: [String: InFlightFacts] = [
            "sess-workspace": InFlightFacts(
                steps: [InFlightStep(text: "Edit: Sources/Session/Room.swift", at: at(6)),
                        InFlightStep(text: "Bash: swift test", at: at(0.4))],
                currentStepIsNewest: true, model: "claude-opus-4-7", startedAt: at(130), busySince: at(12)),
            "sess-api-server": InFlightFacts(
                steps: [InFlightStep(text: "Edit: src/routes/orders.ts", at: at(5)),
                        InFlightStep(text: "Bash: npm run build", at: at(1))],
                currentStepIsNewest: true, model: "claude-sonnet-4-5-20250929", startedAt: at(310), busySince: at(20))
        ]
        let idleFacts: [String: InFlightFacts] = [
            "sess-docs-site": InFlightFacts(model: "claude-sonnet-4-5-20250929", startedAt: at(95), lastTurn: "Changed 1 file (+18 −2)"),
            "sess-mobile-app": InFlightFacts(model: "claude-opus-4-7", startedAt: at(520))
        ]
        var hosts: [String: SessionHostInfo] = [:]
        for s in sessions { hosts[s.sessionId] = SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true) }
        var i = NowInputs(snapshot: snapshot(sessions: sessions, pending: []), now: now, macName: "Studio MBP", idleSeconds: 5)
        i.route = route
        i.hosts = hosts
        i.facts = working
        i.idleFacts = idleFacts
        return i
    }

    /// Budgets for that scene: a line under Open and Steer on every card.
    static func sessionsBudget(now: Date = boardNow()) -> BudgetStatus {
        func row(_ name: String, used: Double, cap: Int?, state: BudgetState) -> BudgetStatus.Row {
            BudgetStatus.Row(projectKey: "/Users/studio/projects/\(name)", projectName: name, used: used, cap: cap, scope: .project,
                             state: state, sessionUsed: used / 2, sessionCap: nil, projectCap: cap, defaultCap: nil)
        }
        let rows: [String: BudgetStatus.Row] = [
            "sess-payments-api": row("payments-api", used: 21, cap: 25, state: .warn),
            "sess-llm-play": row("llm-play", used: 2, cap: nil, state: .ok),
            "sess-sensor-hub": row("sensor-hub", used: 0.4, cap: nil, state: .ok),
            "sess-tokenizer-lab": row("tokenizer-lab", used: 3, cap: 10, state: .ok),
            "sess-docs-site": row("docs-site", used: 1, cap: nil, state: .ok),
            "sess-mobile-shell": row("mobile-shell", used: 5, cap: 15, state: .ok),
            "sess-edge-gateway": row("edge-gateway", used: 7, cap: 15, state: .ok),
            "sess-infra-notes": row("infra-notes", used: 0.2, cap: nil, state: .ok)
        ]
        return BudgetStatus(capture: true, measuring: false, weekPct: 34, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600),
                            defaultCap: nil, projects: [], sessions: rows)
    }
}

extension RenderSurfaces {
    @MainActor
    private static func sessionsStore(_ inputs: NowInputs, closesTerminal: Bool = false) -> NowStore {
        let prefs = NowPrefs.ephemeral()
        prefs.tipDismissed = true
        let st = NowStore(model: NowModel.build(inputs), prefs: prefs)
        st.now = { inputs.now }
        // A tall screen, so the cards show whole.
        st.bodyBudget = 1700
        st.updateBudget(NightWatchFixtures.sessionsBudget(now: inputs.now))
        st.dismissClosesTerminal = closesTerminal
        return st
    }

    /// The copies scene's store: "workspace" is open in two terminals.
    @MainActor
    private static func copiesStore(canCloseOther: Bool, confirm: Bool = false) -> NowStore {
        let inputs = NightWatchFixtures.copiesScene()
        let prefs = NowPrefs.ephemeral()
        prefs.tipDismissed = true
        let st = NowStore(model: NowModel.build(inputs), prefs: prefs)
        st.now = { inputs.now }
        st.bodyBudget = 1700
        st.copies = ["sess-workspace": SessionCopies(count: 2, canCloseOther: canCloseOther)]
        if confirm { st.copiesConfirm = "sess-workspace" }
        return st
    }

    @MainActor
    static func sessionsSurfaces() -> [Surface] {
        let w = NightWatch.Space.popoverWidth + 56
        func popover(_ st: NowStore, name: String) -> Surface {
            Surface(name: name, width: w, view: AnyView(NWNowPopover(store: st).padding(28).background(NWBackdrop())))
        }
        let scene = NightWatchFixtures.sessionsScene()
        let finishedRow = scene.snapshot.pendingInterventions[0].id
        let idleRow = InFlightRow.idlePrefix + "sess-tokenizer-lab"

        let rest = sessionsStore(scene)
        let collapsed = sessionsStore(scene)
        collapsed.setIdleCollapsed(true)
        let all = sessionsStore(scene)
        all.setIdleExpanded(true)

        // 120 pt into a swipe: the card has moved, and the label says what letting go does.
        let swipe = sessionsStore(scene)
        swipe.swipe = NowStore.Swipe(rowId: finishedRow, offset: 120)
        let swipeClose = sessionsStore(scene, closesTerminal: true)
        swipeClose.swipe = NowStore.Swipe(rowId: finishedRow, offset: 120)
        // An idle card too, swiping the other way.
        let swipeIdle = sessionsStore(scene)
        swipeIdle.swipe = NowStore.Swipe(rowId: idleRow, offset: -120)

        // The five seconds: the card is gone, the line offers Undo.
        let undo = sessionsStore(scene)
        undo.dismiss(rowId: idleRow)
        let undoClose = sessionsStore(scene, closesTerminal: true)
        undoClose.dismiss(rowId: idleRow)
        // After them: its tab closed.
        let closed = sessionsStore(scene, closesTerminal: true)
        closed.dismiss(rowId: finishedRow)
        closed.dismissalCommitted(sessionId: "sess-sensor-hub")
        closed.notice = NowStore.Notice(text: DismissCopy.outcome(project: "sensor-hub", .closed(noun: "cmux tab")).text, failed: false)
        // Or not: it started working again.
        let notClosed = sessionsStore(scene, closesTerminal: true)
        notClosed.dismiss(rowId: finishedRow)
        notClosed.dismissalCommitted(sessionId: "sess-sensor-hub")
        let refusal = DismissCopy.outcome(project: "sensor-hub", .refused(.notIdle(.busy)))
        notClosed.notice = NowStore.Notice(text: refusal.text, failed: refusal.failed)

        // Two put away earlier: the header says so, and brings them back.
        let dismissed = sessionsStore(scene)
        dismissed.updateDismissals(hidden: ["sess-edge-gateway", "sess-infra-notes"])

        // The pointer on an idle card: selected, its buttons and × lit.
        let hover = sessionsStore(scene)
        hover.select(idleRow)

        return [
            popover(rest, name: "popover-sessions-rest"),
            popover(collapsed, name: "popover-sessions-idle-collapsed"),
            popover(all, name: "popover-sessions-idle-all"),
            popover(swipe, name: "popover-sessions-swipe"),
            popover(swipeClose, name: "popover-sessions-swipe-close"),
            popover(swipeIdle, name: "popover-sessions-swipe-idle"),
            popover(undo, name: "popover-sessions-undo"),
            popover(undoClose, name: "popover-sessions-undo-close"),
            popover(closed, name: "popover-sessions-closed"),
            popover(notClosed, name: "popover-sessions-not-closed"),
            popover(dismissed, name: "popover-sessions-dismissed-show"),
            popover(hover, name: "popover-sessions-selected"),
            // One conversation open in two terminals: the amber line and Close the other; its confirm; and the
            // other copy busy, so the line stands alone.
            popover(copiesStore(canCloseOther: true), name: "popover-sessions-copies"),
            popover(copiesStore(canCloseOther: true, confirm: true), name: "popover-sessions-copies-confirm"),
            popover(copiesStore(canCloseOther: false), name: "popover-sessions-copies-busy")
        ]
    }
}
