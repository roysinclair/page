import XCTest
@testable import PageCore

/// The bundle folder moved from Page.app to Page Studio.app: hook entries
/// that run the old bundle's script are pointed at the new one, and nothing
/// else in the file changes.
final class HookBundleMigrationTests: XCTestCase {
    var home: URL!
    let oldScript = "/Applications/Page.app/Contents/Resources/hooks/page-notify.sh"
    let newScript = "/Applications/Page Studio.app/Contents/Resources/hooks/page-notify.sh"
    var installer: HookInstaller { HookInstaller(homeDirectory: home, scriptPath: newScript) }
    var oldInstaller: HookInstaller { HookInstaller(homeDirectory: home, scriptPath: oldScript) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hookmove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private var settings: URL { home.appendingPathComponent(".claude/settings.json") }
    private var codexHooks: URL { home.appendingPathComponent(".codex/hooks.json") }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func backups(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".page-backup-") }
    }

    func testPaths() {
        XCTAssertEqual(HookInstaller.legacyScriptPaths(home: "/Users/sam"),
                       [oldScript, "/Users/sam/Applications/Page.app/Contents/Resources/hooks/page-notify.sh"])
        XCTAssertTrue(HookInstaller.isInstalledBundleScript(newScript, home: "/Users/sam"))
        XCTAssertTrue(HookInstaller.isInstalledBundleScript("/Users/sam/Applications/Page Studio.app/Contents/Resources/hooks/page-notify.sh", home: "/Users/sam"))
        XCTAssertFalse(HookInstaller.isInstalledBundleScript("/Users/sam/src/page/Page Studio.app/Contents/Resources/hooks/page-notify.sh", home: "/Users/sam"))
        XCTAssertFalse(HookInstaller.isInstalledBundleScript(oldScript, home: "/Users/sam"))
    }

    func testMovedCommandMatchesOnlyTheExactScript() {
        let q = "'\(oldScript)'"
        let nq = "'\(newScript)'"
        XCTAssertEqual(HookInstaller.movedCommand(q, from: oldScript, to: newScript), nq)
        XCTAssertEqual(HookInstaller.movedCommand(q + " --codex --agent-timeout 570", from: oldScript, to: newScript),
                       nq + " --codex --agent-timeout 570")
        XCTAssertEqual(HookInstaller.movedCommand(oldScript + " --agent-timeout 570", from: oldScript, to: newScript),
                       nq + " --agent-timeout 570", "a bare (unquoted) command written by hand")
        for other in [q + "x", "'\(oldScript).bak'", oldScript + "2", "bash " + q, "'/Users/me/.claude/hooks/page-notify.sh'",
                      "'/Applications/Page.app/Contents/Resources/hooks/other.sh'", "echo '\(oldScript)'"] {
            XCTAssertNil(HookInstaller.movedCommand(other, from: oldScript, to: newScript), other)
        }
    }

    /// A Claude Code file the old app installed into, plus things that must
    /// stay: another tool's hook, a manual --install-hook copy elsewhere,
    /// a near-miss path and a permission rule naming the old script.
    func testMovesOnlyOldBundleEntriesWithBackup() throws {
        try oldInstaller.apply(try oldInstaller.planInstall(.claude))
        var root = try OrderedJSON.parse(try read(settings))
        root = try HookInstaller.addingEntries([
            ("PreToolUse", .object([.init("matcher", .str("Bash")),
                                    .init("hooks", .array([.object([.init("type", .str("command")),
                                                                    .init("command", .str("/usr/local/bin/other-guard"))])]))])),
            ("Stop", .object([.init("hooks", .array([.object([.init("type", .str("command")),
                                                              .init("command", .str("'\(oldScript).bak'"))])]))]))
        ], to: root)
        guard var members = root.objectMembers else { return XCTFail() }
        members.insert(.init("permissions", .object([.init("allow", .array([.str("Bash(\(oldScript))")]))])), at: 0)
        let original = OrderedJSON.object(members).rendered() + "\n"
        try Data(original.utf8).write(to: settings)

        let outcomes = HookBundleMigration.run(installer: installer, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.agent, .claude)
        XCTAssertNil(outcomes.first?.error)
        let backup = try XCTUnwrap(outcomes.first?.backup)
        XCTAssertEqual(try read(URL(fileURLWithPath: backup)), original, "the old file is backed up first")
        XCTAssertEqual(try backups(in: home.appendingPathComponent(".claude")).count, 1)

        // Exactly the three Page commands changed; every other byte is the same.
        let expected = original.replacingOccurrences(of: "\"'\(oldScript)'", with: "\"'\(newScript)'")
        XCTAssertEqual(try read(settings), expected)
        XCTAssertEqual(try read(settings).components(separatedBy: newScript).count - 1, 3)
        XCTAssertTrue(try read(settings).contains("Bash(\(oldScript))"))
        XCTAssertTrue(try read(settings).contains("'\(oldScript).bak'"))
        XCTAssertTrue(try read(settings).contains("/usr/local/bin/other-guard"))
        XCTAssertEqual(installer.status(.claude).pageCommands.filter { $0.hasPrefix("'\(oldScript)'") }, [])

        // Idempotent: nothing more to do, no second backup.
        XCTAssertEqual(HookBundleMigration.run(installer: installer), [])
        XCTAssertEqual(try backups(in: home.appendingPathComponent(".claude")).count, 1)
    }

    func testMovedEntriesAreCurrent() throws {
        try oldInstaller.apply(try oldInstaller.planInstall(.claude))
        XCTAssertEqual(installer.status(.claude).state, .needsUpdate, "the old path reads as out of date")
        _ = HookBundleMigration.run(installer: installer)
        XCTAssertEqual(installer.status(.claude).state, .installed)
    }

    func testCodexEntriesKeepTheirArguments() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try oldInstaller.apply(try oldInstaller.planInstall(.codex, codexStop: true))
        let outcomes = HookBundleMigration.run(installer: installer)
        XCTAssertEqual(outcomes.map(\.agent), [.codex], "no Claude file: nothing to do there")
        XCTAssertEqual(installer.status(.codex).state, .installed)
        XCTAssertTrue(installer.status(.codex).codexStopEnabled)
        XCTAssertTrue(try read(codexHooks).contains("'\(newScript)' --codex --agent-timeout \(HookInstaller.blockingTimeout)"))
        XCTAssertTrue(HookBundleMigration.describe(outcomes[0]).contains("/hooks"), "Codex must be told to trust the changed hook")
    }

    func testOldCopyInHomeApplicationsIsMovedToo() throws {
        let homeOld = home.path + "/Applications/Page.app/Contents/Resources/hooks/page-notify.sh"
        let old = HookInstaller(homeDirectory: home, scriptPath: homeOld)
        try old.apply(try old.planInstall(.claude))
        XCTAssertEqual(HookBundleMigration.run(installer: installer).count, 1)
        XCTAssertFalse(try read(settings).contains("Page.app"))
    }

    func testOnlyAnInstalledCopyTakesTheHooksOver() throws {
        try oldInstaller.apply(try oldInstaller.planInstall(.claude))
        let before = try read(settings)
        for path in ["/Users/me/src/page/Page Studio.app/Contents/Resources/hooks/page-notify.sh",
                     "/Volumes/Page Studio/Page Studio.app/Contents/Resources/hooks/page-notify.sh",
                     "/Users/me/src/page/hooks/page-notify.sh"] {
            XCTAssertEqual(HookBundleMigration.run(installer: HookInstaller(homeDirectory: home, scriptPath: path)), [], path)
        }
        XCTAssertEqual(try read(settings), before)
    }

    func testInvalidFileIsLeftAloneAndReported() throws {
        let bad = "{ \"hooks\": { \"Notification\": [ { \"hooks\": [ { \"command\": \"'\(oldScript)'\" } ] } ] }, // x\n}"
        try Data(bad.utf8).write(to: settings)
        let outcomes = HookBundleMigration.run(installer: installer)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNotNil(outcomes.first?.error)
        XCTAssertEqual(try read(settings), bad)
        XCTAssertEqual(try backups(in: home.appendingPathComponent(".claude")).count, 0)
    }

    func testNothingToMoveWritesNothing() throws {
        try installer.apply(try installer.planInstall(.claude))
        let before = try read(settings)
        XCTAssertEqual(HookBundleMigration.run(installer: installer), [])
        XCTAssertEqual(try read(settings), before)
    }
}
