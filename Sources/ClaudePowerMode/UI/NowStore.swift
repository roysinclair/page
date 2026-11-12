import Foundation
import Combine
import SwiftUI
@testable import PageCore

/// A button on the panel that is not a row key.
enum NowCommand: Equatable {
    case resumePaused
    case newSession
    case preferences
    case more
    case openConfig
}

/// What the panel shows besides the model: the keyboard state, a hold in
/// progress, rows being answered, and the short line after an action. Views
/// read it; keys and clicks go through `handle` / `click` / `beginHold`, and
/// the effects they produce leave through `perform` — the store holds no
/// reference to the Coordinator, a terminal or the window, so the render
/// harness builds it with plain values.
final class NowStore: ObservableObject {
    struct Notice: Equatable {
        let text: String
        let failed: Bool
    }

    @Published var model: NowModel
    @Published private(set) var state = NowPanelState()
    /// 0...1 fill of the hold in progress (0 through its dead zone).
    @Published private(set) var holdProgress: Double = 0
    /// Rows whose reply is on its way (dimmed; their keys do nothing).
    @Published private(set) var sending: Set<String> = []
    /// The latest result of an action that has no receipt (Stop all, O).
    @Published var notice: Notice? {
        didSet {
            // A result line fades after a while; a newer one replaces it first.
            guard let n = notice else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.notice == n { self?.notice = nil }
            }
        }
    }
    /// What Stop all would do, named while the hold fills.
    @Published var stopScope: String = ""
    @Published var composerFocusToken = 0
    /// When each signature motion started (arrivals, receipt threads, the
    /// exhale, dusk, dawn, the hold's unwind and burst). Views turn these into
    /// frames with the pure models in SignatureMotion.swift.
    @Published private(set) var motion = NowMotion()
    /// What the list draws: the model's rows in an order that holds still under
    /// the pointer, plus the rows still folding away after a verified answer.
    @Published private(set) var shownRows: [DecideRow] = []
    /// Arrivals waiting behind the "New ↑" pill while the order is held.
    @Published private(set) var queuedNew = 0
    /// What happened to a message typed from an In-flight row, by row id:
    /// shown in the row itself (typed, queued, or refused with the reason).
    @Published private(set) var flightReceipts: [String: InFlightReceipt] = [:]
    /// Held messages whose Delete is on its way (their button waits).
    @Published private(set) var deletingHeld: Set<String> = []
    /// The first-run tip was dismissed (remembered in UserDefaults).
    @Published private(set) var tipDismissed = false
    /// Bumped by "N working" in the header: the cards scroll to the top.
    @Published private(set) var flightJumpToken = 0
    /// Budgets as the Mac last reported them (nil until it has: no budget rows are drawn then).
    @Published private(set) var budget: BudgetStatus?
    /// Dismissals in their five seconds of Undo, oldest first. They outlive a panel close: the
    /// controller commits them on its own timer, so the store keeps them hidden until then.
    @Published private(set) var pendingDismissals: [PendingDismissal] = []
    /// The sessions the Mac's ledger hides right now (dismissed, and not yet worked again).
    @Published private(set) var ledgerHidden: Set<String> = []
    /// A card dragged sideways: the finger moves it, and the label behind it says Dismiss.
    @Published var swipe: Swipe?
    /// Bumped when a card group's scroller measures itself, so the panel fits its window again.
    @Published private(set) var layoutToken = 0
    /// "Also close its terminal" is on (Preferences ▸ Terminals): the words and colours say so.
    @Published var dismissClosesTerminal = false
    /// Dismissals whose five seconds are over: still kept out until the Mac's ledger says so.
    @Published private(set) var committedDismissals: [String: Date] = [:]
    /// The card under the pointer (not published: moving over cards redraws nothing). The
    /// panel's scroll monitor swipes it when it can be dismissed.
    var hoveredCard: String?

    /// A card being swiped, by row id, and how far it has moved (either direction).
    struct Swipe: Equatable {
        let rowId: String
        var offset: Double
    }
    /// The height the panel can give everything between its header and its
    /// footer: what is left of the screen (set by the panel when it opens).
    var bodyBudget: CGFloat = 760

    /// The tallest the In-flight cards may grow before they scroll: the body's
    /// budget less the rows above them and the runway, tip and status around them.
    var flightCardsMaxHeight: CGFloat {
        let room = cardsRoom
        return max(260, showsIdleGroup && !flightRows.isEmpty ? room * 0.55 : room)
    }

    /// The same for the IDLE group's cards: what the In-flight group leaves.
    var idleCardsMaxHeight: CGFloat {
        let room = cardsRoom
        return max(220, flightRows.isEmpty ? room : room * 0.45)
    }

    /// The body's budget less the rows above the card groups and the runway, tip and status around them.
    private var cardsRoom: CGFloat {
        let rows = CGFloat(min(model.rows.count, NowModel.visibleRows)) * 100
        return max(260, bodyBudget - rows - 110)
    }

    /// The IDLE group is drawn: it has cards, or it has dismissed sessions to bring back.
    var showsIdleGroup: Bool { !idleRows.isEmpty || dismissedCount > 0 }

    var timeZone: TimeZone = .current
    var perform: (NowEffect) -> Void = { _ in }
    var command: (NowCommand) -> Void = { _ in }
    var now: () -> Date = Date.init
    /// A hold crossed one of its ticks (25, 50, 75 %, full): the panel plays a
    /// haptic on a Force Touch trackpad.
    var haptic: (Double) -> Void = { _ in }
    /// The panel is on screen: arrivals, the exhale, dusk and dawn only play then.
    var animates = false
    /// The pointer is over the list: nothing re-sorts under it.
    var pointerInList = false {
        didSet { if pointerInList != oldValue { refreshShown() } }
    }

    /// What the panel remembers between launches (UserDefaults, never config.json).
    let prefs: NowPrefs
    /// In-flight rows as last seen, so a row keeps its place while a draft or
    /// receipt is open after its turn ends.
    private var lastFlight: [String: InFlightRow] = [:]
    /// "Type…" asked for from the classic menu before the host was probed:
    /// the composer opens when the probe answers.
    private var wantedComposer: (sessionId: String, until: Date)?

    private var timer: Timer?
    /// Row ids already on screen (or seen while the panel was closed), so only
    /// genuinely new ones fly in.
    private var knownIds: Set<String> = []
    /// The ids in the order last drawn.
    private var shownIds: [String] = []
    /// The paused agents, kept through dusk so dawn can relight their stars.
    private var lastPaused: [NowModel.PausedAgent] = []

    init(model: NowModel, prefs: NowPrefs = .standard) {
        self.model = model
        self.prefs = prefs
        tipDismissed = prefs.tipDismissed
        state.inFlightCollapsed = prefs.inFlightCollapsed
        state.idleCollapsed = prefs.idleCollapsed
        for r in model.flight { lastFlight[r.id] = r }
        shownRows = model.rows
        shownIds = model.rows.map(\.id)
        knownIds = Set(shownIds)
        if model.mood == .dusk { lastPaused = model.paused }
    }

    deinit { timer?.invalidate() }

    // MARK: model

    /// A new model after a snapshot. The selection stays by id, and is dropped
    /// when its row has gone.
    func update(_ model: NowModel) {
        let old = self.model
        if self.model != model { self.model = model }
        for r in model.flight { lastFlight[r.id] = r }
        let reconciled = NowKeys.reconcile(state, rows: model.rows, flights: flightRows, idle: idleRows)
        if reconciled != state { state = reconciled }
        let kept = Set(flightRows.map(\.id))
        lastFlight = lastFlight.filter { kept.contains($0.key) }
        resolveWantedComposer()
        let still = sending.intersection(Set(model.rows.map(\.id)))
        if still != sending { sending = still }
        noteMotion(from: old, to: model)
        pruneSettledThreads()
        refreshShown()
    }

    /// The working sessions' rows as drawn: the model's, plus any whose turn
    /// ended while a draft or a receipt is still open (so typing is never
    /// lost, and the receipt has a row to sit in). A card whose turn ended and
    /// that was put away stays out.
    var flightRows: [InFlightRow] {
        var rows = model.flight
        let live = Set(rows.map(\.id))
        var keep = Set(flightReceipts.keys)
        if let c = state.composer { keep.insert(c.rowId) }
        if let e = state.budgetEditor { keep.insert(e.rowId) }
        let hidden = hiddenSessionIds
        for id in keep.sorted() where !live.contains(id) {
            if let r = lastFlight[id], r.kind == .session, !hidden.contains(r.sessionId) { rows.append(r.finished) }
        }
        return rows
    }

    /// Sessions kept out of the cards: in their five seconds of Undo, committed and waiting for
    /// the ledger to say so, or hidden by the ledger.
    var hiddenSessionIds: Set<String> {
        Set(pendingDismissals.map(\.id)).union(committedDismissals.keys).union(ledgerHidden)
    }

    /// The IDLE group's cards: sessions at their prompt, less any that has a row of its own (a
    /// FINISHED, Decide or Look row, or a card whose turn just ended) and any put away.
    var idleRows: [InFlightRow] {
        IdleGroup.contents(idle: model.idle, rows: model.rows, flights: flightRows, hidden: hiddenSessionIds)
    }

    /// Every card the keys, hover and clicks may act on: the working ones and the idle ones.
    var cardRows: [InFlightRow] { flightRows + idleRows }

    /// "2 dismissed · Show": the live sessions the ledger hides (not those still in their Undo).
    var dismissedCount: Int { ledgerHidden.count }

    /// A finished turn's session, as its idle card: where it runs, its model and when it last
    /// did something. nil when Page hasn't read them (a FINISHED card then leaves the line out).
    func sessionCard(for sessionId: String) -> InFlightRow? {
        model.idle.first { $0.sessionId == sessionId }
    }

    var selectedId: String? { state.selectedId }
    var expanded: Bool { state.expanded }
    var composer: NowPanelState.Composer? { state.composer }
    var budgetEditor: BudgetEditor? { state.budgetEditor }
    var hold: HoldGesture? { state.hold }

    /// Rows the keys may act on: the ones drawn, not ones held behind the pill,
    /// folding away, or already being answered.
    private var keyRows: [DecideRow] {
        let live = Set(model.rows.map(\.id))
        return shownRows.filter { live.contains($0.id) && !sending.contains($0.id) }
    }

    /// Sessions whose finished-turn rows are kept out: put away and in their Undo, committed, or hidden by
    /// the ledger. The last is safe (the ledger never hides a session that has a different page open), and it
    /// keeps a page the backend still lists for a moment from coming back before the next tick.
    private var hiddenFinishedSessionIds: Set<String> { hiddenSessionIds }

    // MARK: keys and clicks

    /// Feeds a key; true when the panel consumed it.
    @discardableResult
    func handle(_ press: NowKeyPress) -> Bool {
        let before = state
        let r = NowKeys.handle(press, state: state, rows: keyRows, flights: flightRows, idle: idleRows, now: now())
        apply(r.state, effect: r.effect)
        if press.phase == .up { return before.hold != nil }
        explainFlightKey(press, before: before, result: r)
        // ⌘N, ⌘. and ⌘, are ours; every other ⌘ combination (⌘Q, ⌘C, ⌘V …) goes on to the responders.
        if press.command {
            switch press.key {
            case .char("n"), .char("."), .char(","): return true
            default: return false
            }
        }
        // With the composer open, typing and editing belong to its text field:
        // only Esc, Return and Command combinations are ours.
        if before.composer != nil {
            switch press.key {
            case .esc, .ret: return true
            default: return false
            }
        }
        return true
    }

    /// O or T on a selected working row that did nothing: say why, as the
    /// button's click does, instead of staying silent.
    private func explainFlightKey(_ press: NowKeyPress, before: NowPanelState, result r: (state: NowPanelState, effect: NowEffect)) {
        guard r.effect == .none, r.state.composer == nil, before.composer == nil, before.budgetEditor == nil, !before.showShortcuts,
              !press.hasModifiers, !press.isRepeat, case .char(let raw) = press.key,
              let id = before.selectedId, let row = cardRows.first(where: { $0.id == id }) else { return }
        switch raw.lowercased() {
        case PanelKeys.type.lowercased():
            if row.kind == .localModel { notice = Notice(text: "Local model · Page Studio can't steer it", failed: true) }
            else { openFlightComposer(row) }
        case PanelKeys.open.lowercased():
            if row.kind == .localModel { notice = Notice(text: "Local model · Page Studio can't open it", failed: true) }
            else if !row.actions.canOpen { notice = Notice(text: row.actions.openBlocker ?? "Page Studio can't open this one", failed: true) }
        default: break
        }
    }

    func select(_ id: String) {
        guard model.rows.contains(where: { $0.id == id }) || cardRows.contains(where: { $0.id == id }),
              state.composer == nil, state.budgetEditor == nil else { return }
        var s = state
        s.selectedId = id
        s.hold = nil
        state = s
    }

    func setExpanded(_ on: Bool) {
        var s = state
        s.expanded = on
        state = s
    }

    // MARK: in flight

    /// The pointer moved onto a working session's row: it becomes the
    /// selected row, so the keys O and T act on the row the buttons are on.
    /// Selecting sends nothing, and nothing on a working row sends without a
    /// composer and a Return. A draft or a hold is never moved off its row.
    ///
    /// `pointer` (the screen position of the mouse) tells a real move from rows
    /// shifting under a still pointer: with the same position as the last hover,
    /// nothing is selected, so a decision row you were on keeps the keys. The
    /// first hover only takes the selection when no decision row has it.
    func hoverFlight(_ id: String, pointer: CGPoint? = nil) {
        guard state.composer == nil, state.budgetEditor == nil, state.hold == nil, state.selectedId != id else { return }
        if let p = pointer {
            let previous = lastHoverPointer
            lastHoverPointer = p
            let cards = cardRows
            let onDecision = state.selectedId.map { sid in !cards.contains { $0.id == sid } } ?? false
            if let q = previous { guard hypot(p.x - q.x, p.y - q.y) > 0.5 else { return } }
            else if onDecision { return }
        }
        select(id)
    }

    /// Where the mouse was at the last card hover (see `hoverFlight`).
    private var lastHoverPointer: CGPoint?

    /// "N working" in the header: shows the In-flight cards (opening the group
    /// if it was collapsed, closing the shortcuts sheet if it covers them),
    /// selects the first and scrolls to the group. Sends nothing.
    func jumpToInFlight() {
        guard let plan = InFlightJump.plan(rows: flightRows, state: state) else { return }
        var s = state
        if plan.closeShortcuts { s.showShortcuts = false }
        if plan.uncollapse {
            s.inFlightCollapsed = false
            prefs.inFlightCollapsed = false
        }
        // A half-typed message is never moved off its card.
        if s.composer == nil { s.selectedId = plan.selectId }
        s.hold = nil
        state = s
        flightJumpToken += 1
    }

    func setInFlightCollapsed(_ on: Bool) {
        var s = state
        s.inFlightCollapsed = on
        if on, let id = s.selectedId, flightRows.contains(where: { $0.id == id }) { s.selectedId = nil }
        if on, let c = s.composer, c.kind == .type { s.composer = nil }
        state = s
        prefs.inFlightCollapsed = on
    }

    func setInFlightExpanded(_ on: Bool) {
        var s = state
        s.inFlightExpanded = on
        state = s
    }

    /// The IDLE group's header: collapses it to its names, or opens it again (remembered).
    func setIdleCollapsed(_ on: Bool) {
        var s = state
        s.idleCollapsed = on
        if on, let id = s.selectedId, idleRows.contains(where: { $0.id == id }) { s.selectedId = nil }
        if on, let c = s.composer, c.kind == .type, idleRows.contains(where: { $0.id == c.rowId }) { s.composer = nil }
        state = s
        prefs.idleCollapsed = on
    }

    func setIdleExpanded(_ on: Bool) {
        var s = state
        s.idleExpanded = on
        state = s
    }

    /// A click on one of a working session's buttons.
    func clickFlight(_ action: InFlightAction, on row: InFlightRow) {
        guard cardRows.contains(where: { $0.id == row.id }) else { return }
        if state.composer != nil && action == .steer && state.composer?.rowId == row.id { return }
        // A half-typed reply is never thrown away by a click elsewhere.
        if let c = state.composer, !c.text.isEmpty {
            notice = Notice(text: "Finish or close your message first · Esc closes it", failed: false)
            return
        }
        cancelComposer()
        select(row.id)
        switch action {
        case .open:
            let effect = NowKeys.effect(forFlightClick: .open, row: row)
            if effect == .none {
                notice = Notice(text: row.actions.openBlocker ?? "Page Studio can't open this one", failed: true)
            } else {
                apply(state, effect: effect)
            }
        case .steer:
            openFlightComposer(row)
        }
    }

    /// Opens the one-line composer in a working session's row, if Page can type there.
    @discardableResult
    func openFlightComposer(_ row: InFlightRow) -> Bool {
        guard row.actions.canType, let target = row.target else {
            notice = Notice(text: row.actions.checking ? "Checking where it runs · try again in a moment"
                                                        : "Can't steer here · \(row.actions.typeBlocker ?? "Page can't type into this session")",
                            failed: !row.actions.checking)
            return false
        }
        if let e = state.budgetEditor, e.changed {
            notice = Notice(text: "Save or cancel your budget change first · Esc closes it", failed: false)
            return false
        }
        var s = state
        s.selectedId = row.id
        s.composer = NowPanelState.Composer(rowId: row.id, kind: .type, target: target)
        s.budgetEditor = nil
        s.hold = nil
        state = s
        composerFocusToken += 1
        return true
    }

    /// "Type…" from the classic menu: opens the composer on that session's
    /// row, waiting a moment for the host probe if it has not answered.
    func requestComposer(forSessionId id: String) {
        wantedComposer = (id, now().addingTimeInterval(4))
        resolveWantedComposer()
    }

    private func resolveWantedComposer() {
        guard let w = wantedComposer else { return }
        if let row = cardRows.first(where: { $0.sessionId == w.sessionId && $0.kind == .session }) {
            if row.actions.canType || !row.actions.checking {
                wantedComposer = nil
                openFlightComposer(row)
                return
            }
        }
        if now() > w.until { wantedComposer = nil }
    }

    /// Delete beside a message a phone asked to hold until the turn ends.
    func deleteHeld(_ clientId: String, on row: InFlightRow) {
        let effect = NowKeys.effect(forHeldDelete: clientId, row: row)
        guard effect != .none, !deletingHeld.contains(clientId) else { return }
        deletingHeld.insert(clientId)
        apply(state, effect: effect)
    }

    /// The delete answered: deleted (nothing typed), too late, or gone already.
    func finishDeletingHeld(_ clientId: String, result: SessionCommandResult) {
        deletingHeld.remove(clientId)
        let deleted = result.retract == "deleted"
        let detail = result.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        notice = Notice(text: detail.isEmpty ? (deleted ? HeldOutbox.deletedDetail : "Couldn't delete it") : detail, failed: !deleted)
    }

    /// The input path answered (or timed out): the receipt goes in the row.
    func finishTyping(sessionId: String, result: SessionCommandResult) {
        let id = InFlightRow.idPrefix + sessionId
        let route = cardRows.first { $0.sessionId == sessionId }?.route
        setReceipt(InFlightReceipt.from(result, route: route, at: now()), for: id)
    }

    private func setReceipt(_ r: InFlightReceipt, for id: String) {
        flightReceipts[id] = r
        guard r.outcome != .sending else { return }
        let linger: TimeInterval = r.outcome == .typed ? 12 : 20
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            guard let self, self.flightReceipts[id] == r else { return }
            self.flightReceipts[id] = nil
            self.lastFlight = self.lastFlight.filter { k, _ in self.flightRows.contains { $0.id == k } }
        }
    }

    // MARK: shortcuts sheet and the first-run tip

    func toggleShortcuts() {
        var s = state
        s.showShortcuts.toggle()
        if s.showShortcuts { s.composer = nil; s.hold = nil }
        state = s
    }

    /// The first-run tip, until it is dismissed once.
    var tipVisible: Bool {
        PanelTip.shouldShow(dismissed: tipDismissed, hasDecisionRows: !model.rows.isEmpty, hasInFlightRows: !model.flight.isEmpty)
    }

    func dismissTip() {
        tipDismissed = true
        prefs.tipDismissed = true
    }

    /// A click on one of a row's key caps. A cap that types (1, Return, Esc)
    /// first selects its row, which shows what will be typed and where; it
    /// acts on the next click. T and O type nothing and act at once.
    func click(_ action: KeyHint.Action, on row: DecideRow) {
        // Not a row already answered, nor one still folding away after its page closed.
        guard !sending.contains(row.id), model.rows.contains(where: { $0.id == row.id }) else { return }
        let wasSelected = state.selectedId == row.id
        select(row.id)
        if !wasSelected, action == .approve || action == .deny { return }
        if action == .tellInstead {
            guard (row.keys + row.moreKeys).contains(where: { $0.action == .tellInstead }) else { return }
            if let e = state.budgetEditor, e.changed {
                notice = Notice(text: "Save or cancel your budget change first · Esc closes it", failed: false)
                return
            }
            var s = state
            s.composer = NowPanelState.Composer(rowId: row.id)
            s.budgetEditor = nil
            state = s
            composerFocusToken += 1
            return
        }
        let effect = NowKeys.effect(forClickOn: action, row: row)
        if effect != .none { apply(state, effect: effect) }
    }

    var composerText: String {
        get { state.composer?.text ?? "" }
        set {
            guard var c = state.composer else { return }
            c.text = newValue
            var s = state
            s.composer = c
            state = s
        }
    }

    func cancelComposer() {
        var s = state
        s.composer = nil
        state = s
    }

    func submitComposer() {
        handle(NowKeyPress(key: .ret))
    }

    // MARK: budget

    /// The Mac's budgets, after each snapshot.
    func updateBudget(_ status: BudgetStatus?) {
        guard budget != status else { return }
        budget = status
    }

    /// The row under a Claude session's Open and Steer: nil when the Mac hasn't said, or budgets don't cover it.
    func budgetLine(sessionId: String, backend: AgentBackendID?) -> NowBudgetLine? {
        guard backend == .claude, let budget else { return nil }
        return NowBudgetLine.build(status: budget, sessionId: sessionId)
    }

    /// "Set budget": opens the editor in this card, or closes it if it is already open there.
    /// A half-typed message (or an unsaved budget change on another card) is never thrown away.
    func clickSetBudget(rowId: String, sessionId: String, backend: AgentBackendID?) {
        guard let budget, backend == .claude else { return }
        if let e = state.budgetEditor {
            if e.rowId == rowId { cancelBudgetEditor(); return }
            if e.changed {
                notice = Notice(text: "Save or cancel your budget change first · Esc closes it", failed: false)
                return
            }
        }
        if let c = state.composer, !c.text.isEmpty {
            notice = Notice(text: "Finish or close your message first · Esc closes it", failed: false)
            return
        }
        let editor: BudgetEditor
        if budget.capture, let row = budget.sessions[sessionId] {
            editor = BudgetEditor(rowId: rowId, sessionId: sessionId, row: row, resetsAt: budget.resetsAt)
        } else if !budget.capture {
            editor = BudgetEditor(captureOffRowId: rowId, sessionId: sessionId)
        } else {
            return
        }
        var s = state
        s.composer = nil
        s.budgetEditor = editor
        s.selectedId = rowId
        s.hold = nil
        state = s
    }

    private func editBudget(_ change: (inout BudgetEditor) -> Void) {
        guard var e = state.budgetEditor else { return }
        change(&e)
        var s = state
        s.budgetEditor = e
        state = s
    }

    func setBudgetScope(_ scope: BudgetEditor.Scope) { editBudget { $0.setScope(scope) } }
    func setBudgetValue(_ v: Int?) { editBudget { $0.choose(v) } }

    func cancelBudgetEditor() {
        guard state.budgetEditor != nil else { return }
        var s = state
        s.budgetEditor = nil
        state = s
    }

    /// Save: the same effect Return has in the editor.
    func saveBudget() { handle(NowKeyPress(key: .ret)) }

    /// The panel closed (or is opening): nothing stays selected, held or
    /// half-typed, and nothing mid-motion. What is on screen now counts as seen,
    /// so opening the panel never flies the existing rows in.
    func reset() {
        endHold()
        state = NowPanelState()
        state.inFlightCollapsed = prefs.inFlightCollapsed
        state.idleCollapsed = prefs.idleCollapsed
        swipe = nil
        hoveredCard = nil
        notice = nil
        // A typed message's receipt stays through a close, as a pending reply's thread does: the
        // answer may land after the panel is gone, and it must still be there when it opens again.
        // Its own timers expire it.
        wantedComposer = nil
        // Threads still waiting on the Mac stay (the reply is still on its way).
        motion = NowMotion(threads: motion.threads.filter { $0.value.resolvedAt == nil })
        knownIds = Set(model.rows.map(\.id))
        shownIds = []
        pointerInList = false
        refreshShown()
    }

    // MARK: holds

    /// A press with the mouse (the hold-1 cap, the footer's stop). Armed once
    /// per press: moving the pointer while the button is down never starts a
    /// second hold, and a hold that has finished does not restart until the
    /// button has been released.
    private var mouseHoldLatched = false

    func mouseHoldBegan(_ kind: HoldGesture.Kind) {
        guard !mouseHoldLatched else { return }
        mouseHoldLatched = true
        if case .approve(let id) = kind { select(id) }
        beginHold(kind)
    }

    func mouseHoldEnded() {
        mouseHoldLatched = false
        endHold()
    }

    func beginHold(_ kind: HoldGesture.Kind) {
        guard state.hold == nil else { return }
        if case .approve(let id) = kind {
            // Only an Irreversible row that is still there and not already being answered.
            guard !sending.contains(id),
                  let row = model.rows.first(where: { $0.id == id }),
                  row.keys.contains(where: { $0.action == .approveHold }) else { return }
        }
        var s = state
        s.hold = HoldGesture(kind: kind, startedAt: now())
        state = s
        startTicking()
    }

    func endHold() {
        guard state.hold != nil else { return }
        var s = state
        s.hold = nil
        state = s
        stopTicking()
        refreshShown()
    }

    /// Drives the ring while a hold is on.
    func tick() {
        let before = holdProgress
        let r = NowKeys.tick(state: state, now: now())
        if let h = r.state.hold {
            holdProgress = h.progress(now: now())
        } else {
            holdProgress = 0
        }
        // The ticks at 25, 50 and 75 %, and full (the last one as it completes).
        let reached = r.state.hold == nil && r.effect != .none ? 1 : holdProgress
        for t in HoldRingModel.ticksCrossed(from: before, to: reached) { haptic(t) }
        if r.state != state { state = r.state }
        if r.effect != .none { apply(r.state, effect: r.effect) }
        if state.hold == nil { stopTicking() }
    }

    /// For the render harness: shows a hold part-way through without a timer.
    func previewHold(_ kind: HoldGesture.Kind, progress: Double) {
        let h = HoldGesture(kind: kind, startedAt: now())
        let at = h.deadZone + progress * (h.duration - h.deadZone)
        var s = state
        s.hold = HoldGesture(kind: kind, startedAt: now().addingTimeInterval(-at))
        state = s
        holdProgress = progress
        stopScope = StopScope.describe(working: model.stoppableCount)
    }

    /// The hold the timer is driving, for the unwind when it is let go early.
    private var tickingKind: HoldGesture.Kind?

    private func startTicking() {
        stopTicking()
        tickingKind = state.hold?.kind
        motion.unwind = nil
        stopScope = StopScope.describe(working: model.stoppableCount)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
        // Let go early: the ring unwinds backwards from where it was (nothing is sent).
        if let kind = tickingKind, holdProgress > 0.001, holdProgress < 1 {
            let u = NowMotion.Unwind(kind: kind, from: holdProgress, at: now())
            motion.unwind = u
            DispatchQueue.main.asyncAfter(deadline: .now() + HoldRingModel.unwindDuration(from: u.from) + 0.05) { [weak self] in
                if self?.motion.unwind == u { self?.motion.unwind = nil }
            }
        }
        tickingKind = nil
        holdProgress = 0
    }


    // MARK: dismissing finished and idle sessions

    /// A card's width, for deciding whether a drag has gone far enough (the panel's width less
    /// the padding the groups give their cards).
    var cardWidth: Double { Double(NightWatch.Space.popoverWidth) - 20 }

    /// A card group found its height: the window is fitted to the panel again.
    func cardsResized() { layoutToken += 1 }

    func setHover(_ id: String, inside: Bool) {
        if inside { hoveredCard = id } else if hoveredCard == id { hoveredCard = nil }
    }

    /// What a card stands for, if it may be put away: a finished turn, or a card of a session
    /// that is not working. Never a working card, a Decide or a Look row.
    func dismissTarget(forRowId id: String) -> DismissTarget? {
        if let row = model.rows.first(where: { $0.id == id }) { return DismissTarget.of(row) }
        if let card = cardRows.first(where: { $0.id == id }) { return DismissTarget.of(card) }
        return nil
    }

    /// Whether the card takes the swipe, the × and ⌫: it can be dismissed and is not being answered.
    func canDismiss(_ id: String) -> Bool {
        !sending.contains(id) && dismissTarget(forRowId: id) != nil
    }

    /// Where the card's session runs, for the tooltip and the status line.
    func route(forRowId id: String) -> String? {
        if let row = model.rows.first(where: { $0.id == id }) { return sessionCard(for: row.sessionId)?.route }
        return cardRows.first { $0.id == id }?.route
    }

    /// The × tooltip: "Dismiss · ⌫ · hides it until its next turn", or with the setting on,
    /// "…also closes its cmux tab".
    func dismissHelp(forRowId id: String) -> String {
        // Only a Claude Code session's terminal is ever closed.
        let noun = dismissTarget(forRowId: id)?.backend == .claude ? TerminalClose.noun(forRoute: route(forRowId: id)) : nil
        return DismissCopy.tooltip(closesTerminal: dismissClosesTerminal, noun: noun)
    }

    /// The words behind a card as it swipes: teal "Dismiss", or amber "Dismiss · close tab".
    var swipeLabel: String { dismissClosesTerminal ? DismissCopy.swipeCloseLabel : DismissCopy.swipeLabel }

    /// The newest dismissal still in its Undo: what the status line speaks for.
    var dismissStatus: PendingDismissal? { pendingDismissals.last }

    /// Puts a card away: it leaves at once (its slot closes with the gap motion; under Reduce
    /// Motion it fades), and its five seconds of Undo begin. Nothing else happens until they end:
    /// the controller owns the timer and commits it, even if the panel has closed.
    func dismiss(rowId: String) {
        guard let target = dismissTarget(forRowId: rowId), !sending.contains(rowId),
              !pendingDismissals.contains(where: { $0.id == target.sessionId }) else { return }
        let noun = target.backend == .claude ? TerminalClose.noun(forRoute: route(forRowId: rowId)) : nil
        let pending = PendingDismissal(target: target, startedAt: now(), closesTerminal: dismissClosesTerminal, closeNoun: noun)
        let slot = slot(of: rowId)
        let change = { [self] in
            closeGap(at: slot, rowId: rowId)
            pendingDismissals.append(pending)
            var s = state
            if s.selectedId == rowId { s.selectedId = nil }
            if let c = s.composer, c.rowId == rowId { s.composer = nil }
            if let e = s.budgetEditor, e.rowId == rowId { s.budgetEditor = nil }
            state = s
            swipe = nil
            if hoveredCard == rowId { hoveredCard = nil }
            refreshShown()
        }
        if NightWatch.systemReduceMotion { withAnimation(.easeOut(duration: 0.18)) { change() } } else { change() }
        perform(.startDismissal(pending))
    }

    /// Undo: the card comes back and nothing else happens.
    func undoDismissal() {
        guard let p = pendingDismissals.last else { return }
        pendingDismissals.removeAll { $0.id == p.id }
        refreshShown()
        perform(.undoDismissal(sessionId: p.id))
    }

    /// The five seconds are over and the controller has handed the dismissal to the Coordinator:
    /// the line stops offering Undo, and the card stays out until the Mac's ledger says it is hidden.
    func dismissalCommitted(sessionId: String) {
        pendingDismissals.removeAll { $0.id == sessionId }
        committedDismissals[sessionId] = now()
        refreshShown()
    }

    /// The Mac's ledger, after each snapshot: the live sessions it hides.
    func updateDismissals(hidden: Set<String>) {
        if hidden != ledgerHidden { ledgerHidden = hidden }
        let t = now()
        let kept = committedDismissals.filter { id, at in !hidden.contains(id) && t.timeIntervalSince(at) < 12 }
        if kept.count != committedDismissals.count { committedDismissals = kept }
        refreshShown()
    }

    /// "N dismissed · Show": they all come back (the Mac clears its ledger).
    func restoreDismissed() {
        guard !ledgerHidden.isEmpty else { return }
        ledgerHidden = []
        refreshShown()
        perform(.restoreDismissed)
    }

    /// Where a card sat: in the list of finished turns and pages, or in one of the two card groups.
    private enum Slot {
        case row(Int)
        case card(NowMotion.CardGap.Group, Int)
    }

    private func slot(of rowId: String) -> Slot? {
        if let i = shownRows.firstIndex(where: { $0.id == rowId }) { return .row(i) }
        let flights = InFlightLayout.visible(flightRows, collapsed: state.inFlightCollapsed, expanded: state.inFlightExpanded).shown
        if let i = flights.firstIndex(where: { $0.id == rowId }) { return .card(.flight, i) }
        let idle = InFlightLayout.visible(idleRows, collapsed: state.idleCollapsed, expanded: state.idleExpanded).shown
        if let i = idle.firstIndex(where: { $0.id == rowId }) { return .card(.idle, i) }
        return nil
    }

    /// The cards below the one that left glide up into its place (`NowMotion.gaps` for the rows,
    /// `cardGaps` for the two card groups, so an idle card going never moves a decision row).
    private func closeGap(at slot: Slot?, rowId: String) {
        guard let slot else { return }
        let at = now()
        switch slot {
        case .row(let i):
            motion.gaps.append(NowMotion.Gap(index: i, rowId: rowId, at: at))
            DispatchQueue.main.asyncAfter(deadline: .now() + NowMotion.gapDuration + 0.05) { [weak self] in
                self?.motion.gaps.removeAll { $0.at == at }
            }
        case .card(let group, let i):
            motion.cardGaps.append(NowMotion.CardGap(group: group, index: i, rowId: rowId, at: at))
            DispatchQueue.main.asyncAfter(deadline: .now() + NowMotion.gapDuration + 0.05) { [weak self] in
                self?.motion.cardGaps.removeAll { $0.at == at }
            }
        }
    }

    // MARK: swiping

    /// A sideways drag starts on a card: only a dismissable one takes it.
    @discardableResult
    func swipeBegan(rowId: String) -> Bool {
        guard canDismiss(rowId), swipe == nil || swipe?.rowId == rowId else { return false }
        swipe = Swipe(rowId: rowId, offset: 0)
        return true
    }

    func swipeMoved(rowId: String, offset: Double) {
        guard swipe?.rowId == rowId else { return }
        swipe = Swipe(rowId: rowId, offset: offset)
    }

    /// The finger lifts: far enough (or fast enough), and the card is dismissed; otherwise it springs back.
    func swipeEnded(rowId: String, offset: Double, velocity: Double) {
        guard swipe?.rowId == rowId else { return }
        if SwipeDismissModel.shouldDismiss(offset: offset, width: cardWidth, velocity: velocity) {
            dismiss(rowId: rowId)
        } else {
            withAnimation(NightWatch.systemReduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { swipe = nil }
        }
    }

    /// The scroll gesture was cancelled: the card goes back.
    func swipeCancelled() {
        guard swipe != nil else { return }
        withAnimation(NightWatch.systemReduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { swipe = nil }
    }

    // MARK: effects

    private func apply(_ new: NowPanelState, effect: NowEffect) {
        let holdChanged = (new.hold == nil) != (state.hold == nil)
        if state.composer == nil && new.composer != nil { composerFocusToken += 1 }
        if new != state { state = new }
        if holdChanged {
            if new.hold != nil { startTicking() } else { stopTicking() }
        }
        switch effect {
        case .none: break
        case .approve(let id), .deny(let id), .approveAfterAuth(let id):
            sending.insert(id)
            beginThread(rowId: id, authenticating: effect == .approveAfterAuth(rowId: id))
            perform(effect)
        case .send(let id, _):
            sending.insert(id)
            beginThread(rowId: id, authenticating: false)
            perform(effect)
        case .dismiss(let id):
            // The key, ×, swipe or VoiceOver action asked: the store makes it a pending dismissal.
            dismiss(rowId: id)
        case .typeInto(let target, _):
            // Not a page reply: no receipt thread, no Esc. The row says what happened.
            // An idle card's receipt sits under the same key as a working card's: the message
            // starts a turn, and the session moves from IDLE to In flight with it.
            let id = InFlightRow.idPrefix + target.sessionId
            let route = cardRows.first { $0.sessionId == target.sessionId }?.route
            let started = InFlightReceipt(outcome: .sending, route: route, at: now())
            setReceipt(started, for: id)
            perform(effect)
            // The input path always answers; if it somehow does not, the row says so.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.flightReceipts[id] == started else { return }
                self.setReceipt(InFlightReceipt(outcome: .unconfirmed, route: route, at: self.now()), for: id)
            }
        default:
            perform(effect)
        }
    }

    /// The delivery finished (or failed): the row is free again, or gone.
    /// `outcome` is what the Mac confirmed; nil when nothing was sent (Touch ID
    /// refused, the page had gone), which simply drops the thread.
    func finishSending(rowId: String, outcome: DeliveryReceipt.Outcome? = nil) {
        sending.remove(rowId)
        guard var thread = motion.threads[rowId] else { return }
        guard let outcome, thread.sentAt != nil else {
            motion.threads[rowId] = nil
            refreshShown()
            return
        }
        thread.resolvedAt = now()
        thread.resolution = NowMotion.resolution(for: outcome)
        motion.threads[rowId] = thread
        refreshShown()
        let linger: TimeInterval
        switch thread.resolution {
        case .verified?: linger = ReceiptThreadModel.resolveDuration + 0.05
        case .queued?: linger = 30
        default: linger = 4
        }
        let resolvedAt = thread.resolvedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            self?.settleThread(rowId: rowId, resolvedAt: resolvedAt)
        }
    }

    // MARK: signature motions

    /// The reply has been handed to the Mac's reply path: the thread of light
    /// leaves the row. Called right before the delivery starts, so an
    /// Irreversible row only gets here after Touch ID passed (and bursts).
    func markSent(rowId: String) {
        var thread = motion.threads[rowId] ?? NowMotion.Thread(row: model.rows.first { $0.id == rowId }, index: indexShown(rowId))
        if thread.authenticating { motion.burst = NowMotion.Burst(rowId: rowId, at: now()) }
        thread.authenticating = false
        thread.sentAt = now()
        motion.threads[rowId] = thread
    }

    /// Power came back and these sessions' resumes were confirmed: their
    /// stars relight, one by one, in the dawn already rising (or a new one).
    func confirmResumed(sessionIds: [String]) {
        guard !sessionIds.isEmpty else { return }
        var dawn = motion.dawn ?? NowMotion.Dawn(stars: lastPaused, startedAt: now())
        for id in sessionIds where dawn.confirmed[id] == nil { dawn.confirmed[id] = now() }
        motion.dawn = dawn
    }

    /// For the render harness: sets motion state directly. Live, it only
    /// changes through the key handlers, `markSent` / `finishSending`,
    /// `update` and `confirmResumed`.
    func previewMotion(_ edit: (inout NowMotion) -> Void) {
        edit(&motion)
        refreshShown()
    }

    /// For the render harness: a receipt in an In-flight row without a delivery.
    func previewFlightReceipt(_ r: InFlightReceipt, forSessionId id: String) {
        flightReceipts[InFlightRow.idPrefix + id] = r
    }

    /// The "New ↑" pill: let the held arrivals in now.
    func showNew() {
        refreshShown(release: true)
    }

    /// The order is held still: the pointer is over the list, a hold is on or
    /// the composer is open.
    var orderFrozen: Bool { pointerInList || state.hold != nil || state.composer != nil }

    private func beginThread(rowId: String, authenticating: Bool) {
        guard let row = model.rows.first(where: { $0.id == rowId }) else { return }
        var t = NowMotion.Thread(row: row, index: indexShown(rowId))
        t.authenticating = authenticating
        motion.threads[rowId] = t
    }

    private func indexShown(_ id: String) -> Int {
        shownRows.firstIndex { $0.id == id } ?? model.rows.firstIndex { $0.id == id } ?? 0
    }

    /// A resolved thread has had its time. A failure (or "queued") is dropped.
    /// A verified row has folded away: the gap it leaves closes (the rows below
    /// glide up), and the thread stays, keeping the row hidden, until its page
    /// closes, so it never pops back; if the page is somehow still open after
    /// `settleLimit`, the row is shown again, because it is still waiting.
    private func settleThread(rowId: String, resolvedAt: Date?) {
        guard let t = motion.threads[rowId], t.resolvedAt == resolvedAt else { return }
        guard t.resolution == .verified else {
            motion.threads[rowId] = nil
            refreshShown()
            return
        }
        if let i = shownRows.firstIndex(where: { $0.id == rowId }) {
            let at = now()
            motion.gaps.append(NowMotion.Gap(index: i, rowId: rowId, at: at))
            DispatchQueue.main.asyncAfter(deadline: .now() + NowMotion.gapDuration + 0.05) { [weak self] in
                self?.motion.gaps.removeAll { $0.at == at }
            }
        }
        refreshShown()
        DispatchQueue.main.asyncAfter(deadline: .now() + NowMotion.settleLimit) { [weak self] in
            guard let self, self.motion.threads[rowId]?.resolvedAt == resolvedAt else { return }
            self.motion.threads[rowId] = nil
            self.refreshShown()
        }
    }

    /// Drops verified threads whose page has now closed (their rows are gone for good).
    private func pruneSettledThreads() {
        let live = Set(model.rows.map(\.id))
        let t = now()
        let done = motion.threads.filter { _, th in
            guard th.resolution == .verified, let at = th.resolvedAt else { return false }
            return t.timeIntervalSince(at) >= ReceiptThreadModel.resolveDuration && !live.contains(th.rowId)
        }.map(\.key)
        guard !done.isEmpty else { return }
        for id in done { motion.threads[id] = nil }
    }

    /// Notes what changed between two models while the panel is open: new
    /// rows (Final approach), the last waiting item clearing (the exhale),
    /// the cutoff pausing agents (dusk) and power coming back (dawn).
    private func noteMotion(from old: NowModel, to new: NowModel) {
        let t = now()
        let wasWaiting = old.needYouCount + old.lookCount
        let isWaiting = new.needYouCount + new.lookCount
        if new.mood == .dusk { lastPaused = new.paused }
        guard animates else { return }
        if wasWaiting > 0, isWaiting == 0, new.mood != .dusk {
            motion.clearedAt = t
            // The rings the pulse had out: one per decision (else per look), as it counts them.
            motion.clearedRings = PulseModel.ringCount(waiting: old.needYouCount > 0 ? old.needYouCount : old.lookCount)
        } else if isWaiting > 0, motion.clearedAt != nil {
            motion.clearedAt = nil
        }
        if old.mood != .dusk, new.mood == .dusk {
            motion.duskAt = t
            motion.dawn = nil
        } else if old.mood == .dusk, new.mood != .dusk {
            motion.duskAt = nil
            if motion.dawn == nil { motion.dawn = NowMotion.Dawn(stars: lastPaused, startedAt: t) }
            let started = motion.dawn?.startedAt
            DispatchQueue.main.asyncAfter(deadline: .now() + NowMotion.dawnLimit) { [weak self] in
                if self?.motion.dawn?.startedAt == started { self?.motion.dawn = nil }
            }
        }
    }

    /// Rebuilds `shownRows`: the stable order, the arrivals it lets in (each
    /// one flies from the pulse), rows still folding away, and rows already
    /// verified that the model has not dropped yet (hidden, so they do not
    /// pop back after folding).
    private func refreshShown(release: Bool = false) {
        let t = now()
        // A finished turn that was put away stays out: while its Undo lasts and until its page closes.
        let away = hiddenFinishedSessionIds
        let ranked = away.isEmpty ? model.rows : model.rows.filter { $0.section != .review || !away.contains($0.sessionId) }
        let merged = NowStableOrder.merge(shown: shownIds, ranked: ranked, frozen: orderFrozen && !release)
        var rows = merged.rows
        // Verified and folded, but the page has not closed yet: keep it out.
        rows.removeAll { r in
            guard let th = motion.threads[r.id], th.resolution == .verified, let at = th.resolvedAt else { return false }
            return t.timeIntervalSince(at) >= ReceiptThreadModel.resolveDuration
        }
        // Its page closed while the reply was out: the row stays, as a ghost in
        // its old place, until the Mac has answered and the thread has played
        // (the fold after a verified delivery, the words after a failure).
        let live = Set(rows.map(\.id))
        for th in motion.threads.values.sorted(by: { $0.index < $1.index })
        where th.sentAt != nil && !live.contains(th.rowId) {
            guard let row = th.row, NowMotion.keepsGhost(th, now: t) else { continue }
            rows.insert(row, at: min(th.index, rows.count))
        }
        // Arrivals: rows never seen before, a little apart when several come at once.
        if animates {
            let fresh = rows.filter { !knownIds.contains($0.id) }.map(\.id)
            for (i, id) in fresh.enumerated() { motion.arrivals[id] = t.addingTimeInterval(Double(i) * NowMotion.arrivalStagger) }
            if !fresh.isEmpty {
                let ids = fresh
                DispatchQueue.main.asyncAfter(deadline: .now() + ApproachModel.duration + Double(ids.count) * NowMotion.arrivalStagger + 0.05) { [weak self] in
                    guard let self else { return }
                    for id in ids where (self.motion.arrivals[id].map { self.now().timeIntervalSince($0) >= ApproachModel.duration } ?? false) {
                        self.motion.arrivals[id] = nil
                    }
                }
            }
        }
        knownIds.formUnion(rows.map(\.id))
        shownIds = merged.rows.map(\.id)
        if rows != shownRows { shownRows = rows }
        if merged.queuedNew != queuedNew { queuedNew = merged.queuedNew }
    }
}

