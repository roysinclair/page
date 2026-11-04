import XCTest
@testable import ClaudePowerMode
@testable import PageCore

/// Page Orbit's link (docs/ORBIT-LINK.md): the Page Aura line protocol on its
/// own socket, served by `AuraBackend` with the `.orbit` flavour. Its agents
/// run in Anthropic's cloud, so it pages but never keeps the Mac awake, and it
/// has no Sessions-tab rows in v1.

private final class OrbitFakeTransport: AuraLinkTransport {
    var onConnect: (() -> Void)?
    var onLine: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    var started = 0
    var stopped = 0
    var sent: [Data] = []
    func start() -> Bool { started += 1; return true }
    func stop() { stopped += 1 }
    func send(_ line: Data) -> Bool { sent.append(line); return true }
    func receive(_ json: String) { onLine?(Data(json.utf8)) }
    var commands: [[String: Any]] { sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
}

private final class OrbitRecordingRelay: RelaySink {
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

final class OrbitLinkTests: XCTestCase {
    private var transport: OrbitFakeTransport!
    private var relay: OrbitRecordingRelay!
    private var backend: AuraBackend!
    private var clock = Date(timeIntervalSince1970: 1_762_160_000)

    private let busySession = #"{"id":"sesn_01busy","title":"Release notes","model":"claude-opus-5-5","busy":true,"since":1762160000000,"approval":null}"#
    private let askingSession = #"{"id":"sesn_01ask","title":"Weekly report","model":"claude-opus-5-5","busy":false,"since":1762160100000,"approval":{"id":"sevt_01tool","server":"Release manager","tool":"bash","args":"{\"command\":\"git log --oneline\"}"}}"#
    private let permId = "orbit-sesn_01ask-perm-sevt_01tool"

    override func setUp() {
        transport = OrbitFakeTransport()
        relay = OrbitRecordingRelay()
        backend = AuraBackend(config: Config(), flavor: .orbit, transport: transport, now: { [unowned self] in self.clock },
                              userAtMac: { _ in false })
        backend.relay = relay
        backend.start()
        transport.onConnect?()
        transport.receive(#"{"t":"hello","proto":2,"app":"Page Orbit","version":"0.3.0"}"#)
    }

    private func state(_ sessions: String) { transport.receive(#"{"t":"state","chats":[\#(sessions)]}"#) }

    func testIdentityAndRouting() {
        XCTAssertEqual(AgentBackendID(rawValue: "orbit"), .orbit)
        XCTAssertEqual(backend.id, .orbit)
        XCTAssertEqual(backend.displayName, "Page Orbit")
        let r = RelayReply(interventionId: "orbit-x-perm-y", text: "", action: "approve", sessionId: nil, cwd: nil, kind: nil, backend: nil, source: nil)
        XCTAssertEqual(r.owningBackend, .orbit)
        XCTAssertFalse(Coordinator.isLiveSessionCapable(.orbit))
        XCTAssertEqual(AppDelegate.agentName(.orbit), "Page Orbit")
        XCTAssertTrue(AuraLinkServer.path(socketName: "orbit.sock").hasSuffix("/ClaudePowerMode/orbit.sock"))
    }

    func testBusySessionsNeverKeepTheMacAwake() {
        state(busySession)
        let snap = backend.currentSnapshot
        XCTAssertEqual(snap.backendID, .orbit)
        XCTAssertEqual(snap.sessions.first?.sessionId, "orbit-sesn_01busy")
        XCTAssertEqual(snap.sessions.first?.state, .active)
        XCTAssertFalse(snap.wantsPowerAssertion, "Page Orbit's agents run in the cloud")
    }

    func testApprovalPagesWithoutOnThisMac() {
        state(askingSession)
        XCTAssertEqual(relay.opened.count, 1)
        let page = relay.opened[0]
        XCTAssertEqual(page.id, permId)
        XCTAssertEqual(page.backend, .orbit)
        XCTAssertEqual(page.sessionId, "orbit-sesn_01ask")
        XCTAssertTrue(page.context.hasPrefix("Use Release manager · bash\n"), page.context)
        XCTAssertFalse(page.context.contains("on this Mac"))
    }

    func testAllowFromThePhoneReachesPageOrbit() throws {
        state(askingSession)
        backend.handleReply(RelayReply(interventionId: permId, text: "", action: "approve", sessionId: nil, cwd: nil, kind: nil, backend: "orbit", source: nil))
        let cmd = try XCTUnwrap(transport.commands.last)
        XCTAssertEqual(cmd["t"] as? String, "approve")
        XCTAssertEqual(cmd["chatId"] as? String, "sesn_01ask")
        XCTAssertEqual(cmd["approvalId"] as? String, "sevt_01tool")
        XCTAssertEqual(cmd["decision"] as? String, "once")
        transport.receive(#"{"t":"ack","ref":"\#(cmd["id"] as! String)","ok":true,"detail":"Allowed once"}"#)
        XCTAssertEqual(relay.injected.first?.method, "orbit-link")
        XCTAssertEqual(relay.injected.first?.detail, "Allowed once")
        XCTAssertEqual(relay.closed.map(\.reason), ["replied"])
    }

    func testNoSessionsTabEvenForProto2() {
        XCTAssertFalse(transport.commands.contains { $0["t"] as? String == "watch" })
        XCTAssertTrue(backend.remoteSnapshot.sessions.isEmpty)
    }

    func testWordingSaysPageOrbit() {
        XCTAssertEqual(LinkFlavor.orbit.say(AuraLink.notConnectedDetail), "Page Orbit isn't open on your Mac")
        XCTAssertEqual(LinkFlavor.orbit.say(AuraLink.chatGoneDetail), "That session no longer exists")
        XCTAssertEqual(LinkFlavor.aura.say(AuraLink.chatGoneDetail), AuraLink.chatGoneDetail)
    }

    func testConfigDefaultsOnAndDecodesOldFiles() throws {
        XCTAssertTrue(Config().orbitBackendEnabled)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertTrue(old.orbitBackendEnabled)
        var off = Config()
        off.orbitBackendEnabled = false
        let t = OrbitFakeTransport()
        let b = AuraBackend(config: off, flavor: .orbit, transport: t)
        b.start()
        XCTAssertEqual(t.started, 0)
        var auraOff = Config()
        auraOff.auraBackendEnabled = false
        let t2 = OrbitFakeTransport()
        AuraBackend(config: auraOff, flavor: .orbit, transport: t2).start()
        XCTAssertEqual(t2.started, 1, "Page Orbit's switch is its own")
    }
}
