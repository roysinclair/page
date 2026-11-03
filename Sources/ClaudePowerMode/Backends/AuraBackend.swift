import Foundation

/// Page Aura backend (docs/AURA-LINK.md): the bring-your-own-key Claude chat
/// app hands its chats to Page over a local Unix socket.
///
///   - Sessions: each chat in Page Aura's latest `state` (busy, or waiting on
///     a tool approval). Idle chats are not listed.
///   - Keep-awake: `wantsPowerAssertion` while connected and any chat is busy.
///   - Pages: a tool approval is a `permission` page (immediately); a turn
///     that finished well becomes an `idle` page once the chat has been idle
///     `idlePageDelaySeconds` and the user away `idlePageOnlyWhenAwaySeconds`
///     (checked on every tick, dropped after 4 h).
///   - Replies: a `send` / `approve` command over the socket; the page closes
///     `replied` once Page Aura's `ack` says it took it.
///   - Disconnect: everything clears and open pages close `stale`.
///
/// Not in v1: low-battery pause (`BatteryPausable`) and the phone's live
/// sessions view — Page Aura's chats are only paged, not driven.
///
/// Threading: all state is behind `lock`. The transport calls in on its own
/// queue; replies come from the Coordinator's reply queue and never block
/// (the 20 s ack wait is a timer). Relay and callback calls are made after
/// the lock is released.
final class AuraBackend: AgentBackend, @unchecked Sendable {
    let id: AgentBackendID = .aura
    let displayName = "Page Aura"

    static let method = "aura-link"
    /// Page Aura sends `state` at least every 30 s; three missed beats and a
    /// "busy" chat no longer keeps the Mac awake.
    static let staleStateSeconds: TimeInterval = 90
    static let maxPromptContext = 800
    static let recentlyClosedLimit = 100
    /// A finished turn older than this never pages (as for Claude's
    /// `DetectorSettings.maxOpenAge` and Codex's `maxIdlePageAge`).
    static let maxIdlePageAge: TimeInterval = 4 * 3600

    typealias Effect = () -> Void

    var relay: RelaySink? {
        get { locked { _relay } }
        set { locked { _relay = newValue } }
    }
    var onNewIntervention: ((InterventionEvent) -> Void)? {
        get { locked { _onNewIntervention } }
        set { locked { _onNewIntervention = newValue } }
    }
    /// Page Aura has no rate limits Page can see; never called.
    var onNewRateLimit: ((RateLimitEvent) -> Void)? {
        get { locked { _onNewRateLimit } }
        set { locked { _onNewRateLimit = newValue } }
    }
    var onReplyFinished: ((ReplyFinished) -> Void)? {
        get { locked { _onReplyFinished } }
        set { locked { _onReplyFinished = newValue } }
    }

    /// One open page and what a reply to it needs.
    private struct Page {
        var event: InterventionEvent
        let chatId: String
        /// Permission pages: the approval to answer.
        let approvalId: String?
        /// Idle pages: epoch ms the finished turn ended; a chat busy with a
        /// later `since` means the page is moot.
        let idleAt: Int64?
    }

    /// A good, unstopped turn that may still become an idle page: it opens
    /// once the chat has been idle `idlePageDelaySeconds` and the user has
    /// been away `idlePageOnlyWhenAwaySeconds`, on any tick.
    private struct IdleCandidate {
        let chatId: String
        let title: String
        let snippet: String
        /// Epoch ms the turn ended.
        let at: Int64
    }

    private struct Pending {
        let pageId: String
        let timeout: DispatchWorkItem
    }

    private let lock = NSLock()
    private let transport: AuraLinkTransport
    private let now: () -> Date
    private let userAtMac: (Config) -> Bool

    private var _config: Config
    private var _relay: RelaySink?
    private var _onNewIntervention: ((InterventionEvent) -> Void)?
    private var _onNewRateLimit: ((RateLimitEvent) -> Void)?
    private var _onReplyFinished: ((ReplyFinished) -> Void)?

    private var started = false
    private var connected = false
    private var hello: AuraLink.Hello?
    private var chats: [AuraLink.Chat] = []
    private var lastStateAt: Date?
    private var pages: [String: Page] = [:]
    private var recentlyClosed: [String: Page] = [:]
    private var recentlyClosedOrder: [String] = []
    private var pending: [String: Pending] = [:]
    /// Latest finished turn per chat, waiting for the delay and the user's absence.
    private var idleCandidates: [String: IdleCandidate] = [:]
    /// Replies typed at this Mac's panel: told as "resolved on your Mac".
    private var macOriginReplies = Set<String>()
    private var lastSnapshot: AgentBackendSnapshot

