import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import PageCore

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

    func testAuraIsLiveSessionCapable() {
        XCTAssertTrue(Coordinator.isLiveSessionCapable(.claude))
        XCTAssertTrue(Coordinator.isLiveSessionCapable(.codex))
        XCTAssertTrue(Coordinator.isLiveSessionCapable(.aura))
    }

    // MARK: proto 2 frames

    func testChatsFrameDecodesAndClamps() {
        let long = String(repeating: "p", count: 400)
        let frame = #"{"t":"chats","chats":[{"id":"k3j9x","title":"Quarterly numbers","model":"claude-opus-5-5","updatedAt":1762160300000,"busy":false,"approval":null,"preview":"\#(long)"},{"id":"bad id","title":"x"},{"id":"k3j9x","title":"dup"},{"id":"p0q1r","busy":true,"approval":{"id":"a1","server":"S","tool":"t","args":"{}"}}]}"#
        guard case .chats(let chats)? = decode(frame) else { return XCTFail("not chats") }
        XCTAssertEqual(chats.map(\.id), ["k3j9x", "p0q1r"], "bad ids and duplicates are dropped")
        XCTAssertEqual(chats[0].title, "Quarterly numbers")
        XCTAssertEqual(chats[0].updatedAt, 1762160300000)
        XCTAssertEqual(chats[0].preview.count, AuraLink.maxPreviewLength)
        XCTAssertEqual(chats[1].approval?.id, "a1")
        XCTAssertTrue(chats[1].busy)
        XCTAssertNil(decode(#"{"t":"chats"}"#))
        let many = (0..<300).map { #"{"id":"c\#($0)"}"# }.joined(separator: ",")
        guard case .chats(let capped)? = decode(#"{"t":"chats","chats":[\#(many)]}"#) else { return XCTFail() }
        XCTAssertEqual(capped.count, AuraLink.maxRemoteChats)
    }

    func testTranscriptFrameDecodesAndClamps() {
        let long = String(repeating: "t", count: 9000)
        let frame = #"{"t":"transcript","chatId":"k3j9x","truncated":true,"entries":[{"id":"m12","role":"user","text":"hi","at":1762160000000},{"id":"m13","role":"assistant","text":"\#(long)","at":1762160200000,"tool":"ignored"},{"id":"m13-t0","role":"tool","text":"Web search: x","tool":"web_search","at":1762160100000},{"id":"m14","role":"system","text":"nope"},{"role":"user","text":"no id"},{"id":"m15","role":"thinking","text":"never"}]}"#
        guard case .transcript(let t)? = decode(frame) else { return XCTFail("not a transcript") }
        XCTAssertEqual(t.chatId, "k3j9x")
        XCTAssertTrue(t.truncated)
        XCTAssertEqual(t.entries.map(\.id), ["m12", "m13", "m13-t0"], "unknown roles and entries without an id are dropped")
        XCTAssertEqual(t.entries[1].text.count, AuraLink.maxEntryTextLength)
        XCTAssertNil(t.entries[1].tool, "only tool entries carry a tool name")
        XCTAssertEqual(t.entries[2].tool, "web_search")
        XCTAssertEqual(t.entries[0].at, 1762160000000)
        XCTAssertNil(decode(#"{"t":"transcript","chatId":"bad id","entries":[]}"#))
        XCTAssertNil(decode(#"{"t":"transcript","chatId":"k","entries":"x"}"#))
        // Only the last 40 are kept, and the snapshot says older ones exist.
        let entries = (0..<60).map { #"{"id":"m\#($0)","role":"user","text":"x"}"# }.joined(separator: ",")
        guard case .transcript(let big)? = decode(#"{"t":"transcript","chatId":"k","entries":[\#(entries)]}"#) else { return XCTFail() }
        XCTAssertEqual(big.entries.count, 40)
        XCTAssertEqual(big.entries.first?.id, "m20")
        XCTAssertTrue(big.truncated)
    }

    func testTranscriptMapsToThePhonesRows() {
        let t = AuraLink.Transcript(chatId: "k", truncated: false, entries: [
            .init(id: "m1", role: .user, text: "key sk-abcdefghijklmnopqrstuvwx", tool: nil, at: 1762160000000),
            .init(id: "m2", role: .assistant, text: String(repeating: "a", count: 3000), tool: nil, at: nil),
            .init(id: "m2-t0", role: .tool, text: "Used Filesystem · read_file", tool: "read_file", at: 1762160100000)
        ])
        let snap = AuraLink.snapshot(t)
        XCTAssertEqual(snap.entries.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(snap.entries.map(\.id), ["m1", "m2", "m2-t0"])
        XCTAssertFalse(snap.entries[0].text.contains("sk-abcdefghijklmnopqrstuvwx"), "redacted")
        XCTAssertLessThanOrEqual(snap.entries[1].text.count, SessionTranscript.maxEntryChars)
        XCTAssertEqual(snap.entries[2].tool, "read_file")
        XCTAssertEqual(snap.entries[0].jsonObject["at"] as? String, "2025-11-03T08:53:20Z")
        XCTAssertNil(snap.entries[1].jsonObject["at"])
    }

    func testWatchEncodesSorted() throws {
        let line = AuraLink.encodeWatch(list: true, chatIds: ["b", "a"])
        XCTAssertEqual(line.last, 0x0A)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(obj["t"] as? String, "watch")
        XCTAssertEqual(obj["list"] as? Bool, true)
        XCTAssertEqual(obj["chatIds"] as? [String], ["a", "b"])
        XCTAssertEqual(AuraLink.chatId(sessionId: "aura-k3j9x"), "k3j9x")
        XCTAssertNil(AuraLink.chatId(sessionId: "aura-bad id"))
        XCTAssertNil(AuraLink.chatId(sessionId: "claude-k3j9x"))
        XCTAssertNil(AuraLink.chatId(sessionId: "aura-"))
    }

    func testPreviewIsOneRedactedLine() {
        XCTAssertEqual(AuraLink.previewLine("first\nsecond line  "), "second line")
        XCTAssertNil(AuraLink.previewLine(""))
        XCTAssertNil(AuraLink.previewLine("\n\n"))
        XCTAssertFalse((AuraLink.previewLine("token sk-abcdefghijklmnopqrstuvwx") ?? "").contains("sk-abcdefghijklmnopqrstuvwx"))
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
        XCTAssertTrue(page.context.hasPrefix("Use Filesystem · move_file on this computer\n"), page.context)
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
        XCTAssertEqual(relay.injected.last?.detail, "Page Aura isn't open on your computer")
        XCTAssertFalse(backend.isConnected)
    }

    func testAClientThatCannotBeWrittenToFailsTheReply() {
        state(approvalChat)
        transport.accepts = false
        backend.handleReply(reply(permId, action: "approve"))
        XCTAssertEqual(relay.injected.last?.success, false)
        XCTAssertEqual(relay.injected.last?.detail, "Page Aura isn't open on your computer")
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
        let fd = LocalSocket.makeStream()
        let rc = LocalSocket.withAddress(path) { connect(fd, $0, $1) } ?? -1
        XCTAssertEqual(rc, 0, "connect errno \(errno)")
        return fd
    }

    private func write(_ fd: Int32, _ s: String) {
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { LocalSocket.write(fd, $0.baseAddress, $0.count) }
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
        LocalSocket.close(a)
        XCTAssertTrue(server.send(Data("{\"t\":\"send\"}\n".utf8)))
        XCTAssertEqual(readLine(b), #"{"t":"send"}"#)

        // The client closing is reported.
        LocalSocket.close(b)
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
        defer { LocalSocket.close(fd) }
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
        LocalSocket.close(fd)
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
        defer { LocalSocket.close(fd) }
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

// MARK: - Sessions tab (proto 2)

private final class SessionsSink: SessionsUpdateSink {
    private let lock = NSLock()
    private var _sent: [SessionEnvelope] = []
    var isConnected = true
    var sent: [SessionEnvelope] { lock.lock(); defer { lock.unlock() }; return _sent }
    func sendSessionsUpdate(_ envelope: SessionEnvelope) { lock.lock(); _sent.append(envelope); lock.unlock() }
}

private final class MutableClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Page Aura chats through the real `AuraBackend` (fake socket), `LiveSessionBackends`
/// and `SessionRemote`, with the phone's encrypted frames decoded.
final class AuraSessionsTests: XCTestCase {
    private let root = Data((0...31).map { UInt8($0 &* 7) })
    private lazy var keys = SessionKeys(root: root)!
    private let t0 = Date(timeIntervalSince1970: 1_762_160_400)

    private var clock: MutableClock!
    private var transport: FakeTransport!
    private var backend: AuraBackend!
    private var sink: SessionsSink!
    private var remote: SessionRemote!

    override func setUp() {
        clock = MutableClock(t0)
        transport = FakeTransport()
        let c = clock!
        backend = AuraBackend(config: Config(), transport: transport, now: { c.now }, userAtMac: { _ in false })
        let live = LiveSessionBackends(claude: ClaudeBackend(config: Config()), codex: CodexBackend(config: Config()), aura: backend)
        sink = SessionsSink()
        remote = SessionRemote(backends: live, now: { c.now }, autoTimer: false, macName: { "Test Mac" })
        // What the Coordinator does: the backend's change goes to the phone's list.
        backend.onRemoteChange = { [unowned self] in
            let snap = self.backend.remoteSnapshot
            self.remote.update(sessions: snap.sessions, pending: snap.pendingInterventions)
        }
        remote.attach(sink: sink, rootKey: root)
        backend.start()
        transport.connect()
    }

    override func tearDown() {
        remote?.stop()
        remote?.waitUntilIdle()
        backend?.shutdown()
    }

    // MARK: helpers

    private let idleChat = #"{"id":"k3j9x","title":"Quarterly numbers","model":"claude-opus-5-5","updatedAt":1762160300000,"busy":false,"approval":null,"preview":"Here is the summary\nTotals look right."}"#
    private let busyChat = #"{"id":"b2","title":"Long refactor","model":"m","updatedAt":1762160390000,"busy":true,"approval":null,"preview":"Working…"}"#
    private let askChat = #"{"id":"p0q1r","title":"Tidy Downloads","model":"m","updatedAt":1762160200000,"busy":false,"approval":{"id":"a7f3c2d1","server":"Filesystem","tool":"move_file","args":"{}"},"preview":""}"#

    private let askState = #"{"id":"p0q1r","title":"Tidy Downloads","model":"m","busy":false,"since":1762160100000,"approval":{"id":"a7f3c2d1","server":"Filesystem","tool":"move_file","args":"{}"}}"#

    private func hello(proto: Int = 2) { transport.receive(#"{"t":"hello","proto":\#(proto),"app":"Page Aura","version":"0.3.0"}"#) }
    private func chats(_ list: String) { transport.receive(#"{"t":"chats","chats":[\#(list)]}"#); remote.waitUntilIdle() }
    private func lookingPhone() { remote.setPhones(1, from: sink); remote.waitUntilIdle() }

    private func decoded(_ e: SessionEnvelope) -> [String: Any]? {
        SessionCrypto.open(e, key: keys.macToPhone, aad: SessionCrypto.updateAAD)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    private var frames: [[String: Any]] { sink.sent.compactMap(decoded) }
    private func frames(_ kind: String) -> [[String: Any]] { frames.filter { $0["kind"] as? String == kind } }
    private var rows: [[String: Any]] { (frames("list").last?["sessions"] as? [[String: Any]]) ?? [] }
    private func row(_ id: String) -> [String: Any]? { rows.first { $0["id"] as? String == id } }

    private func command(_ fields: [String: Any]) -> SessionEnvelope {
        var obj = fields
        if obj["ts"] == nil { obj["ts"] = clock.now.timeIntervalSince1970 * 1000 }
        if obj["clientId"] == nil { obj["clientId"] = UUID().uuidString }
        if obj["viewer"] == nil { obj["viewer"] = "v1" }
        return SessionCrypto.seal(try! JSONSerialization.data(withJSONObject: obj), key: keys.phoneToMac, aad: SessionCrypto.commandAAD)!
    }
    private func send(_ fields: [String: Any]) {
        remote.handleCommand(command(fields))
        remote.waitUntilIdle()
    }
    private func advance(_ s: TimeInterval) { clock.now = clock.now.addingTimeInterval(s); remote.step() }

    /// Every line Page sent to Page Aura, decoded.
    private var commands: [[String: Any]] {
        transport.sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    private func commands(_ t: String) -> [[String: Any]] { commands.filter { $0["t"] as? String == t } }
    private var lastResult: [String: Any]? { frames("result").last }

    /// A proto-2 peer, a phone looking and a list of chats shown.
    private func showChats(_ list: String? = nil) {
        hello()
        lookingPhone()
        chats(list ?? [idleChat, busyChat, askChat].joined(separator: ","))
        advance(1.1)
    }

    // MARK: watch

    func testWatchGoesOnlyToAProto2Peer() {
        hello(proto: 1)
        lookingPhone()
        XCTAssertTrue(commands("watch").isEmpty, "a proto-1 peer is never sent a watch")
        send(["op": "watch", "sessionId": "aura-k3j9x"])
        XCTAssertTrue(commands("watch").isEmpty)
        remote.setPhones(0, from: sink)
        remote.waitUntilIdle()
        XCTAssertTrue(commands("watch").isEmpty)
        XCTAssertTrue(backend.remoteSnapshot.sessions.isEmpty)
    }

    func testWatchTracksPhonesAndTheWatchSet() {
        transport.sent = []
        lookingPhone()
        XCTAssertTrue(commands("watch").isEmpty, "no hello yet: Page Aura isn't known to speak proto 2")
        hello()
        XCTAssertEqual(commands("watch").count, 1, "sent as soon as the hello says proto 2")
        XCTAssertEqual(commands("watch").last?["list"] as? Bool, true)
        XCTAssertEqual(commands("watch").last?["chatIds"] as? [String], [])

        send(["op": "watch", "sessionId": "aura-k3j9x", "viewer": "v1"])
        XCTAssertEqual(commands("watch").last?["chatIds"] as? [String], ["k3j9x"])
        let count = commands("watch").count
        send(["op": "watch", "sessionId": "aura-k3j9x", "viewer": "v1"])   // the phone's 30 s re-send
        XCTAssertEqual(commands("watch").count, count, "no change, no frame")
        send(["op": "watch", "sessionId": "aura-p0q1r", "viewer": "v2"])
        XCTAssertEqual(commands("watch").last?["chatIds"] as? [String], ["k3j9x", "p0q1r"])
        // A Claude session is not a Page Aura chat.
        send(["op": "watch", "sessionId": "9f1c0000-0000-0000-0000-000000000000", "viewer": "v3"])
        XCTAssertEqual(commands("watch").last?["chatIds"] as? [String], ["k3j9x", "p0q1r"])
        // Leaving the screen, and the TTL.
        send(["op": "watch", "sessionId": NSNull(), "viewer": "v2"])
        XCTAssertEqual(commands("watch").last?["chatIds"] as? [String], ["k3j9x"])
        advance(SessionWatchers.ttl + 1)
        XCTAssertEqual(commands("watch").last?["list"] as? Bool, true)
        XCTAssertEqual(commands("watch").last?["chatIds"] as? [String], [])

        remote.setPhones(0, from: sink)
        remote.waitUntilIdle()
        XCTAssertEqual(commands("watch").last?["list"] as? Bool, false)
        XCTAssertEqual(commands("watch").last?["chatIds"] as? [String], [])
    }

    func testWatchIsResentAfterAReconnect() {
        hello()
        lookingPhone()
        send(["op": "watch", "sessionId": "aura-k3j9x"])
        transport.disconnect()
        transport.sent = []
        transport.connect()
        XCTAssertTrue(commands("watch").isEmpty, "nothing before the hello")
        hello()
        XCTAssertEqual(commands("watch").last?["list"] as? Bool, true)
        XCTAssertEqual(commands("watch").last?["chatIds"] as? [String], ["k3j9x"], "Page Aura assumes list:false on connect")
    }

    func testLiveSessionsOffSendsNoListWatch() {
        hello()
        remote.setEnabled(false)
        lookingPhone()
        XCTAssertTrue(commands("watch").isEmpty, "off → list:false is the default, nothing to say")
    }

    // MARK: list rows

    func testChatsFromAProto1PeerAndUnsolicitedChatsAreIgnored() {
        hello(proto: 1)
        lookingPhone()
        chats(idleChat)
        XCTAssertTrue(backend.remoteSnapshot.sessions.isEmpty)
        transport.disconnect(); transport.connect(); hello()
        chats(idleChat)   // no phone looking → list:false → Page Aura shouldn't send this
        remote.setPhones(0, from: sink)
        remote.waitUntilIdle()
        chats(idleChat)
        XCTAssertTrue(backend.remoteSnapshot.sessions.isEmpty, "a chats frame while list is off is ignored")
    }

    func testRowsFollowTheSpec() throws {
        showChats()
        XCTAssertEqual(rows.count, 3)
        let idle = try XCTUnwrap(row("aura-k3j9x"))
        XCTAssertEqual(idle["backend"] as? String, "aura")
        XCTAssertEqual(idle["title"] as? String, "Quarterly numbers")
        XCTAssertEqual(idle["host"] as? String, "Page Aura")
        XCTAssertEqual(idle["provider"] as? String, "anthropic")
        XCTAssertNil(idle["cwd"], "a chat has no folder")
        XCTAssertEqual(idle["state"] as? String, "idle")
        XCTAssertEqual(idle["canType"] as? Bool, true)
        XCTAssertNil(idle["typeBlocker"])
        XCTAssertEqual(idle["canInterrupt"] as? Bool, false)
        XCTAssertEqual(idle["preview"] as? String, "Totals look right.")
        XCTAssertEqual(idle["lastActivityAt"] as? String, SessionTranscript.isoFormatter.string(from: Date(timeIntervalSince1970: 1_762_160_300)))
        XCTAssertNil(idle["attach"], "no photos")
        XCTAssertEqual(idle["attachBlocker"] as? String, "Page Studio can't send photos to Page Aura yet")
        XCTAssertNil(idle["ask"])
        XCTAssertNil(idle["canHold"])
        XCTAssertNil(idle["held"])

        let busy = try XCTUnwrap(row("aura-b2"))
        XCTAssertEqual(busy["state"] as? String, "active")
        XCTAssertEqual(busy["canType"] as? Bool, false)
        XCTAssertEqual(busy["typeBlocker"] as? String, "Page Aura is still replying")
        XCTAssertEqual(busy["canInterrupt"] as? Bool, true)
        XCTAssertNil(busy["attachBlocker"], "the typeBlocker already says why")

        // The approval page is open once Page Aura's `state` carries it.
        transport.receive(#"{"t":"state","chats":[\#(askState)]}"#)
        remote.waitUntilIdle()
        advance(1.1)
        let waiting = try XCTUnwrap(row("aura-p0q1r"))
        XCTAssertEqual(waiting["state"] as? String, "waitingOnApproval")
        XCTAssertEqual(waiting["canType"] as? Bool, false)
        XCTAssertEqual(waiting["typeBlocker"] as? String, "Page Aura is still replying")
        XCTAssertEqual(waiting["canInterrupt"] as? Bool, false)
        XCTAssertEqual(waiting["interventionId"] as? String, "aura-p0q1r-perm-a7f3c2d1")
        // Needs-you first.
        XCTAssertEqual(rows.first?["id"] as? String, "aura-p0q1r")
    }

    func testStateFrameRefreshesBusyBetweenChatsFrames() throws {
        showChats(idleChat)
        XCTAssertEqual(row("aura-k3j9x")?["state"] as? String, "idle")
        transport.receive(#"{"t":"state","chats":[{"id":"k3j9x","title":"Quarterly numbers","model":"m","busy":true,"since":1762160390000,"approval":null}]}"#)
        remote.waitUntilIdle()
        advance(1.1)
        XCTAssertEqual(row("aura-k3j9x")?["state"] as? String, "active", "the fresher frame decides")
        transport.receive(#"{"t":"state","chats":[]}"#)
        remote.waitUntilIdle()
        advance(1.1)
        XCTAssertEqual(row("aura-k3j9x")?["state"] as? String, "idle")
    }

    func testUntitledChatAndDisconnect() {
        showChats(#"{"id":"c1","title":"","updatedAt":1762160300000,"busy":false,"preview":""}"#)
        XCTAssertEqual(row("aura-c1")?["title"] as? String, "Untitled chat")
        XCTAssertNil(row("aura-c1")?["preview"])
        transport.disconnect()
        remote.waitUntilIdle()
        advance(1.1)
        XCTAssertTrue(rows.isEmpty, "Page Aura closing takes its chats off the phone")
    }

    // MARK: transcript

    func testTranscriptForAWatchedChatIsMappedAndSent() throws {
        showChats()
        send(["op": "watch", "sessionId": "aura-k3j9x"])
        XCTAssertTrue(frames("transcript").isEmpty, "nothing to send until Page Aura sends one")
        transport.receive(#"{"t":"transcript","chatId":"k3j9x","truncated":true,"entries":[{"id":"m12","role":"user","text":"Totals?","at":1762160000000},{"id":"m13","role":"assistant","text":"All good. key sk-abcdefghijklmnopqrstuvwx","at":1762160200000},{"id":"m13-t0","role":"tool","text":"Used Filesystem · read_file","tool":"read_file","at":1762160100000}]}"#)
        advance(1.6)
        let t = try XCTUnwrap(frames("transcript").last)
        XCTAssertEqual(t["sessionId"] as? String, "aura-k3j9x")
        XCTAssertEqual(t["truncated"] as? Bool, true)
        let entries = try XCTUnwrap(t["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["id"] as? String }, ["m12", "m13", "m13-t0"])
        XCTAssertEqual(entries.map { $0["role"] as? String }, ["user", "assistant", "tool"])
        XCTAssertEqual(entries[2]["tool"] as? String, "read_file")
        XCTAssertFalse((entries[1]["text"] as? String ?? "").contains("sk-abcdefghijklmnopqrstuvwx"))
        XCTAssertEqual(entries[0]["at"] as? String, SessionTranscript.isoFormatter.string(from: Date(timeIntervalSince1970: 1_762_160_000)))

        // Unchanged: not re-sent. Changed: sent again, but not faster than every 1.5 s.
        let count = frames("transcript").count
        advance(2)
        XCTAssertEqual(frames("transcript").count, count)
        transport.receive(#"{"t":"transcript","chatId":"k3j9x","entries":[{"id":"m12","role":"user","text":"Totals?"},{"id":"m14","role":"assistant","text":"More"}]}"#)
        advance(1.6)
        XCTAssertEqual(frames("transcript").count, count + 1)
        XCTAssertEqual((frames("transcript").last?["entries"] as? [[String: Any]])?.last?["text"] as? String, "More")
    }

    func testTranscriptOfAnUnwatchedChatIsIgnored() {
        showChats()
        transport.receive(#"{"t":"transcript","chatId":"k3j9x","entries":[{"id":"m1","role":"user","text":"hi"}]}"#)
        XCTAssertNil(backend.remoteTranscript(sessionId: "aura-k3j9x"), "Page Aura wasn't asked for it")
        send(["op": "watch", "sessionId": "aura-k3j9x"])
        transport.receive(#"{"t":"transcript","chatId":"k3j9x","entries":[{"id":"m1","role":"user","text":"hi"}]}"#)
        XCTAssertEqual(backend.remoteTranscript(sessionId: "aura-k3j9x")?.entries.count, 1)
        send(["op": "watch", "sessionId": NSNull()])
        XCTAssertNil(backend.remoteTranscript(sessionId: "aura-k3j9x"), "dropped once nobody watches it")
    }

    // MARK: input

    func testInputBecomesASendAndTheAckBecomesTheResult() throws {
        showChats()
        send(["op": "input", "sessionId": "aura-k3j9x", "text": "  Add a chart  ", "clientId": "c-in", "expectTitle": "Quarterly numbers"])
        let cmd = try XCTUnwrap(commands("send").last)
        XCTAssertEqual(cmd["chatId"] as? String, "k3j9x")
        XCTAssertEqual(cmd["text"] as? String, "Add a chart")
        XCTAssertTrue(AuraLink.isValidId(try XCTUnwrap(cmd["id"] as? String)))
        XCTAssertTrue(frames("result").isEmpty, "the result waits for Page Aura's ack")

        transport.receive(#"{"t":"ack","ref":"\#(cmd["id"] as! String)","ok":true,"detail":"Sent to Page Aura"}"#)
        remote.waitUntilIdle()
        let r = try XCTUnwrap(lastResult)
        XCTAssertEqual(r["clientId"] as? String, "c-in")
        XCTAssertEqual(r["code"] as? String, "delivered")
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["detail"] as? String, "Sent to Page Aura")
    }

    func testAckFailureIsRefusedWithPageAurasWords() throws {
        showChats()
        send(["op": "input", "sessionId": "aura-k3j9x", "text": "hi", "clientId": "c1"])
        let cmd = try XCTUnwrap(commands("send").last)
        transport.receive(#"{"t":"ack","ref":"\#(cmd["id"] as! String)","ok":false,"detail":"Page Aura needs its API key"}"#)
        remote.waitUntilIdle()
        XCTAssertEqual(lastResult?["code"] as? String, "refused")
        XCTAssertEqual(lastResult?["reason"] as? String, "not_typable")
        XCTAssertEqual(lastResult?["detail"] as? String, "Page Aura needs its API key")
        XCTAssertEqual(lastResult?["ok"] as? Bool, false)
    }

    func testInputIsRefusedHereWhenTheChatIsBusyOrAskingOrGone() throws {
        showChats()
        transport.receive(#"{"t":"state","chats":[\#(askState),{"id":"b2","title":"Long refactor","model":"m","busy":true,"since":1762160390000,"approval":null}]}"#)
        remote.waitUntilIdle()
        advance(1.1)
        let before = transport.sent.count
        send(["op": "input", "sessionId": "aura-b2", "text": "hi", "clientId": "c-busy"])
        XCTAssertEqual(lastResult?["reason"] as? String, "not_typable")
        XCTAssertEqual(lastResult?["detail"] as? String, "Page Aura is still replying")
        send(["op": "input", "sessionId": "aura-p0q1r", "text": "hi", "clientId": "c-ask"])
        XCTAssertEqual(lastResult?["reason"] as? String, "waiting")
        XCTAssertEqual(lastResult?["interventionId"] as? String, "aura-p0q1r-perm-a7f3c2d1")
        send(["op": "input", "sessionId": "aura-nope", "text": "hi", "clientId": "c-gone"])
        XCTAssertEqual(lastResult?["reason"] as? String, "not_found")
        send(["op": "input", "sessionId": "aura-k3j9x", "text": "   ", "clientId": "c-empty"])
        XCTAssertEqual(lastResult?["code"] as? String, "refused")
        send(["op": "input", "sessionId": "aura-k3j9x", "text": String(repeating: "a", count: 8001), "clientId": "c-long"])
        XCTAssertEqual(lastResult?["code"] as? String, "refused")
        send(["op": "input", "sessionId": "aura-k3j9x", "text": "hi", "clientId": "c-wrong", "expectTitle": "Some other chat"])
        XCTAssertEqual(lastResult?["reason"] as? String, "target_mismatch")
        send(["op": "input", "sessionId": "aura-k3j9x", "text": "later", "clientId": "c-hold", "hold": true])
        XCTAssertEqual(lastResult?["reason"] as? String, "not_typable")
        XCTAssertEqual(transport.sent.count, before, "none of these reached Page Aura")
    }

    func testInputKeepsTheGatesFreshnessReplayAndDecryption() throws {
        showChats()
        let before = commands("send").count
        // Stale.
        send(["op": "input", "sessionId": "aura-k3j9x", "text": "hi", "clientId": "c-old", "ts": (clock.now.timeIntervalSince1970 - 600) * 1000])
        XCTAssertEqual(lastResult?["reason"] as? String, "stale")
        // Replay: the same command twice is typed once.
        let env = command(["op": "input", "sessionId": "aura-k3j9x", "text": "once", "clientId": "c-same"])
        remote.handleCommand(env); remote.waitUntilIdle()
        remote.handleCommand(env); remote.waitUntilIdle()
        XCTAssertEqual(commands("send").count, before + 1)
        // Sealed with the wrong key: dropped without a word.
        let results = frames("result").count
        let forged = SessionCrypto.seal(try JSONSerialization.data(withJSONObject: ["op": "input", "sessionId": "aura-k3j9x", "text": "x", "clientId": "c-forged",
                                                                                   "ts": clock.now.timeIntervalSince1970 * 1000, "viewer": "v"]),
                                        key: keys.macToPhone, aad: SessionCrypto.commandAAD)!
        remote.handleCommand(forged); remote.waitUntilIdle()
        XCTAssertEqual(commands("send").count, before + 1)
        XCTAssertEqual(frames("result").count, results)
        // Live sessions off in Page's settings.
        remote.setEnabled(false)
        send(["op": "input", "sessionId": "aura-k3j9x", "text": "hi", "clientId": "c-off"])
        XCTAssertEqual(lastResult?["reason"] as? String, "disabled")
        XCTAssertEqual(commands("send").count, before + 1)
    }

    func testInputWithoutPageAuraReportsIt() {
        showChats()
        transport.disconnect()
        // The phone still holds the old list for a moment: the send fails cleanly.
        remote.update(sessions: [AgentSession(backend: .aura, sessionId: "aura-k3j9x", cwd: nil, title: "Quarterly numbers", source: .desktop,
                                              state: .idle, lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)], pending: [])
        send(["op": "input", "sessionId": "aura-k3j9x", "text": "hi", "clientId": "c1"])
        XCTAssertEqual(lastResult?["code"] as? String, "refused")
        XCTAssertEqual(lastResult?["detail"] as? String, "Page Aura isn't open on your computer")
    }

    func testAckLostWhenTheSocketCloses() throws {
        showChats()
        send(["op": "input", "sessionId": "aura-k3j9x", "text": "hi", "clientId": "c1"])
        XCTAssertTrue(frames("result").isEmpty)
        transport.disconnect()
        remote.waitUntilIdle()
        XCTAssertEqual(lastResult?["clientId"] as? String, "c1")
        XCTAssertEqual(lastResult?["code"] as? String, "refused")
        XCTAssertEqual(lastResult?["detail"] as? String, "Page Aura isn't open on your computer")
    }

    // MARK: interrupt

    func testInterruptBecomesAStop() throws {
        showChats()
        send(["op": "interrupt", "sessionId": "aura-b2", "clientId": "c-stop"])
        let cmd = try XCTUnwrap(commands("stop").last)
        XCTAssertEqual(cmd["chatId"] as? String, "b2")
        XCTAssertTrue(frames("result").isEmpty)
        transport.receive(#"{"t":"ack","ref":"\#(cmd["id"] as! String)","ok":true,"detail":"Stopped"}"#)
        remote.waitUntilIdle()
        XCTAssertEqual(lastResult?["clientId"] as? String, "c-stop")
        XCTAssertEqual(lastResult?["code"] as? String, "delivered")
        XCTAssertEqual(lastResult?["detail"] as? String, "Stopped")
    }

    func testInterruptOfAnIdleChatIsRefusedWithoutAStop() {
        showChats()
        send(["op": "interrupt", "sessionId": "aura-k3j9x", "clientId": "c1"])
        XCTAssertEqual(lastResult?["reason"] as? String, "interrupt_unsupported")
        XCTAssertTrue(commands("stop").isEmpty)
    }

    func testStopAllStopsBusyChatsLikeAnyWorkingSession() throws {
        showChats()
        send(["op": "interruptAll", "clientId": "c-all"])
        let stops = commands("stop")
        XCTAssertEqual(stops.map { $0["chatId"] as? String }, ["b2"], "only the busy chat, not the idle or asking ones")
        transport.receive(#"{"t":"ack","ref":"\#(stops[0]["id"] as! String)","ok":true,"detail":"Stopped"}"#)
        remote.waitUntilIdle()
        remote.waitUntilIdle()
        XCTAssertEqual(lastResult?["clientId"] as? String, "c-all")
        XCTAssertEqual(lastResult?["detail"] as? String, "Stopped 1 agent")
        XCTAssertEqual(lastResult?["ok"] as? Bool, true)
    }

    // MARK: ops that don't apply

    func testUnsupportedOpsAreRefusedCleanly() {
        showChats()
        let before = transport.sent.count
        let cases: [(op: String, extra: [String: Any], reason: String)] = [
            ("answer", ["promptKey": "p", "answers": [["question": 0, "labels": ["x"]]]], "answer_unsupported"),
            ("clearDraft", ["text": "draft"], "not_typable"),
            ("peekDraft", [:], "not_typable"),
            ("inputImages", ["text": "look", "images": [["imageId": "i1", "bytes": 10, "sha256": "ab", "mime": "image/jpeg", "total": 1]]], "attach_unsupported"),
        ]
        for c in cases {
            var fields: [String: Any] = ["op": c.op, "sessionId": "aura-k3j9x", "clientId": "c-\(c.op)"]
            fields.merge(c.extra) { a, _ in a }
            send(fields)
            XCTAssertEqual(lastResult?["clientId"] as? String, "c-\(c.op)", c.op)
            XCTAssertEqual(lastResult?["code"] as? String, "refused", c.op)
            XCTAssertEqual(lastResult?["reason"] as? String, c.reason, c.op)
            XCTAssertFalse((lastResult?["detail"] as? String ?? "").isEmpty, c.op)
        }
        let resultsBeforeDiff = frames("result").count
        send(["op": "diff", "sessionId": "aura-k3j9x", "clientId": "c-diff"])
        XCTAssertEqual(frames("result").count, resultsBeforeDiff + 1, "a diff gets a refusal, not a git run")
        XCTAssertEqual(lastResult?["reason"] as? String, "not_typable")
        XCTAssertTrue(frames("diff").isEmpty)
        XCTAssertEqual(transport.sent.count, before, "none of these reached Page Aura")
    }

    func testNoScreenIsReadForAChat() {
        showChats()
        send(["op": "watch", "sessionId": "aura-k3j9x"])
        advance(5)
        XCTAssertTrue(frames("screen").isEmpty)
        XCTAssertTrue(frames("workflows").isEmpty)
    }
}
