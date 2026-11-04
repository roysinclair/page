import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif
@testable import PageCore
@testable import PageLinux

private func fixture(_ path: String) -> String {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path).path
}

private func fixtureText(_ path: String) throws -> String {
    try String(contentsOfFile: fixture(path), encoding: .utf8)
}

// MARK: - /proc

final class ProcFSTests: XCTestCase {
    func testStatSurvivesACommandNameWithSpacesAndParentheses() throws {
        let st = try XCTUnwrap(ProcFS.parseStat(try fixtureText("proc/4242/stat")))
        XCTAssertEqual(st.pid, 4242)
        XCTAssertEqual(st.comm, "claude (dev) x")
        XCTAssertEqual(st.state, "S")
        XCTAssertEqual(st.ppid, 4100)
        XCTAssertEqual(st.pgrp, 4242)
        XCTAssertEqual(st.ttyNr, 34819)
        XCTAssertEqual(st.tpgid, 4242)
        XCTAssertEqual(st.startTicks, 873421)
        XCTAssertNil(ProcFS.parseStat("garbage"))
        XCTAssertNil(ProcFS.parseStat("12 (x) S 1 2"), "too few fields")
    }

    func testTTYNumbersAreNamedAsPsNamesThem() {
        XCTAssertEqual(ProcFS.ttyName(device: 34819), "pts/3")      // major 136, minor 3
        XCTAssertEqual(ProcFS.ttyName(device: 34816 + 256 + 5), "pts/261") // major 137
        XCTAssertEqual(ProcFS.ttyName(device: 1025), "tty1")
        XCTAssertEqual(ProcFS.ttyName(device: 1024 + 64), "ttyS0")
        XCTAssertNil(ProcFS.ttyName(device: 0))
        XCTAssertNil(ProcFS.ttyName(device: 8 << 8), "a disk major is no terminal")
    }

    func testForegroundStateFromStat() throws {
        let st = try XCTUnwrap(ProcFS.parseStat(try fixtureText("proc/4242/stat")))
        XCTAssertEqual(ProcFS.foregroundState(st), .foreground)
        let bg = ProcFS.Stat(pid: 1, comm: "c", state: "S", ppid: 0, pgrp: 10, session: 1, ttyNr: 34819, tpgid: 11, startTicks: 0)
        XCTAssertEqual(ProcFS.foregroundState(bg), .background)
        let stopped = ProcFS.Stat(pid: 1, comm: "c", state: "T", ppid: 0, pgrp: 10, session: 1, ttyNr: 34819, tpgid: 10, startTicks: 0)
        XCTAssertEqual(ProcFS.foregroundState(stopped), .stopped)
        let noTTY = ProcFS.Stat(pid: 1, comm: "c", state: "S", ppid: 0, pgrp: 10, session: 1, ttyNr: 0, tpgid: -1, startTicks: 0)
        XCTAssertEqual(ProcFS.foregroundState(noTTY), .unknown)
    }

    func testCmdlineAndOnlyAllowlistedEnvironment() throws {
        let cmd = try Data(contentsOf: URL(fileURLWithPath: fixture("proc/4242/cmdline")))
        XCTAssertEqual(ProcFS.parseNulList(cmd), ["node", "/usr/local/bin/claude", "--resume", "abc"])
        let env = try Data(contentsOf: URL(fileURLWithPath: fixture("proc/4242/environ")))
        XCTAssertEqual(ProcFS.parseEnviron(env, keys: ["ANTHROPIC_BASE_URL", "OLLAMA_HOST"]),
                       ["ANTHROPIC_BASE_URL": "http://127.0.0.1:11434", "OLLAMA_HOST": "0.0.0.0:11434"])
        XCTAssertNil(ProcFS.parseEnviron(env, keys: ["OLLAMA_HOST"])["ANTHROPIC_AUTH_TOKEN"], "never decoded unless asked")
    }

    func testListeningPortsAndSocketInodes() throws {
        let listeners = ProcFS.parseTCPListeners(try fixtureText("proc/net/tcp"))
        XCTAssertEqual(listeners, [.init(port: 11434, inode: 55501), .init(port: 8080, inode: 55502)], "established sockets aren't listeners")
        XCTAssertEqual(ProcFS.socketInode("socket:[55501]"), 55501)
        XCTAssertNil(ProcFS.socketInode("/dev/null"))
        XCTAssertEqual(ProcFS.bootTime(fromStat: try fixtureText("proc/stat")), 1_762_200_000)
    }

