import XCTest
import Darwin
@testable import ClaudePowerMode

// MARK: - Protocol

final class AuraLinkProtocolTests: XCTestCase {
    private func decode(_ s: String) -> AuraLink.Message? { AuraLink.decode(line: Data(s.utf8)) }

    func testHelloStateFinishedAckDecode() {
        XCTAssertEqual(decode(#"{"t":"hello","proto":1,"app":"Page Aura","version":"0.2.1"}"#),
                       .hello(.init(proto: 1, app: "Page Aura", version: "0.2.1")))
        let state = decode(#"{"t":"state","chats":[{"id":"k3j9x","title":"Q","model":"m","busy":true,"since":1762160000000,"approval":null},{"id":"p0q1r","title":"T","model":"m","busy":false,"since":1,"approval":{"id":"a7f3c2d1","server":"Filesystem","tool":"move_file","args":"{}"}}]}"#)
        guard case .state(let chats)? = state else { return XCTFail("not a state: \(String(describing: state))") }
        XCTAssertEqual(chats.count, 2)
        XCTAssertTrue(chats[0].busy)
        XCTAssertEqual(chats[0].since, 1762160000000)
        XCTAssertNil(chats[0].approval)
        XCTAssertEqual(chats[1].approval, .init(id: "a7f3c2d1", server: "Filesystem", tool: "move_file", args: "{}"))
        XCTAssertEqual(decode(#"{"t":"finished","chatId":"k3j9x","title":"Q","ok":true,"stopped":false,"snippet":"done","at":5}"#),
                       .finished(.init(chatId: "k3j9x", title: "Q", ok: true, stopped: false, snippet: "done", at: 5)))
        XCTAssertEqual(decode(#"{"t":"ack","ref":"c1","ok":true,"detail":"Sent to Page Aura"}"#),
                       .ack(.init(ref: "c1", ok: true, detail: "Sent to Page Aura")))
    }

    func testUnknownTypeAndUnknownFieldsAreIgnored() {
        XCTAssertNil(decode(#"{"t":"future","x":1}"#))
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode(#"{"chats":[]}"#))
        XCTAssertEqual(decode(#"{"t":"ack","ref":"c1","ok":false,"detail":"no","extra":[1,2]}"#),
                       .ack(.init(ref: "c1", ok: false, detail: "no")))
    }

    func testIdsAreValidated() {
        XCTAssertTrue(AuraLink.isValidId("k3j9x_-A"))
        XCTAssertFalse(AuraLink.isValidId(""))
        XCTAssertFalse(AuraLink.isValidId("has space"))
        XCTAssertFalse(AuraLink.isValidId("a/b"))
        XCTAssertFalse(AuraLink.isValidId(String(repeating: "a", count: 65)))
        XCTAssertTrue(AuraLink.isValidId(String(repeating: "a", count: 64)))
        // A chat with a bad id is dropped; the rest of the state stands.
        guard case .state(let chats)? = decode(#"{"t":"state","chats":[{"id":"bad id","busy":true},{"id":"ok","busy":true},{"id":"ok","busy":false}]}"#)
        else { return XCTFail() }
        XCTAssertEqual(chats.map(\.id), ["ok"])
        XCTAssertNil(decode(#"{"t":"finished","chatId":"no way","at":1}"#))
        XCTAssertNil(decode(#"{"t":"ack","ref":"../x","ok":true}"#))
        // A bad approval id means no approval.
        guard case .state(let c2)? = decode(#"{"t":"state","chats":[{"id":"a","approval":{"id":"x y","server":"s","tool":"t","args":""}}]}"#)
        else { return XCTFail() }
        XCTAssertNil(c2[0].approval)
    }

    func testStringsAreClamped() {
        let long = String(repeating: "x", count: 5000)
        guard case .state(let chats)? = decode(#"{"t":"state","chats":[{"id":"a","title":"\#(long)","approval":{"id":"b","server":"\#(long)","tool":"\#(long)","args":"\#(long)"}}]}"#)
        else { return XCTFail() }
        XCTAssertEqual(chats[0].title.count, AuraLink.maxTitleLength)
        XCTAssertEqual(chats[0].approval?.args.count, AuraLink.maxArgsLength)
        XCTAssertEqual(chats[0].approval?.server.count, AuraLink.maxNameLength)
    }

    func testCommandsEncodeAsOneLine() throws {
        let send = AuraLink.encodeSend(id: "c1", chatId: "k3j9x", text: "hi \"there\"\nline two")
        XCTAssertEqual(send.last, 0x0A)
        XCTAssertEqual(send.filter { $0 == 0x0A }.count, 1, "newlines in the text are escaped")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: send) as? [String: String])
        XCTAssertEqual(obj, ["t": "send", "id": "c1", "chatId": "k3j9x", "text": "hi \"there\"\nline two"])
        let approve = try XCTUnwrap(JSONSerialization.jsonObject(with: AuraLink.encodeApprove(id: "c2", chatId: "p", approvalId: "a", decision: "once")) as? [String: String])
        XCTAssertEqual(approve, ["t": "approve", "id": "c2", "chatId": "p", "approvalId": "a", "decision": "once"])
        let stop = try XCTUnwrap(JSONSerialization.jsonObject(with: AuraLink.encodeStop(id: "c3", chatId: "k")) as? [String: String])
        XCTAssertEqual(stop, ["t": "stop", "id": "c3", "chatId": "k"])
        XCTAssertTrue(AuraLink.isValidId(AuraLink.newCommandId()))
        XCTAssertNotEqual(AuraLink.newCommandId(), AuraLink.newCommandId())
    }

    func testLineBuffer() {
        var b = AuraLineBuffer(maxLine: 10)
        XCTAssertEqual(b.append(Data("ab".utf8)), [])
        XCTAssertEqual(b.append(Data("c\nde\n\nf".utf8)).map { $0.map { String(decoding: $0, as: UTF8.self) } }, ["abc", "de"])
        XCTAssertEqual(b.append(Data("g\n".utf8)).map { $0.map { String(decoding: $0, as: UTF8.self) } }, ["fg"])
        XCTAssertNil(b.append(Data("0123456789A".utf8)), "an unterminated line over the cap")
        var c = AuraLineBuffer(maxLine: 4)
        XCTAssertNil(c.append(Data("toolong\n".utf8)), "a terminated line over the cap")
        var d = AuraLineBuffer(maxLine: 4)
        XCTAssertEqual(d.append(Data("abcd\n".utf8)).map(\.count), 1)
    }

    private func reply(_ action: String?, _ text: String = "") -> RelayReply {
        RelayReply(interventionId: "aura-x", text: text, action: action, sessionId: nil, cwd: nil, kind: nil, backend: "aura", source: nil)
    }

    func testReplyPlanForPermissionPages() {
        XCTAssertEqual(AuraLink.plan(kind: .permission, reply: reply("approve")), .approve("once"))
        XCTAssertEqual(AuraLink.plan(kind: .permission, reply: reply("deny")), .approve("deny"))
        XCTAssertEqual(AuraLink.plan(kind: .permission, reply: reply("custom", "yes please")), .failure("Page Aura tool requests take Allow or Deny"))
        XCTAssertEqual(AuraLink.plan(kind: .permission, reply: reply("carry_on")), .failure("Page Aura tool requests take Allow or Deny"))
        XCTAssertEqual(AuraLink.plan(kind: .permission, reply: reply(nil, "ok")), .failure("Page Aura tool requests take Allow or Deny"))
    }

    func testReplyPlanForIdlePages() {
        XCTAssertEqual(AuraLink.plan(kind: .idle, reply: reply("custom", "  tidy it up \n")), .send("tidy it up"))
        XCTAssertEqual(AuraLink.plan(kind: .idle, reply: reply(nil, "go on")), .send("go on"))
        XCTAssertEqual(AuraLink.plan(kind: .idle, reply: reply("carry_on")), .send("Carry on."))
        guard case .failure = AuraLink.plan(kind: .idle, reply: reply("approve")) else { return XCTFail() }
        guard case .failure = AuraLink.plan(kind: .idle, reply: reply("deny")) else { return XCTFail() }
        guard case .failure = AuraLink.plan(kind: .idle, reply: reply("custom", "   ")) else { return XCTFail() }
        guard case .failure = AuraLink.plan(kind: .idle, reply: reply("custom", String(repeating: "a", count: 8001))) else { return XCTFail() }
    }

    func testAuraRepliesRouteToAura() {
        func r(id: String, backend: String?) -> RelayReply {
            RelayReply(interventionId: id, text: "", action: nil, sessionId: nil, cwd: nil, kind: nil, backend: backend, source: nil)
        }
        XCTAssertEqual(r(id: "aura-k-idle-5", backend: nil).owningBackend, .aura)
        XCTAssertEqual(r(id: "aura-k-idle-5", backend: "aura").owningBackend, .aura)
        XCTAssertEqual(r(id: "codex-req-1", backend: nil).owningBackend, .codex)
        XCTAssertEqual(r(id: "abc-idle-1", backend: nil).owningBackend, .claude)
        XCTAssertEqual(AgentBackendID(rawValue: "aura"), .aura)
    }

    func testAuraIsNotLiveSessionCapable() {
        XCTAssertTrue(Coordinator.isLiveSessionCapable(.claude))
        XCTAssertTrue(Coordinator.isLiveSessionCapable(.codex))
        XCTAssertFalse(Coordinator.isLiveSessionCapable(.aura))
    }

    func testConfigDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(Config().auraBackendEnabled)
        var c = Config()
        c.auraBackendEnabled = false
        let data = try JSONEncoder().encode(c)
        XCTAssertFalse(try JSONDecoder().decode(Config.self, from: data).auraBackendEnabled)
        // An old config file without the key keeps the default.
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertTrue(old.auraBackendEnabled)
    }
}

// MARK: - Backend

private final class FakeTransport: AuraLinkTransport {
    var onConnect: (() -> Void)?
    var onLine: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    var started = 0
    var stopped = 0
    var sent: [Data] = []
    var accepts = true
    func start() -> Bool { started += 1; return true }
    func stop() { stopped += 1 }
    func send(_ line: Data) -> Bool { if accepts { sent.append(line) }; return accepts }

    func connect() { onConnect?() }
    func disconnect() { onDisconnect?() }
    func receive(_ json: String) { onLine?(Data(json.utf8)) }
    var lastCommand: [String: Any]? {
        sent.last.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

private final class RecordingRelay: RelaySink {
    private let lock = NSLock()
    private var _opened: [InterventionEvent] = []
    private var _closed: [(id: String, reason: String)] = []
    private var _injected: [(id: String, method: String, success: Bool, detail: String)] = []
    var isConnected = true
    var opened: [InterventionEvent] { lock.lock(); defer { lock.unlock() }; return _opened }
    var closed: [(id: String, reason: String)] { lock.lock(); defer { lock.unlock() }; return _closed }
    var injected: [(id: String, method: String, success: Bool, detail: String)] { lock.lock(); defer { lock.unlock() }; return _injected }
    func sendInterventionOpened(_ event: InterventionEvent) { lock.lock(); _opened.append(event); lock.unlock() }
    func sendInterventionClosed(id: String, reason: String) { lock.lock(); _closed.append((id, reason)); lock.unlock() }
    func sendReplyInjected(interventionId: String, method: String, success: Bool, detail: String, output: String?) {
        lock.lock(); _injected.append((interventionId, method, success, detail)); lock.unlock()
    }
}

final class AuraBackendTests: XCTestCase {
    private var transport: FakeTransport!
    private var relay: RecordingRelay!
    private var backend: AuraBackend!
    private var userAtMac = false
    private var finishedReplies: [ReplyFinished] = []
    private var clock = Date(timeIntervalSince1970: 1_762_160_000)

    override func setUp() {
        transport = FakeTransport()
        relay = RecordingRelay()
        finishedReplies = []
        userAtMac = false
        backend = AuraBackend(config: Config(), transport: transport, now: { [unowned self] in self.clock },
                              userAtMac: { [unowned self] _ in self.userAtMac })
        backend.relay = relay
        backend.onReplyFinished = { [unowned self] in self.finishedReplies.append($0) }
        backend.start()
        transport.connect()
    }

    private func state(_ chats: String) { transport.receive(#"{"t":"state","chats":[\#(chats)]}"#) }
    private func finish(_ chat: String, at: Int64, snippet: String = "hi", ok: Bool = true, stopped: Bool = false) {
        clock = Date(timeIntervalSince1970: Double(at) / 1000)
        transport.receive(#"{"t":"finished","chatId":"\#(chat)","title":"T","ok":\#(ok),"stopped":\#(stopped),"snippet":"\#(snippet)","at":\#(at)}"#)
    }
    /// Moves the clock to `seconds` after the turn ended (`at`, epoch ms) and ticks.
    private func due(_ at: Int64, after seconds: Double = 61) {
        clock = Date(timeIntervalSince1970: Double(at) / 1000 + seconds)
        backend.refresh()
    }
    private let busyChat = #"{"id":"k3j9x","title":"Quarterly numbers","model":"m","busy":true,"since":1762160000000,"approval":null}"#
    private let approvalChat = #"{"id":"p0q1r","title":"Tidy Downloads","model":"m","busy":false,"since":1762160100000,"approval":{"id":"a7f3c2d1","server":"Filesystem","tool":"move_file","args":"{\"to\":\"~/Documents/a.pdf\",\"api_key\":\"sk-abcdefghijklmnopqrstuvwx\"}"}}"#
    private let permId = "aura-p0q1r-perm-a7f3c2d1"

    private func reply(_ id: String, action: String?, text: String = "", source: String? = nil) -> RelayReply {
        RelayReply(interventionId: id, text: text, action: action, sessionId: nil, cwd: nil, kind: nil, backend: "aura", source: source)
    }

    func testStartsTheTransportOnlyWhenEnabled() {
        XCTAssertEqual(transport.started, 1)
        var off = Config()
        off.auraBackendEnabled = false
        let t = FakeTransport()
        let b = AuraBackend(config: off, transport: t)
        b.start()
        XCTAssertEqual(t.started, 0)
        b.reloadConfig(Config())
        XCTAssertEqual(t.started, 1)
        b.reloadConfig(off)
        XCTAssertEqual(t.stopped, 1)
    }

    func testBusyChatsAreSessionsAndKeepTheMacAwake() {
        XCTAssertFalse(backend.currentSnapshot.wantsPowerAssertion)
        state(busyChat + "," + approvalChat)
        let snap = backend.currentSnapshot
        XCTAssertEqual(snap.backendID, .aura)
        XCTAssertEqual(snap.displayName, "Page Aura")
        XCTAssertEqual(snap.sessions.count, 2)
        XCTAssertEqual(snap.sessions.first { $0.title == "Quarterly numbers" }?.state, .active)
        XCTAssertEqual(snap.sessions.first { $0.title == "Tidy Downloads" }?.state, .waitingOnApproval)
        XCTAssertEqual(snap.sessions.first?.source, .desktop)
        XCTAssertTrue(snap.wantsPowerAssertion)
        state(approvalChat) // no chat is busy
        XCTAssertFalse(backend.currentSnapshot.wantsPowerAssertion)
        state("")
        XCTAssertTrue(backend.currentSnapshot.sessions.isEmpty)
    }

    func testStaleHeartbeatReleasesTheAssertion() {
        state(busyChat)
        XCTAssertTrue(backend.currentSnapshot.wantsPowerAssertion)
        clock = clock.addingTimeInterval(AuraBackend.staleStateSeconds + 1)
        backend.refresh()
        XCTAssertFalse(backend.currentSnapshot.wantsPowerAssertion)
        state(busyChat)
        XCTAssertTrue(backend.currentSnapshot.wantsPowerAssertion)
    }

    func testApprovalOpensAPermissionPageAndClosesWhenItDisappears() {
        var callbacks: [InterventionEvent] = []
        backend.onNewIntervention = { callbacks.append($0) }
        state(approvalChat)
        state(approvalChat) // a heartbeat: no second page
        XCTAssertEqual(relay.opened.count, 1)
        let page = relay.opened[0]
        XCTAssertEqual(page.id, permId)
        XCTAssertEqual(page.kind, .permission)
        XCTAssertEqual(page.backend, .aura)
        XCTAssertEqual(page.source, .desktop)
        XCTAssertEqual(page.projectName, "Tidy Downloads")
        XCTAssertTrue(page.context.hasPrefix("Use Filesystem · move_file on this Mac\n"), page.context)
        XCTAssertFalse(page.context.contains("sk-abcdefghijklmnopqrstuvwx"), "secrets are redacted")
        XCTAssertEqual(callbacks.map(\.id), [permId])
        XCTAssertEqual(backend.openInterventionIds(), [permId])
        XCTAssertEqual(backend.currentSnapshot.pendingInterventions.map(\.id), [permId])

        state("") // answered at the Mac
        XCTAssertEqual(relay.closed.map(\.id), [permId])
        XCTAssertEqual(relay.closed.map(\.reason), ["user_resolved_in_terminal"])
        XCTAssertTrue(backend.openInterventionIds().isEmpty)
    }

    func testAllowFromThePhoneSendsApproveAndClosesOnAck() throws {
        state(approvalChat)
        backend.handleReply(reply(permId, action: "approve"))
        let cmd = try XCTUnwrap(transport.lastCommand)
        XCTAssertEqual(cmd["t"] as? String, "approve")
        XCTAssertEqual(cmd["chatId"] as? String, "p0q1r")
        XCTAssertEqual(cmd["approvalId"] as? String, "a7f3c2d1")
        XCTAssertEqual(cmd["decision"] as? String, "once")
        XCTAssertTrue(AuraLink.isValidId(try XCTUnwrap(cmd["id"] as? String)))
        XCTAssertTrue(relay.injected.isEmpty, "nothing is reported until the ack")

        // The approval vanishing from `state` before the ack must not close the page as "answered at the Mac".
        state("")
        XCTAssertTrue(relay.closed.isEmpty)

        transport.receive(#"{"t":"ack","ref":"\#(cmd["id"] as! String)","ok":true,"detail":"Sent to Page Aura"}"#)
        XCTAssertEqual(relay.injected.count, 1)
        XCTAssertEqual(relay.injected[0].method, "aura-link")
        XCTAssertTrue(relay.injected[0].success)
        XCTAssertEqual(relay.injected[0].detail, "Sent to Page Aura")
        XCTAssertEqual(relay.closed.map(\.reason), ["replied"])
        XCTAssertEqual(finishedReplies.map(\.success), [true])
        XCTAssertEqual(finishedReplies.first?.method, "aura-link")
        // A late state that still shows the approval doesn't reopen it.
        state(approvalChat)
        XCTAssertEqual(relay.opened.count, 1)
    }

    func testDenyAndRefusals() throws {
        state(approvalChat)
        backend.handleReply(reply(permId, action: "deny"))
        XCTAssertEqual(transport.lastCommand?["decision"] as? String, "deny")
        // Replying again while that one is in flight is ignored.
        let sentBefore = transport.sent.count
        backend.handleReply(reply(permId, action: "approve"))
        XCTAssertEqual(transport.sent.count, sentBefore)

        transport.receive(#"{"t":"ack","ref":"\#(transport.lastCommand!["id"] as! String)","ok":false,"detail":"That request was already answered"}"#)
        XCTAssertEqual(relay.injected.last?.success, false)
        XCTAssertEqual(relay.injected.last?.detail, "That request was already answered")
        XCTAssertTrue(relay.closed.isEmpty, "a failed reply leaves the page open")

        backend.handleReply(reply(permId, action: "custom", text: "sure"))
        XCTAssertEqual(relay.injected.last?.detail, "Page Aura tool requests take Allow or Deny")
        XCTAssertEqual(relay.injected.last?.success, false)
        XCTAssertEqual(transport.sent.count, sentBefore, "no command for a refused reply")

        backend.handleReply(reply("aura-nope-perm-x", action: "approve"))
        XCTAssertEqual(relay.injected.last?.success, false)
    }

    func testIdlePageAfterAGoodTurnWhileAway() throws {
        state(busyChat)
        transport.receive(#"{"t":"finished","chatId":"k3j9x","title":"Quarterly numbers","ok":true,"stopped":false,"snippet":"The totals are done. token=abcdef123456789","at":1762160300000}"#)
        due(1762160300000)
        XCTAssertEqual(relay.opened.count, 1)
        let page = relay.opened[0]
        XCTAssertEqual(page.id, "aura-k3j9x-idle-1762160300000")
        XCTAssertEqual(page.kind, .idle)
        XCTAssertTrue(page.context.hasPrefix("The totals are done."))
        XCTAssertFalse(page.context.contains("abcdef123456789"))

        // A duplicate does nothing.
        transport.receive(#"{"t":"finished","chatId":"k3j9x","title":"Quarterly numbers","ok":true,"stopped":false,"snippet":"x","at":1762160300000}"#)
        due(1762160300000)
        XCTAssertEqual(relay.opened.count, 1)

        // The stale state of the finished turn (since before `at`) doesn't close it.
        state(busyChat)
        XCTAssertTrue(relay.closed.isEmpty)
        // A new turn does.
        state(#"{"id":"k3j9x","title":"Quarterly numbers","busy":true,"since":1762160400000}"#)
        XCTAssertEqual(relay.closed.map(\.reason), ["session_resolved"])
    }

    func testNoIdlePageForStoppedOrFailedTurns() {
        finish("a", at: 1, ok: true, stopped: true)
        finish("a", at: 2, ok: false)
        due(2)
        XCTAssertTrue(relay.opened.isEmpty)
    }

    func testIdlePageWaitsForTheDelayThenOpensOnATick() {
        finish("a", at: 1_762_160_000_000, snippet: "done")
        due(1_762_160_000_000, after: 59)
        XCTAssertTrue(relay.opened.isEmpty)
        due(1_762_160_000_000, after: 60)
        XCTAssertEqual(relay.opened.map(\.id), ["aura-a-idle-1762160000000"])
        // Once only.
        due(1_762_160_000_000, after: 120)
        XCTAssertEqual(relay.opened.count, 1)
    }

    func testUserAtTheMacWhenItFinishedButAwayLaterStillGetsThePage() {
        userAtMac = true
        finish("a", at: 4)
        due(4)
        due(4, after: 600)
        XCTAssertTrue(relay.opened.isEmpty)
        userAtMac = false
        due(4, after: 660)
        XCTAssertEqual(relay.opened.map(\.id), ["aura-a-idle-4"])
        XCTAssertEqual(backend.openInterventionIds(), ["aura-a-idle-4"])
    }

    func testIdleCandidateIsDroppedWhenTheChatRestartsOrItGetsOld() {
        userAtMac = true
        // A new turn begun after the finished one drops it.
        finish("a", at: 1_762_160_000_000)
        state(#"{"id":"a","title":"T","busy":true,"since":1762160100000}"#)
        userAtMac = false
        due(1_762_160_000_000)
        XCTAssertTrue(relay.opened.isEmpty)
        // A candidate older than 4 h never pages.
        userAtMac = true
        finish("b", at: 5)
        due(5, after: 4 * 3600 + 1)
        userAtMac = false
        due(5, after: 4 * 3600 + 2)
        XCTAssertTrue(relay.opened.isEmpty)
        // Just inside the limit it still does.
        userAtMac = true
        finish("c", at: 7)
        due(7, after: 4 * 3600 - 5)
        userAtMac = false
        due(7, after: 4 * 3600)
        XCTAssertEqual(relay.opened.map(\.id), ["aura-c-idle-7"])
    }

    func testANewerFinishedReplacesThePendingCandidate() {
        userAtMac = true
        finish("a", at: 10_000, snippet: "one")
        finish("a", at: 20_000, snippet: "two")
        finish("a", at: 15_000, snippet: "older")
        userAtMac = false
        due(20_000)
        XCTAssertEqual(relay.opened.map(\.id), ["aura-a-idle-20000"])
        XCTAssertEqual(relay.opened.first?.context, "two")
    }

    func testDisconnectDropsIdleCandidates() {
        userAtMac = true
        finish("a", at: 10_000)
        transport.disconnect()
        transport.connect()
        userAtMac = false
        due(10_000)
        XCTAssertTrue(relay.opened.isEmpty)
    }

    func testANewerIdlePageReplacesTheOlderOne() {
        finish("a", at: 10, snippet: "one")
        due(10)
        finish("a", at: 20, snippet: "two")
        due(20)
        XCTAssertEqual(relay.opened.map(\.id), ["aura-a-idle-10", "aura-a-idle-20"])
        XCTAssertEqual(relay.closed.map(\.id), ["aura-a-idle-10"])
        XCTAssertEqual(relay.closed.map(\.reason), ["session_resolved"])
        XCTAssertEqual(backend.openInterventionIds(), ["aura-a-idle-20"])
    }

    func testIdleReplySendsTheMessageAndCarryOn() throws {
        finish("a", at: 10, snippet: "one")
        due(10)
        backend.handleReply(reply("aura-a-idle-10", action: "custom", text: "now tidy it"))
        let cmd = try XCTUnwrap(transport.lastCommand)
        XCTAssertEqual(cmd["t"] as? String, "send")
        XCTAssertEqual(cmd["chatId"] as? String, "a")
        XCTAssertEqual(cmd["text"] as? String, "now tidy it")
        transport.receive(#"{"t":"ack","ref":"\#(cmd["id"] as! String)","ok":true,"detail":"Sent to Page Aura"}"#)
        XCTAssertEqual(relay.closed.map(\.reason), ["replied"])

        finish("a", at: 30, snippet: "two")
        due(30)
        backend.handleReply(reply("aura-a-idle-30", action: "carry_on"))
        XCTAssertEqual(transport.lastCommand?["text"] as? String, "Carry on.")
        transport.receive(#"{"t":"ack","ref":"\#(transport.lastCommand!["id"] as! String)","ok":false,"detail":"Page Aura is still working in that chat"}"#)
        XCTAssertEqual(relay.injected.last?.detail, "Page Aura is still working in that chat")
        backend.handleReply(reply("aura-a-idle-30", action: "approve"))
        XCTAssertEqual(relay.injected.last?.detail, AuraLink.chatRepliesDetail)
    }

    func testMacOriginReplyIsNotReportedToThePhone() throws {
        finish("a", at: 10, snippet: "one")
        due(10)
        backend.handleReply(reply("aura-a-idle-10", action: "custom", text: "go", source: "mac"))
        transport.receive(#"{"t":"ack","ref":"\#(transport.lastCommand!["id"] as! String)","ok":true,"detail":"Sent to Page Aura"}"#)
        XCTAssertTrue(relay.injected.isEmpty)
        XCTAssertEqual(finishedReplies.map(\.success), [true])
        XCTAssertEqual(relay.closed.map(\.reason), ["session_resolved"])
    }

    func testDisconnectClosesEverythingStale() {
        state(busyChat + "," + approvalChat)
        finish("a", at: 10, snippet: "one")
        due(10)
        XCTAssertEqual(Set(backend.openInterventionIds()), [permId, "aura-a-idle-10"])
        backend.handleReply(reply(permId, action: "approve"))
        transport.disconnect()
        XCTAssertEqual(Set(relay.closed.map(\.id)), [permId, "aura-a-idle-10"])
        XCTAssertEqual(Set(relay.closed.map(\.reason)), ["stale"])
        XCTAssertTrue(backend.openInterventionIds().isEmpty)
        let snap = backend.currentSnapshot
        XCTAssertTrue(snap.sessions.isEmpty)
        XCTAssertFalse(snap.wantsPowerAssertion)
        XCTAssertTrue(snap.pendingInterventions.isEmpty)
        // The reply in flight failed rather than hanging.
        XCTAssertEqual(relay.injected.last?.success, false)

        backend.handleReply(reply(permId, action: "approve"))
        XCTAssertEqual(relay.injected.last?.detail, "Page Aura isn't open on your Mac")
        XCTAssertFalse(backend.isConnected)
    }

    func testAClientThatCannotBeWrittenToFailsTheReply() {
        state(approvalChat)
        transport.accepts = false
        backend.handleReply(reply(permId, action: "approve"))
        XCTAssertEqual(relay.injected.last?.success, false)
        XCTAssertEqual(relay.injected.last?.detail, "Page Aura isn't open on your Mac")
        XCTAssertEqual(backend.openInterventionIds(), [permId])
    }

    func testSwitchingOffClosesPagesAndStopsTheTransport() {
        state(approvalChat)
        var off = Config()
        off.auraBackendEnabled = false
        backend.reloadConfig(off)
        XCTAssertEqual(transport.stopped, 1)
        XCTAssertEqual(relay.closed.map(\.reason), ["stale"])
    }
}

// MARK: - Socket

final class AuraLinkServerTests: XCTestCase {
    private var dir: String!
    private var path: String { dir + "/aura.sock" }

    override func setUp() {
        dir = "/tmp/aura-\(getpid())-\(UInt32.random(in: 0..<1_000_000))"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func connectClient() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(rc, 0, "connect errno \(errno)")
        return fd
    }

    private func write(_ fd: Int32, _ s: String) {
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            off += n
        }
    }

    private func readLine(_ fd: Int32, timeout: TimeInterval = 3) -> String? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var out = Data()
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if poll(&pfd, 1, 100) > 0 {
                var b: UInt8 = 0
                let n = read(fd, &b, 1)
                if n <= 0 { return nil }
                if b == 0x0A { return String(decoding: out, as: UTF8.self) }
                out.append(b)
            }
        }
        return nil
    }

    private func waitUntil(_ what: String, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while Date() < end && !cond() { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(cond(), what)
    }

    func testServerLifecycleAndLines() {
        let server = AuraLinkServer(path: path)
        let lock = NSLock()
        var lines: [String] = []
        var connects = 0
        var disconnects = 0
        server.onConnect = { lock.lock(); connects += 1; lock.unlock() }
        server.onLine = { lock.lock(); lines.append(String(decoding: $0, as: UTF8.self)); lock.unlock() }
        server.onDisconnect = { lock.lock(); disconnects += 1; lock.unlock() }
        func snapshot() -> ([String], Int, Int) { lock.lock(); defer { lock.unlock() }; return (lines, connects, disconnects) }

        XCTAssertFalse(server.send(Data("x\n".utf8)), "no client yet")
        XCTAssertTrue(server.start())
        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertTrue(server.start(), "starting twice is a no-op")

        let a = connectClient()
        waitUntil("connected") { snapshot().1 == 1 }
        write(a, #"{"t":"hello","proto":1}"# + "\n" + #"{"t":"sta"#)
        write(a, #"te","chats":[]}"# + "\n")
        waitUntil("two lines, one split across writes") { snapshot().0.count == 2 }
        XCTAssertEqual(snapshot().0, [#"{"t":"hello","proto":1}"#, #"{"t":"state","chats":[]}"#])

        XCTAssertTrue(server.send(Data("{\"t\":\"stop\"}\n".utf8)))
        XCTAssertEqual(readLine(a), #"{"t":"stop"}"#)

        // A new client replaces the old one.
        let b = connectClient()
        waitUntil("replaced") { snapshot().1 == 2 && snapshot().2 == 1 }
        XCTAssertNil(readLine(a, timeout: 1), "the old client sees EOF")
        Darwin.close(a)
        XCTAssertTrue(server.send(Data("{\"t\":\"send\"}\n".utf8)))
        XCTAssertEqual(readLine(b), #"{"t":"send"}"#)

        // The client closing is reported.
        Darwin.close(b)
        waitUntil("client closed") { snapshot().2 == 2 }
        XCTAssertFalse(server.send(Data("x\n".utf8)))

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the socket file is removed")
        XCTAssertEqual(snapshot().2, 2, "stop() is not reported as a disconnect")
    }

    func testOversizedLineClosesTheConnection() {
        let server = AuraLinkServer(path: path)
        let lock = NSLock()
        var disconnected = false
        var lines = 0
        server.onLine = { _ in lock.lock(); lines += 1; lock.unlock() }
        server.onDisconnect = { lock.lock(); disconnected = true; lock.unlock() }
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let fd = connectClient()
        defer { Darwin.close(fd) }
        write(fd, String(repeating: "a", count: AuraLink.maxLineBytes + 10))
        waitUntil("closed") { lock.lock(); defer { lock.unlock() }; return disconnected }
        XCTAssertEqual(lines, 0)
    }

    func testStaleSocketFileIsReplaced() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let server = AuraLinkServer(path: path)
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let fd = connectClient()
        Darwin.close(fd)
    }

    func testTooLongPathDoesNotStart() {
        let server = AuraLinkServer(path: "/tmp/" + String(repeating: "a", count: 120) + ".sock")
        XCTAssertFalse(server.start())
    }

    func testBackendOverARealSocket() {
        let backend = AuraBackend(config: Config(), transport: AuraLinkServer(path: path), userAtMac: { _ in false })
        let relay = RecordingRelay()
        backend.relay = relay
        backend.start()
        defer { backend.shutdown() }
        let fd = connectClient()
        defer { Darwin.close(fd) }
        write(fd, #"{"t":"hello","proto":1,"app":"Page Aura","version":"1"}"# + "\n")
        write(fd, #"{"t":"state","chats":[{"id":"c1","title":"T","busy":false,"since":1,"approval":{"id":"ap1","server":"S","tool":"t","args":"{}"}}]}"# + "\n")
        waitUntil("the page opens") { relay.opened.count == 1 }
        backend.handleReply(RelayReply(interventionId: "aura-c1-perm-ap1", text: "", action: "approve", sessionId: nil, cwd: nil,
                                       kind: "permission", backend: "aura", source: nil))
        guard let line = readLine(fd), let cmd = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return XCTFail("no command")
        }
        XCTAssertEqual(cmd["t"] as? String, "approve")
        write(fd, #"{"t":"ack","ref":"\#(cmd["id"] as! String)","ok":true,"detail":"Sent to Page Aura"}"# + "\n")
        waitUntil("replied") { relay.closed.map(\.reason) == ["replied"] }
        XCTAssertEqual(relay.injected.first?.method, "aura-link")
    }
}
