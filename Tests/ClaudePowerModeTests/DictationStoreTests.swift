import XCTest
@testable import ClaudePowerMode
@testable import PageCore

/// The Now panel's keys for voice input (Designs/voice-input.md, "Mac"): ⌘D, Esc and Return reach the
/// dictation before the panel's own keys, and the box's close, send and cancel stop listening. The
/// dictation actions are fakes that count calls; no microphone or speech engine runs.
final class DictationStoreTests: XCTestCase {

    /// A store with a Steer box open on a working session, and the dictation actions counting their calls.
    private final class Recorder {
        var toggles = 0
        var cancels = 0
    }

    private func store(_ rec: Recorder) -> NowStore {
        let inputs = NightWatchFixtures.cardsScene()
        let st = NowStore(model: NowModel.build(inputs), prefs: .ephemeral())
        st.now = { inputs.now }
        st.dictationActions = NowDictationActions(toggle: { rec.toggles += 1 }, cancel: { rec.cancels += 1 })
        return st
    }

    /// Opens the one-line Steer box on a working session with `t`, the way the panel does.
    private func openSteerBox(_ st: NowStore) {
        st.hoverFlight(InFlightRow.idPrefix + "sess-page")
        st.handle(NowKeyPress(key: .char("t")))
        XCTAssertNotNil(st.state.composer, "the Steer box opens for the test")
    }

    private func key(_ k: NowKeyPress.Key, command: Bool = false, option: Bool = false, control: Bool = false,
                     repeating: Bool = false, up: Bool = false) -> NowKeyPress {
        NowKeyPress(key: k, phase: up ? .up : .down, command: command, option: option, control: control, isRepeat: repeating)
    }

    // MARK: ⌘D

    func testCommandDTogglesWithTheSteerBoxOpen() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        XCTAssertTrue(st.handle(key(.char("d"), command: true)), "the panel consumes ⌘D")
        XCTAssertEqual(rec.toggles, 1)
        XCTAssertNotNil(st.state.composer, "⌘D does not close the box")
    }

    func testCommandDDoesNothingWithoutTheSteerBox() {
        let rec = Recorder()
        let st = store(rec)
        st.handle(key(.char("d"), command: true))
        XCTAssertEqual(rec.toggles, 0)
        XCTAssertNil(st.state.composer)
    }

    func testOptionCommandDNeverStartsDictation() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.handle(key(.char("d"), command: true, option: true))
        XCTAssertEqual(rec.toggles, 0, "⌥⌘D is Dock hiding")
        XCTAssertNotNil(st.state.composer)
    }

    func testHeldCommandDTogglesOnce() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.handle(key(.char("d"), command: true))
        st.handle(key(.char("d"), command: true, repeating: true))
        XCTAssertEqual(rec.toggles, 1)
    }

    // MARK: Esc

    func testEscWhileListeningStopsAndKeepsTheBoxOpen() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.dictation = .listening(level: 0.2, onDevice: true)
        XCTAssertTrue(st.handle(key(.esc)))
        XCTAssertEqual(rec.toggles, 1, "the first Esc stops listening")
        XCTAssertNotNil(st.state.composer, "the box stays open for the next Esc")
    }

    func testEscWhilePreparingAlsoStopsFirst() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.dictation = .preparing
        st.handle(key(.esc))
        XCTAssertEqual(rec.toggles, 1)
        XCTAssertNotNil(st.state.composer)
    }

    func testSecondEscWithDictationIdleClosesTheBox() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.dictation = .listening(level: 0, onDevice: true)
        st.handle(key(.esc))
        XCTAssertNotNil(st.state.composer)
        st.dictation = .idle
        st.handle(key(.esc))
        XCTAssertEqual(rec.toggles, 1, "the second Esc does not toggle")
        XCTAssertNil(st.state.composer, "and closes the box, as it always did")
    }

    func testEscWhileIdleDoesNotToggle() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.dictation = .idle
        st.handle(key(.esc))
        XCTAssertEqual(rec.toggles, 0)
        XCTAssertNil(st.state.composer)
    }

    func testCommandEscIsNotDictation() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.dictation = .listening(level: 0, onDevice: true)
        st.handle(key(.esc, command: true))
        XCTAssertEqual(rec.toggles, 0)
    }

    // MARK: Return, send and cancel

    func testReturnCancelsDictationBeforeTheSend() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.composerText = "Run the tests"
        st.dictation = .listening(level: 0, onDevice: true)
        st.handle(key(.ret))
        XCTAssertEqual(rec.cancels, 1, "Return stops listening and drops what is still arriving")
        XCTAssertEqual(rec.toggles, 0, "Return is never a toggle")
    }

    func testSubmitComposerCallsCancel() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.composerText = "send this"
        st.submitComposer()
        XCTAssertGreaterThanOrEqual(rec.cancels, 1)
        XCTAssertEqual(rec.toggles, 0)
    }

    func testCancelComposerCallsCancelAndClosesTheBox() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.dictation = .listening(level: 0, onDevice: true)
        st.cancelComposer()
        XCTAssertGreaterThanOrEqual(rec.cancels, 1)
        XCTAssertNil(st.state.composer)
        XCTAssertEqual(rec.toggles, 0)
    }

    func testResetCancelsDictation() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.reset()
        XCTAssertGreaterThanOrEqual(rec.cancels, 1, "closing the panel stops listening")
        XCTAssertNil(st.state.composer)
    }

    func testToggleAndCancelDictationForwardToTheActions() {
        let rec = Recorder()
        let st = store(rec)
        st.toggleDictation()
        st.cancelDictation()
        XCTAssertEqual(rec.toggles, 1)
        XCTAssertEqual(rec.cancels, 1)
    }

    // MARK: typing and other keys

    func testTypingDoesNotToggleDictation() {
        let rec = Recorder()
        let st = store(rec)
        openSteerBox(st)
        st.dictation = .listening(level: 0, onDevice: true)
        st.handle(key(.char("x")))
        XCTAssertEqual(rec.toggles, 0, "typing is the field's; the view stops listening on an edit")
        XCTAssertEqual(rec.cancels, 0)
    }

    func testDictationKeysDoNothingWhenTheBoxIsClosed() {
        let rec = Recorder()
        let st = store(rec)
        st.dictation = .listening(level: 0, onDevice: true)
        st.handle(key(.esc))
        st.handle(key(.ret))
        XCTAssertEqual(rec.toggles, 0)
    }
}
