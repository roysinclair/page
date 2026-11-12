import Foundation

// Budget caps (Designs/budget-caps.md): a project, or one session, may use a
// share of the weekly Claude limit. The Mac measures, stores and enforces;
// the phone draws what the Mac reports and sends changes back. Everything
// here is pure: words, the bar, the picker's steps.

/// Where a budget stands, as the Mac reports it: below 80% of the cap, from
/// 80%, or at the cap (Page has stopped it).
enum BudgetState: String, Equatable {
    case ok, warn, over

    /// The state the numbers give, when the Mac didn't say. No cap is always ok.
    init(used: Double, cap: Int?) {
        guard let cap, cap > 0 else { self = .ok; return }
        if used >= Double(cap) { self = .over }
        else if used >= Double(cap) * BudgetCopy.warnShare { self = .warn }
        else { self = .ok }
    }
}

// MARK: - Wire (the sessions `list`)

/// The capability a Mac advertises (`caps`) when it measures and enforces budgets. Budget controls are
/// drawn only when it is there; the budget pages (`budget_reached`, `budget_warning`) come over the
/// relay inbox and are drawn whatever the list says.
enum BudgetWire {
    static let capability = "budget-v1"

    /// A whole-percent budget the Mac would take: 1–100.
    static func validCap(_ pct: Int?) -> Bool { pct.map { (1...100).contains($0) } ?? true }

    /// A budget read off the wire: a whole number 1–100, else none.
    static func cap(_ raw: Double?) -> Int? {
        guard let raw, raw.isFinite, raw == raw.rounded(), (1...100).contains(raw) else { return nil }
        return Int(raw)
    }

    /// A share of the week read off the wire, kept in 0–100.
    static func share(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        return min(100, max(0, raw))
    }

    /// The share of the work Page has watched so far (`work`, sent only while the Mac is measuring): a finite
    /// number in 0–100, else none. Unlike `share` it never clamps: a figure outside the range is not a share.
    static func work(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, (0...100).contains(raw) else { return nil }
        return raw
    }

    /// What a `list` says about budgets once the Mac's capabilities are known: nothing at all without
    /// `budget-v1`, so no card, chip or sheet is drawn for a Mac that cannot honour a budget. While the header
    /// says `measuring` (with capture on) each row's budget is stamped `measuringHeader`. Pure.
    static func gated(budget: MacBudget?, sessions: [LiveSession], caps: Set<String>) -> (budget: MacBudget?, sessions: [LiveSession]) {
        if caps.contains(capability) {
            // A measuring week: every row's budget reads "Measuring…" (with its share of the work, when sent), never "0% of 25%".
            guard let budget, budget.capture, budget.measuring else { return (budget, sessions) }
            return (budget, sessions.map { s in
                guard var b = s.budget else { return s }
                b.measuringHeader = true
                var s = s
                s.budget = b
                return s
            })
        }
        return (nil, sessions.map { s in
            guard s.budget != nil else { return s }
            var s = s
            s.budget = nil
            return s
        })
    }
}

extension BudgetState {
    /// "ok" / "warn" / "over"; anything else reads as nil, and the numbers decide.
    init?(wire raw: String?) {
        guard let raw, let s = BudgetState(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        self = s
    }
}

/// Lenient, like every optional part of the list: a block that is not an object is nil, a bad project row
/// is dropped, a bad number is missing. Nothing here can fail the list.
extension MacBudget: Decodable {
    private enum CodingKeys: String, CodingKey { case resetsAt, capture, measuring, weekPct, defaultCap, projects }

    /// The most projects one list carries onto the phone.
    static let maxProjects = 60

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resetsAt = LenientDate.decode(c, .resetsAt)
        // Usage tracking is on unless the Mac says it is off: a block with no word on it still lists its projects.
        capture = c.lenientBool(.capture) ?? true
        measuring = c.lenientBool(.measuring) ?? false
        weekPct = BudgetWire.share((try? c.decodeIfPresent(Double.self, forKey: .weekPct)) ?? nil)
        defaultCap = BudgetWire.cap((try? c.decodeIfPresent(Double.self, forKey: .defaultCap)) ?? nil)
        projects = Array((((try? c.decodeIfPresent(LossyList<BudgetProject>.self, forKey: .projects)) ?? nil)?.elements ?? []).prefix(Self.maxProjects))
    }
}