    init(config: Config,
         transport: AuraLinkTransport = AuraLinkServer(),
         now: @escaping () -> Date = Date.init,
         userAtMac: @escaping (Config) -> Bool = { cfg in
             cfg.idlePageOnlyWhenAwaySeconds > 0 && UserPresence.isActive(within: cfg.idlePageOnlyWhenAwaySeconds)
         }) {
        self._config = config
        self.transport = transport
        self.now = now
        self.userAtMac = userAtMac
        self.lastSnapshot = Self.emptySnapshot
        transport.onConnect = { [weak self] in self?.handleConnect() }
        transport.onLine = { [weak self] line in self?.handleLine(line) }
        transport.onDisconnect = { [weak self] in self?.handleDisconnect() }
    }

    private static let emptySnapshot = AgentBackendSnapshot(
        backendID: .aura, displayName: "Page Aura", sessions: [], wantsPowerAssertion: false, pendingInterventions: [])

    var currentSnapshot: AgentBackendSnapshot { locked { lastSnapshot } }

    func openInterventionIds() -> [String] { locked { Array(pages.keys) } }

    /// Whether Page Aura is connected right now (for diagnostics and tests).
    var isConnected: Bool { locked { connected } }

    // MARK: lifecycle

    func start() {
        guard locked({ _config.auraBackendEnabled }) else {
            Logger.shared.log("AuraBackend disabled in config — not starting")
            return
        }
        locked { started = true }
        transport.start()
    }

    func refresh() {
        let (enabled, wasStarted) = locked { (_config.auraBackendEnabled, started) }
        // A listener that couldn't open (no folder, busy path) is retried on
        // every tick; `start()` on a listening transport is a no-op.
        if enabled && wasStarted { transport.start() }
        openDueIdlePages()
    }

    func shutdown() {
        stop(closingPages: false)
    }

    func reloadConfig(_ config: Config) {
        let old: Config = locked {
            let o = _config
            _config = config
            return o
        }
        if old.auraBackendEnabled && !config.auraBackendEnabled {
            Logger.shared.log("AuraBackend disabled via config — shutting down")
            stop(closingPages: true)
        } else if !old.auraBackendEnabled && config.auraBackendEnabled {
            Logger.shared.log("AuraBackend enabled via config — starting")
            start()
        }
    }

    private func stop(closingPages: Bool) {
        locked { started = false }
        transport.stop()
        run { fx in
            clearConnectionLocked(&fx, pageReason: closingPages ? "stale" : nil, failure: "Page Aura switched off")
        }
    }

    // MARK: transport events

    private func handleConnect() {
        run { fx in
            // A replaced client was already reported as a disconnect.
            connected = true
            hello = nil
            chats = []
            lastStateAt = nil
            idleCandidates = [:]
            Logger.shared.log("AuraBackend: connected")
        }
    }

    private func handleDisconnect() {
        run { fx in
            Logger.shared.log("AuraBackend: disconnected")
            clearConnectionLocked(&fx, pageReason: "stale", failure: AuraLink.notConnectedDetail)
        }
    }

    private func handleLine(_ line: Data) {
        guard let message = AuraLink.decode(line: line) else { return }
        switch message {
        case .hello(let h):
            locked { hello = h }
            Logger.shared.log("AuraBackend: hello from \(h.app) \(h.version) (proto \(h.proto))")
        case .state(let list):
            run { fx in
                guard connected else { return }
                chats = list
                lastStateAt = now()
                idleCandidates = idleCandidates.filter { !chatRestartedLocked($0.value) }
                reconcilePagesLocked(&fx)
            }
        case .finished(let f):
            handleFinished(f)
        case .ack(let ack):
            handleAck(ack)
        }
    }

    // MARK: pages

    private static func permissionId(chat: String, approval: String) -> String { "aura-\(chat)-perm-\(approval)" }
    private static func idleId(chat: String, at: Int64) -> String { "aura-\(chat)-idle-\(at)" }