/// When each signature motion began, for the views to turn into frames.
struct NowMotion: Equatable {
    /// A reply's receipt thread.
    struct Thread: Equatable {
        /// The row as it was when answered (drawn as a ghost if its page closes first).
        let row: DecideRow?
        var rowId: String { row?.id ?? "" }
        /// Where it was in the list.
        let index: Int
        /// Waiting for Touch ID: nothing has been sent.
        var authenticating = false
        /// Handed to the Mac's reply path.
        var sentAt: Date?
        /// When the Mac answered, and what it said.
        var resolvedAt: Date?
        var resolution: ReceiptThreadModel.Resolution?

        init(row: DecideRow?, index: Int) {
            self.row = row
            self.index = index
        }
    }

    struct Dawn: Equatable {
        /// The agents that were paused: one star each.
        let stars: [NowModel.PausedAgent]
        let startedAt: Date
        /// Session id → when its resume was confirmed.
        var confirmed: [String: Date] = [:]
    }

    /// A hold let go early, unwinding.
    struct Unwind: Equatable {
        let kind: HoldGesture.Kind
        let from: Double
        let at: Date
    }

    /// Touch ID passed for an Irreversible row.
    struct Burst: Equatable {
        let rowId: String
        let at: Date
    }

    /// A folded row has gone: rows from `index` down glide up into its place.
    struct Gap: Equatable {
        let index: Int
        let rowId: String
        let at: Date
    }

