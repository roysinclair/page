import Foundation
import AVFoundation
import Speech

// macOS 26 and later: SpeechAnalyzer with SpeechTranscriber (or DictationTranscriber), on the Mac. The
// language's model is fetched once by macOS and kept by it, not by Page. The microphone is an
// AVAudioEngine input tap converted to the analyzer's format; macOS has no AVAudioSession.
//
// The macOS 26 SDK arrived with Swift 6.2, so everything that names these types sits behind
// `#if compiler(>=6.2)`. An older toolchain gets the stubs at the bottom, and the controller then falls
// through to SFSpeechRecognizer.

/// What this Mac's transcribers say about a language. Used to choose the engine.
struct DictationTranscriberSupport {
    var speechTranscriberAvailable = false
    var speechLocale: Locale?
    var dictationLocale: Locale?
}

#if compiler(>=6.2)

enum DictationAnalyzerKind {
    case speech, dictation
}

/// The engine for `kind`, or nil on a macOS that does not have the transcribers.
func makeDictationAnalyzerEngine(kind: DictationAnalyzerKind, locale: Locale, events: DictationEngineEvents) -> DictationEngine? {
    guard #available(macOS 26.0, *) else { return nil }
    return DictationAnalyzerEngine(kind: kind, locale: locale, events: events)
}

/// SpeechTranscriber and DictationTranscriber's view of `locale` (macOS 26 and later; empty before that).
func probeDictationTranscribers(for locale: Locale) async -> DictationTranscriberSupport {
    guard #available(macOS 26.0, *) else { return DictationTranscriberSupport() }
    var support = DictationTranscriberSupport()
    support.speechTranscriberAvailable = SpeechTranscriber.isAvailable
    support.speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    support.dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale)
    return support
}

@available(macOS 26.0, *)
/// Everything but the audio and Speech callbacks runs on the main thread; those hop to it before they touch state.
final class DictationAnalyzerEngine: DictationEngine, @unchecked Sendable {
    /// Stop waiting for the last words after this long.
    static let finalizeTimeout: TimeInterval = 5

    private let kind: DictationAnalyzerKind
    private let locale: Locale
    private let events: DictationEngineEvents
    private let mic = DictationMicTap()
    private var runTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var listening = false
    private var closed = false
    private var stopRequested = false
    private var interruptRequested = false

    init(kind: DictationAnalyzerKind, locale: Locale, events: DictationEngineEvents) {
        self.kind = kind
        self.locale = locale
        self.events = events
    }

    var level: Double { mic.level }

    func start() {
        runTask = Task { @MainActor [weak self] in await self?.run() }
    }

    func stop() {
        guard !closed, !stopRequested else { return }
        stopRequested = true
        winddown()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        mic.onInterrupt = nil
        mic.stop()
        continuation?.finish()
        continuation = nil
        runTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    // MARK: the run

    @MainActor private func run() async {
        switch kind {
        case .speech:
            // `.fastResults` on top of the brief's `.volatileResults`: measured on this Mac with real-time audio from a
            // file, `.volatileResults` alone delivered nothing for the first ~4 s and then in bursts (each sentence
            // committed ~3 s after it ended), where DictationTranscriber's progressive preset and `.fastResults` show
            // the first words after ~1 s. It trades some accuracy for that. Drop it here if the lag is preferred.
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                           reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            await run(module) { String($0.text.characters) }
        case .dictation:
            let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            await run(module) { String($0.text.characters) }
        }
    }

    @MainActor private func run<M: SpeechModule>(_ module: M, text: @escaping (M.Result) -> String) async {
        // 1. The language's model: here already, or fetched by macOS.
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported:
            return end(.cannotStart)
        case .supported, .downloading:
            do {
                if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    let progress = install.progress
                    events.downloading(progress.isIndeterminate ? nil : progress.fractionCompleted)
                    let observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
                        let fraction: Double? = p.isIndeterminate ? nil : p.fractionCompleted
                        DispatchQueue.main.async {
                            guard let self, !self.closed, !self.listening else { return }
                            self.events.downloading(fraction)
                        }
                    }
                    defer { observation.invalidate() }
                    try await install.downloadAndInstall()
                }
            } catch {
                return end(closed ? nil : .cannotStart)
            }
        case .installed:
            break
        @unknown default:
            break
        }
        guard !closed else { return }

        // 2. The analyzer, and the format it wants.
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            return end(.cannotStart)
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            return end(closed ? nil : .cannotStart)
        }
        guard !closed else { return }

        // 3. Results first, so none are missed, then the input, then the microphone.
        let results = Task { @MainActor [weak self] in
            do {
                for try await result in module.results {
                    guard let self, !self.closed else { return }
                    let words = text(result)
                    if result.isFinal { self.events.commit(words) } else { self.events.volatile(words) }
                }
            } catch {
                guard let self, !self.closed else { return }
                // The analysis failed under us: keep what was heard.
                self.interruptRequested = true
            }
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        do {
            try await analyzer.start(inputSequence: stream)
            guard !closed else { return results.cancel() }
            let converter = DictationBufferConverter(to: format)
            mic.onInterrupt = { [weak self] in self?.interrupted() }
            try mic.start { buffer in
                if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
            }
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            return end(closed ? nil : .interrupted)
        }
        listening = true
        events.listening()
        if stopRequested || interruptRequested { winddown() }

        // 4. Until the results end: after `stop()` (finalised), an interruption, or an error.
        await results.value
        guard !closed else { return }
        end(interruptRequested ? .interrupted : .finished)
    }

    // MARK: ending

    /// Closes the microphone, lets the analyzer finalise what it has heard, and gives up on it after a while.
    private func winddown() {
        mic.onInterrupt = nil
        mic.stop()
        continuation?.finish()
        guard let analyzer else {
            // Still setting up: nothing was heard.
            cancel()
            return end(.finished)
        }
        Task { @MainActor in
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalizeTimeout) { [weak self] in
            guard let self, !self.closed else { return }
            if let analyzer = self.analyzer { Task { await analyzer.cancelAndFinishNow() } }
        }
    }

    private func interrupted() {
        guard !closed, !stopRequested else { return }
        interruptRequested = true
        winddown()
    }

    /// `how` nil: the engine was cancelled meanwhile, so there is nothing to say.
    private func end(_ how: DictationEngineEnd?) {
        guard !closed else { return }
        closed = true
        mic.onInterrupt = nil
        mic.stop()
        continuation?.finish()
        continuation = nil
        // Finished already after a stop; after an error this lets go of the analyzer.
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        if let how { events.ended(how) }
    }
}

#else

enum DictationAnalyzerKind {
    case speech, dictation
}

func makeDictationAnalyzerEngine(kind: DictationAnalyzerKind, locale: Locale, events: DictationEngineEvents) -> DictationEngine? { nil }

func probeDictationTranscribers(for locale: Locale) async -> DictationTranscriberSupport { DictationTranscriberSupport() }

#endif
