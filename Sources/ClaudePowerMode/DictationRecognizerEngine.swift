import Foundation
import AVFoundation
import Speech

// SFSpeechRecognizer: macOS before 26, or a Mac or language the new transcribers don't cover. On the Mac
// when `supportsOnDeviceRecognition`, otherwise Apple's speech service (decision D1: `onDevice` is false
// then, and the line says so while it listens). A server request ends near a minute, so a new one starts
// at 55 s and the committed words carry over (they live in the controller's DictationDraft).

/// Everything but the audio and Speech callbacks runs on the main thread; those hop to it before they touch state.
final class DictationRecognizerEngine: DictationEngine, @unchecked Sendable {
    /// Apple's server ends a request near a minute: start the next one before that.
    static let serverRolloverAfter: TimeInterval = 55
    /// Stop waiting for the last words after this long.
    static let finalizeTimeout: TimeInterval = 4

    private let locale: Locale
    private let onDevice: Bool
    private let events: DictationEngineEvents
    private let mic = DictationMicTap()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    /// Appended to from the audio thread; every access is under `lock`.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let lock = NSLock()
    /// Which request's results count. Bumped for every new request, so a late result of an old one is ignored.
    private var token = 0
    private var requestStartedAt = Date()
    private var heardInRequest = false
    private var fastFailures = 0
    private var lastVolatile = ""
    private var closed = false
    private var stopRequested = false
    private var interruptRequested = false

    init(locale: Locale, onDevice: Bool, events: DictationEngineEvents) {
        self.locale = locale
        self.onDevice = onDevice
        self.events = events
    }

    var level: Double { mic.level }

    func start() {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return end(.cannotStart)
        }
        self.recognizer = recognizer
        beginRequest()
        mic.onInterrupt = { [weak self] in self?.interrupted() }
        do {
            try mic.start { [weak self] buffer in self?.append(buffer) }
        } catch {
            teardown()
            return end(.interrupted)
        }
        events.listening()
    }

    func stop() {
        guard !closed, !stopRequested else { return }
        stopRequested = true
        mic.stop()
        finishAudio()
        scheduleFinalizeTimeout()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        teardown()
    }

    // MARK: requests

    private func beginRequest() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.requiresOnDeviceRecognition = onDevice
        if #available(macOS 13.0, *) { req.addsPunctuation = true }
        token += 1
        let mine = token
        setRequest(req)
        requestStartedAt = Date()
        heardInRequest = false
        task = DictationRecognizerEngine.makeTask(recognizer: recognizer, request: req) { [weak self] text, final, failed in
            DispatchQueue.main.async { self?.received(token: mine, text: text, final: final, failed: failed) }
        }
        if !onDevice {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.serverRolloverAfter) { [weak self] in
                guard let self, !self.closed, !self.stopRequested, self.token == mine else { return }
                self.rollover(commitVolatile: true)
            }
        }
    }

    /// Created off the main actor: the result handler runs on a Speech queue.
    private static func makeTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                 handler: @escaping @Sendable (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    private func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }

    /// The audio thread. Under the lock, so an `append` can never run after the `endAudio` of the same request
    /// (that is an Objective-C exception, which Swift cannot catch).
    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        lock.unlock()
    }

    private func finishAudio() {
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
    }

    private func received(token mine: Int, text: String?, final: Bool, failed: Bool) {
        guard !closed, mine == token else { return }
        if let text, !text.isEmpty { heardInRequest = true }
        if let text {
            if final {
                lastVolatile = ""
                events.commit(text)
            } else {
                lastVolatile = text
                events.volatile(text)
            }
        }
        if final || failed { requestEnded(failed: failed && !final) }
    }

    /// The task finished: after a stop that is the end; otherwise the recognizer ended it (a pause, a
    /// server limit, "no speech") and the next request carries on.
    private func requestEnded(failed: Bool) {
        if stopRequested || interruptRequested {
            if !lastVolatile.isEmpty { events.commit(lastVolatile); lastVolatile = "" }
            return end(interruptRequested ? .interrupted : .finished)
        }
        let quick = Date().timeIntervalSince(requestStartedAt) < 1 && !heardInRequest
        fastFailures = quick ? fastFailures + 1 : 0
        // A recognizer that fails again and again at once will not run (Dictation off, say).
        if fastFailures >= 3 {
            teardown()
            return end(failed ? .refused : .interrupted)
        }
        rollover(commitVolatile: failed)
    }

    /// A new request on the same microphone. What is showing as volatile is kept as final words first, and
    /// the old request's late results are ignored. A fraction of a second of audio may be lost.
    private func rollover(commitVolatile: Bool) {
        if commitVolatile, !lastVolatile.isEmpty { events.commit(lastVolatile) }
        lastVolatile = ""
        let old = task
        finishAudio()
        old?.cancel()
        beginRequest()
    }

    // MARK: ending

    private func interrupted() {
        guard !closed, !stopRequested else { return }
        // The microphone is already closed. Finalise what was heard, then say so.
        interruptRequested = true
        finishAudio()
        scheduleFinalizeTimeout()
    }

    private func scheduleFinalizeTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalizeTimeout) { [weak self] in
            guard let self, !self.closed else { return }
            if !self.lastVolatile.isEmpty { self.events.commit(self.lastVolatile); self.lastVolatile = "" }
            self.teardown()
            self.end(self.interruptRequested ? .interrupted : .finished)
        }
    }

    private func end(_ how: DictationEngineEnd) {
        guard !closed else { return }
        closed = true
        teardown()
        events.ended(how)
    }

    private func teardown() {
        mic.onInterrupt = nil
        mic.stop()
        setRequest(nil)
        task?.cancel()
        task = nil
        recognizer = nil
    }
}
