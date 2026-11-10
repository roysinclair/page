import XCTest
@testable import PageCore

/// The shell side of budget caps, run for real: the PreToolUse gate
/// (`hooks/page-budget-gate.sh`), the status-line wrapper that feeds the books
/// (`UsageCapture.script`), and the gate's hook entry (`HookInstaller`). The
/// gate tests use the marker files the controller writes, so the script and the
/// Swift side are checked against the same format. Everything lives in temp folders.
final class BudgetGateScriptTests: XCTestCase {
    private var base: URL!
    private var gateURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hooks/page-budget-gate.sh")
    }
    /// Nonexistent folders, so the cwd is only matched as written unless a test makes a real one.
    private let project = "/budgettest-gate-no-such/proj"
    private var stop: String { BudgetGate.stopLine(reason: "Page: Night Owl reached its budget (25% of the week).") }

    override func setUpWithError() throws {
        // A hook that exits before reading all of stdin must not kill the test run.
        signal(SIGPIPE, SIG_IGN)
        base = FileManager.default.temporaryDirectory.appendingPathComponent("budget-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: running the script

    private struct Run: Equatable {
        let status: Int32
        let stdout: String
    }

    private func runGate(stdin: String, budgetDir: URL? = nil) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [gateURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PAGE_BUDGET_DIR"] = (budgetDir ?? base).path
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }

    /// A hook call as Claude Code sends it: the top-level fields first, then the tool's input.
    private func call(session: String = "s9", cwd: String, tool: String = "Bash") -> String {
        #"{"session_id":"\#(session)","transcript_path":"/x/t.jsonl","cwd":"\#(cwd)","hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":{"command":"ls"}}"#
    }

    private var overDir: URL { base.appendingPathComponent("budget-over", isDirectory: true) }
    private var allowDir: URL { base.appendingPathComponent("budget-allow", isDirectory: true) }

    private func expiresLater() -> Int { Int(Date().timeIntervalSince1970) + 3600 }

    /// Writes a marker the way the controller does (`BudgetGate.gateFile`).
    private func writeGate(hash: String, project: String?, session: String?, expires: Int? = nil, stopLine: String? = nil) throws {
        try FileManager.default.createDirectory(at: overDir, withIntermediateDirectories: true)
        let text = BudgetGate.gateFile(project: project, session: session, expires: expires ?? expiresLater(), stopLine: stopLine ?? stop)!
        try text.write(to: overDir.appendingPathComponent(hash + ".gate"), atomically: true, encoding: .utf8)
    }

    private func assertPasses(_ run: Run, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.status, 0, message, file: file, line: line)
        XCTAssertEqual(run.stdout, "", message, file: file, line: line)
    }

    private func assertStops(_ run: Run, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.status, 0, message, file: file, line: line)
        XCTAssertEqual(run.stdout, stop + "\n", message, file: file, line: line)
        XCTAssertTrue(run.stdout.contains("\"continue\":false"), message, file: file, line: line)
    }

    // MARK: no folder, no marker

    func testNoBudgetFolderLetsEverythingThrough() throws {
        assertPasses(try runGate(stdin: call(cwd: project)), "no budget-over folder at all")
    }

    func testEmptyBudgetFolderLetsEverythingThrough() throws {
        try FileManager.default.createDirectory(at: overDir, withIntermediateDirectories: true)
        assertPasses(try runGate(stdin: call(cwd: project)), "budget-over with no .gate in it")
    }

    // MARK: project markers

    func testProjectMarkerMatchesItsFolder() throws {
        try writeGate(hash: "aaaa", project: project, session: nil)
        assertStops(try runGate(stdin: call(cwd: project)))
    }

    func testProjectMarkerMatchesFoldersBelowIt() throws {
        try writeGate(hash: "aaaa", project: project, session: nil)
        assertStops(try runGate(stdin: call(cwd: project + "/sub/deeper")))
    }

    func testTrailingSlashOnTheCwdStillMatches() throws {
        try writeGate(hash: "aaaa", project: project, session: nil)
        assertStops(try runGate(stdin: call(cwd: project + "/")))
    }

    func testASiblingWithTheSamePrefixIsNotCovered() throws {
        try writeGate(hash: "aaaa", project: project, session: nil)
        assertPasses(try runGate(stdin: call(cwd: project + "2")), "/x/proj does not cover /x/proj2")
        assertPasses(try runGate(stdin: call(cwd: "/budgettest-gate-no-such")), "a parent is not covered")
    }

    func testTheCwdIsAlsoTriedAsPwdP() throws {
        // The marker's key has its symlinks resolved; the call's folder may be reached through a link.
        let real = base.appendingPathComponent("real/proj", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // The controller's own key (realpath): URL.resolvingSymlinksInPath leaves /var as it is.
        let resolved = BudgetProjectKey.resolveSymlinks(real.path)
        try writeGate(hash: "aaaa", project: resolved, session: nil)
        assertStops(try runGate(stdin: call(cwd: link.path)), "the link resolves to the marker's folder")
    }

    func testProjectMarkerWithNoProjectAndNoSessionIsIgnored() throws {
        try writeGate(hash: "aaaa", project: nil, session: nil)
        assertPasses(try runGate(stdin: call(cwd: project)))
    }

    // MARK: session markers

    func testSessionMarkerMatchesOnlyItsSession() throws {
        try writeGate(hash: "bbbb", project: nil, session: "s1")
        assertStops(try runGate(stdin: call(session: "s1", cwd: "/somewhere/else")), "a session cap ignores the folder")
        assertPasses(try runGate(stdin: call(session: "s2", cwd: project)), "another session in the same folder")
        assertPasses(try runGate(stdin: #"{"cwd":"\#(project)"}"#), "no session_id, no match")
    }

    func testASessionCapAndAProjectCapCoverTheirOwnSessions() throws {
        try writeGate(hash: "bbbb", project: nil, session: "s1")
        try writeGate(hash: "cccc", project: project, session: nil)
        // s2 is covered by the project marker, s1 by its own: both stop.
        assertStops(try runGate(stdin: call(session: "s1", cwd: "/x")))
        assertStops(try runGate(stdin: call(session: "s2", cwd: project)))
    }

    // MARK: allow files

    func testAnAllowFileLetsItsSessionFinishItsTurn() throws {
        try writeGate(hash: "aaaa", project: project, session: nil)
        try FileManager.default.createDirectory(at: allowDir, withIntermediateDirectories: true)
        try "1800000000\n".write(to: allowDir.appendingPathComponent("s9"), atomically: true, encoding: .utf8)
        assertPasses(try runGate(stdin: call(session: "s9", cwd: project)), "allowed")
        assertStops(try runGate(stdin: call(session: "s8", cwd: project)), "another session is still stopped")
    }

    // MARK: malformed and expired markers

    func testExpiredMarkerIsIgnored() throws {
        try writeGate(hash: "aaaa", project: project, session: nil, expires: Int(Date().timeIntervalSince1970) - 100)
        assertPasses(try runGate(stdin: call(cwd: project)))
    }

    func testMalformedMarkersAreIgnored() throws {
        try FileManager.default.createDirectory(at: overDir, withIntermediateDirectories: true)
        let bad: [(String, String)] = [
            ("noStop", "project=\(project)\nsession=\nexpires=\(expiresLater())\n"),
            ("badExpires", "project=\(project)\nsession=\nexpires=soon\nstop=\(stop)\n"),
            ("noExpires", "project=\(project)\nsession=\nstop=\(stop)\n"),
            ("noKeys", "stop=\(stop)\nexpires=\(expiresLater())\n"),
            ("garbage", "\u{0}\u{1}not a marker at all"),
        ]
        for (name, text) in bad {
            try text.write(to: overDir.appendingPathComponent(name + ".gate"), atomically: true, encoding: .utf8)
        }
        assertPasses(try runGate(stdin: call(cwd: project)), "none of the malformed markers may block")
    }

    func testAMarkerThatNamesNoProjectOrSessionIsIgnored() throws {
        try FileManager.default.createDirectory(at: overDir, withIntermediateDirectories: true)
        try "project=\nsession=\nexpires=\(expiresLater())\nstop=\(stop)\n".write(
            to: overDir.appendingPathComponent("empty.gate"), atomically: true, encoding: .utf8)
        assertPasses(try runGate(stdin: call(cwd: "/")), "an empty key matches nothing")
    }

    // MARK: stdin

    func testGarbageAndEmptyStdinPassThrough() throws {
        try writeGate(hash: "aaaa", project: project, session: nil)
        assertPasses(try runGate(stdin: ""), "empty stdin")
        assertPasses(try runGate(stdin: "not json at all \u{0} {{{"), "garbage stdin")
        assertPasses(try runGate(stdin: "{\"session_id\":\"s9\""), "truncated JSON has no cwd")
    }

    func testTheFirstTopLevelFieldsDecideNotTextInsideToolInput() throws {
        try writeGate(hash: "aaaa", project: project, session: nil)
        // The real cwd is elsewhere; a decoy cwd sits inside the tool's input.
        let decoy = #"{"session_id":"s9","cwd":"/elsewhere/x","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls","cwd":"\#(project)"}}"#
        assertPasses(try runGate(stdin: decoy), "a cwd inside tool_input is not the call's cwd")
    }

    func testADecoySessionIdInsideToolInputIsIgnored() throws {
        try writeGate(hash: "bbbb", project: nil, session: "s1")
        let decoy = #"{"session_id":"s9","cwd":"\#(project)","tool_name":"Bash","tool_input":{"session_id":"s1"}}"#
        assertPasses(try runGate(stdin: decoy), "s9 is the call's session; the s1 in its input is text")
    }

    func testTopLevelFieldsStillMatchWhenToolInputFollows() throws {
        try writeGate(hash: "aaaa", project: project, session: nil)
        let real = #"{"session_id":"s9","cwd":"\#(project)","tool_name":"Bash","tool_input":{"cwd":"/elsewhere"}}"#
        assertStops(try runGate(stdin: real))
    }

    func testABackslashInTheCwdIsLetThrough() throws {
        // Documented in Designs/budget-caps.md §4: Page can't compare an escaped path, so it allows.
        try writeGate(hash: "aaaa", project: project, session: nil)
        assertPasses(try runGate(stdin: call(cwd: project + #"\x"#)))
    }

    // MARK: the controller's own markers

    func testTheControllersMarkersAreWhatTheHookReads() throws {
        // The real clock: the gate compares `expires` with `date +%s`, so the controller must run on it too.
        let t0 = Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970)))
        // Five days after t0, so the window is still open for the controller and for the gate.
        let resets = t0.addingTimeInterval(5 * 86400)
        let files = BudgetFiles(support: base)
        let statusDir = files.statusline
        try FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)
        func status(cost: Double, week: Double, at: Date) throws {
            let obj: [String: Any] = ["session_id": "s1", "cwd": project, "workspace": ["project_dir": project],
                                      "cost": ["total_cost_usd": cost],
                                      "rate_limits": ["seven_day": ["used_percentage": week, "resets_at": Int(resets.timeIntervalSince1970)]]]
            let url = statusDir.appendingPathComponent("s1.json")
            try JSONSerialization.data(withJSONObject: obj).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
        }
        var b = BudgetConfig()
        b.projects[project] = 25
        let controller = BudgetController(files: files)
        let busy = [BudgetLiveSession(sessionId: "s1", cwd: project, busy: true)]
        // First sight at 10%, then 40%: over the 25% budget in one step (rise 30, all of it s1's).
        try status(cost: 0, week: 10, at: t0)
        controller.refresh(now: t0, budget: b, captureOn: true, live: busy)
        try status(cost: 10, week: 40, at: t0.addingTimeInterval(60))
        let effects = controller.refresh(now: t0.addingTimeInterval(60), budget: b, captureOn: true, live: busy)
        XCTAssertTrue(effects.contains(.interrupt(sessionIds: ["s1"])))

        // The stop line is the controller's own, naming the project.
        let blocked = try runGate(stdin: call(session: "s1", cwd: project))
        XCTAssertEqual(blocked.status, 0)
        XCTAssertTrue(blocked.stdout.hasPrefix("{\"continue\":false,\"stopReason\":\"Page: proj reached its budget (25% of the week). "),
                      "the controller's project marker stops the call: \(blocked.stdout)")
        XCTAssertTrue(try runGate(stdin: call(session: "s2", cwd: project + "/sub")).stdout.contains("\"continue\":false"),
                      "and the folder below it")
        // Allowing the session (what "Let this turn finish" writes) lets its turn go on.
        controller.allowSessions(["s1"], now: t0.addingTimeInterval(70), live: busy)
        assertPasses(try runGate(stdin: call(session: "s1", cwd: project)), "allowed for one turn")
        // Raising the cap removes the marker: nothing blocks.
        b.projects[project] = 60
        controller.reevaluate(now: t0.addingTimeInterval(80), budget: b, captureOn: true, live: busy)
        XCTAssertEqual(files.markerHashes(), [])
        assertPasses(try runGate(stdin: call(session: "s2", cwd: project)), "the raised budget lets it through")
    }

    func testTheGateScriptIsExecutableInTheRepo() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: gateURL.path), gateURL.path)
        XCTAssertEqual(HookInstaller.gateScriptName, "page-budget-gate.sh")
    }
}

