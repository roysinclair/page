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
        guard let cap else { return base + ", no budget" }
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
    static let captureOff = "Turn on usage tracking in Page Studio on your computer to see and set budgets."

    /// Early in the week, before shares mean anything.
    static let measuring = "Measuring… shares appear once the week has moved a little."

    /// The Session room's chip: "Budget 18/25%"; nil with no budget.
    static func chip(_ b: SessionBudget) -> String? {
        guard let cap = b.cap else { return nil }
        return "Budget \(Int(b.used.rounded()))/\(cap)%"
    }

    /// The cap-reached card's line: "about 25% of the week · 2 sessions stopped".
    static func reachedLine(used: Double, stopped: Int) -> String {
        let s = stopped == 1 ? "1 session stopped" : "\(stopped) sessions stopped"
        return "about \(pct(used)) of the week · \(s)"
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

    /// The card's line: "about 25% of the week · 2 sessions stopped" (reached),
    /// "20% of its 25% budget" (warning); nil when the text had no numbers.
    func line(reached: Bool) -> String? {
        if reached, let used { return BudgetCopy.reachedLine(used: used, stopped: stopped ?? 0) }
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

    var id: String { "\(scope)-\(key ?? "default")" }

    var title: String {
        switch scope {
        case .project: return "\(name)’s budget"
        case .session: return "This session only"
        case .defaultCap: return "Default budget"
        }
    }

    /// "18% of the week so far"; the default's purpose.
    var subtitle: String {
        switch scope {
        case .defaultCap: return "For every project without a budget of its own"
        case .project, .session:
            let u = used.map { "\(BudgetCopy.pct($0)) of the week so far" } ?? "Nothing used this week yet"
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
