import AppKit
import SwiftUI
@testable import PageCore

/// The Tower: Page's settings window. A SwiftUI view (UI/Tower) in a dark,
/// full-size-content window. The entry points the rest of the app uses are
/// unchanged: `init(coordinator:)` and `showAndFocus()`.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: Coordinator
    let store: TowerStore

    /// `copyDiagnostics` lives in AppDelegate (a notification). Pairing, the
    /// cmux setup and the hook installer are pages of this window.
    init(coordinator: Coordinator, macName: String = "this Mac",
         copyDiagnostics: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.store = TowerStore(config: coordinator.config, macName: macName)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Page Studio Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NightWatch.Palette.background.nsColor
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: NWTowerView(store: store))
        store.env = makeEnvironment(copyDiagnostics: copyDiagnostics)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeEnvironment(copyDiagnostics: @escaping () -> Void) -> TowerEnvironment {
        var env = TowerEnvironment()
        let coordinator = self.coordinator
        env.loadConfig = { Config.loadResult() }
        env.runningConfig = { coordinator.config }
        env.writeConfig = { try $0.write() }
        env.reloadConfig = { coordinator.reloadConfig() }
        env.isExecutable = { FileManager.default.isExecutableFile(atPath: $0) }
        env.findCodex = { ProcessRunner.findExecutable("codex", configured: $0) }
        env.checkHelper = { refresh, done in coordinator.checkPowerHelper(refresh: refresh, completion: done) }
        env.installHelper = { done in coordinator.installPowerHelper(completion: done) }
        env.usageCaptureState = { UsageCapture().state() }
        env.setUsageCapture = { on in try UsageCapture().set(on)?.lastPathComponent }
        env.localModelLines = { LocalActivity.menuLines(coordinator.localActivities) }
        env.probeRelay = { base, done in Self.probeRelay(base, done) }
        env.runDialog = { [weak self] spec, done in
            guard let self else { return done(spec.cancelIndex) }
            self.runDialog(spec, done)
        }
        env.showAlert = { [weak self] title, text in self?.runDialog(.notice(title, text)) { _ in } }
        env.setBudget = { [weak self] op in
            coordinator.setBudget(op) { result in
                guard result.code != .delivered else { return }
                DispatchQueue.main.async { self?.runDialog(.notice("Couldn’t save the budget", result.detail)) { _ in } }
            }
        }
        env.confirmReplaceBrokenConfig = { [weak self] info, done in
            guard let self else { return done(false) }
            self.runDialog(.confirm("config.json couldn’t be read", info, ok: "Replace config.json", tone: .warning, destructive: true)) { done($0 == 0) }
        }
        env.close = { [weak self] in self?.window?.close() }
        env.beep = { NSSound.beep() }
        env.log = { Logger.shared.log($0) }
        env.hookSource = { [weak self] in self?.hookSource }
        env.cmuxSecrets = KeychainSecretStore.cmuxSocketPassword
        env.pairing = Self.makePairingBackend(coordinator)
        env.copyLocalDiagnostics = copyDiagnostics
        env.openConfigFile = { NSWorkspace.shared.open(Config.configURL) }
        env.openLog = { NSWorkspace.shared.open(Logger.logURL) }
        env.reloadFromMenu = { coordinator.reloadConfig() }
        // Terminals page: every probe runs off the main queue; every write is a click.
        let terminalQueue = DispatchQueue(label: "ClaudePowerMode.TerminalProbe", qos: .userInitiated)
        env.probeTerminals = { sessions, done in
            terminalQueue.async {
                let snapshot = TerminalProbe.gather(sessions: sessions, probeHosts: { coordinator.probeHosts($0) })
                DispatchQueue.main.async { done(snapshot) }
            }
        }
        env.previewKitty = { KittyConfigFile.preview() }
        env.enableKitty = { KittyConfigFile.enable() }
        env.undoKitty = { KittyConfigFile.undo() }
        env.requestAutomation = { id, done in
            terminalQueue.async {
                let access = TerminalProbe.requestAutomation(id)
                DispatchQueue.main.async { done(access) }
            }
        }
        env.confirm = { [weak self] title, text, okTitle, done in
            guard let self else { return done(false) }
            self.runDialog(.confirm(title, text, ok: okTitle, tone: .info)) { done($0 == 0) }
        }
        // Widgets page: pluginkit and LaunchServices run off the main queue, and the
        // registration only on a click ("Ask macOS to find them").
        let widgetQueue = DispatchQueue(label: "ClaudePowerMode.WidgetSetup", qos: .userInitiated)
        env.probeWidgets = { done in
            widgetQueue.async {
                let status = WidgetSetup.status()
                DispatchQueue.main.async { done(status) }
            }
        }
        env.registerWidgets = { done in
            widgetQueue.async {
                let status = WidgetSetup.register()
                DispatchQueue.main.async { done(status) }
            }
        }
        env.openURL = { NSWorkspace.shared.open($0) }
        env.windowVisible = { [weak self] in self?.window?.isVisible == true }
        return env
    }

    /// GET `<relay>/health`: a Page relay answers `{"ok": true}`. Only runs
    /// when the user clicks Test.
    private static func probeRelay(_ base: URL, _ done: @escaping (String, Bool) -> Void) {
        var request = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { data, response, error in
            let message: String
            let ok: Bool
            if let error {
                message = "✗ Can’t reach it: \(error.localizedDescription)"
                ok = false
            } else if (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["ok"] as? Bool == true {
                message = "✓ Page Relay is reachable"
                ok = true
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                message = "✗ That server answered (HTTP \(code)) but isn’t a Page Relay"
                ok = false
            }
            DispatchQueue.main.async { done(message, ok) }
        }.resume()
    }

    /// A Night Watch dialog, a sheet on the Tower. Returns at once; `done` gets the button.
    private func runDialog(_ spec: NWDialogSpec, _ done: @escaping (Int) -> Void) {
        NWDialog.present(spec, over: window, completion: done)
    }

    /// The hook installer, made the first time the Phone approvals page asks
    /// (this is where `locateScript` runs).
    private lazy var hookSource: TowerHookSource = {
        let located = HookInstaller.locateScript()
        return TowerHookSource(
            installer: HookInstaller(homeDirectory: FileManager.default.homeDirectoryForCurrentUser, scriptPath: located ?? ""),
            scriptPath: located)
    }()

    /// What the pairing page reads: the running config, the pairing payload,
    /// the relay's /health, the pasteboard and the token.
    private static func makePairingBackend(_ coordinator: Coordinator) -> TowerPairingBackend {
        var backend = TowerPairingBackend()
        backend.info = {
            let cfg = coordinator.config
            if cfg.relayIsUsable, let base = cfg.relayBaseURL {
                let payload = PairingTokenManager.pairingPayloadJSON(relayBaseURL: base,
                                                                     sessionKey: PairingTokenManager.currentSessionKey())
                return .ready(base: base, payload: payload)
            }
            return .setupNeeded(reason: TowerPairingModel.setupReason(relayEnabled: cfg.relayEnabled,
                                                                      urlProblem: cfg.relayURLProblem?.message))
        }
        backend.probeHealth = { base, done in
            var request = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 8)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            URLSession.shared.dataTask(with: request) { data, response, error in
                let result = TowerPairingModel.healthText(base: base, data: data, response: response, error: error)
                DispatchQueue.main.async { done(result.text, result.ok) }
            }.resume()
        }
        backend.copy = { payload in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(payload, forType: .string)
            // The payload carries the relay token. These markers (nspasteboard.org
            // convention) ask clipboard managers not to record or sync it.
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        backend.regenerate = { PairingTokenManager.regenerate() }
        return backend
    }

    // Hook files edited elsewhere (by hand, by Claude Code) show up on return.
    func windowDidBecomeKey(_ notification: Notification) { store.windowBecameKey() }

    /// Reloads every control from disk, so Cancel always reverts and edits
    /// made to config.json by hand show up. `section` picks the page.
    func showAndFocus(section: TowerSection? = nil) {
        // A dialog is up over the form: reloading or switching page under it would
        // change what its answer applies to. Bring the window forward and leave it be.
        if window?.attachedSheet == nil { store.load(section: section) }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