    func testInspectorOverAFixtureTree() throws {
        let p = LinuxProcessInspector(root: fixture("proc"))
        let info = try XCTUnwrap(p.arguments(pid: 4242, envKeys: ["OLLAMA_HOST"]))
        XCTAssertEqual(info.argv.first, "node")
        XCTAssertEqual(info.env, ["OLLAMA_HOST": "0.0.0.0:11434"])
        let row = try XCTUnwrap(p.processTable().first { $0.pid == 4242 })
        XCTAssertEqual(row.tty, "pts/3")
        XCTAssertEqual(row.command, "node /usr/local/bin/claude --resume abc")
        XCTAssertEqual(p.startSeconds(pid: 4242), 1_762_200_000 + Int(Double(873421) / p.ticksPerSecond))
        XCTAssertNil(p.arguments(pid: 99999, envKeys: []))
    }

    /// lsof's two shapes, answered from /proc in its -F format.
    func testLsofEmulation() {
        let files: [Int32: [(fd: Int, path: String)]] = [
            10: [(0, "/dev/pts/1"), (7, "/home/u/.codex/sessions/r.jsonl")],
            11: [(3, "socket:[1]")],
        ]
        let byPid = ProcFS.emulateLsof(["-a", "-p", "10,11,12", "-F", "fn"], pids: [10, 11],
                                       openFiles: { files[$0] }, command: { _ in "codex" })
        XCTAssertEqual(byPid.status, 0)
        XCTAssertEqual(byPid.stdout, "p10\nf0\nn/dev/pts/1\nf7\nn/home/u/.codex/sessions/r.jsonl\np11\nf3\nnsocket:[1]\n")
        let byFile = ProcFS.emulateLsof(["-w", "-F", "pc", "--", "/home/u/.codex/sessions/r.jsonl"], pids: [10, 11],
                                        openFiles: { files[$0] }, command: { _ in "codex" })
        XCTAssertEqual(byFile.stdout, "p10\nccodex\n")
        let nobody = ProcFS.emulateLsof(["-w", "-F", "pc", "--", "/elsewhere"], pids: [10, 11],
                                        openFiles: { files[$0] }, command: { _ in nil })
        XCTAssertEqual(nobody.status, 1, "lsof's \"nobody has it open\"")
        XCTAssertTrue(nobody.stdout.isEmpty)
    }

    /// The live inspector against this very process.
    func testLiveOwnProcess() throws {
        let p = LinuxProcessInspector()
        let me = getpid()
        XCTAssertNotNil(p.arguments(pid: me, envKeys: ["PATH"])?.env["PATH"])
        XCTAssertNotNil(p.startSeconds(pid: me))
        XCTAssertTrue(p.processTable().contains { $0.pid == me })
        XCTAssertEqual(p.execPath(pid: me).map { URL(fileURLWithPath: $0).lastPathComponent.isEmpty }, false)
        // A file this process holds open is found by the lsof emulation.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lsof-\(me).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close(); try? FileManager.default.removeItem(at: url) }
        let r = p.lsof(["-w", "-F", "pc", "--", url.path], timeout: 5)
        XCTAssertTrue(r.stdout.contains("p\(me)\n"), r.stdout)
    }
}

// MARK: - power

final class LinuxBatteryTests: XCTestCase {
    func testLaptopOnBatteryIgnoresAMouseBattery() {
        let s = LinuxBattery.snapshot(from: LinuxBattery.readSupplies(fixture("power_supply/laptop")))
        XCTAssertEqual(s, PowerSnapshot(percent: 41, onAC: false, hasBattery: true, isCharging: false))
    }

    func testTwoBatteriesCombineByEnergy() {
        let s = LinuxBattery.snapshot(from: LinuxBattery.readSupplies(fixture("power_supply/dual")))
        XCTAssertEqual(s, PowerSnapshot(percent: 80, onAC: true, hasBattery: true, isCharging: true))
    }

    func testDesktopHasNoBatteryAndAUPSCountsOnlyAlone() {
        XCTAssertEqual(LinuxBattery.snapshot(from: LinuxBattery.readSupplies(fixture("power_supply/desktop"))), .noBattery)
        XCTAssertEqual(LinuxBattery.snapshot(from: LinuxBattery.readSupplies(fixture("power_supply/ups"))),
                       PowerSnapshot(percent: 88, onAC: false, hasBattery: true, isCharging: false))
        XCTAssertEqual(LinuxBattery.snapshot(from: [:]), .noBattery)
    }

