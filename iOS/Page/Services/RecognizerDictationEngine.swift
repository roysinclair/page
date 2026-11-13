import AVFoundation
import Foundation
import Speech

// iOS 17 to 25, and any phone SpeechAnalyzer can't serve: SFSpeechRecognizer with a buffer request fed from the
// AVAudioEngine tap. On the device when the recognizer supports it (`requiresOnDeviceRecognition`); otherwise through
// Apple's speech service (decision D1), which ends a request near a minute, so a new request starts at 55 s and the
// old one is left to deliver its last words. The words are never written anywhere: they only travel as events.

final class RecognizerDictationEngine: DictationEngine, @unchecked Sendable {
    /// The server ends a request near a minute: a new one starts at this age.
    static let serverRequestLimit: TimeInterval = 55
    /// A rotated request that has not finished by now is finished for it.
    private static let straggler: TimeInterval = 5

    /// One recognition request and its task. The recognizer reports each one's words separately.
    private final class Generation {
        let number: Int
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        let startedAt = Date()
        /// What this request has heard so far and not finished.
        var lastText = ""
        init(number: Int, request: SFSpeechAudioBufferRecognitionRequest) {
            self.number = number
            self.request = request
        }
    }

    private let locale: Locale
    private let onDevice: Bool
    private let pipe = DictationEventPipe()
    private let audio = DictationAudio()
    /// The recognizer's handlers run here, one at a time and in order.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    /// Every request that has not finished: the one the audio goes to (`currentNumber`), and any that were rotated
    /// out and have not delivered their last words. Registered before the recognizer starts, so no result is early.
    private var generations: [Int: Generation] = [:]
    private var currentNumber: Int?
    private var nextNumber = 0
    private var stopping = false
    private var cancelled = false
    private var endedSent = false
    /// Requests in a row that ended at once with nothing heard: the recognizer is not working.
    private var quickEnds = 0

    var events: AsyncStream<DictationEvent> { pipe.stream }

    init(locale: Locale, onDevice: Bool) {
        self.locale = locale
        self.onDevice = onDevice
    }

    // MARK: Start

    func start() async {
        pipe.send(.preparing)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              !onDevice || recognizer.supportsOnDeviceRecognition else { return pipe.send(.failed) }
        recognizer.queue = queue
        recognizer.defaultTaskHint = .dictation
        lock.withLock { self.recognizer = recognizer }

        guard let first = makeGeneration() else { return pipe.send(.failed) }
        install(first)
        do {
            try audio.start(
                onBuffer: { [weak self] buffer in self?.append(buffer) },
                onLevel: { [pipe] level in pipe.send(.level(level)) },
                onInterrupted: { [pipe] in pipe.send(.interrupted) })
        } catch {
            // The microphone is busy (a call, Siri) or gone.
            pipe.send(.interrupted)
            cancel()
            return
        }
        pipe.send(.listening(onDevice: onDevice))
    }

    // MARK: Requests

