import XCTest
@testable import PageCore

// Regression tests for the power / relay hardening fixes (PWR-1, PWR-9,
// CONC-2, synthetic-input presence). SleepGuard and BatteryPolicy cases live
// in PowerTests.swift next to their fakes.

private func agentSession(_ id: String, backend: AgentBackendID = .claude, state: AgentSessionState,
                          flags: [String] = []) -> AgentSession {
    AgentSession(backend: backend, sessionId: id, cwd: "/tmp/\(id)", title: id, source: .terminal,
                 state: state, lastActivityAt: nil, activeFlags: flags, supportsRemoteReply: true)
}

private func snap(_ backend: AgentBackendID, sessions: [AgentSession] = [], wantsPower: Bool = false,
                  pending: [InterventionEvent] = []) -> AgentBackendSnapshot {
    AgentBackendSnapshot(backendID: backend, displayName: backend.rawValue, sessions: sessions,
                         wantsPowerAssertion: wantsPower, pendingInterventions: pending)
}

private func page(_ id: String, session: String, kind: InterventionKind,
                  backend: AgentBackendID = .claude) -> InterventionEvent {
    InterventionEvent(id: id, sessionId: session, cwd: "/tmp/\(session)", projectName: session, kind: kind,
                      openedAt: Date(timeIntervalSince1970: 1_800_000_000), context: "ctx", transcriptPath: "",
                      backend: backend)
}

final class AgentsWorkingTests: XCTestCase {
    // PWR-1: holds (rate-limit reset, pending page, waiting prompt) want the
    // assertion but are not "working".
    func testOnlyMidTurnSessionsCountAsWorking() {
        XCTAssertFalse(Coordinator.agentsWorking([]))
        XCTAssertFalse(Coordinator.agentsWorking([
            snap(.claude, sessions: [agentSession("a", state: .rateLimited)], wantsPower: true)
        ]), "holding through a rate-limit reset")
        XCTAssertFalse(Coordinator.agentsWorking([
            snap(.claude, sessions: [agentSession("a", state: .idle)], wantsPower: true,
                 pending: [page("p", session: "a", kind: .idle)])
        ]), "holding for a pending page")
        XCTAssertFalse(Coordinator.agentsWorking([
            snap(.codex, sessions: [agentSession("t", backend: .codex, state: .waitingOnApproval, flags: ["waitingOnApproval"]),
                                    agentSession("u", backend: .codex, state: .waitingOnUser)], wantsPower: true)
        ]), "Codex waiting on the user")
        XCTAssertFalse(Coordinator.agentsWorking([
            snap(.codex, sessions: [agentSession("t", backend: .codex, state: .active, flags: ["waitingOnApproval"])])
        ]), "an active-but-waiting thread")
        XCTAssertTrue(Coordinator.agentsWorking([
            snap(.claude, sessions: [agentSession("a", state: .idle)]),
            snap(.codex, sessions: [agentSession("t", backend: .codex, state: .active)])
        ]))
        XCTAssertTrue(Coordinator.agentsWorking([
            snap(.claude, sessions: [agentSession("a", state: .active, flags: ["busy"])])
        ]))
    }
}

final class PowerReadingFilterTests: XCTestCase {
    private let bat = PowerSnapshot(percent: 8, onAC: false, hasBattery: true, isCharging: false)

    // PWR-9: one failed IOPS read must not look like "battery gone".
    func testTransientNoBatteryReadingIsIgnored() {
        var f = PowerReadingFilter()
        XCTAssertEqual(f.filter(bat), bat)
        XCTAssertEqual(f.filter(.noBattery), bat)
        XCTAssertEqual(f.filter(.noBattery), bat)
        XCTAssertEqual(f.filter(bat), bat, "a real reading resets the streak")
        XCTAssertEqual(f.filter(.noBattery), bat)
        XCTAssertEqual(f.filter(.noBattery), bat)
        XCTAssertEqual(f.filter(.noBattery), .noBattery, "three in a row: the battery (UPS) really is gone")
        XCTAssertEqual(f.filter(.noBattery), .noBattery)
    }

    func testDesktopPassesThrough() {
        var f = PowerReadingFilter()
        XCTAssertEqual(f.filter(.noBattery), .noBattery)
        XCTAssertEqual(f.filter(.noBattery), .noBattery)
    }

