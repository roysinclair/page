import AVFoundation
import Foundation
import Speech

// iOS 26 and later: SpeechAnalyzer with SpeechTranscriber (or, for a language only it has, DictationTranscriber).
// Both run on the device. The audio is an AVAudioEngine tap converted to the analyzer's format; the words come
// back as volatile results (still changing) and final ones (finished). iOS 27's AnalyzerInputConverter and
// CaptureInputSequenceProvider are not used, so one path covers 26 and 27.

@available(iOS 26, *)
final class AnalyzerDictationEngine: DictationEngine, @unchecked Sendable {
    enum Kind { case speech, dictation }

    private let kind: Kind
    private let locale: Locale
    private let pipe = DictationEventPipe()
    private let audio = DictationAudio()
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var inputs: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var stopping = false
    private var cancelled = false

    var events: AsyncStream<DictationEvent> { pipe.stream }

    init(kind: Kind, locale: Locale) {
        self.kind = kind
        self.locale = locale
    }

    /// `.fastResults` as well as `.volatileResults`: measured on the Mac with real-time audio, `.volatileResults` alone
    /// showed nothing for the first ~4 s and then came in bursts; with `.fastResults` the first words show after ~1 s.
    /// It trades a little accuracy for words that keep up with the voice (the Mac engine does the same).
    static func makeSpeechTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    static func makeDictationTranscriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    // MARK: Start

    func start() async {
        pipe.send(.preparing)
        // The module, and the one task that reads its results (started before the analyzer, so none are missed).
        let module: any SpeechModule
        let reading: Task<Void, Never>
        switch kind {
        case .speech:
            let t = Self.makeSpeechTranscriber(locale)
            module = t
            reading = read(t.results) { (String($0.text.characters), $0.isFinal) }
        case .dictation:
            let t = Self.makeDictationTranscriber(locale)
            module = t
            reading = read(t.results) { (String($0.text.characters), $0.isFinal) }
        }
        lock.withLock { resultsTask = reading }

        do {
            guard try await ensureAssets(for: module) else { return fail(reading) }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            guard let format, !isCancelled else { return fail(reading) }

            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.prepareToAnalyze(in: format)
            if isCancelled { await analyzer.cancelAndFinishNow(); return }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            let wasCancelled: Bool = lock.withLock {
                if cancelled { return true }
                self.analyzer = analyzer
                inputs = continuation
                return false
            }
            if wasCancelled {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                return
            }

            // Only now does the microphone open.
            let converter = DictationBufferConverter(to: format)
            do {
                try audio.start(
                    onBuffer: { buffer in
                        if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
                    },
                    onLevel: { [pipe] level in pipe.send(.level(level)) },
                    onInterrupted: { [pipe] in pipe.send(.interrupted) })
            } catch {
                // The microphone is busy (a call, Siri) or gone: not this engine's fault.
                pipe.send(.interrupted)
                cancel()
                return
            }
            pipe.send(.listening(onDevice: true))
        } catch {
            if !isCancelled { fail(reading) }
        }
    }

    /// Makes sure the language's model is on the phone, downloading it (once, kept by iOS) when it is not.
    /// False: this engine can't be used for the language.
    private func ensureAssets(for module: any SpeechModule) async throws -> Bool {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return true
        case .unsupported:
            return false
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return true }
            let progress = request.progress
            pipe.send(.downloading(progress.isIndeterminate ? nil : progress.fractionCompleted))
            let observation = progress.observe(\.fractionCompleted, options: [.new]) { [pipe] p, _ in
                pipe.send(.downloading(p.isIndeterminate ? nil : p.fractionCompleted))
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
            pipe.send(.preparing)
            return true
        @unknown default:
            return true
        }
    }

    /// This engine can't be used: tell the controller (which will pick the next one) and stop reading.
    private func fail(_ reading: Task<Void, Never>) {
        reading.cancel()
        if !isCancelled { pipe.send(.failed) }
    }

    /// Reads a transcriber's results until they end. Volatile results replace the words still changing; final
    /// ones are finished words.
    private func read<S: AsyncSequence & Sendable>(_ sequence: S, _ text: @escaping @Sendable (S.Element) -> (String, Bool)) -> Task<Void, Never>
    where S.Element: Sendable {
        Task { [weak self, pipe] in
            do {
                for try await result in sequence {
                    let (words, isFinal) = text(result)
                    pipe.send(isFinal ? .committed(words) : .volatile(words))
                }
            } catch {
                guard let self, !self.isStopping, !self.isCancelled else { return }
                pipe.send(.failed)
            }
        }
    }

    // MARK: Stop

    func stop() {
        lock.lock()
        guard !stopping, !cancelled else { lock.unlock(); return }
        guard let analyzer else {
            // Not listening yet: nothing to finalise.
            lock.unlock()
            return cancel()
        }
        stopping = true
        let continuation = inputs
        let reading = resultsTask
        lock.unlock()
        // The microphone closes now; what was heard is still turned into words.
        audio.stop()
        continuation?.finish()
        Task { [pipe] in
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await reading?.value
            pipe.send(.ended)
        }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let analyzer = self.analyzer
        let continuation = inputs
        let reading = resultsTask
        lock.unlock()
        audio.stop()
        continuation?.finish()
        reading?.cancel()
        pipe.close()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }
}