extension BudgetProject: Decodable {
    private enum CodingKeys: String, CodingKey { case key, name, used, cap, state, work }

    /// Needs a key (the Mac's project folder, sent back verbatim) and a share; the rest has a fallback.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKey = (c.lenientString(.key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty, rawKey.count <= 1024 else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: c, debugDescription: "Bad project key")
        }
        guard let used = BudgetWire.share(try c.decode(Double.self, forKey: .used)) else {
            throw DecodingError.dataCorruptedError(forKey: .used, in: c, debugDescription: "Bad share")
        }
        key = rawKey
        let named = (c.lenientString(.name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = String((named.isEmpty ? (rawKey as NSString).lastPathComponent : named).prefix(80))
        self.used = used
        cap = BudgetWire.cap((try? c.decodeIfPresent(Double.self, forKey: .cap)) ?? nil)
        state = BudgetState(wire: c.lenientString(.state)) ?? BudgetState(used: used, cap: cap)
        work = BudgetWire.work((try? c.decodeIfPresent(Double.self, forKey: .work)) ?? nil)
    }
}

extension SessionBudget: Decodable {
    private enum CodingKeys: String, CodingKey { case projectKey, used, cap, scope, state, sessionUsed, sessionCap, work }

    /// Needs the project key and the share; a row whose `budget` is anything else has none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKey = (c.lenientString(.projectKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty, rawKey.count <= 1024 else {
            throw DecodingError.dataCorruptedError(forKey: .projectKey, in: c, debugDescription: "Bad project key")
        }
        guard let used = BudgetWire.share(try c.decode(Double.self, forKey: .used)) else {
            throw DecodingError.dataCorruptedError(forKey: .used, in: c, debugDescription: "Bad share")
        }
        projectKey = rawKey
        self.used = used
        cap = BudgetWire.cap((try? c.decodeIfPresent(Double.self, forKey: .cap)) ?? nil)
        scope = Scope(rawValue: c.lenientString(.scope) ?? "") ?? .project
        state = BudgetState(wire: c.lenientString(.state)) ?? BudgetState(used: used, cap: cap)
        sessionUsed = BudgetWire.share((try? c.decodeIfPresent(Double.self, forKey: .sessionUsed)) ?? nil)
        sessionCap = BudgetWire.cap((try? c.decodeIfPresent(Double.self, forKey: .sessionCap)) ?? nil)
        work = BudgetWire.work((try? c.decodeIfPresent(Double.self, forKey: .work)) ?? nil)
    }
}

/// The Mac's budget block for the week (the sessions list header).
struct MacBudget: Equatable {
    /// When the weekly limit resets.
    var resetsAt: Date?
    /// Usage capture is on in Page Studio: without it nothing is measured.
    var capture: Bool
    /// Not enough of the week has moved yet to share it out.
    var measuring: Bool
    /// The account's weekly %, for the ring.
    var weekPct: Double?
    /// The budget every project without its own gets; nil = none.
    var defaultCap: Int?
    /// Every project with spend or a budget this week, most used first.
    var projects: [BudgetProject]
}

/// One project's week. `key` is the Mac's (an absolute folder path); the
/// phone sends it back verbatim and never derives one.
struct BudgetProject: Equatable, Identifiable {
    var key: String
    var name: String
    /// Share of the week, 0–100.
    var used: Double
    /// Its own budget; nil = none (the default may still apply: `effectiveCap`).
    var cap: Int?
    var state: BudgetState
    /// While the Mac is measuring: its share of the work Page has watched so far, 0–100. Nil when the
    /// Mac did not say (not measuring, nothing watched yet, or an older Mac).
    var work: Double? = nil
    var id: String { key }

    /// Its own budget, else the default.
    func effectiveCap(default d: Int?) -> Int? { cap ?? d }

    /// The colour it wears everywhere else: the hue of its home-abbreviated folder,
    /// as session cards hash it.
    var hue: ProjectHue { ProjectHue(key: PathDisplay.abbreviatingHome(key)) }
}