    /// A dismissed card has gone from its group (In flight, or IDLE): the cards below it glide up.
    struct CardGap: Equatable {
        enum Group: Equatable { case flight, idle }
        let group: Group
        let index: Int
        let rowId: String
        let at: Date
    }

    var arrivals: [String: Date] = [:]
    var threads: [String: Thread] = [:]
    var clearedAt: Date?
    var clearedRings = 0
    var duskAt: Date?
    var dawn: Dawn?
    var unwind: Unwind?
    var burst: Burst?
    var gaps: [Gap] = []
    var cardGaps: [CardGap] = []

    static let arrivalStagger: TimeInterval = 0.09
    /// The longest a verified row stays hidden waiting for its page to close.
    static let settleLimit: TimeInterval = 6
    static let gapDuration: TimeInterval = 0.3
    /// A dawn whose resumes never confirm stops waiting after this.
    static let dawnLimit: TimeInterval = 20

    /// Pure. Whether a thread whose page has closed still shows its row: while
    /// the Mac has not answered, through the fold after a verified delivery,
    /// and for a few seconds of words after anything else.
    static func keepsGhost(_ th: Thread, now: Date) -> Bool {
        guard th.sentAt != nil else { return false }
        guard let at = th.resolvedAt else { return true }
        let e = now.timeIntervalSince(at)
        return th.resolution == .verified ? e < ReceiptThreadModel.resolveDuration : e < ghostWords
    }

    /// How long a closed page's row keeps its failure (or "queued") in words.
    static let ghostWords: TimeInterval = 4

    /// Pure. The Mac's delivery outcome as the thread's resolution: only a
    /// confirmed delivery is verified; queued has not landed yet.
    static func resolution(for outcome: DeliveryReceipt.Outcome) -> ReceiptThreadModel.Resolution {
        switch outcome {
        case .delivered: return .verified
        case .queued: return .queued
        default: return .failed(outcome.failureMessage ?? "Couldn't deliver the reply")
        }
    }
}