    func testUPowerFallback() throws {
        XCTAssertEqual(LinuxBattery.parseUPower(try fixtureText("upower-laptop.txt")),
                       PowerSnapshot(percent: 41, onAC: false, hasBattery: true, isCharging: false))
        XCTAssertNil(LinuxBattery.parseUPower(try fixtureText("upower-desktop.txt")), "no power supply")
    }

    func testThermalTripPoints() {
        XCTAssertEqual(LinuxThermal.read(root: fixture("thermal/hot")), .serious, "past 'hot', short of 'critical'")
        XCTAssertEqual(LinuxThermal.read(root: fixture("thermal/cool")), .nominal)
        XCTAssertEqual(LinuxThermal.state([.init(milliCelsius: 96_000, trips: [])]), .critical, "no trip points: fixed limits")
        XCTAssertEqual(LinuxThermal.read(root: "/nonexistent"), .nominal)
    }

    func testInhibitorChildIsAnArgumentListTiedToPaged() {
        let args = LogindInhibitor.arguments(what: "idle:sleep", why: "2 agents working; $(rm -rf ~)", parentPid: 4242)
        XCTAssertEqual(args, ["--what=idle:sleep", "--who=Page", "--why=2 agents working; $(rm -rf ~)", "--mode=block",
                              "/usr/bin/env", "tail", "--pid=4242", "-f", "/dev/null"])
    }

    func testRefusalsReadPlainly() {
        XCTAssertTrue(LogindInhibitor.explainFailure(stderr: "Failed to connect to bus: No such file or directory").contains("logind isn't running"))
        XCTAssertTrue(LogindInhibitor.explainFailure(stderr: "System has not been booted with systemd as init system (PID 1). Can't operate.").contains("logind isn't running"))
        XCTAssertTrue(LogindInhibitor.explainFailure(stderr: "Failed to inhibit: Access denied").contains("polkit"))
    }

    /// Without logind (this container) the backend says so and holds nothing.
    func testNoLogindHoldsNothingAndSaysWhy() throws {
        let missing = LogindInhibitor(what: "idle:sleep", tool: nil)
        let backend = LinuxPowerBackend(idle: missing, lid: LogindInhibitor(what: "handle-lid-switch", tool: nil),
                                        battery: { .noBattery })
        backend.apply(AwakeAssertions(preventIdleSleep: true, preventSystemSleep: true), reason: "test")
        XCTAssertEqual(backend.held, .none)
        XCTAssertEqual(backend.problem, LogindInhibitor.unavailableMessage)
    }

    /// With a stand-in systemd-inhibit that just runs its command, the
    /// inhibitor is a live child for as long as it is held.
    func testInhibitorChildLivesWhileHeld() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inhibit-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("systemd-inhibit")
        // Drops the --options and runs the rest, as systemd-inhibit does.
        try "#!/bin/sh\nwhile [ \"${1#--}\" != \"$1\" ]; do shift; done\nexec \"$@\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let inhibitor = LogindInhibitor(what: "idle:sleep", tool: fake.path)
        XCTAssertTrue(inhibitor.acquire(why: "test"))
        XCTAssertTrue(inhibitor.isHeld)
        inhibitor.release()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(inhibitor.isHeld)
    }
}

// MARK: - presence

final class LinuxPresenceTests: XCTestCase {
    func testParsers() throws {
        XCTAssertEqual(LinuxPresence.parseXprintidle("12345\n"), 12.345)
        XCTAssertNil(LinuxPresence.parseXprintidle("couldn't open display"))
        XCTAssertEqual(LinuxPresence.parseMutterIdle("(uint64 61000,)\n"), 61)
        XCTAssertNil(LinuxPresence.parseMutterIdle("Error: GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown"))
        XCTAssertEqual(LinuxPresence.sessionId("2\n"), "2")
        XCTAssertNil(LinuxPresence.sessionId("\n"), "no graphical session")
        XCTAssertNil(LinuxPresence.sessionId("2; rm -rf ~"))
        let now = Date(timeIntervalSince1970: 1_762_261_500)
        XCTAssertEqual(LinuxPresence.parseLogindIdle(try fixtureText("loginctl-idle.txt"), now: now), 300)
        XCTAssertEqual(LinuxPresence.parseLogindIdle(try fixtureText("loginctl-active.txt"), now: now), 0)
        XCTAssertNil(LinuxPresence.parseLogindIdle(try fixtureText("loginctl-tty.txt"), now: now), "a text console isn't a screen")
    }