/// A session's budget (a sessions list row): the binding cap (the lower of
/// its own and its project's) and how much of it is used.
struct SessionBudget: Hashable {
    enum Scope: String, Hashable { case project, session }
    var projectKey: String
    /// The project's share of the week (or the session's, when `scope` is session).
    var used: Double
    var cap: Int?
    var scope: Scope
    var state: BudgetState
    /// The session's own share and budget, when it has one.
    var sessionUsed: Double?
    var sessionCap: Int?
    /// While the Mac is measuring: the binding scope's share of the work watched so far, 0–100 (the
    /// session's when `scope` is session, else the project's). Nil when the Mac did not say; the Mac
    /// sends it only while measuring, so a figure here means the week has not risen a whole point yet.
    var work: Double? = nil

    /// The list's header said `measuring: true` (set by `BudgetWire.gated`, never on the wire): the week has not
    /// risen a whole point, so this row's figures mean nothing yet even when the Mac sent no `work` for it.
    var measuringHeader: Bool = false

    /// The Mac is still measuring the week: its header says so, or it sent `work` (only sent while measuring).
    var measuring: Bool { measuringHeader || work != nil }

    var meter: BudgetMeter { BudgetMeter(used: used, cap: cap, state: state) }
}

/// A budget as drawn: the words, the bar's fill and tone.
struct BudgetMeter: Equatable {
    enum Tone: Equatable { case quiet, calm, warm }

    let used: Double
    let cap: Int?
    let state: BudgetState
    /// "18%" (or "<1%").
    let usedText: String
    /// "18% of 25%"; "18% · no budget".
    let line: String
    /// The bar's fill, 0…1. With a budget the bar is the budget (full = stopped);
    /// with none it is the whole week.
    let fraction: Double
    /// The warning tick on the bar, 0…1; nil with no budget.
    let warnMark: Double?
    let tone: Tone

    init(used: Double, cap: Int?, state: BudgetState? = nil) {
        self.used = used
        self.cap = cap
        let st = state ?? BudgetState(used: used, cap: cap)
        self.state = st
        usedText = BudgetCopy.pct(used)
        if let cap, cap > 0 {
            line = "\(usedText) of \(cap)%"
            fraction = min(1, max(0, used / Double(cap)))
            warnMark = BudgetCopy.warnShare
            tone = st == .ok ? .calm : .warm
        } else {
            line = "\(usedText) · no budget"
            fraction = min(1, max(0, used / 100))
            warnMark = nil
            tone = .quiet
        }
    }

    /// "Night Owl, 18% of the week, budget 25%" for VoiceOver.
    func spoken(name: String) -> String {
        let base = "\(name), \(usedText) of the week"
        guard let cap, cap > 0 else { return base + ", no budget" }
        switch state {
        case .over: return base + ", budget \(cap)% reached, stopped"
        case .warn: return base + ", near its \(cap)% budget"
        case .ok: return base + ", budget \(cap)%"
        }
    }
}

/// The budget picker's values: Off, the presets, and steps of 5.
enum BudgetPercent {
    static let presets: [Int?] = [nil, 10, 25, 50]
    static let step = 5

    /// One step up: Off → 5; 23 → 25; 25 → 30; never past 100.
    static func up(_ v: Int?) -> Int {
        guard let v else { return step }
        return min(100, (v / step + 1) * step)
    }

    /// One step down: 27 → 25; 25 → 20; 5 (or less) → Off.
    static func down(_ v: Int?) -> Int? {
        guard let v else { return nil }
        let next = v % step == 0 ? v - step : (v / step) * step
        return next < 1 ? nil : next
    }

    /// The cap-reached page's "Raise to …": ten more, at most 100.
    static func raised(_ cap: Int) -> Int { min(100, cap + 10) }

    /// "Off", "25%".
    static func text(_ v: Int?) -> String { v.map { "\($0)%" } ?? "Off" }
}

enum BudgetCopy {
    /// The pie that marks a budget: the BUDGET chip, the room's chip, the in-flight fact.
    static let symbol = "chart.pie.fill"

    /// A page and amber from this share of the budget.
    static let warnShare = 0.8

    /// Where Page warns for a budget: 25 → 20.
    static func warnAt(_ cap: Int) -> Int { max(1, Int((Double(cap) * warnShare).rounded())) }