/// The status line wrapper (`UsageCapture.script`) run with `/bin/sh` in a temp folder.
final class BudgetStatusLineScriptTests: XCTestCase {
    private var base: URL!
    private var dir: URL!
    private var wrapper: URL { dir.appendingPathComponent("page-statusline.sh") }

    override func setUpWithError() throws {
        signal(SIGPIPE, SIG_IGN)
        base = FileManager.default.temporaryDirectory.appendingPathComponent("statusline-\(UUID().uuidString)", isDirectory: true)
        dir = base.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try UsageCapture.script.write(to: wrapper, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Runs the wrapper with `input` on stdin. `original` is the user's own status line command, if any.
    private func run(_ input: String, original: String? = nil) throws -> String {
        if let original { try original.write(to: dir.appendingPathComponent("statusline-original.txt"), atomically: true, encoding: .utf8) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [wrapper.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }

    private var statusline: URL { dir.appendingPathComponent("statusline", isDirectory: true) }

    func testSavesTheInputAndOneCopyPerSessionAt0600() throws {
        let input = #"{"session_id":"abc-123","rate_limits":{"seven_day":{"used_percentage":12}}}"#
        _ = try run(input)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("statusline-input.json")), input)
        let inputPerms = (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("statusline-input.json").path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(inputPerms, 0o600, "the latest input is private too")
        let copy = statusline.appendingPathComponent("abc-123.json")
        XCTAssertEqual(try String(contentsOf: copy), input)
        let perms = (try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: statusline.path), ["abc-123.json"],
                       "no temp file is left behind")
    }

    func testTheSessionIdIsKeptToLettersDigitsAndDashes() throws {
        _ = try run(#"{"session_id":"../../evil id"}"#)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: statusline.path), ["evilid.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("evil.json").path), "nothing written outside")
    }

    func testTheSessionIdIsCappedAt128Characters() throws {
        let long = String(repeating: "a", count: 200)
        _ = try run(#"{"session_id":"\#(long)"}"#)
        let names = try FileManager.default.contentsOfDirectory(atPath: statusline.path)
        XCTAssertEqual(names, [String(repeating: "a", count: 128) + ".json"])
    }

    func testNoSessionIdWritesNoPerSessionFile() throws {
        _ = try run(#"{"rate_limits":{"seven_day":{"used_percentage":12}}}"#)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("statusline-input.json").path),
                      "the latest input is still saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusline.path), "no statusline folder without an id")
    }

    func testAnIdWithNothingLeftWritesNoPerSessionFile() throws {
        _ = try run(#"{"session_id":"!!! ???"}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusline.path))
    }

    func testRunsTheOriginalStatusLineWithTheInput() throws {
        let input = #"{"session_id":"s1"}"#
        XCTAssertEqual(try run(input, original: "cat"), input, "the user's own command gets the same input")
    }

    func testWithoutAnOriginalNothingIsPrinted() throws {
        XCTAssertEqual(try run(#"{"session_id":"s1"}"#), "")
    }
}

/// The hook entry for the gate in `~/.claude/settings.json` (HookInstaller).
final class BudgetHookInstallTests: XCTestCase {
    private var home: URL!
    private let script = "/Applications/Page Studio.app/Contents/Resources/hooks/page-notify.sh"
    private let gateCommand = "'/Applications/Page Studio.app/Contents/Resources/hooks/page-budget-gate.sh'"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("budget-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func installer(gate: Bool = true) -> HookInstaller {
        var i = HookInstaller(homeDirectory: home, scriptPath: script)
        i.budgetGate = gate
        return i
    }

    private func gateEntries(_ entries: [(event: String, group: OrderedJSON)]) -> [(event: String, group: OrderedJSON)] {
        entries.filter { $0.event == "PreToolUse" && $0.group["matcher"]?.stringValue == HookInstaller.gateMatcher }
    }

    func testTheGateSitsBesideTheNotifyScript() {
        XCTAssertEqual(HookInstaller.gateSibling(ofScript: script),
                       "/Applications/Page Studio.app/Contents/Resources/hooks/page-budget-gate.sh")
    }

    func testClaudeGetsOneNonBlockingPreToolUseGate() throws {
        let gates = gateEntries(installer().canonicalEntries(for: .claude))
        XCTAssertEqual(gates.count, 1)
        let handler = gates.first?.group["hooks"]?.arrayValue?.first
        XCTAssertEqual(handler?["command"]?.stringValue, gateCommand, "the quoted path of the gate")
        XCTAssertEqual(handler?["type"]?.stringValue, "command")
        XCTAssertNil(handler?["statusMessage"], "silent unless it stops something")
        XCTAssertTrue(gates.first?.group.rendered().contains("\"timeout\": 5") == true)
    }

    func testCodexGetsNoGate() {
        XCTAssertEqual(gateEntries(installer().canonicalEntries(for: .codex)).count, 0)
    }

    func testTurningTheGateOffOmitsItsEntry() {
        XCTAssertEqual(gateEntries(installer(gate: false).canonicalEntries(for: .claude)).count, 0)
    }

    func testInstallAddsTheGateAndUninstallRemovesIt() throws {
        try installer().apply(try installer().planInstall(.claude))
        let installed = try String(contentsOf: installer().claudeSettingsURL, encoding: .utf8)
        XCTAssertTrue(installed.contains("page-budget-gate.sh"))
        XCTAssertTrue(installer().status(.claude).pageCommands.contains { $0.contains("page-budget-gate.sh") },
                      "Page recognises the gate as its own")

        try installer().apply(try installer().planUninstall(.claude))
        let after = try String(contentsOf: installer().claudeSettingsURL, encoding: .utf8)
        XCTAssertFalse(after.contains("page-budget-gate.sh"))
        XCTAssertFalse(after.contains("page-notify.sh"))
    }
}

/// Capture on, the wrapper is kept current: `refreshWrapper` (Designs/budget-caps.md §2).
final class BudgetStatusLineRefreshTests: XCTestCase {
    private var base: URL!
    private var home: URL!
    private var support: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("usage-refresh-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        support = base.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testAStaleWrapperIsRewrittenOnlyWhenCaptureIsOn() throws {
        let capture = UsageCapture(home: home, supportDirectory: support)
        try capture.set(true)
        XCTAssertEqual(capture.state(), .on)
        try "#!/bin/sh\necho old\n".write(to: capture.wrapperURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(capture.refreshWrapper(), "capture is on and the file differs")
        XCTAssertEqual(try String(contentsOf: capture.wrapperURL, encoding: .utf8), UsageCapture.script)
        let perms = (try FileManager.default.attributesOfItem(atPath: capture.wrapperURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700)
        XCTAssertFalse(capture.refreshWrapper(), "already current")
    }

    func testCaptureOffLeavesTheWrapperAlone() throws {
        let capture = UsageCapture(home: home, supportDirectory: support)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "#!/bin/sh\necho old\n".write(to: capture.wrapperURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(capture.state(), .off)
        XCTAssertFalse(capture.refreshWrapper())
        XCTAssertEqual(try String(contentsOf: capture.wrapperURL, encoding: .utf8), "#!/bin/sh\necho old\n")
    }

    func testTurningCaptureOffUnwrapsAndRemovesTheInput() throws {
        let capture = UsageCapture(home: home, supportDirectory: support)
        try capture.set(true)
        try "{}".write(to: capture.inputURL, atomically: true, encoding: .utf8)
        try capture.set(false)
        XCTAssertEqual(capture.state(), .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.inputURL.path))
    }
}
