import Foundation

// Budget caps (Designs/budget-caps.md): a project, or one session, may use a
// share of the weekly Claude limit. This file is the pure part: how the share
// is estimated from the status line files, the caps, where a budget stands,
// the words, and the wire shapes. No file, clock or queue is touched here;
// `BudgetStore.swift` keeps the files and `BudgetController.swift` acts on
// them. Foundation only: it builds on Linux too.

// MARK: - State

/// Where a budget stands: below 80% of the cap, from 80%, or at the cap.
enum BudgetState: String, Equatable, Comparable, CaseIterable {
    case ok, warn, over

    private var rank: Int { self == .ok ? 0 : (self == .warn ? 1 : 2) }
    static func < (a: BudgetState, b: BudgetState) -> Bool { a.rank < b.rank }

    /// The state the numbers give. No cap is always ok.
    init(used: Double, cap: Int?) {
        guard let cap, cap > 0 else { self = .ok; return }
        if used >= Double(cap) { self = .over }
        else if used >= Double(cap) * BudgetCopy.warnShare { self = .warn }
        else { self = .ok }
    }
}

// MARK: - Words

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

    /// A whole number of percent, never below 1, for the pages' "about 26%".
    static func wholePct(_ v: Double) -> Int { max(1, Int(v.rounded())) }

    /// "Mon 09:00" (24-hour, in `timeZone`).
    static func resets(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(cal.component(.weekday, from: date) - 1) % 7]
        let h = cal.component(.hour, from: date), m = cal.component(.minute, from: date)
        return "\(day) " + (h < 10 ? "0" : "") + "\(h):" + (m < 10 ? "0" : "") + "\(m)"
    }

    /// The editor's plain-words line.
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

    /// The same, for the default budget.
    static func defaultPreview(cap: Int?, resetsAt: Date?, timeZone: TimeZone) -> String {
        let reset = resetsAt.map { " Resets \(resets($0, timeZone: timeZone))." } ?? ""
        guard let cap else { return "No default: projects without a budget can use any share of the week.\(reset)" }
        return "Every project without its own budget stops at \(cap)% of the week, with a warning at \(warnAt(cap))%.\(reset)"
    }

    /// The one honest line, under the Budget list.
    static let footnote = "Estimated from Claude Code on this Mac. Chats elsewhere count toward the week, so shares can read a little high."

    /// Budget with usage tracking off.
    static let captureOff = "Turn on usage tracking in Page Studio ▸ Budget to set budgets."

    /// Early in the week, before shares mean anything.
    static let measuring = "Measuring… shares appear once the week has moved a little."

    /// "18% of 25%", "18% · no budget", with "· stopped" once over. Pure.
    static func line(used: Double, cap: Int?, state: BudgetState, isDefault: Bool = false) -> String {
        guard let cap else { return "\(pct(used)) · no budget" }
        let base = "\(pct(used)) of \(cap)%"
        if state == .over { return base + " · stopped" }
        return isDefault ? base + " · default budget" : base
    }
}

/// The percent picker's values: Off, presets, and steps of 5.
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

    /// A usable cap: a whole percent, 1...100.
    static func isValid(_ v: Int) -> Bool { (1...100).contains(v) }
}

// MARK: - Keys

