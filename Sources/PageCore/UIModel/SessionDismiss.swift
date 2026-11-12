import Foundation

// Putting a finished session away (Designs/panel-sessions.md): the ledger that
// hides it until its next turn, the swipe's thresholds, the five seconds of
// Undo, and the words the status line says. No clock, file, host or
// UserDefaults inside any of it: the store, the controller and the tests feed
// it values. The one file touch, `SessionDismissalStore`, takes its URL.

// MARK: - The ledger

/// One session the person put away, and the finished-turn page (if it had one)
/// that was dismissed with it.
struct SessionDismissal: Codable, Equatable {
    let sessionId: String
    let backend: AgentBackendID
    let at: Date
    /// The finished-turn page closed with it; nil for an idle session that had none.
    let pageId: String?

    init(sessionId: String, backend: AgentBackendID, at: Date, pageId: String? = nil) {
        self.sessionId = sessionId
        self.backend = backend
        self.at = at
        self.pageId = pageId
    }
}

/// The sessions the person dismissed, by session id. A dismissed session stays
/// out of the panel until its next turn: the entry goes when the session works
/// again (or waits for an approval), when a different page opens for it, or when
/// the session is gone. Pure: the Coordinator owns the one live copy, loads and
/// saves it through `SessionDismissalStore`, and publishes it in the snapshot.
struct SessionDismissals: Codable, Equatable {
    private(set) var entries: [String: SessionDismissal] = [:]

    init() {}

    var isEmpty: Bool { entries.isEmpty }

    mutating func dismiss(_ d: SessionDismissal) { entries[d.sessionId] = d }

    mutating func clear() { entries = [:] }

    /// Pure. `openPageIds` is that session's own open pages (not every page on
    /// the Mac): see `openPageIds(for:in:)`. True while the session has an
    /// entry, is neither `.active` nor `.waitingOnApproval`, and no page other
    /// than the one dismissed with it is open.
    func hides(_ session: AgentSession, openPageIds: Set<String>) -> Bool {
        guard let d = entries[session.sessionId] else { return false }
        switch session.state {
        case .active, .waitingOnApproval: return false
        default: break
        }
        return openPageIds.subtracting(d.pageId.map { [$0] } ?? []).isEmpty
    }

    /// Drops every entry that no longer applies: its session is gone, it became
    /// `.active` or `.waitingOnApproval`, or a different page opened for it.
    /// So the next time the session finishes, it shows again. True when
    /// anything was dropped (the caller then saves). `reported`: the backends that have said
    /// what sessions they have; an entry of one that has not (Codex scans on its own queue, and a
    /// relaunch is not a reason to forget what was put away) is kept even though its session is not
    /// listed yet.
    @discardableResult
    mutating func prune(live: [AgentSession], openPages: [InterventionEvent],
                        reported: Set<AgentBackendID> = [.claude, .codex, .aura, .orbit]) -> Bool {
        let byId = Dictionary(live.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for (id, d) in entries {
            var drop = reported.contains(d.backend)
            if let s = byId[id] {
                let other = Self.openPageIds(for: id, in: openPages).subtracting(d.pageId.map { [$0] } ?? [])
                drop = s.state == .active || s.state == .waitingOnApproval || !other.isEmpty
            }
            if drop {
                entries[id] = nil
                changed = true
            }
        }
        return changed
    }

    /// Pure. The ids of the pages open for one session.
    static func openPageIds(for sessionId: String, in pages: [InterventionEvent]) -> Set<String> {
        Set(pages.filter { $0.sessionId == sessionId }.map(\.id))
    }

    /// Pure. The live sessions the ledger hides right now.
    func hiddenSessionIds(live: [AgentSession], openPages: [InterventionEvent]) -> Set<String> {
        guard !entries.isEmpty else { return [] }
        let byId = Dictionary(grouping: openPages, by: \.sessionId).mapValues { Set($0.map(\.id)) }
        return Set(live.filter { hides($0, openPageIds: byId[$0.sessionId] ?? []) }.map(\.sessionId))
    }
}

/// `dismissed-sessions.json` in Page's support folder, 0600, written atomically.
/// The only part of the ledger that touches a file: `SessionDismissals` itself is
/// a plain value. The URL is injected, so tests and `--render-ui` never touch the
/// real support folder.
struct SessionDismissalStore {
    static let fileName = "dismissed-sessions.json"
    let url: URL

