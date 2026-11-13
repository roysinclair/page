import AppKit
import AVFoundation
import Combine
import Speech
@testable import PageCore

// Voice input in the panel's Steer boxes (Designs/voice-input.md, "Mac"). The controller owns at most
// one dictation session, drives `NowStore.dictation`, and writes what it hears into the open box through
// `DictationDraft`. It never sends anything: Return (or Send) is the same key it always was, and the
// controller stops listening before it runs.
//
// Everything here runs on the main thread. Speech and AVFoundation are touched only on the first toggle,
// never at launch.

final class DictationController {
    private final class Session {
        /// The box this session writes to.
        let rowId: String
        var draft: DictationDraft
        /// What dictation last wrote (at first, the draft it started from). The box holding anything else
        /// means the person typed.
        var lastWritten: String
        var probe = DictationProbe()
        var choice: DictationEngineChoice?
        var engine: DictationEngine?
        var clock: DictationClock?
        var listening = false
        /// Stopped by the person (or the clock): the microphone is closed, the last words are on their way.
        var finishing = false
        var finishTimeout: DispatchWorkItem?

        init(rowId: String, base: String) {
            self.rowId = rowId
            draft = DictationDraft(base: base)
            lastWritten = base
        }
    }

    /// Stop waiting for the last words after this long.
    static let finishTimeout: TimeInterval = 6
    /// An interruption's line goes away by itself after this long.
    static let noteLinger: TimeInterval = 4

    private let store: NowStore
    private let now: () -> Date
    private var session: Session?
    private var stateObserver: AnyCancellable?
    private var levelTimer: Timer?
    private var noteWork: DispatchWorkItem?
    private var lastRowId: String?

    /// Called with true while a macOS permission prompt is up, so the panel does not close under it, and
    /// with false when it is gone.
    var onSystemPrompt: (Bool) -> Void = { _ in }

    init(store: NowStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        store.dictationActions = NowDictationActions(
            toggle: { [weak self] in self?.toggle() },
            cancel: { [weak self] in self?.cancel() },
            openSettings: { [weak self] permission in self?.openSettings(permission) })
        // `@Published` calls its subscribers before the value changes, so only the value handed over is read here.
        stateObserver = store.$state.sink { [weak self] new in self?.stateChanged(new) }
    }

    // MARK: what the store asks for

    /// The mic, ⌘D, or the first Esc: start, or stop and keep the words.
    private func toggle() {
        if let s = session, !s.finishing { return stop() }
        start()
    }

    /// Return, typing, closing the box: nothing more is written. What shows stays.
    private func cancel() {
        dropSession()
        if store.dictation.isActive { setPhase(.idle) }
    }