    func testHeadlessIsAway() {
        let p = LinuxPresence(environment: { [:] }, run: { _, _ in nil }, find: { _ in nil })
        XCTAssertEqual(p.rawSecondsSinceLastInput(), .infinity)
        XCTAssertTrue(p.reading().source.contains("no graphical session"))
    }

    func testSourcesInOrder() {
        var asked: [String] = []
        let p = LinuxPresence(environment: { ["DISPLAY": ":0"] },
                              run: { tool, _ in asked.append(tool); return tool == "/x/xprintidle" ? "1500" : nil },
                              find: { "/x/\($0)" })
        XCTAssertEqual(p.rawSecondsSinceLastInput(), 1.5)
        XCTAssertEqual(asked, ["/x/xprintidle"])
        let gnome = LinuxPresence(environment: { ["WAYLAND_DISPLAY": "wayland-0"] },
                                  run: { tool, _ in tool == "/x/gdbus" ? "(uint64 2000,)" : nil }, find: { "/x/\($0)" })
        XCTAssertEqual(gnome.reading().source, "gnome-mutter")
        XCTAssertEqual(gnome.rawSecondsSinceLastInput(), 2)
    }
}

// MARK: - resume timers

final class SystemdTimerTests: XCTestCase {
    func testUnitsQuoteEverything() {
        XCTAssertEqual(SystemdTimerScheduler.quote(#"/home/a b/$x%y"q\"#), #""/home/a b/$$x%%y\"q\\""#)
        let service = SystemdTimerScheduler.serviceUnit(scriptPath: "/home/a b/page.sh", path: "/usr/bin:/bin")
        XCTAssertTrue(service.contains(#"ExecStart=/bin/bash "/home/a b/page.sh""#))
        XCTAssertTrue(service.contains(#"Environment="PATH=/usr/bin:/bin""#))
        let fire = ResumeScheduler.calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 18, minute: 5))!
        let timer = SystemdTimerScheduler.timerUnit(label: "local.Page.resume.abc", fireAt: fire)
        XCTAssertTrue(timer.contains("OnCalendar=2026-11-04 18:05:00"))
        XCTAssertTrue(timer.contains("Persistent=true"))
        XCTAssertTrue(timer.contains("Unit=local.Page.resume.abc.service"))
    }

    func testLoadedJobsFromListUnits() throws {
        let jobs = SystemdTimerScheduler.parseListUnits(try fixtureText("systemctl-list-units.txt"), prefixes: ["local.Page.resume."])
        XCTAssertEqual(jobs.map(\.label), ["local.Page.resume.0b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60",
                                           "local.Page.resume.1b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60"])
        XCTAssertNil(jobs[0].pid, "waiting")
        XCTAssertNotNil(jobs[1].pid, "its service is running")
    }

    func testInstallWritesUnitsAndStartsTheTimer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("units-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var calls: [[String]] = []
        let s = SystemdTimerScheduler(unitDirectory: dir, runCommand: { path, args in
            calls.append([path] + args)
            return ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
        }, systemctl: "/usr/bin/systemctl")
        let label = "local.Page.resume.abc"
        let job = s.jobFileURL(label: label, in: dir)
        try s.install(label: label, jobFile: job, scriptPath: "/s.sh", fireAt: Date(), logPath: "/l.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(label).service").path))
        XCTAssertEqual(calls.last, ["/usr/bin/systemctl", "--user", "start", "\(label).timer"])
        XCTAssertTrue(s.remove(label: label))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(label).service").path))
        XCTAssertNil(s.scheduleWake(at: Date()), "a user service can't wake the machine")
    }
}

// MARK: - relay transport

final class NIORelayTransportTests: XCTestCase {
    func testProxyFromTheEnvironment() {
        let wss = URL(string: "wss://relay.example.workers.dev/ws")!
        XCTAssertEqual(NIORelayTransport.proxy(for: wss, environment: ["HTTPS_PROXY": "http://127.0.0.1:3128"]),
                       .init(host: "127.0.0.1", port: 3128, authorization: nil))
        XCTAssertEqual(NIORelayTransport.proxy(for: wss, environment: ["https_proxy": "http://u%40x:p@proxy:8080"])?.authorization,
                       "Basic " + Data("u@x:p".utf8).base64EncodedString())
        XCTAssertNil(NIORelayTransport.proxy(for: wss, environment: ["HTTPS_PROXY": "http://p:1", "NO_PROXY": ".workers.dev"]))
        XCTAssertNil(NIORelayTransport.proxy(for: wss, environment: ["HTTPS_PROXY": "http://p:1", "NO_PROXY": "example.workers.dev"]))
        XCTAssertNil(NIORelayTransport.proxy(for: URL(string: "ws://127.0.0.1:8787/ws")!,
                                             environment: ["HTTPS_PROXY": "http://p:1"]), "ws uses HTTP_PROXY")
        XCTAssertNil(NIORelayTransport.proxy(for: wss, environment: [:]))
    }

    /// A tiny WebSocket server (Python, loopback only): the client opens,
    /// receives a text frame, sends a binary one, and pings.
    func testRoundTripAgainstALocalServer() throws {
        guard let python = ProcessRunner.findExecutable("python3") else { throw XCTSkip("no python3") }
        let script = """
        import socket, base64, hashlib, struct, sys
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', 0)); s.listen(1)
        print(s.getsockname()[1], flush=True)
        c, _ = s.accept(); req = b''
        while b'\\r\\n\\r\\n' not in req: req += c.recv(4096)
        key = [l.split(b':', 1)[1].strip() for l in req.split(b'\\r\\n') if l.lower().startswith(b'sec-websocket-key')][0]
        auth = [l for l in req.split(b'\\r\\n') if l.lower().startswith(b'authorization')]
        acc = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
        c.sendall(b'HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Accept: ' + acc + b'\\r\\n\\r\\n')
        msg = b'{"type":"phones.status","payload":{"phones":1},"auth":"' + (b'yes' if auth else b'no') + b'"}'
        c.sendall(bytes([0x81, len(msg)]) + msg)
        def frame():
            h = c.recv(2); op = h[0] & 0x0f; n = h[1] & 0x7f
            if n == 126: n = struct.unpack('>H', c.recv(2))[0]
            mask = c.recv(4); data = b''
            while len(data) < n: data += c.recv(n - len(data))
            return op, bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        while True:
            op, data = frame()
            if op == 0x9: c.sendall(bytes([0x8A, len(data)]) + data)
            elif op == 0x2: c.sendall(bytes([0x82, len(data)]) + data)
            elif op == 0x8: break
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-I", "-c", script]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        defer { p.terminate() }
        let portLine = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try XCTUnwrap(Int(portLine))

        final class Events: RelayWebSocketEvents {
            let opened = XCTestExpectation(description: "open")
            func webSocketDidOpen(_ socket: RelayWebSocket) { opened.fulfill() }
            func webSocketDidClose(_ socket: RelayWebSocket, code: Int) {}
            func webSocketDidComplete(_ socket: RelayWebSocket, error: Error?, httpStatus: Int?) {}
        }
        let queue = DispatchQueue(label: "test.relay")
        let transport = NIORelayTransport(queue: queue, environment: [:])
        defer { transport.invalidate() }
        let events = Events()
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        req.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        let socket = transport.makeWebSocket(request: req, events: events)
        socket.resume()
        wait(for: [events.opened], timeout: 10)

        let got = expectation(description: "text")
        socket.receive { r in
            if case .success(.string(let s)) = r { XCTAssertTrue(s.contains(#""auth":"yes""#), s); got.fulfill() }
        }
        wait(for: [got], timeout: 5)
        let echoed = expectation(description: "echo")
        socket.send(.data(Data("{\"type\":\"heartbeat\"}".utf8))) { XCTAssertNil($0) }
        socket.receive { r in
            if case .success(.data(let d)) = r { XCTAssertEqual(String(decoding: d, as: UTF8.self), "{\"type\":\"heartbeat\"}"); echoed.fulfill() }
        }
        wait(for: [echoed], timeout: 5)
        let pong = expectation(description: "pong")
        socket.sendPing { XCTAssertNil($0); pong.fulfill() }
        wait(for: [pong], timeout: 5)
        socket.cancel()
    }
}

// MARK: - sockets, files, CLI

final class LocalSocketLinuxTests: XCTestCase {
    func testPeerCredentialsAreOurOwnUid() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds), 0)
        defer { LocalSocket.close(fds[0]); LocalSocket.close(fds[1]) }
        XCTAssertEqual(LocalSocket.peerUID(fds[0]), getuid())
        XCTAssertEqual(LocalSocket.maxPathBytes, 107)
    }

    /// A write to a socket whose reader is gone fails (EPIPE) instead of
    /// killing the test process with SIGPIPE.
    func testWriteToAClosedPeerDoesNotRaiseSIGPIPE() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds), 0)
        LocalSocket.close(fds[1])
        defer { LocalSocket.close(fds[0]) }
        let n = [UInt8]("x".utf8).withUnsafeBytes { LocalSocket.write(fds[0], $0.baseAddress, 1) }
        XCTAssertEqual(n, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    func testAuraSocketIsUnderTheDataFolderAndPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aura-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("aura.sock").path
        let server = AuraLinkServer(path: path)
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(PlatformPaths.xdg(environment: [:], home: "/home/u").support.appendingPathComponent("aura.sock").path,
                       "/home/u/.local/share/page/aura.sock")
    }
}

final class PagedFilesTests: XCTestCase {
    func testXDGLayout() {
        let p = PlatformPaths.xdg(environment: ["XDG_CONFIG_HOME": "/c", "XDG_DATA_HOME": "relative", "XDG_STATE_HOME": "/s"], home: "/home/u")
        XCTAssertEqual(p.configFile.path, "/c/page/config.json")
        XCTAssertEqual(p.support.path, "/home/u/.local/share/page", "a relative XDG value is ignored")
        XCTAssertEqual(p.logs.path, "/s/page")
        XCTAssertEqual(p.logFileName, "paged.log")
    }

    func testPrivateFilesAndTheInstanceLock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paged-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("secret.txt")
        try PrivateFile.write(Data("a".utf8), to: f)
        try PrivateFile.write(Data("b".utf8), to: f)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "b")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let pid = dir.appendingPathComponent("paged.pid")
        let lock = try XCTUnwrap(InstanceLock.acquire(at: pid))
        _ = lock
        XCTAssertNil(InstanceLock.runningPid(at: pid), "held, but this test runner isn't called paged")
    }

    func testConfigSetIsTypedAndValidated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try #"{"someFutureKey": 1}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try PagedCLI.setValue("relayEnabled", "true", at: url).get())
        XCTAssertNoThrow(try PagedCLI.setValue("relayURL", "https://r.example.workers.dev", at: url).get())
        XCTAssertNoThrow(try PagedCLI.setValue("lowBatteryCutoff", "15", at: url).get())
        if case .success = PagedCLI.setValue("relayEnabled", "maybe", at: url) { XCTFail("not a bool") }
        if case .success = PagedCLI.setValue("noSuchKey", "1", at: url) { XCTFail("unknown key") }
        let cfg = try XCTUnwrap(Config.loadResult(from: url).config)
        XCTAssertTrue(cfg.relayEnabled)
        XCTAssertEqual(cfg.relayURL, "https://r.example.workers.dev")
        XCTAssertEqual(cfg.lowBatteryCutoff, 15)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNotNil(raw?["someFutureKey"], "other keys are kept")
    }

    func testStatusRendering() {
        let s = DaemonStatus(version: "0.1.0", pid: 1, startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 60),
                             relay: "connected", sessions: [.init(agent: "Claude", state: "active", project: "page")],
                             pendingPages: 0, keepAwake: "off", keepAwakeProblem: "logind isn't running here",
                             lidClosedOnBattery: false, battery: "no battery (on AC)", presence: "away (no graphical session (away))",
                             configProblem: nil, statusLine: "Watching 1 session")
        let text = PagedCLI.render(s, relayURL: "https://r.example")
        XCTAssertTrue(text.contains("relay:       connected (https://r.example)"))
        XCTAssertTrue(text.contains("Claude page [active]"))
        XCTAssertTrue(text.contains("keep-awake:  off — logind isn't running here"))
    }

    func testNotifySendArgumentsEndOptions() {
        XCTAssertEqual(NotifySendNotifier.arguments(title: "-x", body: "b"), ["--app-name=Page", "--icon=dialog-information", "--", "-x", "b"])
        XCTAssertFalse(NotifySendNotifier(tool: nil, environment: ["DISPLAY": ":0"]).available)
        XCTAssertFalse(NotifySendNotifier(tool: "/usr/bin/notify-send", environment: [:]).available, "no desktop session")
    }
}
