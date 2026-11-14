import Foundation

/// One Claude conversation open in more than one terminal (Designs/session-copies.md §A). Claude Code
/// keeps each process's own memory of the conversation, so two processes on one session id both append to
/// one transcript and each knows only its own half. Page follows one of them, the "lead": the pick is pure
/// and made fresh on every read, so the tick, a reply and a close all agree on it.
enum ConversationCopies {
    /// What a reply gets when its page was raised for a terminal that is no longer the lead: a prompt
    /// answered in one copy must never be answered again in another.
    static let movedMessage = "This conversation moved to another terminal — check it on your Mac"

    // MARK: who counts

    /// A copy is a live interactive process with a terminal. Background owners (kind bg/daemon) never reach
    /// the registry's list, and a `--print` run is a one-shot, not a terminal a person has open.
    static func isCopy(_ s: ClaudeLiveSession) -> Bool {
        s.tty != nil && !s.isPrint
    }

    // MARK: the lead

    /// Status order: a prompt on screen first, then a turn running, then a finished turn with a shell still
    /// going, then idle; a status Page can't read comes last.
    static func statusRank(_ status: ClaudeSessionStatus) -> Int {
        switch status {
        case .waiting: return 4
        case .busy: return 3
        case .shell: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }

    /// Pure. Whether `a` leads `b`: status, then the later status change, then the later start, then the
    /// higher pid. The last two make the pick total, so it can't flap between equals.
    static func leads(_ a: ClaudeLiveSession, over b: ClaudeLiveSession) -> Bool {
        let (ra, rb) = (statusRank(a.status), statusRank(b.status))
        if ra != rb { return ra > rb }
        let (ua, ub) = (a.statusUpdatedAt ?? .distantPast, b.statusUpdatedAt ?? .distantPast)
        if ua != ub { return ua > ub }
        let (sa, sb) = (a.startedAt ?? .distantPast, b.startedAt ?? .distantPast)
        if sa != sb { return sa > sb }
        return a.pid > b.pid
    }

    /// Pure. The copy Page follows among the processes of one conversation; nil when none is a copy.
    static func lead(of processes: [ClaudeLiveSession]) -> ClaudeLiveSession? {
        processes.filter(isCopy).max { leads($1, over: $0) }
    }

    /// Pure. The copies of one conversation other than the lead, by pid.
    static func others(of processes: [ClaudeLiveSession]) -> [ClaudeLiveSession] {
        guard let lead = lead(of: processes) else { return [] }
        return processes.filter { isCopy($0) && $0.pid != lead.pid }.sorted { $0.pid < $1.pid }
    }

    /// Pure. Every conversation's copies (one or more), by session id.
    static func copies(in sessions: [ClaudeLiveSession]) -> [String: [ClaudeLiveSession]] {
        Dictionary(grouping: sessions.filter(isCopy), by: \.sessionId)
    }

    /// Pure. How many terminals have each conversation open, for those with more than one.
    static func counts(in sessions: [ClaudeLiveSession]) -> [String: Int] {
        copies(in: sessions).compactMapValues { $0.count > 1 ? $0.count : nil }
    }

    /// Pure. What Page follows: one session per conversation. A conversation with copies is its lead (the
    /// other copies, and a headless process sharing the id, are not looked at); anything else is as before.
    /// Keeps the input's order.
    static func leads(_ sessions: [ClaudeLiveSession]) -> [ClaudeLiveSession] {
        let groups = copies(in: sessions)
        let leadPids = Dictionary(uniqueKeysWithValues: groups.compactMap { id, g in lead(of: g).map { (id, $0.pid) } })
        return sessions.filter { s in
            guard let leadPid = leadPids[s.sessionId] else { return true }
            return s.pid == leadPid
        }
    }

    // MARK: closing the others

    /// Pure. The only statuses "Close the other" accepts in a copy it is about to close: at its prompt.
    static func closable(_ status: ClaudeSessionStatus) -> Bool { TerminalClose.eligible(status) }

    /// Pure. Whether "Close the other" is offered: there is another copy, every other copy is idle or at a
    /// shell (read by the caller from the registry), and every one of them is in a cmux tab.
    static func canCloseOther(others: [ClaudeLiveSession], inCmux: (ClaudeLiveSession) -> Bool) -> Bool {
        !others.isEmpty && others.allSatisfy { closable($0.status) && inCmux($0) }
    }
}

/// A conversation just found open in a second terminal (or more): what the Mac notification says.
struct CopiesNotice: Equatable {
    let sessionId: String
    /// How many terminals have it open (2 or more).
    let count: Int
    /// What the person calls the session: the name they gave it, else its folder.
    let name: String
}

/// The Mac notification "<name> is open twice": once per conversation when a second copy appears, and again
/// only after the conversation has been back to one copy for 60 s.
struct CopiesNoticeTracker: Equatable {
    static let rearmAfter: TimeInterval = 60

