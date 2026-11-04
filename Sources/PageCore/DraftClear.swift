import Foundation

/// Reading and clearing the text a person left in a session's input box, for
/// the phone's "Clear it and send" (SESSIONS-PROTOCOL.md §5 `clearDraft`).
///
/// A refused `input` with reason `draft` may carry the text Page read in the
/// box (`SessionCommandResult.draft`). If the phone's person agrees, the phone
/// sends it back in a `clearDraft`; Page reads the box again and presses
/// Backspace once per character only if the box still holds exactly that text.
///
/// `peekDraft` is the read half on its own: a reply to a page that failed with
/// reason `draft` never carried the text (that reply travels in plaintext), so
/// the phone asks for it over the sealed channel. It presses no key.
///
/// Safety rules, all enforced in `SessionInputGate.runClaudeClearDraft`: only
/// text Page could read exactly (one row, no chips or paste placeholders, at
/// most 200 characters, nothing the screen mirror would redact), never Esc,
/// Enter or a Ctrl key, no key while a prompt may be open, and the text
/// itself is never logged.
enum DraftClear {
    static let maxLength = 200
    private static let placeholderPattern = #"\[[^\]]*#[0-9]+[^\]]*\]"#

    static let changedMessage = "The text in the input box changed on your Mac, so Page left it alone."
    static let alreadyClearMessage = "Already clear"
    static let clearedMessage = "Cleared"
    static let failedMessage = "Couldn't clear the input box — clear it at the Mac"
    static let atTheMacMessage = "Clear it at the Mac"
    static let unreadableMessage = "Couldn't read the session's input box — clear it at the Mac"
    static let codexMessage = "Page can't clear the input box in this session — clear it at the Mac"

    static func unsupportedMessage(_ app: String) -> String {
        "Page can't clear the input box in \(app) — clear it at the Mac"
    }

    /// What the input box holds, as far as Page can tell.
    enum Box: Equatable {
        /// Not seen (screen unreadable, another mode, a layout Page doesn't know).
        case unreadable
        /// A prompt or menu is open instead (cmux says so itself).
        case dialog
        case empty
        /// Text Page read exactly and may report or clear (`reportable`).
        case text(String)
        /// Something is typed, but not exactly readable: several rows, an
        /// image chip, a paste placeholder, a secret, too long.
        case other
    }

    /// One Backspace per call; nil when it was sent, else the phone-safe reason it wasn't.
    typealias Backspacer = () -> String?

    /// Pure. Whether `text` is something Page reports to a phone and clears:
    /// one trimmed line of 1...200 characters with no control characters, no
    /// bracketed `#n` placeholder (`[Image #1]`, `[Pasted text #2 +9 lines]`:
    /// one Backspace removes the whole hidden paste) and nothing the screen
    /// mirror would redact (this field must not carry what that one hides).
    static func reportable(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxLength,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }),
              text.range(of: placeholderPattern, options: .regularExpression) == nil else { return false }
        return ContextRedactor.redact(text) == text
    }

    /// Pure. The box as read off the screen (`InjectionExecutor.inputBox(of:)`).
    static func classify(_ content: InjectionExecutor.ClaudeInputContent?) -> Box {
        guard let content else { return .unreadable }
        if content.isEmpty { return .empty }
        guard content.boxRows == 1, content.chips == 0 else { return .other }
        let typed = content.typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = content.plain.trimmingCharacters(in: .whitespacesAndNewlines)
        // A styled read leaves dim and grey cells out of `typed`: a hidden paste
        // placeholder, or dim text before or between the typed characters, would
        // make the Backspace count differ from what the phone confirmed. Dim text
        // is tolerated only as a ghost after what was typed.
        guard plain.range(of: placeholderPattern, options: .regularExpression) == nil,
              plain.hasPrefix(typed) else { return .other }
        return reportable(typed) ? .text(typed) : .other
    }
}