    /// End to end with the policy: a glitch while drained must not "recover"
    /// (which would type "Power is back" into paused sessions at 8%).
    func testGlitchWhileTrippedDoesNotRecover() {
        let s = BatteryPolicy.Settings(cutoff: 10, recovery: 25, recoveryRequiresAC: true, action: .pause,
                                       graceSeconds: 90, resumeAfterRecovery: true)
        var policy = BatteryPolicy()
        var f = PowerReadingFilter()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = policy.observe(f.filter(bat), settings: s, now: t0)
        XCTAssertEqual(policy.phase, .grace)
        let effects = policy.observe(f.filter(.noBattery), settings: s, now: t0.addingTimeInterval(15))
        XCTAssertFalse(effects.contains { if case .recovered = $0 { return true }; return false })
        XCTAssertEqual(policy.phase, .grace)
    }
}

final class RelayResendTests: XCTestCase {
    // CONC-2: a new relay channel (token / Worker URL) gets the open pages
    // again, with the backends' first-send gates applied.
    func testPagesToResendAppliesGates() {
        let approval = page("a-permission-1", session: "a", kind: .permission)
        let idle = page("b-idle-1", session: "b", kind: .idle)
        let pausedIdle = page("c-idle-1", session: "c", kind: .idle)
        let hookOwned = page("hook-abc-1-2", session: "d", kind: .question)
        let replied = page("e-question-1", session: "e", kind: .question)
        let codexIdle = page("codex-t-idle", session: "t", kind: .idle, backend: .codex)
        let codexHeldIdle = page("codex-h-idle", session: "h", kind: .idle, backend: .codex)
        let snaps = [
            snap(.claude, pending: [approval, idle, pausedIdle, hookOwned, replied, approval]),
            snap(.codex, pending: [codexIdle, codexHeldIdle])
        ]
        let away = Coordinator.pagesToResend(snaps, excludedIds: [replied.id],
                                             pausedSessionKeys: ["claude|c"], hookHeldSessionIds: ["h"],
                                             userAtMac: false)
        XCTAssertEqual(away.map(\.id), [approval.id, idle.id, codexIdle.id])

        let atMac = Coordinator.pagesToResend(snaps, excludedIds: [replied.id],
                                              pausedSessionKeys: ["claude|c"], hookHeldSessionIds: ["h"],
                                              userAtMac: true)
        XCTAssertEqual(atMac.map(\.id), [approval.id], "idle pages wait while the user is at your computer")
    }
}

/// UserPresence consults SyntheticInput (the Codex path's marker) rather
/// than keeping its own record; the rule matches the hook's.
final class UserPresenceSyntheticInputTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testPagesOwnKeystrokeReadsAsAway() {
        // Page's Return at t0; 1 s later the counter says 1 s.
        XCTAssertEqual(UserPresence.effectiveIdle(raw: 1, now: t0.addingTimeInterval(1), syntheticAt: t0), .infinity)
        // Within the 3 s tolerance either side (whole-second marker times).
        XCTAssertEqual(UserPresence.effectiveIdle(raw: 0.2, now: t0.addingTimeInterval(3), syntheticAt: t0), .infinity)
        XCTAssertEqual(UserPresence.effectiveIdle(raw: 4, now: t0.addingTimeInterval(1), syntheticAt: t0), .infinity)
        // A real key press 5 s after the synthetic one counts.
        XCTAssertEqual(UserPresence.effectiveIdle(raw: 1, now: t0.addingTimeInterval(6), syntheticAt: t0), 1)
        // Input well before the keystroke is the user's own.
        XCTAssertEqual(UserPresence.effectiveIdle(raw: 30, now: t0.addingTimeInterval(1), syntheticAt: t0), 30)
        // No synthetic input recorded, or an unknown counter: unchanged.
        XCTAssertEqual(UserPresence.effectiveIdle(raw: 0.5, now: t0, syntheticAt: nil), 0.5)
        XCTAssertEqual(UserPresence.effectiveIdle(raw: .infinity, now: t0, syntheticAt: t0), .infinity)
    }

    /// Same decision as `SyntheticInput.explainsIdleReset` (the single
    /// source of truth) for every offset around the marker.
    func testAgreesWithSyntheticInputRule() {
        for offset in stride(from: -6.0, through: 6.0, by: 0.5) {
            let now = t0.addingTimeInterval(10)
            let raw = now.timeIntervalSince(t0.addingTimeInterval(offset))
            let explained = SyntheticInput.explainsIdleReset(idleSeconds: raw, now: now, at: t0)
            XCTAssertEqual(UserPresence.effectiveIdle(raw: raw, now: now, syntheticAt: t0) == .infinity, explained,
                           "offset \(offset)")
        }
    }
}