    private var notified: Set<String> = []
    /// When a notified conversation was first seen at one copy (or none) again.
    private var belowSince: [String: Date] = [:]

    /// `counts`: the conversations with more than one copy now (`ConversationCopies.counts`). A conversation
    /// that is gone counts as one copy. Returns the session ids to notify, sorted.
    mutating func step(counts: [String: Int], now: Date) -> [String] {
        var fire: [String] = []
        for (id, n) in counts where n >= 2 {
            belowSince[id] = nil
            if notified.insert(id).inserted { fire.append(id) }
        }
        for id in notified where (counts[id] ?? 1) < 2 {
            if let since = belowSince[id] {
                if now.timeIntervalSince(since) >= Self.rearmAfter {
                    notified.remove(id)
                    belowSince[id] = nil
                }
            } else {
                belowSince[id] = now
            }
        }
        return fire.sorted()
    }
}

// MARK: - Close the other

/// Why Page left the other terminals open.
enum CopiesCloseRefusal: Equatable {
    /// No second terminal is open any more.
    case noOther
    /// The copy to close isn't at its prompt (busy, a prompt on screen, or a status Page can't read).
    case notIdle(ClaudeSessionStatus)
    /// A copy isn't in a cmux tab Page can name: only cmux is closed from here.
    case notCmux(String)
    /// Which terminal Page follows changed while it was checking: the copy to close may now be the working one.
    case leadChanged
    /// A plan's own refusal.
    case plan(String)

    var text: String {
        switch self {
        case .noOther: return "there's no other terminal open any more"
        case .notIdle(let status):
            switch status {
            case .busy: return "it started working"
            case .waiting: return "it is waiting for an answer"
            default: return "Page can't tell what it is doing"
            }
        case .notCmux(let why): return why
        case .leadChanged: return "the working terminal changed, look again"
        case .plan(let why): return why
        }
    }
}

enum CopiesCloseOutcome: Equatable {
    /// `count` terminals closed.
    case closed(count: Int, noun: String)
    case refused(CopiesCloseRefusal)
    /// It was tried and did not work (some may have closed before it).
    case failed(String)
}

extension TerminalClose {
    /// "Close the other" (Designs/session-copies.md §A): closes every copy of the conversation that is not the
    /// lead, through the same exact-tab path as dismiss-closes-terminal (`cmuxCloseArgs`, `--force`, a last tab
    /// closes its workspace). Never a copy that is busy or waiting, never one outside cmux, and nothing is closed
    /// unless every one of them passes. Each is read again just before it is closed, and the lead is picked again
    /// from fresh reads, so a copy that has started working since (and so now leads) is left alone. Blocking: off
    /// the main thread, and only after the panel's confirm.
    static func closeOtherCopies(sessionId: String, io: TerminalCloseIO) -> CopiesCloseOutcome {
        let others = ConversationCopies.others(of: io.liveSessions().filter { $0.sessionId == sessionId })
        guard !others.isEmpty else { return .refused(.noOther) }
        let table = io.processTable()
        var plans: [(pid: Int32, plan: TerminalClosePlan)] = []
        for o in others {
            guard let status = io.currentStatus(o.pid) else { return .refused(.noOther) }
            guard ConversationCopies.closable(status) else { return .refused(.notIdle(status)) }
            let plan = plan(for: io.resolveHost(o, table))
            switch plan {
            case .cmux: plans.append((o.pid, plan))
            case .refuse(let why): return .refused(.plan(why))
            default: return .refused(.notCmux("Page closes the other terminal only in cmux"))
            }
        }
        var closed = 0
        for (pid, plan) in plans {
            // The lead and the copy's own status, read again: this one may have woken up, or the lead moved onto it.
            let now = io.liveSessions().filter { $0.sessionId == sessionId }
            guard now.contains(where: { $0.pid == pid }) else { continue }
            if ConversationCopies.lead(of: now)?.pid == pid { return closed == 0 ? .refused(.leadChanged) : .failed("the working terminal changed after \(closed) closed") }
            guard let status = io.currentStatus(pid), ConversationCopies.closable(status) else {
                let why = CopiesCloseRefusal.notIdle(io.currentStatus(pid) ?? .unknown)
                return closed == 0 ? .refused(why) : .failed("one started working after \(closed) closed")
            }
            switch io.run(plan) {
            case .closed: closed += 1
            case .refused(let why): return closed == 0 ? .refused(.plan(why)) : .failed(why)
            case .failed(let why): return .failed(why)
            }
        }
        // Every other copy ended between the checks and the closes: nothing was closed.
        return closed == 0 ? .refused(.noOther) : .closed(count: closed, noun: "cmux tab")
    }
}