    /// A request and its task, not yet current. Nil when the engine is over or the recognizer is gone.
    private func makeGeneration() -> Generation? {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        // On the device when it can; the server path says so on the line the whole time (D1).
        request.requiresOnDeviceRecognition = onDevice

        lock.lock()
        guard !cancelled, !stopping, let recognizer else { lock.unlock(); return nil }
        let number = nextNumber
        nextNumber += 1
        let generation = Generation(number: number, request: request)
        generations[number] = generation
        lock.unlock()

        generation.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(number, result: result, error: error)
        }
        return generation
    }

    /// Makes a request current (the audio goes to it). If the engine ended meanwhile, drops it.
    private func install(_ generation: Generation) {
        lock.lock()
        if cancelled || stopping {
            generations[generation.number] = nil
            lock.unlock()
            generation.task?.cancel()
            endedIfDone()
            return
        }
        currentNumber = generation.number
        lock.unlock()
        if !onDevice { scheduleRotation(of: generation.number) }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let request = currentNumber.flatMap { generations[$0] }?.request; lock.unlock()
        request?.append(buffer)
    }

    // MARK: Results

    /// Everything not yet finished, in the order it was said: the rotated-out requests, then the current one.
    /// Caller holds the lock.
    private func volatileText() -> String {
        generations.values.sorted { $0.number < $1.number }.map(\.lastText).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func handle(_ number: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        lock.lock()
        if cancelled { lock.unlock(); return }
        guard let generation = generations[number] else { lock.unlock(); return }
        let isCurrent = currentNumber == number

        let latest = result?.bestTranscription.formattedString
        if let result, !result.isFinal, error == nil {
            // Words still changing: they replace this request's last words.
            generation.lastText = latest ?? ""
            let shown = volatileText()
            lock.unlock()
            pipe.send(.volatile(shown))
            return
        }

        // This request is over: a final result, or an error (no speech heard, the service gave up).
        let words = result?.isFinal == true ? (latest ?? "") : ((latest?.isEmpty == false ? latest : nil) ?? generation.lastText)
        generations[number] = nil
        if isCurrent { currentNumber = nil }
        var restart = false
        var giveUp = false
        if isCurrent, !stopping {
            quickEnds = (words.isEmpty && Date().timeIntervalSince(generation.startedAt) < 1.5) ? quickEnds + 1 : 0
            giveUp = quickEnds >= 3
            restart = !giveUp
        }
        let others = volatileText()
        lock.unlock()

        pipe.send(.committed(words))
        // Committing clears the words still changing; the other requests' words come back.
        if !others.isEmpty { pipe.send(.volatile(others)) }
        if giveUp {
            pipe.send(.failed)
        } else if restart, let next = makeGeneration() {
            // The recognizer ended its request by itself (a pause, a minute) while the person is still talking.
            install(next)
        }
        endedIfDone()
    }

    /// After `stop()`: the last words are in once every request has finished.
    private func endedIfDone() {
        lock.lock()
        let done = stopping && !cancelled && generations.isEmpty && !endedSent
        if done { endedSent = true }
        lock.unlock()
        if done { pipe.send(.ended) }
    }

    // MARK: Server requests end near a minute

    private func scheduleRotation(of number: Int) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.serverRequestLimit) { [weak self] in
            self?.rotate(number)
        }
    }

    /// A new request takes the audio at once; the old one is told the audio is over and delivers its last words
    /// (shown with the new request's, so nothing disappears and nothing is said twice).
    private func rotate(_ number: Int) {
        guard let fresh = makeGeneration() else { return }
        lock.lock()
        guard !cancelled, !stopping, currentNumber == number, let old = generations[number] else {
            generations[fresh.number] = nil
            lock.unlock()
            fresh.task?.cancel()
            return
        }
        currentNumber = fresh.number
        lock.unlock()
        old.request.endAudio()
        scheduleRotation(of: fresh.number)
        // One that never delivers is finished with what it had.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.straggler) { [weak self] in
            self?.dropStraggler(number)
        }
    }

    private func dropStraggler(_ number: Int) {
        lock.lock()
        guard !cancelled, currentNumber != number, let old = generations[number] else { lock.unlock(); return }
        generations[number] = nil
        let words = old.lastText
        let others = volatileText()
        lock.unlock()
        old.task?.cancel()
        pipe.send(.committed(words))
        if !others.isEmpty { pipe.send(.volatile(others)) }
        endedIfDone()
    }

    // MARK: Stop

    func stop() {
        lock.lock()
        guard !stopping, !cancelled else { lock.unlock(); return }
        stopping = true
        let request = currentNumber.flatMap { generations[$0] }?.request
        lock.unlock()
        // The microphone closes now; the request is told the audio is over and finishes what it heard.
        audio.stop()
        request?.endAudio()
        endedIfDone()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let all = Array(generations.values)
        generations = [:]
        currentNumber = nil
        lock.unlock()
        audio.stop()
        all.forEach { $0.task?.cancel() }
        pipe.close()
    }
}
