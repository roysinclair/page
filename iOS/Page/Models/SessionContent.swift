import Foundation
import Combine

/// What a session's room reads and Now never does: the transcripts, the terminal screens and the diffs the Mac
/// sends. They arrive up to every 1.5 s while the Mac is busy, so they live apart from `SessionStore`: Now, Lanes
/// and the other containers observe the store, and a frame that only moves a transcript must not rebuild them.
/// The room, the agent room and the Changes sheet observe this object as well.
///
/// Every write checks that something changed first, so a frame that repeats what is held publishes nothing.
@MainActor
final class SessionContent: ObservableObject {
    @Published private(set) var transcripts: [String: SessionTranscript] = [:]
    /// The watched session's terminal, from Macs that send it.
    @Published private(set) var screens: [String: SessionScreen] = [:]
    /// The latest `diff` per session, and why the last request failed.
    @Published private(set) var diffs: [String: SessionDiff] = [:]
    @Published private(set) var diffErrors: [String: String] = [:]

    static let maxTranscripts = 12
    static let maxScreens = 4
    static let maxDiffs = 4

    /// A workflow agent's transcript, if the Mac sent it.
    func agentTranscript(sessionId: String, runId: String, agentId: String) -> SessionTranscript? {
        transcripts[SessionTranscript.key(sessionId: sessionId, runId: runId, agentId: agentId)]
    }

    /// A `transcript` frame. Keeps what is on screen (the session's and the open agent's) when it makes room.
    func apply(transcript t: SessionTranscript, watched: String?, watchedAgent: (runId: String, agentId: String)?) {
        var next = transcripts
        next[t.key] = t
        var keep: Set<String> = [t.key]
        if let sid = watched {
            keep.insert(sid)
            if let a = watchedAgent { keep.insert(SessionTranscript.key(sessionId: sid, runId: a.runId, agentId: a.agentId)) }
        }
        while next.count > Self.maxTranscripts, let victim = next.keys.first(where: { !keep.contains($0) }) {
            next[victim] = nil
        }
        if next != transcripts { transcripts = next }
    }

    /// A `screen` frame.
    func apply(screen s: SessionScreen, watched: String?) {
        var next = screens
        next[s.sessionId] = s
        if next.count > Self.maxScreens {
            for id in next.keys where id != s.sessionId && id != watched { next[id] = nil; break }
        }
        if next != screens { screens = next }
    }

    /// A `diff` frame: it also clears the last failure for the session.
    func apply(diff d: SessionDiff, watched: String?) {
        var next = diffs
        next[d.sessionId] = d
        if next.count > Self.maxDiffs {
            for id in next.keys where id != d.sessionId && id != watched { next[id] = nil; break }
        }
        if next != diffs { diffs = next }
        setDiffError(nil, for: d.sessionId)
    }

    /// Why the last diff request failed, or nil to clear it.
    func setDiffError(_ why: String?, for sessionId: String) {
        guard diffErrors[sessionId] != why else { return }
        diffErrors[sessionId] = why
    }

    /// A new `list`: transcripts and screens only for sessions that still exist (plus the one on screen, which
    /// shows "ended" over its last transcript).
    func prune(live: Set<String>, watched: String?) {
        let stale = transcripts.filter { !live.contains($0.value.sessionId) && $0.value.sessionId != watched }.keys
        if !stale.isEmpty {
            var next = transcripts
            for id in stale { next[id] = nil }
            transcripts = next
        }
        let staleScreens = screens.keys.filter { !live.contains($0) && $0 != watched }
        if !staleScreens.isEmpty {
            var next = screens
            for id in staleScreens { next[id] = nil }
            screens = next
        }
    }

    /// A transcript set outright (DEV mode's seeded and simulated ones).
    func set(transcript t: SessionTranscript, forKey key: String? = nil) {
        let key = key ?? t.key
        guard transcripts[key] != t else { return }
        transcripts[key] = t
    }

    func reset() {
        if !transcripts.isEmpty { transcripts = [:] }
        if !screens.isEmpty { screens = [:] }
        if !diffs.isEmpty { diffs = [:] }
        if !diffErrors.isEmpty { diffErrors = [:] }
    }
}
