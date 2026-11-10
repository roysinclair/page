import Foundation

// Budget caps, enforcement (Designs/budget-caps.md §4): keeps the books, decides
// what is over, writes the gate's marker files, and says what to do about it as
// plain effects the Coordinator carries out (Esc, pages). Nothing here touches
// a session, the relay or a clock: directories, `now` and the live sessions are
// passed in, so it runs against a temp folder in tests.

/// A Claude session the controller may cover with a marker.
struct BudgetLiveSession: Equatable {
    var sessionId: String
    var cwd: String?
    /// Mid-turn.
    var busy: Bool
}

/// What the Coordinator does for the controller.
enum BudgetEffect: Equatable {
    case openPage(InterventionEvent)
    case closePage(id: String, reason: String)
    /// Esc in these busy sessions (Page's marker is already in place).
    case interrupt(sessionIds: [String])
}

/// What survives a restart besides the ledger: which budgets are stopped, which
/// pages are open, and which sessions may finish a turn.
struct BudgetEnforcementState: Codable, Equatable {
    /// A budget that is over: its marker files stand.
    struct Marker: Codable, Equatable {
        var project: String?
        var session: String?
        var name: String
        var cap: Int
        var used: Double
        /// The window's reset (unix seconds).
        var window: Int
        var openedAt: Date
        /// Sessions Page pressed Esc in, or saw working while the marker stood:
        /// what a raise or "finish this turn" carries on.
        var affected: [String]
        /// The open cap-reached page; nil once it was answered.
        var pageId: String?
        /// The page's text, to send it again on a new relay channel.
        var pageText: String
    }

    /// An open near-the-budget page.
    struct Warning: Codable, Equatable {
        var pageId: String
        var project: String?
        var session: String?
        var name: String
        var pageText: String
        var openedAt: Date
    }

    /// A session let through the gate for one turn.
    struct Allow: Codable, Equatable {
        var createdAt: Date
        /// Seen working since: the allow ends when it next stops.
        var sawBusy: Bool
    }

    var markers: [String: Marker] = [:]
    var warnings: [String: Warning] = [:]
    var allow: [String: Allow] = [:]

    var isEmpty: Bool { markers.isEmpty && warnings.isEmpty && allow.isEmpty }
}

/// A reply to a budget page, read against what is open.
struct BudgetReplyPlan: Equatable {
    var decision: BudgetPages.Decision
    var kind: BudgetPages.Kind
    var hash: String
    var name: String
    /// What a raise changes.
    var target: BudgetOp.Target
    /// The cap that binds now, and ten more (at most 100); nil when it can't go higher.
    var currentCap: Int?
    var raisedCap: Int?
    /// Sessions Page stopped for this marker, still running: what a raise carries on.
    var affected: [String]
    /// Every running session the marker covers (the busy ones may finish their turn).
    var covered: [String]
    /// When Page stopped them: what "the user hasn't touched it since" is measured from.
    var openedAt: Date?
}

final class BudgetController {
    let files: BudgetFiles
    var timeZone: TimeZone = .current

    private(set) var ledger: BudgetLedger
    private(set) var sessionCaps: BudgetSessionCaps
    private(set) var state: BudgetEnforcementState
    private(set) var caps = BudgetCaps()
    private(set) var status = BudgetStatus.off
    private var scanner = BudgetStatusScanner()
    private var cwdKeys: [String: String] = [:]

    /// An allow ends after this long if the session never got going.
    static let allowLifetime: TimeInterval = 30 * 60
    /// A window this long over is dead: its spend is dropped.
    static let windowGrace: TimeInterval = 600

    init(files: BudgetFiles) {
        self.files = files
        ledger = files.loadLedger()
        sessionCaps = files.loadSessionCaps()
        state = files.loadState()
    }

    // MARK: the pass

    /// One pass (every 15 s from the Coordinator): reads the status line files that
    /// changed, updates the books, and brings markers, pages and allows in line with
    /// the caps. Returns what to do.
    @discardableResult
    func refresh(now: Date, budget: BudgetConfig, captureOn: Bool, live: [BudgetLiveSession]) -> [BudgetEffect] {
        var effects: [BudgetEffect] = []
        let stateBefore = state
        guard captureOn else {
            status = .off
            caps = BudgetCaps()
            effects += clearEverything()
            if state != stateBefore { files.save(state) }
            return effects
        }
        var ledgerDirty = false
        for s in scanner.scan(directory: files.statusline, now: now) where ledger.observe(s, now: now) != .ignored { ledgerDirty = true }
        if ledger.prune(now: now) { ledgerDirty = true }

        if sessionCaps.refresh(live: Set(live.map(\.sessionId)), now: now) { files.save(sessionCaps) }
        caps = BudgetCaps(config: budget, sessions: sessionCaps.caps)
        status = BudgetStatus.build(ledger: ledger, caps: caps, capture: true, live: sessionKeys(live))

        let warnedBefore = ledger.warned
        effects += enforce(now: now, live: live)
        if ledger.warned != warnedBefore { ledgerDirty = true }
        if ledgerDirty { files.save(ledger) }
        if state != stateBefore { files.save(state) }
        return effects
    }