    /// "18%", "<1%", "100%".
    static func pct(_ v: Double) -> String {
        if v > 0 && v < 1 { return "<1%" }
        return "\(Int(v.rounded()))%"
    }

    /// "Mon 09:00".
    static func resets(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(cal.component(.weekday, from: date) - 1) % 7]
        return "\(day) \(NowFormat.clock(date, timeZone: timeZone))"
    }

    /// The budget sheet's plain-words line.
    /// "Page warns at 20% and stops Night Owl at 25% of the week. Resets Mon 09:00."
    static func preview(name: String, cap: Int?, session: Bool, resetsAt: Date?, timeZone: TimeZone) -> String {
        let reset = resetsAt.map { " Resets \(resets($0, timeZone: timeZone))." } ?? ""
        let who = session ? "this session" : name
        guard let cap else {
            return session ? "No budget of its own: this session shares \(name)'s.\(reset)"
                           : "No budget: \(name) can use any share of the week.\(reset)"
        }
        return "Page warns at \(warnAt(cap))% and stops \(who) at \(cap)% of the week.\(reset)"
    }

    /// The one honest line, under the Budget list.
    static let footnote = "Estimated from Claude Code on this Mac. Chats elsewhere count toward the week, so shares can read a little high."

    /// Budget with usage tracking off.
    static let captureOff = "Turn on usage tracking in Page Studio ▸ Budget to see and set budgets."

    /// The Budget list's note while the week is still being measured.
    static let measuring = "Measuring until the week rises one whole point. Meanwhile each project shows its share of the work so far."

    /// What "Measuring" means, for VoiceOver (the Mac's tooltip says the same).
    static let measuringHelp = "Its share of the work this week's sessions have done so far. It becomes a share of your week once the week has risen one whole point."

    /// A project's or session's line while the Mac is measuring (Designs/budget-caps.md §2).
    /// Long form, for rows with room: "Measuring · 63% of the work so far".
    /// Short form (`short`), for a one-line chip: "Measuring · 63% of work".
    /// A whole percent, "<1%" above 0 and below 1; with no work (nil, 0, or not a finite 0–100 figure) a plain "Measuring…".
    static func measuringLine(work: Double?, short: Bool = false) -> String {
        guard let w = BudgetWire.work(work), w > 0 else { return "Measuring…" }
        return short ? "Measuring · \(pct(w)) of work" : "Measuring · \(pct(w)) of the work so far"
    }

    /// The same line for VoiceOver, with no "·": "measuring, 63% of the work so far"; just "measuring" with no work.
    static func measuringPhrase(work: Double?) -> String {
        guard let w = BudgetWire.work(work), w > 0 else { return "measuring" }
        return "measuring, \(pct(w)) of the work so far"
    }

    /// "payments-api, measuring, 63% of the work so far".
    static func measuringSpoken(name: String, work: Double?) -> String { "\(name), \(measuringPhrase(work: work))" }

    /// The Session room's chip: "Budget 18/25%"; nil with no budget. While the Mac is measuring (it sent
    /// `work`) the figures mean nothing yet, so the chip says so in the short form: "Measuring · 63% of work".
    static func chip(_ b: SessionBudget) -> String? {
        guard let cap = b.cap else { return nil }
        if b.measuring { return measuringLine(work: b.work, short: true) }
        return "Budget \(Int(b.used.rounded()))/\(cap)%"
    }

    /// The cap-reached card's line: "about 25% of the week · 2 sessions stopped";
    /// just "about 25% of the week" when the count is unknown.
    static func reachedLine(used: Double, stopped: Int?) -> String {
        let week = "about \(pct(used)) of the week"
        guard let stopped else { return week }
        return week + " · " + (stopped == 1 ? "1 session stopped" : "\(stopped) sessions stopped")
    }
}

/// What a budget page's text says. The Mac writes it in words
/// ("Night Owl reached its budget: about 25% of the week (budget 25%). Page stopped 2 sessions.");
/// the phone reads back the numbers it needs for the card. Missing numbers stay nil.
struct BudgetPage: Equatable {
    var used: Double?
    var cap: Int?
    var stopped: Int?

