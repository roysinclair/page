import Foundation

// The budget row on a session card in the menu-bar panel (Designs/budget-caps.md
// §6): a slim line under Open and Steer, and the editor that opens in the card
// from its "Set budget" button. Pure: the panel's store holds the state, the
// views draw it, and Save becomes a `BudgetOp` that goes through the same
// Coordinator path as Page Studio's steppers and the phone's `budget` op.

/// The line on a card: "Budget ▮▮▮▯ 21% of 25%".
struct NowBudgetLine: Equatable {
    /// Usage capture is on. Without it the row has only its button, and the editor says why.
    let captureOn: Bool
    /// Too early in the week to share it out.
    let measuring: Bool
    /// "21% of 25%", "2% · no budget", "stopped at 25%", "Measuring · 63% of work" (or plain "Measuring…"); empty with capture off.
    let text: String
    /// While measuring: the share of the work watched so far the text shows (0–100); nil otherwise or with none yet.
    var work: Double? = nil
    /// The bar's fill, 0…1: against the budget (full = stopped), or the whole week with none.
    let fraction: Double
    let hasBudget: Bool
    /// Amber from 80% of the budget.
    let warm: Bool
    let state: BudgetState

    /// nil when budgets don't cover this session (capture on, but it isn't a known Claude session).
    static func build(status: BudgetStatus, sessionId: String) -> NowBudgetLine? {
        guard status.capture else {
            return NowBudgetLine(captureOn: false, measuring: false, text: "", fraction: 0, hasBudget: false, warm: false, state: .ok)
        }
        guard let r = status.sessions[sessionId] else { return nil }
        let cap = r.cap.flatMap { $0 > 0 ? $0 : nil }
        let fraction = cap.map { min(1, max(0, r.used / Double($0))) } ?? min(1, max(0, r.used / 100))
        // Stopped reads short, so the card's "Set budget" button keeps its words.
        let work = status.measuring ? r.work : nil
        let text = status.measuring ? BudgetCopy.measuringShort(work: work) : (r.state == .over ? cap.map { "stopped at \($0)%" } : nil) ?? r.line
        return NowBudgetLine(captureOn: true, measuring: status.measuring, text: text, work: work,
                             fraction: status.measuring ? 0 : fraction, hasBudget: cap != nil && !status.measuring,
                             warm: r.state != .ok && !status.measuring, state: status.measuring ? .ok : r.state)
    }

    /// The tooltip on the text while measuring (what the share of work means); nil otherwise.
    var help: String? { captureOn && measuring ? BudgetCopy.measuringHelp : nil }

    /// For VoiceOver: "Budget, 21% of 25%"; while measuring "Budget, Measuring · 63% of the work so far".
    var accessibilityText: String {
        guard captureOn else { return "Budget, usage tracking is off" }
        return "Budget, " + (measuring ? BudgetCopy.measuringLong(work: work) : text)
    }
}

/// The inline editor in a card: project or this session, a percent, and what Page will do.
struct BudgetEditor: Equatable {
    enum Scope: String, Equatable {
        case project, session

        var title: String { self == .project ? "Project (all its sessions)" : "This session only" }
    }

    /// The card it is open in (a working row's id, or a finished page's).
    let rowId: String
    let sessionId: String
    let projectKey: String
    let projectName: String
    /// The caps as the card showed them: the project's own (never the default it may be using) and the session's.
    let projectCap: Int?
    let sessionCap: Int?
    let resetsAt: Date?
    /// Usage capture is off: nothing to edit, only the way to turn it on.
    let captureOff: Bool
    var scope: Scope = .project
    var value: Int?

    init(rowId: String, sessionId: String, row: BudgetStatus.Row, resetsAt: Date?) {
        self.rowId = rowId
        self.sessionId = sessionId
        projectKey = row.projectKey
        projectName = row.projectName
        projectCap = row.projectCap
        sessionCap = row.sessionCap
        self.resetsAt = resetsAt
        captureOff = false
        value = row.projectCap
    }

    /// The editor of a card while usage capture is off.
    init(captureOffRowId rowId: String, sessionId: String) {
        self.rowId = rowId
        self.sessionId = sessionId
        projectKey = ""
        projectName = ""
        projectCap = nil
        sessionCap = nil
        resetsAt = nil
        captureOff = true
        value = nil
    }

    /// What the chosen scope has now (the starting point of an edit).
    var seed: Int? { scope == .project ? projectCap : sessionCap }
    var changed: Bool { !captureOff && value != seed }

    mutating func setScope(_ s: Scope) {
        guard s != scope else { return }
        scope = s
        value = seed
    }

    mutating func choose(_ v: Int?) {
        if let v, !BudgetPercent.isValid(v) { return }
        value = v
    }

    mutating func step(up: Bool) { value = up ? BudgetPercent.up(value) : BudgetPercent.down(value) }

    /// What Save does.
    var op: BudgetOp? {
        guard !captureOff else { return nil }
        return scope == .project ? BudgetOp(target: .project(projectKey), pct: value) : BudgetOp(target: .session(sessionId), pct: value)
    }

    /// "Page warns at 20% and stops Night Owl at 25% of the week. Resets Mon 09:00."
    func preview(timeZone: TimeZone = .current) -> String {
        BudgetCopy.preview(name: projectName, cap: value, session: scope == .session, resetsAt: resetsAt, timeZone: timeZone)
    }
}