    /// Re-runs enforcement now with the caps and live sessions as they are
    /// (after a cap changed), without reading the status line files again.
    @discardableResult
    func reevaluate(now: Date, budget: BudgetConfig, captureOn: Bool, live: [BudgetLiveSession]) -> [BudgetEffect] {
        refresh(now: now, budget: budget, captureOn: captureOn, live: live)
    }

    /// Session id → project key, for every running session: the ledger's, else its folder, resolved once.
    private func sessionKeys(_ live: [BudgetLiveSession]) -> [String: String] {
        var out: [String: String] = [:]
        for s in live {
            if let k = ledger.sessions[s.sessionId]?.projectKey { out[s.sessionId] = k; continue }
            guard let cwd = s.cwd, cwd.hasPrefix("/") else { continue }
            if cwdKeys[cwd] == nil {
                if cwdKeys.count > 300 { cwdKeys.removeAll() }
                cwdKeys[cwd] = BudgetProjectKey.key(projectDir: nil, cwd: cwd) ?? ""
            }
            if let k = cwdKeys[cwd], !k.isEmpty { out[s.sessionId] = k }
        }
        return out
    }

    // MARK: enforcement

    private struct Target {
        let hash: String
        let project: String?
        let session: String?
        let name: String
        let cap: Int
        let used: Double
        let state: BudgetState
        var isSession: Bool { session != nil }
        var subject: String { BudgetPages.subject(name: name, session: isSession) }
    }

    /// The running sessions a target covers: by session id, or by project (the
    /// ledger's key, or a folder inside it: the gate's rule).
    private func covered(_ t: Target, live: [BudgetLiveSession]) -> [BudgetLiveSession] {
        if let sid = t.session { return live.filter { $0.sessionId == sid } }
        guard let key = t.project else { return [] }
        return live.filter { s in
            ledger.sessions[s.sessionId]?.projectKey == key || (s.cwd.map { BudgetGate.covers(project: key, cwd: $0) } ?? false)
        }
    }

    private func targets() -> [String: Target] {
        var out: [String: Target] = [:]
        for p in status.projects {
            guard let c = caps.projectCap(p.key) else { continue }
            out[BudgetHash.project(p.key)] = Target(hash: BudgetHash.project(p.key), project: p.key, session: nil, name: p.name,
                                                    cap: c.cap, used: p.used, state: BudgetState(used: p.used, cap: c.cap))
        }
        for (sid, cap) in caps.sessions {
            let used = ledger.used(session: sid)
            let h = BudgetHash.session(sid)
            let project = ledger.sessions[sid]?.projectKey
            out[h] = Target(hash: h, project: nil, session: sid, name: project.map { ledger.name(of: $0) } ?? "this session",
                            cap: cap, used: used, state: BudgetState(used: used, cap: cap))
        }
        return out
    }

