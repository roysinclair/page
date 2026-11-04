import XCTest
@testable import PageCore

/// `clearDraft` and the `draft` field of a refused `input`: what Page reads in
/// the input box, what it will report, and the sequence of Backspaces, with the
/// registry and the terminal faked. Nothing here types into a real terminal.
final class DraftClearTests: XCTestCase {
    typealias Gate = SessionInputGate
    private let sid = "6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90"
    private let tmux = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/t", paneId: "%3", inMode: false)

    private func live(status: ClaudeSessionStatus = .idle) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 4242, sessionId: sid, cwd: "/tmp/p", status: status, statusUpdatedAt: nil,
                          tty: "ttys003", hasSessionFile: true)
    }

    private let rule = String(repeating: "─", count: 40)
    private func screen(_ rows: [String]) -> String {
        (["● Done."] + [rule] + rows + [rule, "  ? for shortcuts"]).joined(separator: "\n")
    }
    private func content(_ rows: [String], styled: Bool = false) -> InjectionExecutor.ClaudeInputContent? {
        InjectionExecutor.claudeInputContent(screen: screen(rows), styled: styled)
    }

    // MARK: what Page will report

    func testReportableIsOneCleanLineOfAtMost200Characters() {
        XCTAssertTrue(DraftClear.reportable("0"))
        XCTAssertTrue(DraftClear.reportable("fix the flaky test in Foo.swift"))
        XCTAssertTrue(DraftClear.reportable(String(repeating: "a", count: 200)))
        XCTAssertFalse(DraftClear.reportable(String(repeating: "a", count: 201)))
        XCTAssertFalse(DraftClear.reportable(""))
        XCTAssertFalse(DraftClear.reportable(" padded "), "the computer reports trimmed text")
        XCTAssertFalse(DraftClear.reportable("two\nlines"))
        XCTAssertFalse(DraftClear.reportable("tab\there"))
        XCTAssertFalse(DraftClear.reportable("[Pasted text #1 +14 lines]"), "one Backspace deletes the whole paste")
        XCTAssertFalse(DraftClear.reportable("look at [Image #2]"))
        XCTAssertFalse(DraftClear.reportable("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEF"),
                       "what the screen mirror would redact is not sent in this field either")
    }

    func testTheBoxIsClassifiedFromTheScreen() {
        XCTAssertEqual(DraftClear.classify(nil), .unreadable)
        XCTAssertEqual(DraftClear.classify(content(["> "])), .empty)
        XCTAssertEqual(DraftClear.classify(content(["> 0"])), .text("0"))
        XCTAssertEqual(DraftClear.classify(content(["❯ run the tests  "])), .text("run the tests"))
        // A wrapped or multi-line draft is never one exact line.
        XCTAssertEqual(DraftClear.classify(content(["> first line", "  second line"])), .other)
        XCTAssertEqual(DraftClear.classify(content(["> first line", "  "])), .other, "a trailing blank row is a newline")
        XCTAssertEqual(DraftClear.classify(content(["> [Image #1]"])), .other)
        XCTAssertEqual(DraftClear.classify(content(["> [Pasted text #1 +9 lines]"])), .other)
        XCTAssertEqual(DraftClear.classify(content(["> " + String(repeating: "x", count: 201)])), .other)
    }

    func testDimSuggestionsAreNotADraft() {
        let dim = "\u{1B}[2mTry \"fix lint errors\"\u{1B}[22m"
        XCTAssertEqual(DraftClear.classify(content(["> " + dim], styled: true)), .empty)
        XCTAssertEqual(DraftClear.classify(content(["> 0" + dim], styled: true)), .text("0"))
    }

    func testHiddenOrLeadingDimCellsAreNotADraft() {
        let dim = "\u{1B}[2m", grey = "\u{1B}[90m", off = "\u{1B}[0m"
        // A dim paste placeholder left out of `typed` must not be deleted unseen.
        XCTAssertEqual(DraftClear.classify(content(["> hello " + dim + "[Pasted text #1 +9 lines]" + off], styled: true)), .other)
        XCTAssertEqual(DraftClear.classify(content(["> " + grey + "[Pasted text #1 +9 lines]" + off + " hello"], styled: true)), .other)
        // Dim text before the typed characters changes the Backspace count.
        XCTAssertEqual(DraftClear.classify(content(["> " + dim + "ab " + off + "hello"], styled: true)), .other)
    }

    // MARK: the result field

    func testTheDraftFieldRidesOnlyWithReasonDraft() {
        var r = SessionCommandResult.refused(.draft, CmuxBridge.draftDetail)
        XCTAssertNil(r.fields(clientId: "c")["draft"])
        r.draft = "0"
        XCTAssertEqual(r.fields(clientId: "c")["draft"] as? String, "0")
        XCTAssertEqual(r.fields(clientId: "c")["reason"] as? String, "draft")
        var other = SessionCommandResult.refused(.inputUnverified, InjectionExecutor.inputUnverifiedMessage)
        other.draft = "0"
        XCTAssertNil(other.fields(clientId: "c")["draft"])
        XCTAssertEqual(other.fields(clientId: "c")["reason"] as? String, "input_unverified")
        XCTAssertEqual(SessionCommandResult.refused(.draftChanged, DraftClear.changedMessage).fields(clientId: "c")["reason"] as? String,
                       "draft_changed")
    }

    // MARK: a refused input reports what it read

    private final class World {
        var status: String? = "idle"
        var foreground: Bool? = true
        var host: InjectionExecutor.TerminalHost = .unknown
        var deliverDetail = CmuxBridge.draftDetail
        /// What the box reads, in order; the last repeats.
        var boxes: [DraftClear.Box] = [.text("0")]
        var reads = 0
        var presses = 0
        /// Status after this many presses (a menu that opens mid-run).
        var statusAfterPress: (Int, String)?
        var pressFails = false
        /// The box once every key was sent.
        var afterKeys: DraftClear.Box = .empty

        var io: SessionInputGate.ClaudeIO {
            let target = InjectionExecutor.ClaudeTarget.live(
                ClaudeLiveSession(pid: 4242, sessionId: "6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90", cwd: "/tmp/p", status: .idle,
                                  statusUpdatedAt: nil, tty: "ttys003", hasSessionFile: true),
                [ProcessRunner.ProcessInfoRow(pid: 4242, ppid: 1, tty: "ttys003", command: "claude")])
            return SessionInputGate.ClaudeIO(
                resolve: { _ in target },
                currentRecord: { pid in
                    if let (n, s) = self.statusAfterPress, self.presses >= n { return ClaudeSessionRecord(pid: pid, status: s) }
                    return self.status.map { ClaudeSessionRecord(pid: pid, status: $0) }
                },
                resolveHost: { _, _ in self.host },
                deliver: { _, _, _ in InjectionResult(method: .tmux, success: false, output: "x", detail: self.deliverDetail) },
                isForeground: { _ in self.foreground },
                sendInterrupt: { _ in InjectionResult(method: .tmux, success: true, output: "ok") },
                readDraftBox: { _ in
                    self.reads += 1
                    if self.presses > 0 && self.pressesDone { return self.afterKeys }
                    return self.boxes[min(self.reads - 1, self.boxes.count - 1)]
                },
                backspacer: { _ in { self.presses += 1; return self.pressFails ? "Couldn't press Backspace" : nil } },
                settle: {})
        }
        var expectedPresses = 0
        var pressesDone: Bool { presses >= expectedPresses }
    }

    private func world(_ text: String = "0", host: InjectionExecutor.TerminalHost? = nil) -> World {
        let w = World()
        w.host = host ?? tmux
        w.boxes = [.text(text)]
        w.expectedPresses = text.count
        return w
    }

    private func input(_ w: World) -> SessionCommandResult {
        Gate.runClaudeInput(sessionId: sid, clientId: "c1", text: "run the tests", interventionId: nil, io: w.io)
    }

    private func clear(_ w: World, _ text: String = "0") -> SessionCommandResult {
        Gate.runClaudeClearDraft(sessionId: sid, text: text, interventionId: "p1", io: w.io)
    }

    func testARefusedInputCarriesTheTextItRead() {
        let w = world("0")
        let r = input(w)
        XCTAssertEqual(r.reason, .draft)
        XCTAssertEqual(r.draft, "0")
        XCTAssertEqual(r.fields(clientId: "c1")["draft"] as? String, "0")
    }

    func testNoDraftFieldWhenPageCouldNotReadItExactly() {
        for box in [DraftClear.Box.unreadable, .other, .empty, .dialog] {
            let w = world("0")
            w.boxes = [box]
            let r = input(w)
            XCTAssertEqual(r.reason, .draft, "\(box)")
            XCTAssertNil(r.draft, "\(box)")
            XCTAssertNil(r.fields(clientId: "c1")["draft"])
        }
        // A box Page couldn't see is not a draft at all.
        let unseen = world("0")
        unseen.deliverDetail = InjectionExecutor.inputUnverifiedMessage
        let r = input(unseen)
        XCTAssertEqual(r.reason, .inputUnverified)
        XCTAssertNil(r.draft)
        XCTAssertEqual(unseen.reads, 0)
    }

    // MARK: clearDraft

    func testClearsExactlyOneBackspacePerCharacter() {
        for text in ["0", "hello", "naïve 👍🏽 ok", String(repeating: "z", count: 200)] {
            let w = world(text)
            let r = clear(w, text)
            XCTAssertEqual(r.code, .delivered, text)
            XCTAssertEqual(r.detail, "Cleared")
            XCTAssertEqual(w.presses, text.count, text)
        }
    }

    func testAnEmptyBoxIsAlreadyClear() {
        let w = world()
        w.boxes = [.empty]
        let r = clear(w)
        XCTAssertEqual(r.code, .delivered)
        XCTAssertEqual(r.detail, "Already clear")
        XCTAssertEqual(w.presses, 0)
    }

    func testChangedTextIsLeftAlone() {
        for now in [DraftClear.Box.text("00"), .text("1"), .text("0 "), .other] {
            let w = world()
            w.boxes = [now]
            let r = clear(w)
            XCTAssertEqual(r.reason, .draftChanged, "\(now)")
            XCTAssertEqual(r.detail, "The text in the input box changed on your computer, so Page Studio left it alone.")
            XCTAssertEqual(w.presses, 0)
        }
    }

    func testUnreadableOrOpenDialogPressesNothing() {
        let blind = world()
        blind.boxes = [.unreadable]
        XCTAssertEqual(clear(blind).reason, .inputUnverified)
        XCTAssertEqual(blind.presses, 0)
        let menu = world()
        menu.boxes = [.dialog]
        let r = clear(menu)
        XCTAssertEqual(r.reason, .waiting)
        XCTAssertEqual(r.interventionId, "p1")
        XCTAssertEqual(menu.presses, 0)
    }

    func testAWaitingSessionIsRefusedBeforeAnythingIsRead() {
        let w = world()
        w.status = "waiting"
        let r = clear(w)
        XCTAssertEqual(r.reason, .waiting)
        XCTAssertEqual(r.interventionId, "p1")
        XCTAssertEqual(w.reads, 0)
        XCTAssertEqual(w.presses, 0)
        let unknown = world()
        unknown.status = "thinking"
        XCTAssertEqual(clear(unknown).reason, .unknownState)
        XCTAssertEqual(unknown.presses, 0)
    }

    func testTextThatCouldNeverHaveBeenReportedIsNotTypable() {
        for text in ["", String(repeating: "a", count: 201), "two\nlines", "[Pasted text #1]"] {
            let w = world()
            let r = clear(w, text)
            XCTAssertEqual(r.reason, .notTypable, text)
            XCTAssertEqual(r.detail, "Clear it at your computer")
            XCTAssertEqual(w.reads, 0)
            XCTAssertEqual(w.presses, 0)
        }
    }

    func testHostsThatCannotPressASingleKeyAreRefusedByName() {
        let cases: [(InjectionExecutor.TerminalHost, String)] = [
            (.terminalApp(tty: "/dev/ttys003"), "Page Studio can't clear the input box in Terminal.app — clear it at your computer"),
            (.iTerm(tty: "/dev/ttys003"), "Page Studio can't clear the input box in iTerm2 — clear it at your computer"),
            (.unsupported("Ghostty"), "Page Studio can't clear the input box in Ghostty — clear it at your computer"),
        ]
        for (host, detail) in cases {
            let w = world(host: host)
            let r = clear(w)
            XCTAssertEqual(r.reason, .notTypable)
            XCTAssertEqual(r.detail, detail)
            XCTAssertEqual(w.reads, 0)
            XCTAssertEqual(w.presses, 0)
        }
        XCTAssertEqual(clear(world(host: .unknown)).reason, .notTypable)
    }

    func testAMenuThatOpensMidRunStopsTheKeys() {
        let w = world("hello")
        w.statusAfterPress = (2, "waiting")
        let r = clear(w, "hello")
        XCTAssertEqual(r.reason, .waiting)
        XCTAssertEqual(w.presses, 2, "no key after the status turned to waiting")
    }

    func testAJobSentToTheBackgroundMidRunStopsTheKeys() {
        let w = world()
        w.foreground = false
        let r = clear(w)
        XCTAssertEqual(r.reason, .notTypable)
        XCTAssertEqual(r.detail, InjectionExecutor.notForegroundMessage)
        XCTAssertEqual(w.presses, 0)
    }

    func testAFailedKeyOrALeftoverBoxIsFailedNotDelivered() {
        let keyFails = world("abc")
        keyFails.pressFails = true
        let r = clear(keyFails, "abc")
        XCTAssertEqual(r.code, .failed)
        XCTAssertEqual(r.detail, "Couldn't press Backspace")
        XCTAssertEqual(keyFails.presses, 1)

        let leftover = world("abc")
        leftover.afterKeys = .text("c")
        let left = clear(leftover, "abc")
        XCTAssertEqual(left.code, .failed)
        XCTAssertEqual(left.detail, "Couldn't clear the input box — clear it at your computer")
    }

    func testTheDraftIsNeverInTheOutcomeDetail() {
        let w = world("hunter2 is my password")
        w.afterKeys = .text("x")
        let r = clear(w, "hunter2 is my password")
        XCTAssertFalse(r.detail.contains("hunter2"))
    }

    // MARK: peekDraft

    private func peek(_ w: World) -> SessionCommandResult {
        Gate.runClaudePeekDraft(sessionId: sid, interventionId: "p1", io: w.io)
    }

    func testPeekReportsTheTextOrThatThereIsSome() {
        let seen = world("fix the test")
        let r = peek(seen)
        XCTAssertEqual(r.code, .refused)
        XCTAssertEqual(r.reason, .draft)
        XCTAssertEqual(r.detail, CmuxBridge.draftDetail)
        XCTAssertEqual(r.draft, "fix the test")

        let unreadableText = world()
        unreadableText.boxes = [.other]
        let o = peek(unreadableText)
        XCTAssertEqual(o.reason, .draft)
        XCTAssertNil(o.draft)
    }

    func testPeekSaysAnEmptyBoxIsAlreadyClear() {
        let w = world()
        w.boxes = [.empty]
        let r = peek(w)
        XCTAssertEqual(r.code, .delivered)
        XCTAssertEqual(r.detail, "Already clear")
    }

    func testPeekRefusesWhatItCannotSee() {
        let blind = world()
        blind.boxes = [.unreadable]
        XCTAssertEqual(peek(blind).reason, .inputUnverified)
        let menu = world()
        menu.boxes = [.dialog]
        let r = peek(menu)
        XCTAssertEqual(r.reason, .waiting)
        XCTAssertEqual(r.interventionId, "p1")
        let waiting = world()
        waiting.status = "waiting"
        XCTAssertEqual(peek(waiting).reason, .waiting)
        XCTAssertEqual(waiting.reads, 0)
        XCTAssertEqual(peek(world(host: .terminalApp(tty: "/dev/ttys003"))).reason, .notTypable)
    }

    func testPeekPressesNoKey() {
        for box in [DraftClear.Box.text("abc"), .other, .empty, .unreadable, .dialog] {
            let w = world()
            w.boxes = [box]
            _ = peek(w)
            XCTAssertEqual(w.presses, 0, "\(box)")
        }
    }

    // MARK: reply.injected

    func testAFailedReplyNamesWhyButNeverCarriesTheText() {
        let reasons: [(String, String?)] = [
            (CmuxBridge.draftDetail, "draft"),
            (InjectionExecutor.inputUnverifiedMessage, "input_unverified"),
            (CmuxBridge.noInputBoxDetail, "input_unverified"),
            (CodexInjector.composerUnverifiedDetail, "input_unverified"),
            (CodexInjector.terminalComposerUnverifiedDetail, "input_unverified"),
            (InjectionExecutor.notForegroundMessage, nil),
            ("", nil),
        ]
        for (detail, reason) in reasons {
            let p = RelayClient.replyInjectedPayload(interventionId: "i", method: "none", success: false, detail: detail, output: nil)
            XCTAssertEqual(p["reason"] as? String, reason, detail)
            XCTAssertEqual(Set(p.keys).subtracting(["interventionId", "method", "success", "detail", "reason"]), [])
        }
        let ok = RelayClient.replyInjectedPayload(interventionId: "i", method: "tmux", success: true, detail: CmuxBridge.draftDetail, output: nil)
        XCTAssertNil(ok["reason"], "only a failure has a reason")
    }
}