    init(url: URL) { self.url = url }

    init(support: URL) { self.url = support.appendingPathComponent(Self.fileName) }

    /// The live file, in Page's support folder.
    static func live() -> SessionDismissalStore { SessionDismissalStore(support: Platform.current.paths.support) }

    func load() -> SessionDismissals {
        guard let data = BudgetFiles.read(url), let d = try? BudgetFiles.decoder().decode(SessionDismissals.self, from: data) else {
            return SessionDismissals()
        }
        return d
    }

    @discardableResult
    func save(_ d: SessionDismissals) -> Bool {
        guard let data = try? BudgetFiles.encoder().encode(d) else { return false }
        return BudgetFiles.write(data, to: url)
    }
}

// MARK: - What can be dismissed

/// The session behind a card the person put away.
struct DismissTarget: Equatable {
    let rowId: String
    let sessionId: String
    let backend: AgentBackendID
    /// The finished-turn page that closes with it; nil for an idle session.
    let pageId: String?
    let project: String

    /// Pure. A card of a session that is not working: an IDLE card, or a working
    /// card whose turn has ended. Never a working card or a local model.
    static func of(_ row: InFlightRow) -> DismissTarget? {
        guard row.dismissable, let backend = row.backend else { return nil }
        return DismissTarget(rowId: row.id, sessionId: row.sessionId, backend: backend, pageId: nil, project: row.project)
    }

    /// Pure. A finished turn (`section == .review`). Never a Decide or Look row.
    static func of(_ row: DecideRow) -> DismissTarget? {
        guard row.section == .review else { return nil }
        return DismissTarget(rowId: row.id, sessionId: row.sessionId, backend: row.backend, pageId: row.id, project: row.projectName)
    }
}

/// A dismissal in its five seconds of Undo: the card is already gone, nothing
/// else has happened yet. At the end the controller commits it.
struct PendingDismissal: Equatable, Identifiable {
    /// How long Undo lasts.
    static let window: TimeInterval = 5

    let target: DismissTarget
    let startedAt: Date
    /// "Also close its terminal" was on when it was dismissed.
    let closesTerminal: Bool
    /// "cmux tab", "tmux pane"…: what would close, when Page knows (and says so in the line).
    let closeNoun: String?

    var id: String { target.sessionId }
    var commitAt: Date { startedAt.addingTimeInterval(Self.window) }

    /// Pure. Whole seconds left, rounded up: 5, 4, … 1, then 0.
    func secondsLeft(now: Date) -> Int { max(0, Int(commitAt.timeIntervalSince(now).rounded(.up))) }

    func isDue(now: Date) -> Bool { now >= commitAt }

    /// Pure. The status line while Undo lasts, without its "Undo".
    func line(now: Date) -> String {
        DismissCopy.pending(project: target.project, closeNoun: closesTerminal ? closeNoun : nil, secondsLeft: secondsLeft(now: now))
    }
}

// MARK: - The IDLE group

enum IdleGroup {
    /// The id the header jump scrolls to: the top of the group.
    static let anchorId = "idle-group"

    /// Pure. "Idle · 9".
    static func title(count: Int) -> String { "Idle · \(count)" }

    /// Pure. "2 dismissed · Show".
    static func dismissedTitle(count: Int) -> String { "\(count) dismissed · Show" }

    /// Pure. The sessions the Mac must know about to draw the group (where each runs, its model,
    /// what its last turn changed): Claude and Codex sessions at their prompt, or with only a
    /// finished-turn page waiting (their FINISHED card takes its who-line from the same read).
    /// Narrower than the cards (`InFlightRows.buildIdle` also needs what the probe finds), so the
    /// probe never reads a session the group can't show.
    static func probeCandidates(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { s in
            (s.backend == .claude || s.backend == .codex) && s.sessionId != InFlightRows.aggregateSessionId
                && (s.state == .idle || s.state == .waitingOnUser)
        }
    }