extension InjectionExecutor {
    /// The input box for `clearDraft` and `peekDraft`. cmux reports its own empty / draft /
    /// dialog state, and its screen is plain text (a dim placeholder would read
    /// as typing), so the screen is parsed only when cmux says there is a draft.
    static func draftBox(of host: TerminalHost) -> DraftClear.Box {
        switch host {
        case .cmux(let target):
            guard case .success(let client) = CmuxBridge.connect(cliPath: target.cliPath),
                  case .success(let (state, draftLength)) = client.inputStateAndLength(surface: target.surfaceId) else { return .unreadable }
            switch state {
            case .empty: return .empty
            case .dialog: return .dialog
            case .unknown: return .unreadable
            case .draft:
                let box = DraftClear.classify(inputBox(of: host))
                // cmux sees text and the screen shows none: Page can't tell which is right.
                if box == .empty { return .unreadable }
                // The screen is plain text, so a dim ghost would read as typing; cmux's own
                // count of the draft must agree (as characters, scalars or bytes, whichever it counts).
                if case .text(let t) = box, let n = draftLength,
                   ![t.count, t.unicodeScalars.count, t.utf8.count].contains(n) { return .unreadable }
                return box
            }
        case .tmux, .wezterm, .kitty, .herdr:
            return DraftClear.classify(inputBox(of: host))
        case .terminalApp, .iTerm, .unreachable, .unsupported, .unknown:
            return .unreadable
        }
    }

    /// A run of Backspaces into `host`. Only the hosts that can press a single
    /// key: Terminal.app's `do script` always adds a Return, and iTerm2's
    /// transport has no Backspace; those are refused before they get here.
    /// Never Ctrl-H or Ctrl-U, never Esc or Enter.
    static func backspacer(for host: TerminalHost) -> DraftClear.Backspacer {
        let failed = "Couldn't press Backspace in \(host.label)"
        switch host {
        case .tmux(let tmux, let pane, let inMode, _):
            return {
                // A pane in copy mode would take the key as a mode command.
                if inMode { return "tmux pane \(pane) is in copy mode — clear the input box at the Mac" }
                return ProcessRunner.run(tmux, ["send-keys", "-t", pane, "BSpace"], timeout: 3).succeeded ? nil : failed
            }
        case .wezterm(let target):
            // DEL, the byte a terminal sends for Backspace.
            return {
                let sent = WezTermBridge.sendArgs(paneId: target.paneId, key: .text("\u{7F}"))
                    .map { WezTermBridge.run(target, $0.args, stdin: $0.stdin) }
                return sent?.succeeded == true ? nil : failed
            }
        case .kitty(let target):
            return {
                let args = ["@", "--to", target.socket, "send-key", "--match", "id:\(target.windowId)", "backspace"]
                return KittyBridge.run(target, args).succeeded ? nil : failed
            }
        case .herdr(let target):
            return {
                if let why = HerdrBridge.recheck(target) { return why }
                return HerdrBridge.sendNamed(target, key: "backspace").succeeded ? nil : failed
            }
        case .cmux(let target):
            let client: CmuxBridge.Client
            switch CmuxBridge.connect(cliPath: target.cliPath) {
            case .failure(let f): return { f.detail }
            case .success(let c): client = c
            }
            return {
                // Only while cmux still sees a draft; no --force, so cmux also refuses a key into a dialog.
                guard case .success(.draft) = client.inputState(surface: target.surfaceId) else { return failed }
                if case .failure(let f) = client.sendKey(surface: target.surfaceId, key: "backspace", force: false) { return f.detail }
                return nil
            }
        case .terminalApp, .iTerm, .unreachable, .unsupported, .unknown:
            return { DraftClear.unsupportedMessage(host.label) }
        }
    }
}

extension SessionInputGate {
    /// The session and terminal a `clearDraft` or `peekDraft` acts on, or why
    /// not: resolve, status, foreground, host. Same order as `runClaudeInterrupt`.
    private static func resolveDraftTarget(sessionId: String, interventionId: String?, io: ClaudeIO)
        -> Result<(session: ClaudeLiveSession, host: InjectionExecutor.TerminalHost), SessionCommandResult> {
        let req = claudeRequest(sessionId: sessionId, clientId: "clearDraft", text: "")
        let session: ClaudeLiveSession
        let table: [ProcessRunner.ProcessInfoRow]
        switch io.resolve(req) {
        case .ended: return .failure(.refused(.ended, endedMessage))
        case .failed(let f): return .failure(.refused(.notTypable, f.detail))
        case .live(let s, let t): session = s; table = t
        }
        guard session.hasSessionFile, let rec = io.currentRecord(session.pid) else {
            return .failure(.refused(.unknownState, unknownStateMessage))
        }
        switch ClaudeSessionStatus(raw: rec.status) {
        case .waiting: return .failure(.refused(.waiting, waitingMessage, interventionId: interventionId))
        case .unknown: return .failure(.refused(.unknownState, unknownStateMessage))
        case .busy, .idle, .shell: break
        }
        guard io.isForeground(session.pid) == true else {
            return .failure(.refused(.notTypable, InjectionExecutor.notForegroundMessage))
        }
        let host = io.resolveHost(session, table)
        switch host {
        // A pane in copy mode would take the key as a mode command.
        case .tmux(_, let pane, true, _): return .failure(.refused(.notTypable, "tmux pane \(pane) is in copy mode — clear the input box at the Mac"))
        case .tmux, .cmux, .wezterm, .kitty, .herdr: break
        case .terminalApp: return .failure(.refused(.notTypable, DraftClear.unsupportedMessage("Terminal.app")))
        case .iTerm: return .failure(.refused(.notTypable, DraftClear.unsupportedMessage("iTerm2")))
        case .unsupported(let app): return .failure(.refused(.notTypable, DraftClear.unsupportedMessage(app)))
        case .unreachable(let why): return .failure(.refused(.notTypable, why))
        case .unknown: return .failure(.refused(.notTypable, "Couldn't find the session's terminal"))
        }
        if io.squadPaused(session, host) { return .failure(.refused(.notTypable, ClaudeSquad.pausedMessage)) }
        return .success((session, host))
    }