    private func openSettings(_ permission: DictationPermission) {
        let pane = permission == .microphone ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: start

    private func start() {
        guard let box = store.composer else { return }
        dropSession()
        noteWork?.cancel()
        lastRowId = box.rowId
        let s = Session(rowId: box.rowId, base: box.text)
        session = s
        store.dictationLanguage = DictationProbe.displayName(for: Locale.current)
        setPhase(.preparing)
        store.composerFocusToken += 1
        Task { @MainActor [weak self] in await self?.prepare(s) }
    }

    @MainActor private func prepare(_ s: Session) async {
        // An app bundle that lacks the usage strings is killed by macOS the moment it asks.
        guard DictationPermissions.declared else {
            Logger.shared.log("Voice input: Info.plist has no microphone or speech usage string, so the mic stays off")
            return fail(s, .unavailable(.noRecognizer))
        }
        let prompting = DictationPermissions.needsPrompt
        if prompting { onSystemPrompt(true) }
        let heard = await DictationPermissions.microphone()
        let allowed = heard ? await DictationPermissions.speech() : true
        if prompting { onSystemPrompt(false) }
        guard session === s else { return }
        guard heard else { return fail(s, .denied(.microphone)) }
        guard allowed else { return fail(s, .denied(.speech)) }

        let probe = await DictationProbe.run(for: Locale.current)
        guard session === s else { return }
        s.probe = probe
        store.dictationLanguage = probe.languageName
        launch(s)
    }

    /// Starts the engine the probe picks. One that can't start (its model is unsupported, it won't download)
    /// is ruled out and the next one is tried; the order is `DictationEngineChoice.pick`'s.
    private func launch(_ s: Session) {
        guard session === s else { return }
        let choice = s.probe.choice
        s.choice = choice
        let events = makeEvents(for: s, onDevice: choice.isOnDevice)
        let engine: DictationEngine?
        switch choice {
        case .unavailable(let why):
            return fail(s, .unavailable(why))
        case .speechTranscriber:
            engine = s.probe.speechLocale.flatMap { makeDictationAnalyzerEngine(kind: .speech, locale: $0, events: events) }
        case .dictationTranscriber:
            engine = s.probe.dictationLocale.flatMap { makeDictationAnalyzerEngine(kind: .dictation, locale: $0, events: events) }
        case .recognizerOnDevice, .recognizerServer:
            engine = s.probe.recognizerLocale.map { DictationRecognizerEngine(locale: $0, onDevice: choice.isOnDevice, events: events) }
        }
        guard let engine else {
            s.probe.ruleOut(choice)
            return launch(s)
        }
        // Set before `start()`: an engine that can't start says so at once, and the next one replaces it.
        s.engine = engine
        engine.start()
    }

    private func makeEvents(for s: Session, onDevice: Bool) -> DictationEngineEvents {
        DictationEngineEvents(
            downloading: { [weak self, weak s] fraction in
                guard let self, let s, self.session === s, !s.listening, !s.finishing else { return }
                self.setPhase(.downloading(fraction: fraction))
            },
            listening: { [weak self, weak s] in
                guard let self, let s, self.session === s, !s.finishing else { return }
                s.listening = true
                s.clock = DictationClock(startedAt: self.now())
                self.setPhase(.listening(level: 0, onDevice: onDevice))
                self.startLevelTimer()
            },
            volatile: { [weak self, weak s] text in self?.heard(s, text, final: false) },
            commit: { [weak self, weak s] text in self?.heard(s, text, final: true) },
            ended: { [weak self, weak s] how in self?.ended(s, how) })
    }

    // MARK: words

    private func heard(_ s: Session?, _ text: String, final: Bool) {
        guard let s, session === s else { return }
        let before = s.draft.text
        if final { s.draft.commit(text) } else { s.draft.setVolatile(text) }
        guard s.draft.text != before else { return }
        s.clock?.heardWords(at: now())
        write(s)
    }

    /// Puts what shows into the box. Never writes over something the person typed.
    private func write(_ s: Session) {
        guard store.composer?.rowId == s.rowId,
              !DictationGuard.userEdited(current: store.composerText, lastWritten: s.lastWritten) else {
            dropSession()
            if store.dictation.isActive { setPhase(.idle) }
            return
        }
        let text = s.draft.text
        guard text != s.lastWritten else { return }
        // Recorded first: the write comes straight back through `stateChanged`, which compares the two.
        s.lastWritten = text
        store.composerText = text
    }

    // MARK: stop and end

    /// Stops listening and keeps the words: the microphone closes now, the last words are finalised, and
    /// the line is gone. A stop before the microphone opened just drops the session.
    private func stop() {
        guard let s = session, !s.finishing else { return }
        store.composerFocusToken += 1
        guard s.listening else {
            dropSession()
            return setPhase(.idle)
        }
        s.finishing = true
        stopLevelTimer()
        setPhase(.idle)
        let timeout = DispatchWorkItem { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            self.finish(s)
        }
        s.finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishTimeout, execute: timeout)
        s.engine?.stop()
    }

    private func ended(_ s: Session?, _ how: DictationEngineEnd) {
        guard let s, session === s else { return }
        switch how {
        case .finished:
            finish(s)
            if store.dictation.isActive { setPhase(.idle) }
        case .interrupted:
            let byPerson = s.finishing
            finish(s)
            if byPerson { return }
            setPhase(.interrupted)
            scheduleNoteFade()
        case .refused:
            finish(s)
            setPhase(.unavailable(.noRecognizer))
        case .cannotStart:
            if s.listening {
                finish(s)
                setPhase(.interrupted)
                scheduleNoteFade()
            } else {
                s.engine = nil
                s.probe.ruleOut(s.choice)
                launch(s)
            }
        }
    }

    /// The words are final: what showed stays in the box, and the session is over.
    private func finish(_ s: Session) {
        guard session === s else { return }
        write(s)
        if session === s { dropSession() }
    }

    /// Ends the session with a line instead of words.
    private func fail(_ s: Session, _ phase: DictationPhase) {
        guard session === s else { return }
        dropSession()
        setPhase(phase)
    }

    /// Closes the microphone and forgets the session. Late results are dropped because nothing is listening.
    private func dropSession() {
        guard let s = session else { return }
        session = nil
        s.finishTimeout?.cancel()
        let engine = s.engine
        s.engine = nil
        engine?.cancel()
        stopLevelTimer()
    }