    /// Pure. The cards the group lists: the model's idle sessions, less any session
    /// that already has a row (its FINISHED or Decide card, or a working card whose
    /// turn just ended, shows it) and any session in `hidden` (dismissed, or in its
    /// five seconds of Undo). Order is the model's: most recent activity first.
    static func contents(idle: [InFlightRow], rows: [DecideRow], flights: [InFlightRow] = [], hidden: Set<String>) -> [InFlightRow] {
        var skip = hidden
        for r in rows { skip.insert(r.sessionId) }
        for f in flights { skip.insert(f.sessionId) }
        return idle.filter { !skip.contains($0.sessionId) }
    }
}

// MARK: - The swipe

/// When a sideways drag puts a card away, and how it moves until then.
enum SwipeDismissModel {
    /// A drag past this share of the card's width dismisses it.
    static let widthFraction = 0.35
    /// Or a flick at least this fast (points a second)…
    static let flickVelocity = 900.0
    /// …that has gone at least this far (points).
    static let flickDistance = 40.0
    /// A trackpad gesture counts as sideways when |Δx| is more than this times |Δy|.
    static let sidewaysRatio = 1.5

    /// Pure. True when |offset| ≥ 0.35 × width, or when |velocity| ≥ 900 pt/s and
    /// |offset| ≥ 40. A card with no width never dismisses.
    static func shouldDismiss(offset: Double, width: Double, velocity: Double) -> Bool {
        guard width > 0 else { return false }
        let moved = abs(offset)
        return moved >= widthFraction * width || (abs(velocity) >= flickVelocity && moved >= flickDistance)
    }

    /// Pure. How far a card that can't be dismissed follows the finger: it resists,
    /// and never goes past `limit`. (Only dismissable cards take the gesture, so
    /// this is the fallback.)
    static func rubberBand(offset: Double, limit: Double = 80) -> Double {
        let reach = limit * (1 - 1 / (abs(offset) * 0.55 / limit + 1))
        return offset < 0 ? -reach : reach
    }

    /// Pure. 0...1: how close the drag is to dismissing, for the label behind the card.
    static func progress(offset: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(1, abs(offset) / (widthFraction * width))
    }

    /// Pure. The first scroll event of a trackpad gesture decides: sideways when
    /// |Δx| > 1.5 × |Δy|. Anything else is the list scrolling, left alone.
    static func isSideways(deltaX: Double, deltaY: Double) -> Bool {
        abs(deltaX) > sidewaysRatio * abs(deltaY) && abs(deltaX) > 0
    }

    /// Pure. Points a second, from the distance moved over a span of time.
    static func velocity(delta: Double, seconds: Double) -> Double {
        seconds > 0 ? delta / seconds : 0
    }
}

// MARK: - Words

/// What the panel says about putting a session away, in one place.
enum DismissCopy {
    /// Behind the card as it swipes.
    static let swipeLabel = "Dismiss"
    static let swipeCloseLabel = "Dismiss · close tab"
    static let undoTitle = "Undo"
    /// The VoiceOver action every dismissable card carries.
    static let accessibilityAction = "Dismiss"

    /// Pure. "Dismiss · ⌫ · hides it until its next turn", or, with the setting
    /// on and the host known, "Dismiss · ⌫ · also closes its cmux tab".
    static func tooltip(closesTerminal: Bool, noun: String?) -> String {
        guard closesTerminal else { return "Dismiss · ⌫ · hides it until its next turn" }
        guard let noun else { return "Dismiss · ⌫ · hides it until its next turn · Page can't close this terminal" }
        return "Dismiss · ⌫ · also closes its \(noun)"
    }

    /// Pure. "Dismissed payments-api", or "Closing payments-api's cmux tab in 5s".
    /// The status line adds its " · Undo".
    static func pending(project: String, closeNoun: String?, secondsLeft: Int) -> String {
        guard let closeNoun else { return "Dismissed \(project)" }
        return "Closing \(project)'s \(closeNoun) in \(secondsLeft)s"
    }

    /// Pure. The line after the five seconds, and whether it is drawn amber:
    /// "Closed payments-api's cmux tab", "Dismissed payments-api · didn't close its tab: it started working again",
    /// "Dismissed payments-api · Page can't close Ghostty tabs".
    static func outcome(project: String, _ outcome: TerminalCloseOutcome) -> (text: String, failed: Bool) {
        switch outcome {
        case .closed(let noun):
            return ("Closed \(project)'s \(noun)", false)
        case .refused(let why):
            return (why.isPageLimit ? "Dismissed \(project) · \(why.text)"
                                    : "Dismissed \(project) · didn't close its tab: \(why.text)", true)
        case .failed(let why):
            return ("Dismissed \(project) · didn't close its tab: \(why)", true)
        }
    }
}