/// A short stable hash for file and page names. Not `hashValue` (that changes
/// on every launch); FNV-1a, 64 bits, 16 hex digits.
enum BudgetHash {
    static func hex(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let digits = String(h, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// The hash a project's marker, page and warning share.
    static func project(_ key: String) -> String { hex("p:" + key) }
    /// The hash of a session cap's marker and pages.
    static func session(_ id: String) -> String { hex("s:" + id) }
}

enum BudgetProjectKey {
    static let maxLength = 1024

    /// Whether `key` can be stored and sent back: absolute, not too long,
    /// no control characters (a newline would break the gate's `key=value` file).
    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.count <= maxLength && key.hasPrefix("/")
            && !key.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// The canonical key: `workspace.project_dir` with symlinks resolved, else `cwd`.
    /// nil when neither is a usable absolute path. Pure of the clock; `resolve`
    /// is the symlink step (a test passes a plain one).
    static func key(projectDir: String?, cwd: String?, resolve: (String) -> String = Self.resolveSymlinks) -> String? {
        for raw in [projectDir, cwd] {
            guard let raw, raw.hasPrefix("/") else { continue }
            let key = resolve(normalized(raw))
            if isValid(key) { return key }
        }
        return nil
    }

    /// Collapses "//", "." and ".." and drops a trailing "/". Pure.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for p in path.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." { continue }
            if p == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(p)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The real path (`realpath`, so /tmp is /private/tmp, as `pwd -P` says in
    /// the gate). A path in a privacy-protected folder is left as written:
    /// even a stat there can raise macOS's prompt. A path that doesn't exist stays too.
    static func resolveSymlinks(_ path: String) -> String {
        guard !PrivacyProtectedPaths.contains(path) else { return path }
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    /// The name shown: what the Mac already calls the project everywhere else.
    static func displayName(forKey key: String) -> String {
        guard !PrivacyProtectedPaths.contains(key) else { return lastComponent(key) }
        let name = InterventionDetector.projectName(forCwd: key, fallback: nil)
        return name.isEmpty ? lastComponent(key) : name
    }

    static func lastComponent(_ key: String) -> String {
        let c = (key as NSString).lastPathComponent
        return c.isEmpty || c == "/" ? "root" : c
    }

    /// A session id as the gate sees it: letters, digits and "-" only.
    static func sanitizedSessionId(_ id: String) -> String {
        String(id.unicodeScalars.filter { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
            || ($0.value >= 97 && $0.value <= 122) || $0.value == 45 }.map(Character.init))
    }

    /// A session id Page will store a cap for: 1...128 of [A-Za-z0-9-].
    static func isSaneSessionId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && sanitizedSessionId(id) == id
    }
}

// MARK: - Samples

/// One status line payload, reduced to what budgets use.
struct BudgetSample: Equatable {
    var sessionId: String
    /// The project key (see `BudgetProjectKey.key`); nil when no absolute folder was given.
    var projectKey: String?
    /// `cost.total_cost_usd`: weight only, never shown.
    var cost: Double?
    /// `rate_limits.seven_day`: the account's weekly %, and when the window resets.
    var weekPct: Double?
    var resetsAt: Date?
    /// When Claude Code wrote it (the file's mtime).
    var at: Date

    /// nil unless the payload is a JSON object with a session id.
    static func parse(_ data: Data, at: Date, resolve: (String) -> String = BudgetProjectKey.resolveSymlinks) -> BudgetSample? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = obj["session_id"] as? String, BudgetProjectKey.isSaneSessionId(sid) else { return nil }
        let workspace = obj["workspace"] as? [String: Any]
        let key = BudgetProjectKey.key(projectDir: workspace?["project_dir"] as? String,
                                       cwd: (obj["cwd"] as? String) ?? (workspace?["current_dir"] as? String), resolve: resolve)
        var cost: Double?
        if let c = ((obj["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue, c.isFinite, c >= 0 { cost = c }
        var week: UsageSnapshot.Window?
        if let limits = obj["rate_limits"] as? [String: Any] { week = UsageSnapshot.window(limits["seven_day"]) }
        return BudgetSample(sessionId: sid, projectKey: key, cost: cost, weekPct: week?.pct, resetsAt: week?.resetsAt, at: at)
    }
}

// MARK: - Ledger

/// The week's books (`budget-ledger.json`): where the weekly % stood when Page
/// first saw this window, and the dollars each session has spent since, as the
/// weights that share the rise out. Designs/budget-caps.md §2.
struct BudgetLedger: Codable, Equatable {
    struct Session: Codable, Equatable {
        var projectKey: String
        /// The last `total_cost_usd` seen.
        var lastCost: Double
        /// Dollars counted in this window.
        var spent: Double
        /// When its file was last written.
        var seenAt: Date
    }

    /// When the window resets (the latest value seen; it jitters by minutes).
    var resetsAt: Date?
    /// The weekly % when Page first saw this window.
    var startPct: Double = 0
    /// The weekly % now, and when the file that said so was written.
    var weekPct: Double?
    var weekPctAt: Date?
    var sessions: [String: Session] = [:]
    /// Spend of sessions dropped after 8 days, by project.
    var closedSpent: [String: Double] = [:]
    /// Display names by project key.
    var names: [String: String] = [:]
    /// Budgets already warned about in this window (marker hashes).
    var warned: [String] = []

    /// A resets_at that moved by less than this is the same window (jitter).
    static let sameWindow: TimeInterval = 3600
    /// A status line file older than this says nothing about now.
    static let staleAfter: TimeInterval = 6 * 3600
    /// A session no file has touched for this long is dropped into `closedSpent`.
    static let closeAfter: TimeInterval = 8 * 24 * 3600
    /// A window this long over (and no sample from the next) has nothing left to count.
    static let deadAfter: TimeInterval = 600
    /// The weekly % must have risen this much before shares mean anything.
    static let measuredRise = 1.0

    enum Outcome: Equatable {
        /// Counted: a window, a weekly % and (when it had a cost) a session.
        case counted
        /// Started a new window.
        case newWindow
        /// Said nothing usable: no weekly figure, too old, or from a window already over.
        case ignored
    }

    /// Takes one sample. Returns what it did (for the caller to save, and for tests).
    @discardableResult
    mutating func observe(_ s: BudgetSample, now: Date, name: (String) -> String = BudgetProjectKey.displayName(forKey:)) -> Outcome {
        guard let resets = s.resetsAt, let w = s.weekPct, resets > now,
              now.timeIntervalSince(s.at) <= Self.staleAfter else { return .ignored }
        var outcome = Outcome.counted
        // A file still showing an older window only moves its session's baseline.
        var baselineOnly = false
        if let cur = resetsAt {
            let moved = resets.timeIntervalSince(cur)
            if abs(moved) < Self.sameWindow {
                if s.at >= (weekPctAt ?? .distantPast) {
                    if w < startPct { startWindow(resets: resets, pct: w, at: s.at); outcome = .newWindow }
                    else { weekPct = w; weekPctAt = s.at; resetsAt = resets }
                }
            } else if moved > 0 {
                startWindow(resets: resets, pct: w, at: s.at)
                outcome = .newWindow
            } else {
                baselineOnly = true
            }
        } else {
            startWindow(resets: resets, pct: w, at: s.at)
            outcome = .newWindow
        }
        if let cost = s.cost, let key = s.projectKey, BudgetProjectKey.isSaneSessionId(s.sessionId) {
            if var e = sessions[s.sessionId] {
                if !baselineOnly { e.spent += cost >= e.lastCost ? cost - e.lastCost : cost }
                e.lastCost = cost
                e.projectKey = key
                e.seenAt = max(e.seenAt, s.at)
                sessions[s.sessionId] = e
            } else {
                sessions[s.sessionId] = Session(projectKey: key, lastCost: cost, spent: 0, seenAt: s.at)
            }
            if names[key] == nil { names[key] = name(key) }
        }
        return outcome
    }

    /// A new window: every `spent` goes to 0 and the start moves to the new
    /// weekly %. `lastCost` stays: it is the baseline the next sighting is
    /// measured from (what a session spent across the boundary is counted
    /// in the new window, which is where most of it was).
    private mutating func startWindow(resets: Date, pct: Double, at: Date) {
        resetsAt = resets
        startPct = pct
        weekPct = pct
        weekPctAt = at
        for k in sessions.keys { sessions[k]?.spent = 0 }
        closedSpent = [:]
        warned = []
    }

    /// Drops sessions no file has touched for 8 days into their project's
    /// `closedSpent`, and names nothing refers to. True when anything changed.
    @discardableResult
    mutating func prune(now: Date) -> Bool {
        var changed = false
        for (id, s) in sessions where now.timeIntervalSince(s.seenAt) > Self.closeAfter {
            closedSpent[s.projectKey, default: 0] += s.spent
            sessions[id] = nil
            changed = true
        }
        let used = Set(sessions.values.map(\.projectKey)).union(closedSpent.keys)
        for k in names.keys where !used.contains(k) { names[k] = nil; changed = true }
        // A window that ended before now has nothing to say (a new sample starts the next).
        if let r = resetsAt, r <= now.addingTimeInterval(-Self.deadAfter),
           sessions.values.contains(where: { $0.spent > 0 }) || !closedSpent.isEmpty || !warned.isEmpty {
            for k in sessions.keys { sessions[k]?.spent = 0 }
            closedSpent = [:]
            warned = []
            changed = true
        }
        return changed
    }

    // MARK: estimate

    /// The rise Page has watched this window, and how it is shared.
    var estimate: BudgetEstimate {
        BudgetEstimate(rise: max(0, (weekPct ?? 0) - startPct), total: sessions.values.reduce(0) { $0 + $1.spent }
                       + closedSpent.values.reduce(0, +), hasWeek: weekPct != nil)
    }

    /// Dollars a project has spent this window: live sessions plus closed ones.
    func spent(project key: String) -> Double {
        sessions.values.filter { $0.projectKey == key }.reduce(0) { $0 + $1.spent } + (closedSpent[key] ?? 0)
    }

    func used(project key: String) -> Double { estimate.share(of: spent(project: key)) }
    func used(session id: String) -> Double { estimate.share(of: sessions[id]?.spent ?? 0) }

    /// Every project with spend this window (the keys; caps add theirs).
    var projectKeys: Set<String> {
        Set(sessions.values.map(\.projectKey)).union(closedSpent.keys)
    }

    func name(of key: String) -> String { names[key] ?? BudgetProjectKey.displayName(forKey: key) }
}

/// `used(S) = (W − startPct) × S / C` (Designs/budget-caps.md §2): each project
/// gets its share of the rise Page has watched this week.
struct BudgetEstimate: Equatable {
    /// W − startPct, never below 0.
    let rise: Double
    /// C: the dollars all sessions spent this window.
    let total: Double
    /// Whether a weekly figure has been seen at all.
    let hasWeek: Bool

    /// Until the weekly % has risen by 1, nothing is shared out and no cap can trigger.
    var measuring: Bool { rise < BudgetLedger.measuredRise }

    func share(of spent: Double) -> Double {
        guard !measuring, total > 0, spent > 0 else { return 0 }
        return min(100, rise * min(1, spent / total))
    }
}

// MARK: - Caps

/// What may be spent: per project (and a default) from config.json, per
/// session from `budget-session-caps.json`. Whole percent, 1...100; nil is off.
struct BudgetCaps: Equatable {
    var projects: [String: Int] = [:]
    var defaultPct: Int?
    var sessions: [String: Int] = [:]

    init(projects: [String: Int] = [:], defaultPct: Int? = nil, sessions: [String: Int] = [:]) {
        self.projects = projects.filter { BudgetProjectKey.isValid($0.key) && BudgetPercent.isValid($0.value) }
        self.defaultPct = defaultPct.flatMap { BudgetPercent.isValid($0) ? $0 : nil }
        self.sessions = sessions.filter { BudgetProjectKey.isSaneSessionId($0.key) && BudgetPercent.isValid($0.value) }
    }

    init(config: BudgetConfig, sessions: [String: Int]) {
        self.init(projects: config.projects, defaultPct: config.defaultPct, sessions: sessions)
    }

    /// A project's own cap, else the default.
    func projectCap(_ key: String) -> (cap: Int, isDefault: Bool)? {
        if let c = projects[key] { return (c, false) }
        if let d = defaultPct { return (d, true) }
        return nil
    }

    /// Which of a session's two caps binds: the one that is further along
    /// (over, then warn, then ok), the lower cap on a tie, the project's on a
    /// tie of both. With only one cap, that one. Designs/budget-caps.md §3.
    static func binding(project: (cap: Int, used: Double)?, session: (cap: Int, used: Double)?)
        -> (scope: BudgetScope, cap: Int, used: Double, state: BudgetState)? {
        let p = project.map { (BudgetScope.project, $0.cap, $0.used, BudgetState(used: $0.used, cap: $0.cap)) }
        let s = session.map { (BudgetScope.session, $0.cap, $0.used, BudgetState(used: $0.used, cap: $0.cap)) }
        switch (p, s) {
        case (nil, nil): return nil
        case let (p?, nil): return (p.0, p.1, p.2, p.3)
        case let (nil, s?): return (s.0, s.1, s.2, s.3)
        case let (p?, s?):
            if s.3 != p.3 { return s.3 > p.3 ? (s.0, s.1, s.2, s.3) : (p.0, p.1, p.2, p.3) }
            return s.1 < p.1 ? (s.0, s.1, s.2, s.3) : (p.0, p.1, p.2, p.3)
        }
    }
}

enum BudgetScope: String, Equatable { case project, session }

// MARK: - Status

/// Everything the screens and phones show about budgets, as a value: built
/// from the ledger and the caps, handed to the UI and to SessionRemote.
struct BudgetStatus: Equatable {
    struct Project: Equatable, Identifiable {
        let key: String
        let name: String
        /// Share of the week, 0–100.
        let used: Double
        /// Its own cap; nil when it has none (the default may apply).
        let cap: Int?
        /// Against its own cap, else the default.
        let state: BudgetState
        var id: String { key }
    }

    /// A session's budget (a `list` row): the cap that binds it and how much of it is used.
    struct Row: Equatable {
        let projectKey: String
        let projectName: String
        /// The project's share (the session's, when `scope` is session).
        let used: Double
        let cap: Int?
        let scope: BudgetScope
        let state: BudgetState
        let sessionUsed: Double
        let sessionCap: Int?
        /// The project's own cap, and the default that applies when it has none.
        let projectCap: Int?
        let defaultCap: Int?

        /// The line a card shows: "21% of 25%", "2% · no budget".
        var line: String { BudgetCopy.line(used: used, cap: cap, state: state, isDefault: scope == .project && projectCap == nil && cap != nil) }
    }

    /// Usage capture is on: without it nothing is measured or enforced.
    var capture: Bool
    /// Too early in the week to share it out.
    var measuring: Bool
    var weekPct: Double?
    var resetsAt: Date?
    var defaultCap: Int?
    /// Most used first; every project with spend or a cap this week.
    var projects: [Project]
    /// By session id: every session the ledger knows.
    var sessions: [String: Row]

    static let off = BudgetStatus(capture: false, measuring: false, weekPct: nil, resetsAt: nil, defaultCap: nil,
                                  projects: [], sessions: [:])

    /// `live`: session id → project key for every running session, so a session the
    /// status line hasn't reported yet still gets a row (its project's budget).
    static func build(ledger: BudgetLedger, caps: BudgetCaps, capture: Bool, live: [String: String] = [:]) -> BudgetStatus {
        guard capture else { return BudgetStatus.off }
        let est = ledger.estimate
        var keys = ledger.projectKeys.union(caps.projects.keys)
        keys = keys.filter { BudgetProjectKey.isValid($0) }
        let projects = keys.map { key -> Project in
            let used = ledger.used(project: key)
            let cap = caps.projects[key]
            return Project(key: key, name: ledger.name(of: key), used: used, cap: cap,
                           state: BudgetState(used: used, cap: cap ?? caps.defaultPct))
        }.sorted { a, b in a.used != b.used ? a.used > b.used : a.name.localizedCompare(b.name) == .orderedAscending }
        var rows: [String: Row] = [:]
        for (id, k) in live where BudgetProjectKey.isValid(k) {
            rows[id] = row(sessionId: id, projectKey: k, ledger: ledger, caps: caps)
        }
        for (id, s) in ledger.sessions {
            rows[id] = row(sessionId: id, projectKey: s.projectKey, ledger: ledger, caps: caps)
        }
        return BudgetStatus(capture: true, measuring: est.measuring, weekPct: ledger.weekPct, resetsAt: ledger.resetsAt,
                            defaultCap: caps.defaultPct, projects: projects, sessions: rows)
    }

    /// One session's budget. `projectKey` is the ledger's, or a resolved folder for a session not seen yet.
    static func row(sessionId: String, projectKey: String, ledger: BudgetLedger, caps: BudgetCaps) -> Row {
        let pUsed = ledger.used(project: projectKey), sUsed = ledger.used(session: sessionId)
        let own = caps.projects[projectKey]
        let pc = caps.projectCap(projectKey)
        let sc = caps.sessions[sessionId]
        let bind = BudgetCaps.binding(project: pc.map { ($0.cap, pUsed) }, session: sc.map { ($0, sUsed) })
        return Row(projectKey: projectKey, projectName: ledger.name(of: projectKey),
                   used: bind?.used ?? pUsed, cap: bind?.cap, scope: bind?.scope ?? .project, state: bind?.state ?? .ok,
                   sessionUsed: sUsed, sessionCap: sc, projectCap: own, defaultCap: caps.defaultPct)
    }

    func project(_ key: String) -> Project? { projects.first { $0.key == key } }

    // MARK: wire

    /// 18.4 → 18.4; 0.0123 → 0 (one decimal).
    static func rounded1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    /// The `list` header's `budget` block (Designs/budget-caps.md §5).
    var headerWire: [String: Any] {
        var o: [String: Any] = ["window": "week", "capture": capture, "measuring": measuring,
                                "defaultCap": defaultCap.map { $0 as Any } ?? NSNull()]
        if let resetsAt { o["resetsAt"] = Int(resetsAt.timeIntervalSince1970) }
        if let weekPct { o["weekPct"] = Self.rounded1(weekPct) }
        o["projects"] = projects.prefix(Self.maxWireProjects).map { p -> [String: Any] in
            ["key": p.key, "name": p.name, "used": Self.rounded1(p.used),
             "cap": p.cap.map { $0 as Any } ?? NSNull(), "state": p.state.rawValue]
        }
        return o
    }

    static let maxWireProjects = 60

    /// A `list` row's `budget` object; nil for a session the ledger hasn't seen.
    func rowWire(sessionId: String) -> [String: Any]? {
        guard capture, let r = sessions[sessionId] else { return nil }
        return ["projectKey": r.projectKey, "used": Self.rounded1(r.used), "cap": r.cap.map { $0 as Any } ?? NSNull(),
                "scope": r.scope.rawValue, "state": r.state.rawValue, "sessionUsed": Self.rounded1(r.sessionUsed),
                "sessionCap": r.sessionCap.map { $0 as Any } ?? NSNull()]
    }

    /// The Page Studio Budget page's board.
    func board(timeZone: TimeZone = .current) -> BudgetBoard {
        BudgetBoard(rows: projects.map {
            BudgetBoardRow(key: $0.key, name: $0.name, used: $0.used, cap: $0.cap,
                           state: BudgetBoardRow.State(rawValue: $0.state.rawValue) ?? .ok)
        }, defaultCap: defaultCap, resetText: resetsAt.map { "resets " + BudgetCopy.resets($0, timeZone: timeZone) },
           measuring: measuring, captureOn: capture)
    }
}

// MARK: - Pages

/// The pages Page sends for budgets, and what a reply to one means.
enum BudgetPages {
    static let idPrefix = "page-budget-"

    enum Kind: String, Equatable { case warn, stop }

    static func isPageId(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// "page-budget-<hash>-warn-<window>" / "…-stop-<window>": the window (the
    /// reset's epoch seconds) makes the next week's page a new one.
    static func pageId(hash: String, kind: Kind, window: Int) -> String { "\(idPrefix)\(hash)-\(kind.rawValue)-\(window)" }

    /// The session id a page carries: one per project or session cap.
    static func pageSessionId(hash: String) -> String { idPrefix + hash }

    static func parse(_ id: String) -> (hash: String, kind: Kind, window: Int)? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let parts = id.dropFirst(idPrefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 16, let kind = Kind(rawValue: String(parts[1])), let w = Int(parts[2]) else { return nil }
        return (String(parts[0]), kind, w)
    }

    static let warningSubtype = "budget_warning"
    static let reachedSubtype = "budget_reached"

    /// "Night Owl has used about 20% of the week (budget 25%). Page stops it at 25%."
    /// The phones read `about N%` and `budget N%` back: keep the words.
    static func warningText(subject: String, used: Double, cap: Int) -> String {
        "\(subject) has used about \(BudgetCopy.wholePct(used))% of the week (budget \(cap)%). Page stops it at \(cap)%."
    }

    /// "Night Owl reached its budget: about 26% of the week (budget 25%). Page stopped 2 sessions."
    /// The phones read `about N%`, `budget N%` and `stopped N session`.
    static func reachedText(subject: String, used: Double, cap: Int, stopped: Int) -> String {
        "\(subject) reached its budget: about \(BudgetCopy.wholePct(used))% of the week (budget \(cap)%). "
            + "Page stopped \(stopped) session\(stopped == 1 ? "" : "s")."
    }

    /// Who a page is about: the project's name, or one session in it.
    static func subject(name: String, session: Bool) -> String { session ? "A session in \(name)" : name }

    /// What a reply to a budget page does. A typed reply never reaches a session.
    enum Decision: Equatable {
        /// Raise the cap by 10 (at most 100) for good.
        case raise
        /// Let this turn finish.
        case carryOn
        /// Keep it stopped (or dismiss the warning) and close the page.
        case keepStopped
    }

    static func decision(action: String?, text: String) -> Decision {
        switch action {
        case "approve": return .raise
        case "carry_on": return .carryOn
        default: return .keepStopped
        }
    }

    /// What the phone's receipt says. Always given: without it the phone falls back to
    /// "typed into the session", which is wrong here.
    static func raisedDetail(name: String, cap: Int) -> String { "Raised \(name) to \(cap)%" }
    static func carryOnDetail(name: String) -> String { "\(name) can finish this turn" }
    static func keptStoppedDetail(name: String) -> String { "Kept \(name) stopped" }
    static func dismissedDetail(name: String) -> String { "Dismissed the warning for \(name)" }
    static let alreadyMaxDetail = "That budget is already 100% of the week, so it can’t go higher"
    static let staleDetail = "This budget page no longer applies"
    static func stillOverDetail(name: String, cap: Int, used: Double) -> String {
        "Raised \(name) to \(cap)%, but it has used about \(BudgetCopy.wholePct(used))%, so it stays stopped"
    }

    /// The line typed into a session Page stopped, once it may go on.
    static func raisedMessage(cap: Int) -> String { "Page: budget raised to \(cap)% — carry on where you left off." }
    static let finishTurnMessage = "Page: you can finish this turn — carry on where you left off."
}

// MARK: - The gate

/// What the PreToolUse gate reads (`hooks/page-budget-gate.sh`): per marker, a
/// `.gate` file of plain `key=value` lines, so the hook stays dumb.
enum BudgetGate {
    /// "Page: Night Owl reached its budget (25% of the week). Raise it in Page, or wait for the reset on Mon 09:00."
    static func stopReason(subject: String, cap: Int, resetsAt: Date?, timeZone: TimeZone) -> String {
        let wait = resetsAt.map { ", or wait for the reset on \(BudgetCopy.resets($0, timeZone: timeZone))" } ?? ""
        return "Page: \(subject) reached its budget (\(cap)% of the week). Raise it in Page\(wait)."
    }

    /// The complete, pre-escaped JSON line the hook prints on a match.
    static func stopLine(reason: String) -> String {
        let clean = String(reason.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : Character($0) })
        let data = (try? JSONSerialization.data(withJSONObject: ["continue": false, "stopReason": clean],
                                                options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The `.gate` file's text: `project`, `session`, `expires` (unix seconds) and `stop`.
    /// nil when a key has a newline (it would break the format).
    static func gateFile(project: String?, session: String?, expires: Int, stopLine: String) -> String? {
        for v in [project, session].compactMap({ $0 }) where v.contains("\n") || v.contains("\r") { return nil }
        guard !stopLine.contains("\n"), !stopLine.contains("\r") else { return nil }
        return "project=\(project ?? "")\nsession=\(session ?? "")\nexpires=\(expires)\nstop=\(stopLine)\n"
    }

    /// The `.json` marker (Designs/budget-caps.md §4).
    static func markerJSON(project: String?, session: String?, name: String, cap: Int, used: Double, expiresAt: Int) -> Data {
        let o: [String: Any] = ["project": project.map { $0 as Any } ?? NSNull(), "session": session.map { $0 as Any } ?? NSNull(),
                                "name": name, "cap": cap, "used": BudgetStatus.rounded1(used), "expiresAt": expiresAt]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    /// Whether a hook `cwd` is inside `project` (a path boundary: /x/proj is not /x/proj2). Mirrors the shell.
    static func covers(project: String, cwd: String) -> Bool {
        cwd == project || cwd.hasPrefix(project.hasSuffix("/") ? project : project + "/")
    }
}

// MARK: - The wire op

/// The phone's `budget` op (Designs/budget-caps.md §5), validated.
struct BudgetOp: Equatable {
    enum Target: Equatable {
        case project(String)
        case session(String)
        case defaultCap
    }

    var target: Target
    /// 1...100, or nil to clear.
    var pct: Int?

    /// How `pct` arrived on the wire (missing and `null` both clear; a boolean or a fraction is invalid).
    enum PctField: Equatable { case absent, null, int(Int), invalid }

    enum Failure: Error, Equatable {
        case message(String)
        var detail: String { if case .message(let m) = self { return m }; return "" }
    }

    static func parse(scope: String?, key: String?, sessionId: String?, pct: PctField) -> Result<BudgetOp, Failure> {
        let value: Int?
        switch pct {
        // A missing `pct` clears, like `null` (the phones send null).
        case .absent: value = nil
        case .invalid: return .failure(.message("A budget is a whole percent from 1 to 100"))
        case .null: value = nil
        case .int(let n):
            guard BudgetPercent.isValid(n) else { return .failure(.message("A budget is a whole percent from 1 to 100")) }
            value = n
        }
        switch scope {
        case "project":
            guard var key, !key.isEmpty else { return .failure(.message("Say which project")) }
            while key.count > 1 && key.hasSuffix("/") { key.removeLast() }
            guard BudgetProjectKey.isValid(key) else { return .failure(.message("That isn't a project folder Page Studio knows")) }
            return .success(BudgetOp(target: .project(key), pct: value))
        case "session":
            guard let sessionId, BudgetProjectKey.isSaneSessionId(sessionId) else { return .failure(.message("Say which session")) }
            return .success(BudgetOp(target: .session(sessionId), pct: value))
        case "default":
            return .success(BudgetOp(target: .defaultCap, pct: value))
        default:
            return .failure(.message("Say whether this is a project, a session or the default budget"))
        }
    }

    /// "Night Owl's budget is now 30%", "This session's budget is off", "The default budget is now 15%". Pure.
    /// `projectName` is the project's name when the caller knows it.
    func resultDetail(projectName: String?) -> String {
        let value = pct.map { "now \($0)%" } ?? "off"
        switch target {
        case .project: return "\(projectName ?? "The project")’s budget is \(value)"
        case .session: return "This session’s budget is \(value)"
        case .defaultCap: return "The default budget is \(value)"
        }
    }

    /// Pure. The config's budget with this op applied (project and default only).
    func applied(to budget: BudgetConfig) -> BudgetConfig {
        var b = budget
        switch target {
        case .project(let key): b.projects[key] = pct
        case .defaultCap: b.defaultPct = pct
        case .session: break
        }
        return b
    }
}

extension BudgetOp.PctField {
    /// `raw` is the JSON value of `pct`, `present` whether the key was there at all.
    /// A boolean, or a number that isn't whole, is invalid.
    static func from(_ raw: Any?, present: Bool) -> BudgetOp.PctField {
        guard present else { return .absent }
        if raw == nil || raw is NSNull { return .null }
        guard let n = raw as? NSNumber, !n.isJSONBool else { return .invalid }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e6 else { return .invalid }
        return .int(Int(d))
    }
}