    /// The phone's look at the input box (`peekDraft`), for a reply to a
    /// page that was refused for text in the box: what `input` would have
    /// reported as `draft`, asked for again on its own. Reads the box and
    /// presses no key.
    static func runClaudePeekDraft(sessionId: String, interventionId: String?, io: ClaudeIO) -> SessionCommandResult {
        let host: InjectionExecutor.TerminalHost
        switch resolveDraftTarget(sessionId: sessionId, interventionId: interventionId, io: io) {
        case .failure(let refusal): return refusal
        case .success(let target): host = target.host
        }
        switch io.readDraftBox(host) {
        case .unreadable: return .refused(.inputUnverified, DraftClear.unreadableMessage)
        case .dialog: return .refused(.waiting, waitingMessage, interventionId: interventionId)
        case .empty: return SessionCommandResult(code: .delivered, reason: nil, detail: DraftClear.alreadyClearMessage)
        case .other: return .refused(.draft, CmuxBridge.draftDetail)
        case .text(let typed):
            var result = SessionCommandResult.refused(.draft, CmuxBridge.draftDetail)
            result.draft = typed
            return result
        }
    }

    /// The phone's "Clear it and send" (`clearDraft`): empties the input box
    /// of a Claude session, but only if it still holds exactly `text` (what a
    /// refused `input` reported as `draft`). Same order as `runClaudeInterrupt`:
    /// resolve, status, foreground, host, then the box is read, Backspace is
    /// pressed once per character with status and foreground checked before
    /// every key, and the box is read again.
    static func runClaudeClearDraft(sessionId: String, text: String, interventionId: String?, io: ClaudeIO) -> SessionCommandResult {
        guard DraftClear.reportable(text) else { return .refused(.notTypable, DraftClear.atTheMacMessage) }
        let session: ClaudeLiveSession
        let host: InjectionExecutor.TerminalHost
        switch resolveDraftTarget(sessionId: sessionId, interventionId: interventionId, io: io) {
        case .failure(let refusal): return refusal
        case .success(let target): session = target.session; host = target.host
        }

        switch io.readDraftBox(host) {
        case .unreadable: return .refused(.inputUnverified, DraftClear.unreadableMessage)
        case .dialog: return .refused(.waiting, waitingMessage, interventionId: interventionId)
        case .empty: return SessionCommandResult(code: .delivered, reason: nil, detail: DraftClear.alreadyClearMessage)
        case .other: return .refused(.draftChanged, DraftClear.changedMessage)
        case .text(let now) where now != text: return .refused(.draftChanged, DraftClear.changedMessage)
        case .text: break
        }

        let press = io.backspacer(host)
        for _ in 0..<text.count {
            // Right before each key: a prompt that opened since, or a job brought to the front since, must not get it.
            guard let again = io.currentRecord(session.pid) else { return .refused(.unknownState, unknownStateMessage) }
            switch ClaudeSessionStatus(raw: again.status) {
            case .waiting: return .refused(.waiting, waitingMessage, interventionId: interventionId)
            case .unknown: return .refused(.unknownState, unknownStateMessage)
            case .busy, .idle, .shell: break
            }
            guard io.isForeground(session.pid) == true else {
                return .refused(.notTypable, InjectionExecutor.notForegroundMessage)
            }
            if let why = press() { return .failed(why.isEmpty ? DraftClear.failedMessage : why) }
        }

        // The terminal may take a moment to redraw.
        for _ in 0..<4 {
            io.settle()
            if io.readDraftBox(host) == .empty {
                return SessionCommandResult(code: .delivered, reason: nil, detail: DraftClear.clearedMessage)
            }
        }
        return .failed(DraftClear.failedMessage)
    }
}