/// install.sh is never executed here: functions are extracted and run with
/// a temporary HOME, or the text is checked.
final class InstallScriptTests: XCTestCase {
    private var installSh: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("install.sh")
    }

    private func function(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "\n\(name)() {\n") else { return nil }
        guard let end = text.range(of: "\n}\n", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    // L4: uninstall must notice app-installed hook entries (Claude and Codex).
    func testLeftoverHookDetection() throws {
        let text = try String(contentsOf: installSh, encoding: .utf8)
        let fn = try XCTUnwrap(function("check_leftover_hooks", in: text))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("page-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        func run() -> ProcessRunner.Result {
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            return ProcessRunner.run("/bin/bash", ["-c", "APP_DEST='/Applications/Page Studio.app'\n\(fn)\ncheck_leftover_hooks"],
                                     timeout: 10, environment: env)
        }
        XCTAssertTrue(run().succeeded, "no files: nothing left over")
        try #"{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"'/Users/x/.claude/hooks/page-notify.sh'"}]}]}}"#
            .write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(run().succeeded, "the --install-hook copy survives an uninstall")
        try #"{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"'/Applications/Page Studio.app/Contents/Resources/hooks/page-notify.sh' --codex"}]}]}}"#
            .write(to: home.appendingPathComponent(".codex/hooks.json"), atomically: true, encoding: .utf8)
        let r = run()
        XCTAssertFalse(r.succeeded)
        XCTAssertTrue(r.stderr.contains(".codex/hooks.json"), r.stderr)
    }

    // The bundle folder moved from Page.app to Page Studio.app: an install
    // points the hooks at the new folder before it removes the old one, and
    // keeps the old one while any hook entry still runs its script.
    func testOldBundleMigration() throws {
        let text = try String(contentsOf: installSh, encoding: .utf8)
        let fns = try ["safe_rm_app", "check_leftover_hooks", "migrate_old_bundle"].map { try XCTUnwrap(function($0, in: text), $0) }
        XCTAssertTrue(text.contains("OLD_PAGE_APPS=(\"/Applications/Page.app\" \"$HOME/Applications/Page.app\")"))
        XCTAssertTrue(text.contains("APP_DEST=\"/Applications/$APP_NAME\""))
        XCTAssertTrue(text.contains("APP_NAME=\"Page Studio.app\""))
        // In the install flow: copy the new bundle, then migrate, then write the LaunchAgent.
        func at(_ s: String) throws -> String.Index { try XCTUnwrap(text.range(of: s, options: .backwards), s).lowerBound }
        XCTAssertLessThan(try at("cp -R \"$APP_SRC\" \"$APP_DEST\""), try at("\nmigrate_old_bundle\n"))
        XCTAssertLessThan(try at("\nmigrate_old_bundle\n"), try at("echo \"==> Writing LaunchAgent"))

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("page-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let old = home.appendingPathComponent("Applications/Page.app")
        let new = home.appendingPathComponent("Applications/Page Studio.app")
        let oldScript = old.path + "/Contents/Resources/hooks/page-notify.sh"
        let newScript = new.path + "/Contents/Resources/hooks/page-notify.sh"
        let settings = home.appendingPathComponent(".claude/settings.json")
        let called = home.appendingPathComponent("called")
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: new.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)

        /// `fake` stands in for the installed app's --migrate-hook-paths.
        func run(fake: String) throws -> ProcessRunner.Result {
            try fm.createDirectory(at: old.appendingPathComponent("Contents/Resources/hooks"), withIntermediateDirectories: true)
            let exe = new.appendingPathComponent("Contents/MacOS/Page")
            try ("#!/bin/bash\n[[ \"$1\" == --migrate-hook-paths ]] || exit 9\ntouch \"$HOME/called\"\n" + fake + "\n")
                .write(to: exe, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            try? fm.removeItem(at: called)
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            let script = """
            set -euo pipefail
            cd "$HOME"
            APP_DEST="$HOME/Applications/Page Studio.app"
            BUNDLE_NAME=Page
            OLD_PAGE_APPS=("$HOME/Applications/Page.app")
            LSREGISTER=true
            pluginkit() { :; }
            \(fns.joined(separator: "\n"))
            migrate_old_bundle
            """
            return ProcessRunner.run("/bin/bash", ["-c", script], timeout: 20, environment: env)
        }
        let oldEntry = #"{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"'"# + oldScript + #"'"}]}]}}"#

        // No hook names the old bundle: the app isn't asked, the old bundle goes.
        try #"{"hooks":{}}"#.write(to: settings, atomically: true, encoding: .utf8)
        var r = try run(fake: "exit 0")
        XCTAssertTrue(r.succeeded, r.stderr)
        XCTAssertFalse(fm.fileExists(atPath: called.path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))

        // The app moves them: the old bundle goes.
        try oldEntry.write(to: settings, atomically: true, encoding: .utf8)
        r = try run(fake: "sed -i.bak 's#\(oldScript)#\(newScript)#' \"$HOME/.claude/settings.json\"")
        XCTAssertTrue(r.succeeded, r.stderr)
        XCTAssertTrue(fm.fileExists(atPath: called.path))
        XCTAssertTrue(try String(contentsOf: settings, encoding: .utf8).contains(newScript))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: new.path))

        // The app can't move them (it fails, or leaves an entry): the old bundle stays.
        for fake in ["echo nope >&2; exit 1", "exit 0"] {
            try oldEntry.write(to: settings, atomically: true, encoding: .utf8)
            r = try run(fake: fake)
            XCTAssertTrue(r.succeeded, r.stderr)
            XCTAssertTrue(fm.fileExists(atPath: old.path), fake)
            XCTAssertTrue(r.stderr.contains("Kept"), r.stderr)
            XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), oldEntry)
        }
    }

    func testSafeRemoveRefusesOddPaths() throws {
        let text = try String(contentsOf: installSh, encoding: .utf8)
        let fn = try XCTUnwrap(function("safe_rm_app", in: text))
        for bad in ["/", "/Applications", "/Applications/../Users/x.app", "/tmp/Page.app", "/Users/x/Page.app"] {
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = "/Users/nobody-\(UUID().uuidString)"
            let r = ProcessRunner.run("/bin/bash", ["-c", "cd /\n\(fn)\nsafe_rm_app '\(bad)'"], timeout: 10, environment: env)
            XCTAssertFalse(r.succeeded, bad)
        }
    }

    // L1: the printed snippet matches what the in-app installer writes.
    func testHookSnippetTimeoutsMatchTheApp() throws {
        let text = try String(contentsOf: installSh, encoding: .utf8)
        let fn = try XCTUnwrap(function("install_hook", in: text))
        XCTAssertTrue(fn.contains("\"timeout\": \(HookInstaller.blockingTimeout)"))
        XCTAssertTrue(fn.contains("\"timeout\": \(HookInstaller.notificationTimeout)"))
        XCTAssertTrue(fn.contains("\"matcher\": \"\(HookInstaller.questionMatcher)\""))
        XCTAssertTrue(fn.contains("\"PermissionRequest\""))
        XCTAssertFalse(fn.contains("Bash|Edit|Write"), "no legacy blocking-every-tool example")
        XCTAssertGreaterThan(HookInstaller.blockingTimeout, HookInstaller.hookWaitSeconds)
    }

    // PWR-2: Page is stopped before the flag is cleared, and the flag is
    // cleared again after the rule (the only way to re-set it) is gone.
    func testDisablePowerHelpersOrdering() throws {
        let text = try String(contentsOf: installSh, encoding: .utf8)
        let fn = try XCTUnwrap(function("disable_power_helpers", in: text))
        func at(_ s: String) throws -> String.Index { try XCTUnwrap(fn.range(of: s), s).lowerBound }
        XCTAssertLessThan(try at("stop_page_processes"), try at("clear_disablesleep"))
        XCTAssertLessThan(try at("clear_disablesleep"), try at("sudo rm -f \"$SUDOERS_FILE\""))
        XCTAssertLessThan(try at("sudo rm -f \"$SUDOERS_FILE\""), try at("sudo /usr/bin/pmset -a disablesleep 0"))
        XCTAssertTrue(ProcessRunner.run("/bin/bash", ["-n", installSh.path]).succeeded, "install.sh parses")
    }
}
