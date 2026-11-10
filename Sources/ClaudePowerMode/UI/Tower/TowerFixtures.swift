import Foundation
@testable import PageCore

/// Tower scenes for the render harness (and for tests): real
/// `Coordinator.Snapshot` and `NowModel` values, a form from a real `Config`,
/// and no environment, so nothing is read or written.
enum TowerFixtures {
    static let day = DayStats(unblockedFast: 11, decisions: 12, shipped: 7, finished: 10, calmSeconds: 4 * 3600 + 10 * 60)

    static func backends(codex: Bool = false) -> [Coordinator.BackendInfo] {
        [Coordinator.BackendInfo(id: .claude, displayName: "Claude Code", enabled: true, sessionCount: 7, activeCount: 5, waitingCount: 2),
         Coordinator.BackendInfo(id: .codex, displayName: "Codex", enabled: codex, sessionCount: codex ? 2 : 0, activeCount: 0, waitingCount: 0)]
    }

    static func usage(now: Date) -> UsageSnapshot {
        UsageSnapshot(fiveHour: .init(pct: 62, resetsAt: NightWatchFixtures.at(now, hour: 3, minute: 0)),
                      sevenDay: .init(pct: 30, resetsAt: NightWatchFixtures.at(now, hour: 23, minute: 0).addingTimeInterval(3 * 86400)),
                      updatedAt: now.addingTimeInterval(-60))
    }

    /// Board 41: 41% on battery, cutoff in 1 h 50 min, lid closed and awake, five working, two need you.
    static func board(now: Date = NightWatchFixtures.boardNow()) -> (snapshot: Coordinator.Snapshot, model: NowModel) {
        let pending = [
            NightWatchFixtures.event("bottle-flip", kind: .permission, context: "[Bash] rm -rf Builds/Dev/*.app\nDelete the dev builds",
                                     openedAt: now.addingTimeInterval(-4 * 60)),
            NightWatchFixtures.event("page", kind: .permission, context: "[Bash] swift test --filter Stuck\nRun the Stuck tests",
                                     openedAt: now.addingTimeInterval(-90))
        ]
        let snap = NightWatchFixtures.snapshot(
            sessions: NightWatchFixtures.working5,
            power: PowerSnapshot(percent: 41, onAC: false, hasBattery: true, isCharging: false),
            awake: AwakeAssertions(preventIdleSleep: true, preventSystemSleep: false),
            pending: pending,
            forecast: BatteryForecast.Estimate(percent: 41, cutoff: 10, drainPerHour: 17, minutesToCutoff: 110),
            lidClosedOnBattery: true, backends: backends(codex: true), usage: usage(now: now),
            usageHitAt: NightWatchFixtures.at(now, hour: 2, minute: 40))
        var i = NowInputs(snapshot: snap, now: now, macName: "Studio MBP", idleSeconds: 5)
        i.usage = snap.usage
        i.usageHitAt = snap.usageHitAt
        i.day = day
        i.route = NightWatchFixtures.route
        return (snap, NowModel.build(i))
    }

    /// Card glow for harness renders (`--card-glow`); the shipped default is off.
    static var cardGlow: CardGlow = .off

    /// The board's settings: cutoff 10%, pause, hold 1 h, both lid options on, resume on power at 25%.
    static func boardConfig() -> Config {
        var c = Config()
        c.lowBatteryCutoff = 10
        c.lowBatteryAction = .pause
        c.holdAwakeForPendingPageMinutes = 60
        c.keepAwakeLidClosedOnAC = true
        c.keepAwakeLidClosedOnBattery = true
        c.earlyBatteryPause = false
        c.resumeAfterBatteryRecovery = true
        c.recoveryThreshold = 25
        c.relayEnabled = true
        c.relayURL = "https://page-relay.example.workers.dev"
        c.codexBackendEnabled = true
        c.cardGlow = cardGlow
        return c
    }