    private func event(chatId: String, title: String, kind: InterventionKind, id: String, context: String) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: "aura-\(chatId)", cwd: "",
                          projectName: title.isEmpty ? "Page Aura" : title, kind: kind, openedAt: now(),
                          context: context, transcriptPath: "", backend: .aura, source: .desktop)
    }

    /// Pure. "Use <server> · <tool> on this Mac" plus the redacted, clipped args.
    static func permissionContext(server: String, tool: String, args: String) -> String {
        var head = "Use \(server.isEmpty ? "an app" : server)"
        if !tool.isEmpty { head += " · \(tool)" }
        head += " on this Mac"
        let shown = ContextRedactor.redactedPrefix(args, maxPromptContext).prefix(maxPromptContext)
        guard !shown.isEmpty else { return head }
        return head + "\n" + shown + (args.count > maxPromptContext ? "…" : "")
    }

    /// Pure. The redacted end of the reply, clipped.
    static func idleContext(snippet: String) -> String {
        String(ContextRedactor.redactedSuffix(snippet, AuraLink.maxSnippetLength).suffix(AuraLink.maxSnippetLength))
    }

    /// Opens permission pages for new approvals and closes pages whose
    /// approval is gone or whose chat has started a new turn. Pages with a
    /// reply in flight are left to that reply. Under `lock`.
    private func reconcilePagesLocked(_ fx: inout [Effect]) {
        var wanted = Set<String>()
        for chat in chats {
            guard let a = chat.approval else { continue }
            let pid = Self.permissionId(chat: chat.id, approval: a.id)
            wanted.insert(pid)
            guard pages[pid] == nil, recentlyClosed[pid] == nil else { continue }
            let e = event(chatId: chat.id, title: chat.title, kind: .permission, id: pid,
                          context: Self.permissionContext(server: a.server, tool: a.tool, args: a.args))
            pages[pid] = Page(event: e, chatId: chat.id, approvalId: a.id, idleAt: nil)
            publishLocked(e, &fx)
        }
        for (pid, page) in pages where !hasPendingLocked(for: pid) {
            switch page.event.kind {
            case .permission:
                if !wanted.contains(pid) { closeLocked(pid, "user_resolved_in_terminal", &fx) }
            case .idle:
                if let chat = chats.first(where: { $0.id == page.chatId }), chat.busy || chat.approval != nil,
                   (chat.since ?? .max) > (page.idleAt ?? 0) {
                    closeLocked(pid, "session_resolved", &fx)
                }
            default:
                break
            }
        }
    }

    /// Only a good, unstopped turn can page. It becomes a candidate; the page
    /// itself opens from `openDueIdlePages` once it is due, so a user who was
    /// at the Mac when the reply finished and then walks away still gets it.
    private func handleFinished(_ f: AuraLink.Finished) {
        guard f.ok, !f.stopped else { return }
        run { _ in
            guard connected else { return }
            if let existing = idleCandidates[f.chatId], existing.at > f.at { return }
            idleCandidates[f.chatId] = IdleCandidate(chatId: f.chatId, title: f.title, snippet: f.snippet, at: f.at)
        }
        openDueIdlePages()
    }

    /// Whether the chat's latest `state` shows a turn begun after the candidate
    /// ended (the same rule that closes an open idle page). Under `lock`.
    private func chatRestartedLocked(_ c: IdleCandidate) -> Bool {
        guard let chat = chats.first(where: { $0.id == c.chatId }), chat.busy || chat.approval != nil else { return false }
        return (chat.since ?? .max) > c.at
    }

    /// Opens the idle page of every candidate that is due: idle for
    /// `idlePageDelaySeconds` and the user away (`idlePageOnlyWhenAwaySeconds`),
    /// evaluated on every tick as for Claude. Each candidate opens at most
    /// once; one older than `maxIdlePageAge` is dropped. Presence is read
    /// before the lock is taken.
    private func openDueIdlePages() {
        let (cfg, hasCandidates) = locked { (_config, !idleCandidates.isEmpty) }
        let atMac = hasCandidates ? userAtMac(cfg) : false
        let delay = max(0, cfg.idlePageDelaySeconds)
        run { fx in
            let t = now()
            for c in idleCandidates.values.sorted(by: { ($0.at, $0.chatId) < ($1.at, $1.chatId) }) {
                let age = t.timeIntervalSince(Date(timeIntervalSince1970: Double(c.at) / 1000))
                let pid = Self.idleId(chat: c.chatId, at: c.at)
                if !connected || age > Self.maxIdlePageAge || chatRestartedLocked(c)
                    || pages[pid] != nil || recentlyClosed[pid] != nil {
                    idleCandidates[c.chatId] = nil
                    continue
                }
                guard age >= delay, !atMac else { continue }
                idleCandidates[c.chatId] = nil
                // A newer page for the chat replaces the older one.
                for (oldId, old) in pages where old.event.kind == .idle && old.chatId == c.chatId && !hasPendingLocked(for: oldId) {
                    closeLocked(oldId, "session_resolved", &fx)
                }
                let e = event(chatId: c.chatId, title: c.title, kind: .idle, id: pid, context: Self.idleContext(snippet: c.snippet))
                pages[pid] = Page(event: e, chatId: c.chatId, approvalId: nil, idleAt: c.at)
                publishLocked(e, &fx)
            }
        }
    }

    private func publishLocked(_ e: InterventionEvent, _ fx: inout [Effect]) {
        let relay = _relay
        let callback = _onNewIntervention
        Logger.shared.log("AuraBackend: OPENED \(e.kind.rawValue) \(e.id.prefix(48))")
        fx.append {
            relay?.sendInterventionOpened(e)
            callback?(e)
        }
    }

    /// Removes the page and tells the relay. Under `lock`.
    private func closeLocked(_ pid: String, _ reason: String, _ fx: inout [Effect]) {
        guard let page = pages.removeValue(forKey: pid) else { return }
        rememberClosedLocked(pid, page)
        let relay = _relay
        Logger.shared.log("AuraBackend: CLOSED \(pid.prefix(48)) (\(reason))")
        fx.append { relay?.sendInterventionClosed(id: pid, reason: reason) }
    }

    private func rememberClosedLocked(_ pid: String, _ page: Page) {
        if recentlyClosed[pid] == nil { recentlyClosedOrder.append(pid) }
        recentlyClosed[pid] = page
        while recentlyClosedOrder.count > Self.recentlyClosedLimit {
            recentlyClosed[recentlyClosedOrder.removeFirst()] = nil
        }
    }

    private func hasPendingLocked(for pid: String) -> Bool {
        pending.values.contains { $0.pageId == pid }
    }

    /// The connection is over: forget the chats, fail replies in flight and
    /// (optionally) close every open page. Under `lock`.
    private func clearConnectionLocked(_ fx: inout [Effect], pageReason: String?, failure: String) {
        connected = false
        hello = nil
        chats = []
        lastStateAt = nil
        idleCandidates = [:]
        for (cid, p) in pending {
            p.timeout.cancel()
            finishLocked(commandId: cid, pageId: p.pageId, success: false, detail: failure, &fx)
        }
        pending = [:]
        if let pageReason {
            for pid in Array(pages.keys) { closeLocked(pid, pageReason, &fx) }
        } else {
            pages = [:]
        }
    }

    // MARK: replies

    func handleReply(_ reply: RelayReply) {
        let pid = reply.interventionId
        if reply.source == "mac" {
            locked {
                if macOriginReplies.count > 200 { macOriginReplies.removeAll() }
                macOriginReplies.insert(pid)
            }
        }
        // The socket write happens after the lock is released: the transport's
        // queue calls back into this class, so the two must never wait on each other.
        var outgoing: (line: Data, commandId: String)?
        run { fx in
            guard connected else {
                return failReplyLocked(pid, AuraLink.notConnectedDetail, &fx)
            }
            guard !pending.values.contains(where: { $0.pageId == pid }) else {
                Logger.shared.log("AuraBackend: reply \(pid.prefix(48)) ignored — one is already in flight")
                return
            }
            let page: Page
            if let open = pages[pid] {
                page = open
            } else if let gone = recentlyClosed[pid], gone.event.kind == .idle {
                // A message typed for an idle page that closed moments ago
                // still goes into the chat; Page Aura refuses it if it's busy.
                page = gone
            } else {
                let detail = recentlyClosed[pid] != nil ? AuraLink.requestGoneDetail : AuraLink.pageGoneDetail
                return failReplyLocked(pid, detail, &fx)
            }
            let commandId = AuraLink.newCommandId()
            let line: Data
            switch AuraLink.plan(kind: page.event.kind, reply: reply) {
            case .failure(let detail):
                return failReplyLocked(pid, detail, &fx)
            case .send(let text):
                line = AuraLink.encodeSend(id: commandId, chatId: page.chatId, text: text)
            case .approve(let decision):
                guard let approvalId = page.approvalId else { return failReplyLocked(pid, AuraLink.requestGoneDetail, &fx) }
                line = AuraLink.encodeApprove(id: commandId, chatId: page.chatId, approvalId: approvalId, decision: decision)
            }
            let timeout = DispatchWorkItem { [weak self] in self?.commandTimedOut(commandId) }
            pending[commandId] = Pending(pageId: pid, timeout: timeout)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + AuraLink.ackTimeout, execute: timeout)
            outgoing = (line, commandId)
        }
        guard let outgoing, !transport.send(outgoing.line) else { return }
        run { fx in
            guard let p = pending.removeValue(forKey: outgoing.commandId) else { return }
            p.timeout.cancel()
            finishLocked(commandId: outgoing.commandId, pageId: p.pageId, success: false, detail: AuraLink.notConnectedDetail, &fx)
        }
    }

    private func handleAck(_ ack: AuraLink.Ack) {
        run { fx in
            guard let p = pending.removeValue(forKey: ack.ref) else { return }
            p.timeout.cancel()
            let detail = ack.detail.isEmpty ? (ack.ok ? "Sent to Page Aura" : "Page Aura couldn't do that") : ack.detail
            finishLocked(commandId: ack.ref, pageId: p.pageId, success: ack.ok, detail: detail, &fx)
            reconcilePagesLocked(&fx)
        }
    }

    private func commandTimedOut(_ commandId: String) {
        run { fx in
            guard let p = pending.removeValue(forKey: commandId) else { return }
            Logger.shared.log("AuraBackend: no ack for \(commandId.prefix(12)) in \(Int(AuraLink.ackTimeout)) s")
            finishLocked(commandId: commandId, pageId: p.pageId, success: false, detail: ReplyFinished.timeoutDetail, &fx)
            reconcilePagesLocked(&fx)
        }
    }

    private func failReplyLocked(_ pid: String, _ detail: String, _ fx: inout [Effect]) {
        finishLocked(commandId: nil, pageId: pid, success: false, detail: detail, &fx)
    }

    /// Reports one reply's result and, on success, closes its page. Under `lock`;
    /// the relay and Coordinator calls run after it is released.
    private func finishLocked(commandId: String?, pageId pid: String, success: Bool, detail: String, _ fx: inout [Effect]) {
        Logger.shared.log("AuraBackend: reply \(pid.prefix(48)) → success=\(success) — \(detail)")
        let relay = _relay
        let finished = _onReplyFinished
        let viaMac = macOriginReplies.remove(pid) != nil
        fx.append {
            finished?(ReplyFinished(interventionId: pid, success: success, method: Self.method, detail: detail))
            if !viaMac {
                relay?.sendReplyInjected(interventionId: pid, method: Self.method, success: success, detail: detail, output: nil)
            }
        }
        guard success else { return }
        // A message into an idle page that had just closed has nothing to close.
        closeLocked(pid, viaMac ? "session_resolved" : "replied", &fx)
    }

    // MARK: state

    /// Runs `body` under the lock, rebuilds the snapshot, then runs the
    /// effects it collected with the lock released.
    private func run(_ body: (inout [Effect]) -> Void) {
        var fx: [Effect] = []
        lock.lock()
        body(&fx)
        rebuildSnapshotLocked()
        lock.unlock()
        fx.forEach { $0() }
    }

    private func rebuildSnapshotLocked() {
        let t = now()
        let fresh = lastStateAt.map { t.timeIntervalSince($0) < Self.staleStateSeconds } ?? false
        let sessions = connected ? chats.map { chat -> AgentSession in
            AgentSession(backend: .aura, sessionId: "aura-\(chat.id)", cwd: nil,
                         title: chat.title.isEmpty ? nil : chat.title, source: .desktop,
                         state: chat.approval != nil ? .waitingOnApproval : (chat.busy ? .active : .idle),
                         lastActivityAt: chat.since.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                         activeFlags: [], supportsRemoteReply: true)
        } : []
        lastSnapshot = AgentBackendSnapshot(
            backendID: .aura, displayName: displayName, sessions: sessions,
            wantsPowerAssertion: connected && fresh && chats.contains { $0.busy },
            pendingInterventions: pages.values.map(\.event).sorted { ($0.openedAt, $0.id) < ($1.openedAt, $1.id) })
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