    private func enforce(now: Date, live: [BudgetLiveSession]) -> [BudgetEffect] {
        // No window, or one that is over: nothing is over.
        guard let resets = ledger.resetsAt, resets > now else { return clearEverything() }
        let window = Int(resets.timeIntervalSince1970)
        let all = targets()
        var effects: [BudgetEffect] = []

        // Over: a marker each. New ones stop the busy sessions they cover, once.
        for (h, t) in all where t.state == .over {
            if var m = state.markers[h] {
                let rewrite = m.cap != t.cap || m.window != window || abs(m.used - t.used) >= 0.5 || !files.markerExists(hash: h)
                m.cap = t.cap; m.used = t.used; m.window = window
                for s in covered(t, live: live) where s.busy && !m.affected.contains(s.sessionId) { m.affected.append(s.sessionId) }
                if rewrite { _ = writeMarker(t, window: window) }
                state.markers[h] = m
                continue
            }
            let cover = covered(t, live: live)
            let stopping = cover.filter { $0.busy && state.allow[$0.sessionId] == nil }.map(\.sessionId)
            guard writeMarker(t, window: window) else {
                Logger.shared.log("Budget: couldn't write the marker for \(t.name) — not enforced")
                continue
            }
            if let w = state.warnings.removeValue(forKey: h) { effects.append(.closePage(id: w.pageId, reason: "resolved")) }
            let id = BudgetPages.pageId(hash: h, kind: .stop, window: window)
            let text = BudgetPages.reachedText(subject: t.subject, used: t.used, cap: t.cap, stopped: stopping.count)
            state.markers[h] = BudgetEnforcementState.Marker(project: t.project, session: t.session, name: t.name, cap: t.cap, used: t.used,
                                                              window: window, openedAt: now, affected: stopping, pageId: id, pageText: text)
            Logger.shared.log("Budget: \(t.name) reached its budget (\(Int(t.used.rounded()))% of \(t.cap)%) — stopping \(stopping.count) session(s)")
            if !stopping.isEmpty { effects.append(.interrupt(sessionIds: stopping)) }
            effects.append(.openPage(Self.event(id: id, hash: h, project: t.project, name: t.name, text: text, subtype: BudgetPages.reachedSubtype, at: now)))
        }
        for (h, m) in state.markers where all[h]?.state != .over {
            files.removeMarker(hash: h)
            if let p = m.pageId { effects.append(.closePage(id: p, reason: "resolved")) }
            state.markers[h] = nil
            Logger.shared.log("Budget: \(m.name) is under its budget again — marker removed")
        }
        for h in files.markerHashes() where state.markers[h] == nil { files.removeMarker(hash: h) }

        // Warn: once per budget and window, closed when it stops applying.
        for (h, t) in all where t.state == .warn && state.markers[h] == nil && state.warnings[h] == nil && !ledger.warned.contains(h) {
            let id = BudgetPages.pageId(hash: h, kind: .warn, window: window)
            let text = BudgetPages.warningText(subject: t.subject, used: t.used, cap: t.cap)
            state.warnings[h] = BudgetEnforcementState.Warning(pageId: id, project: t.project, session: t.session, name: t.name,
                                                                pageText: text, openedAt: now)
            ledger.warned.append(h)
            effects.append(.openPage(Self.event(id: id, hash: h, project: t.project, name: t.name, text: text, subtype: BudgetPages.warningSubtype, at: now)))
        }
        for (h, w) in state.warnings where all[h]?.state != .warn {
            state.warnings[h] = nil
            effects.append(.closePage(id: w.pageId, reason: "resolved"))
        }

        updateAllows(now: now, live: live, all: all)
        return effects
    }

    /// An allow ends when its session has worked and stopped again, has gone, no
    /// marker covers it any more, or never got going within 30 minutes.
    private func updateAllows(now: Date, live: [BudgetLiveSession], all: [String: Target]) {
        for (sid, var a) in state.allow {
            let s = live.first { $0.sessionId == sid }
            if s?.busy == true { a.sawBusy = true }
            let stillCovered = state.markers.keys.contains { h in all[h].map { t in covered(t, live: live).contains { $0.sessionId == sid } } ?? false }
            let ended = s == nil || (a.sawBusy && s?.busy == false) || (!a.sawBusy && now.timeIntervalSince(a.createdAt) > Self.allowLifetime)
            if ended || !stillCovered {
                files.removeAllow(sessionId: sid)
                state.allow[sid] = nil
            } else {
                state.allow[sid] = a
            }
        }
        let known = Set(state.allow.keys.map(BudgetProjectKey.sanitizedSessionId))
        for n in files.allowNames() where !known.contains(n) { files.removeAllow(sessionId: n) }
    }

    /// Capture is off, or there is no window: no markers, no allows, no open pages.
    private func clearEverything() -> [BudgetEffect] {
        var effects: [BudgetEffect] = []
        for (_, m) in state.markers { if let p = m.pageId { effects.append(.closePage(id: p, reason: "resolved")) } }
        for (_, w) in state.warnings { effects.append(.closePage(id: w.pageId, reason: "resolved")) }
        state = BudgetEnforcementState()
        files.removeAllMarkersAndAllows()
        return effects
    }

    private func writeMarker(_ t: Target, window: Int) -> Bool {
        let reason = BudgetGate.stopReason(subject: t.session != nil ? "this session" : t.name, cap: t.cap,
                                           resetsAt: Date(timeIntervalSince1970: TimeInterval(window)), timeZone: timeZone)
        guard let gate = BudgetGate.gateFile(project: t.project, session: t.session, expires: window,
                                             stopLine: BudgetGate.stopLine(reason: reason)) else { return false }
        let json = BudgetGate.markerJSON(project: t.project, session: t.session, name: t.name, cap: t.cap, used: t.used, expiresAt: window)
        return files.writeMarker(hash: t.hash, json: json, gate: gate)
    }