    @MainActor
    static func store(section: TowerSection, config: Config = boardConfig(),
                      scene: (snapshot: Coordinator.Snapshot, model: NowModel) = board()) -> TowerStore {
        let st = TowerStore(config: config, macName: "Studio MBP")
        st.selection = section
        st.update(snapshot: scene.snapshot, model: scene.model)
        st.now = { NightWatchFixtures.boardNow() }
        st.preview(helper: .available, localLines: ["Ollama — generating · exact", "LM Studio — idle"],
                   usageCapture: TowerStore.UsageCaptureStatus(on: true), terminals: terminals(), budgetBoard: budgetBoard())
        return st
    }

    /// The week three days from its reset: one project stopped, one near its budget, one on the default.
    static func budgetBoard() -> BudgetBoard {
        func r(_ name: String, _ used: Double, _ cap: Int?, _ s: BudgetBoardRow.State) -> BudgetBoardRow {
            BudgetBoardRow(key: "/Users/studio/projects/\(name)", name: name, used: used, cap: cap, state: s)
        }
        // Shares add up to under the fixture's 30% week.
        return BudgetBoard(rows: [r("payments-api", 10.4, 10, .over), r("sensor-hub", 8.4, 10, .warn), r("page", 6.1, nil, .ok),
                                  r("bottle-flip", 3.1, 10, .ok), r("llm-play", 1.4, nil, .ok)],
                           defaultCap: 15, resetText: "resets Fri 05:12", measuring: false)
    }

    /// The Terminals page with a bit of everything: in use, ready, a blocked
    /// cmux, kitty without remote control, Terminal not checked (not running),
    /// iTerm2 not yet allowed, Herdr missing.
    static func terminals() -> TerminalProbe.Snapshot {
        typealias F = TerminalCatalog.Facts
        typealias U = TerminalCatalog.HostUse
        return TerminalProbe.Snapshot(facts: [
            .terminal: F(installed: true, use: U(), setup: .unchecked),
            .iTerm: F(installed: true, use: U(), setup: .needed("Page Studio hasn’t asked macOS for permission to control iTerm2 yet. Click Allow…")),
            .tmux: F(installed: true, use: U(typable: 3), setup: .notNeeded),
            .cmux: F(installed: true, use: U(typable: 0, blocked: 1, blocker: "cmux isn’t letting Page Studio type yet — click Set up…"), setup: .needed("cmux’s socket is set to “cmux processes only”, which keeps Page Studio out. Click Set up…")),
            .wezterm: F(installed: true, use: U(), setup: .notNeeded),
            .kitty: F(installed: true, use: U(), setup: .needed("Remote control is off in kitty. Page Studio adds two lines to kitty.conf; restart kitty after.")),
            .herdr: F(installed: false, use: U(), setup: .notNeeded),
            .claudeSquad: F(installed: true, use: U(typable: 2), setup: .notNeeded),
        ], pageAddedKittyLines: false)
    }

    /// Plugged in, odd values that no preset matches, the helper missing and wanted, Pause off.
    @MainActor
    static func acCustom(section: TowerSection) -> TowerStore {
        var c = boardConfig()
        c.lowBatteryCutoff = 12
        c.recoveryThreshold = 40
        c.recoveryRequiresAC = false
        c.holdAwakeForPendingPageMinutes = 90
        c.lowBatteryAction = .off
        let now = NightWatchFixtures.boardNow()
        let snap = NightWatchFixtures.snapshot(
            sessions: NightWatchFixtures.working5,
            power: PowerSnapshot(percent: 88, onAC: true, hasBattery: true, isCharging: true),
            backends: backends())
        var i = NowInputs(snapshot: snap, now: now, macName: "Studio MBP", idleSeconds: 5)
        i.day = day
        let st = store(section: section, config: c, scene: (snap, NowModel.build(i)))
        st.preview(helper: .missing)
        return st
    }
}