    // MARK: the box changed

    /// The box closed, moved to another row, or the person typed in it: stop and drop late results.
    private func stateChanged(_ new: NowPanelState) {
        let rowId = new.composer?.rowId
        if rowId != lastRowId {
            lastRowId = rowId
            dropSession()
            settle()
        } else if let s = session, let box = new.composer,
                  DictationGuard.userEdited(current: box.text, lastWritten: s.lastWritten) {
            dropSession()
            settle()
        }
    }

    /// The line goes back to idle. Later than the change that caused it: this runs inside the store's own update.
    private func settle() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session == nil else { return }
            self.setPhase(.idle)
        }
    }

    private func scheduleNoteFade() {
        noteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session == nil, self.store.dictation == .interrupted else { return }
            self.store.dictation = .idle
        }
        noteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteLinger, execute: work)
    }

    private func setPhase(_ phase: DictationPhase) {
        if store.dictation != phase { store.dictation = phase }
    }

    // MARK: level and the clock

    private func startLevelTimer() {
        stopLevelTimer()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    /// About 15 times a second while listening: the bars, and the silence limit and the cap.
    private func tick() {
        guard let s = session, s.listening, !s.finishing else { return stopLevelTimer() }
        if s.clock?.expiry(at: now()) != nil { return stop() }
        if case .listening(let old, let onDevice) = store.dictation {
            let level = s.engine?.level ?? 0
            if abs(level - old) >= 0.02 { store.dictation = .listening(level: level, onDevice: onDevice) }
        }
    }
}

// MARK: - What this Mac can do

/// What the Mac's speech engines say about the language, gathered on the first toggle. The choice itself
/// is `DictationEngineChoice.pick` (pure, tested); this only asks the questions.
struct DictationProbe {
    var osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    var languageName = ""
    var speechTranscriberAvailable = false
    var speechLocale: Locale?
    var dictationLocale: Locale?
    var recognizerLocale: Locale?
    var recognizerAvailable = false
    var recognizerOnDevice = false

    var choice: DictationEngineChoice {
        DictationEngineChoice.pick(
            osMajor: osMajor,
            transcriberAvailable: speechTranscriberAvailable,
            transcriberSupportsLocale: speechLocale != nil,
            dictationSupportsLocale: dictationLocale != nil,
            sfSupportsLocale: recognizerLocale != nil,
            sfOnDevice: recognizerOnDevice,
            sfAvailable: recognizerAvailable,
            language: languageName)
    }

    /// An engine that could not start is not tried again. A recognizer that fails on the device is not
    /// swapped for Apple's server: that path is only for a Mac that has no on-device recognition.
    mutating func ruleOut(_ choice: DictationEngineChoice?) {
        switch choice {
        case .speechTranscriber?: speechLocale = nil
        case .dictationTranscriber?: dictationLocale = nil
        case .recognizerOnDevice?, .recognizerServer?: recognizerAvailable = false
        case .unavailable?, nil: break
        }
    }

    /// "English (United Kingdom)", in the language the person uses.
    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    static func run(for locale: Locale) async -> DictationProbe {
        var probe = DictationProbe()
        let transcribers = await probeDictationTranscribers(for: locale)
        probe.speechTranscriberAvailable = transcribers.speechTranscriberAvailable
        probe.speechLocale = transcribers.speechLocale
        probe.dictationLocale = transcribers.dictationLocale
        let supported = SFSpeechRecognizer.supportedLocales()
        if let id = DictationLocale.nearest(to: locale.identifier, in: supported.map(\.identifier)),
           let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)) {
            probe.recognizerLocale = recognizer.locale
            probe.recognizerAvailable = recognizer.isAvailable
            probe.recognizerOnDevice = recognizer.supportsOnDeviceRecognition
        }
        probe.languageName = displayName(for: transcribers.speechLocale ?? transcribers.dictationLocale
                                         ?? probe.recognizerLocale ?? locale)
        return probe
    }
}

// MARK: - Permissions

/// Microphone and Speech Recognition. Both are asked for, whichever engine listens (the SDK does not say
/// whether SpeechAnalyzer needs the second). The completions run off the main thread, so they are made here,
/// outside any actor.
enum DictationPermissions {
    /// The usage strings are in Info.plist. Only an app bundle needs them (a bare executable asks on behalf of
    /// its terminal), and one without them is terminated by macOS when it asks.
    static var declared: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return true }
        return Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    /// macOS will ask the person something.
    static var needsPrompt: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            || SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    static func microphone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            return false
        }
    }

    static func speech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }
}