    static func event(id: String, hash: String, project: String?, name: String, text: String, subtype: String, at: Date) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: BudgetPages.pageSessionId(hash: hash), cwd: project ?? "", projectName: name,
                          kind: .rateLimit, openedAt: at, context: text, transcriptPath: "", backend: .claude, source: .terminal,
                          subtype: subtype)
    }

    // MARK: pages that are open

    /// The open budget pages' ids (for the relay's `sync`).
    var openPageIds: [String] {
        state.markers.values.compactMap(\.pageId) + state.warnings.values.map(\.pageId)
    }

    /// The open pages as events, to send again on a new relay channel.
    var openPages: [InterventionEvent] {
        var out: [InterventionEvent] = []
        for (h, m) in state.markers { if let id = m.pageId {
            out.append(Self.event(id: id, hash: h, project: m.project, name: m.name, text: m.pageText, subtype: BudgetPages.reachedSubtype, at: m.openedAt))
        } }
        for (h, w) in state.warnings {
            out.append(Self.event(id: w.pageId, hash: h, project: w.project, name: w.name, text: w.pageText, subtype: BudgetPages.warningSubtype, at: w.openedAt))
        }
        return out
    }

    // MARK: replies

    /// Reads a reply against what is open. nil when the page is not (or no longer) one of ours.
    func plan(pageId: String, action: String?, text: String, live: [BudgetLiveSession], now: Date = Date()) -> BudgetReplyPlan? {
        guard let parsed = BudgetPages.parse(pageId) else { return nil }
        let h = parsed.hash
        let decision = BudgetPages.decision(action: action, text: text)
        let project: String?, session: String?, name: String, cap: Int?
        var affected: [String] = []
        var openedAt: Date?
        switch parsed.kind {
        case .stop:
            guard let m = state.markers[h], m.pageId == pageId else { return nil }
            project = m.project; session = m.session; name = m.name
            cap = m.cap
            affected = m.affected
            openedAt = m.openedAt
        case .warn:
            guard let w = state.warnings[h], w.pageId == pageId else { return nil }
            project = w.project; session = w.session; name = w.name
            cap = nil
        }
        let target: BudgetOp.Target
        var current: Int?
        if let session { target = .session(session); current = caps.sessions[session] ?? cap }
        else if let project { target = .project(project); current = caps.projectCap(project)?.cap ?? cap }
        else { return nil }
        if current == nil {
            // A warning's cap is whatever binds now.
            if let t = targets()[h] { current = t.cap }
        }
        let t = Target(hash: h, project: project, session: session, name: name, cap: current ?? 0, used: 0, state: .ok)
        let cover = covered(t, live: live)
        let running = Set(live.map(\.sessionId))
        return BudgetReplyPlan(decision: decision, kind: parsed.kind, hash: h, name: name, target: target, currentCap: current,
                               raisedCap: current.flatMap { $0 >= 100 ? nil : BudgetPercent.raised($0) },
                               affected: affected.filter { running.contains($0) }, covered: cover.map(\.sessionId), openedAt: openedAt)
    }

    /// The reply was answered without raising: the page is closed, the marker stays.
    func pageAnswered(hash: String, kind: BudgetPages.Kind) {
        switch kind {
        case .stop: state.markers[hash]?.pageId = nil
        case .warn: state.warnings[hash] = nil
        }
        files.save(state)
    }

    /// "Let this turn finish": these sessions pass the gate until they have worked and stopped.
    func allowSessions(_ ids: [String], now: Date, live: [BudgetLiveSession]) {
        for id in ids where BudgetProjectKey.isSaneSessionId(id) {
            guard files.writeAllow(sessionId: id, now: now) else { continue }
            state.allow[id] = BudgetEnforcementState.Allow(createdAt: now, sawBusy: live.first { $0.sessionId == id }?.busy == true)
        }
        files.save(state)
    }

    /// The sessions Page stopped, as the battery path's resume wants them.
    func pausedSessions(_ ids: [String], plan: BudgetReplyPlan, live: [BudgetLiveSession], now: Date) -> [PausedSession] {
        let openedAt = plan.openedAt ?? now
        return ids.compactMap { id in
            guard let s = live.first(where: { $0.sessionId == id }) else { return nil }
            return PausedSession(backend: .claude, sessionId: id, projectName: plan.name, cwd: s.cwd ?? "", pausedAt: openedAt,
                                 detail: "Stopped at its budget")
        }
    }

    // MARK: caps

    /// A session cap from the phone, the popover or Page Studio (project and default caps
    /// go through config.json, which the Coordinator owns).
    func setSessionCap(_ id: String, pct: Int?, now: Date) {
        sessionCaps.set(id, pct: pct, now: now)
        files.save(sessionCaps)
    }
}