    static func parse(_ text: String) -> BudgetPage {
        func number(_ pattern: String) -> Double? {
            guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return Double(text[r].filter { $0.isNumber || $0 == "." })
        }
        return BudgetPage(used: number(#"about \d+(\.\d+)?%"#),
                          cap: number(#"budget \d+%"#).map { Int($0) },
                          stopped: number(#"stopped \d+ session"#).map { Int($0) })
    }

    /// The bar a budget page draws: the used share against the budget the text names. A cap-reached page
    /// that names none is full by definition (it stopped at the budget); a warning without one has no bar.
    func meter(reached: Bool) -> BudgetMeter? {
        guard let used else { return nil }
        if let cap { return BudgetMeter(used: used, cap: cap) }
        guard reached else { return nil }
        return BudgetMeter(used: used, cap: max(1, Int(used.rounded())), state: .over)
    }

    /// The card's line: "about 25% of the week · 2 sessions stopped" (reached),
    /// "20% of its 25% budget" (warning); nil when the text had no numbers.
    func line(reached: Bool) -> String? {
        if reached, let used { return BudgetCopy.reachedLine(used: used, stopped: stopped) }
        if let used, let cap { return "\(BudgetCopy.pct(used)) of its \(cap)% budget" }
        return nil
    }
}

/// What the budget sheet edits: a project's budget, one session's, or the default.
struct BudgetSheetModel: Equatable, Identifiable {
    enum Scope: Equatable { case project, session, defaultCap }
    var scope: Scope
    /// The project's name ("Night Owl"); unused for the default.
    var name: String
    /// The Mac's project key, or the session id: sent back verbatim.
    var key: String?
    /// The project's colour; nil for the default.
    var hue: ProjectHue?
    /// The share of the week used so far; nil for the default.
    var used: Double?
    /// The budget now.
    var cap: Int?
    var resetsAt: Date?
    /// A session's project key (`SessionBudget.projectKey`): sent with the session's own budget.
    var projectKey: String? = nil
    /// The Mac is still measuring the week: the subtitle says so, with `work` when it is known, instead of a share of the week.
    var measuring: Bool = false
    /// The share of the work watched so far that belongs to what the sheet edits (the project's; the session's own
    /// only when the row's budget is the session's). Nil when not known.
    var work: Double? = nil

    var id: String { "\(scope)-\(key ?? "default")" }

    var title: String {
        switch scope {
        case .project: return "\(name)’s budget"
        case .session: return "This session only"
        case .defaultCap: return "Default budget"
        }
    }

    /// "18% of the week so far"; while measuring "Measuring · 63% of the work so far"; the default's purpose.
    var subtitle: String {
        switch scope {
        case .defaultCap: return "For every project without a budget of its own"
        case .project, .session:
            let u = measuring ? BudgetCopy.measuringLine(work: work)
                : used.map { "\(BudgetCopy.pct($0)) of the week so far" } ?? "Nothing used this week yet"
            return scope == .session ? "\(name) · \(u)" : u
        }
    }

    func preview(_ value: Int?, timeZone: TimeZone) -> String {
        if scope == .defaultCap {
            let reset = resetsAt.map { " Resets \(BudgetCopy.resets($0, timeZone: timeZone))." } ?? ""
            guard let value else { return "No default: projects without a budget can use any share of the week.\(reset)" }
            return "Every project without its own budget stops at \(value)% of the week, with a warning at \(BudgetCopy.warnAt(value))%.\(reset)"
        }
        return BudgetCopy.preview(name: name, cap: value, session: scope == .session, resetsAt: resetsAt, timeZone: timeZone)
    }
}

// MARK: - The sheets' models, from what the Mac reported

extension BudgetSheetModel {
    /// A project's sheet: its own budget (not the default it may be using) is what is edited. `measuring` is the
    /// header's flag; a project that carries `work` is measuring too.
    static func project(_ p: BudgetProject, resetsAt: Date?, measuring: Bool = false) -> BudgetSheetModel {
        BudgetSheetModel(scope: .project, name: p.name, key: p.key, hue: p.hue, used: p.used, cap: p.cap, resetsAt: resetsAt,
                         measuring: measuring || p.work != nil, work: p.work)
    }

    /// The default for projects with none of their own.
    static func forDefault(_ b: MacBudget) -> BudgetSheetModel {
        BudgetSheetModel(scope: .defaultCap, name: "", key: nil, hue: nil, used: nil, cap: b.defaultCap, resetsAt: b.resetsAt)
    }

    /// "This session only": the session's own budget and share, never the binding cap (saving that
    /// unchanged would quietly give the session a budget equal to its project's).
    static func session(_ s: LiveSession, resetsAt: Date?) -> BudgetSheetModel {
        BudgetSheetModel(scope: .session, name: SkyModel.projectName(cwd: s.cwd, fallback: s.title), key: s.id,
                         hue: ProjectHue(key: s.cwd.isEmpty ? s.title : s.cwd),
                         used: s.budget?.sessionUsed, cap: s.budget?.sessionCap, resetsAt: resetsAt, projectKey: s.budget?.projectKey,
                         measuring: s.budget?.measuring ?? false, work: s.budget?.scope == .session ? s.budget?.work : nil)
    }

    /// The `budget` op that saves `pct` (nil = Off), or nil when none can be sent: a project or session
    /// with no key to send back, or a percentage the Mac would not take (outside 1–100).
    func command(pct: Int?) -> SessionCommand? {
        guard BudgetWire.validCap(pct) else { return nil }
        switch scope {
        case .project:
            guard let key, !key.isEmpty else { return nil }
            return .budget(scope: .project, key: key, sessionId: nil, pct: pct)
        case .session:
            guard let key, !key.isEmpty else { return nil }
            return .budget(scope: .session, key: projectKey, sessionId: key, pct: pct)
        case .defaultCap:
            return .budget(scope: .default, key: nil, sessionId: nil, pct: pct)
        }
    }
}

// MARK: - Changing a budget (the `budget` op)

/// What a `budget` op edits, as the wire names it.
enum BudgetOpScope: String, Equatable {
    case project, session
    case `default`
}

/// Where a budget change stands, for the sheet's own line. The sheet keeps the old value until the Mac
/// answers; `saved` closes it, `failed` says why under the picker and leaves the old value in place.
enum BudgetSaveStatus: Equatable {
    case idle
    case saving
    case saved
    case failed(String)

    var isSaving: Bool { self == .saving }
    var failure: String? { if case .failed(let why) = self { return why } else { return nil } }

    /// The relay answered the POST. Only a refusal says anything: 202 means the Mac has it, and its
    /// `result` is the answer (nil = keep waiting). A Mac that is away is said in the spec's words.
    static func afterPost(_ outcome: SessionCommandOutcome) -> BudgetSaveStatus? {
        switch outcome {
        case .accepted: return nil
        case .macOffline: return .failed(BudgetCopy.macOffline)
        case .rateLimited: return .failed("Too many changes in a minute. Wait a moment and try again. The budget wasn't changed.")
        case .relayTooOld: return .failed("Your relay doesn't support live sessions yet. Update your Cloudflare Worker.")
        default: return .failed(["The budget wasn't changed.", outcome.failureMessage].compactMap { $0 }.joined(separator: " "))
        }
    }

    /// The Mac's `result` for the op: ok is saved; anything else is its words, or Page's for a known reason.
    static func from(result r: CommandResult) -> BudgetSaveStatus {
        if r.ok { return .saved }
        return .failed(BudgetCopy.refusal(reason: r.reason, detail: r.detail))
    }

    /// The Mac never answered within the wait.
    static let noAnswer = BudgetSaveStatus.failed(BudgetCopy.noAnswer)

    static let resultTimeout: TimeInterval = SessionDeliveryState.resultTimeout
}

extension BudgetCopy {
    /// A change that could not reach the Mac: said once, in these words.
    static let macOffline = "Your Mac is offline — the budget wasn't changed."

    /// The Mac didn't answer in time.
    static let noAnswer = "Your Mac didn't confirm the change, so the budget may not have changed. Check again in a moment."

    /// The Mac refused or failed the op.
    static func refusal(reason: String?, detail: String?) -> String {
        switch reason {
        case "not_found": return "Your Mac doesn't have that project or session any more. The budget wasn't changed."
        case "stale", "replay": return SessionResultCopy.refusal(reason: reason, detail: detail, agent: "Your agent")
        case "invalid": return detail ?? "Your Mac didn't accept that percentage. The budget wasn't changed."
        default: return detail ?? "Your Mac couldn't change the budget."
        }
    }
}
