import AVFoundation
import Foundation
import Speech

// Voice input's engines (Designs/voice-input.md): one protocol, two implementations. An engine opens the
// microphone, turns what it hears into words, and reports them as an ordered stream of events. The controller
// (DictationController) owns the box, the draft and the limits; an engine knows nothing about them.

/// What an engine reports, in order.
enum DictationEvent: Equatable {
    /// Getting ready: the recognizer is being set up (also after a language download).
    case preparing
    /// A language model is being fetched by the OS (nil: no fraction to show).
    case downloading(Double?)
    /// The microphone is open. `onDevice` is false when Apple's speech service turns the words into text.
    case listening(onDevice: Bool)
    /// The voice level, 0…1.
    case level(Double)
    /// The words still changing, as they stand now (replaces the last volatile words).
    case volatile(String)
    /// Words that are finished.
    case committed(String)
    /// Something else took the microphone (or it could not be opened).
    case interrupted
    /// This engine can't be used (before it listens), or died (after).
    case failed
    /// After `stop()`: the last words have been delivered.
    case ended
}

protocol DictationEngine: AnyObject, Sendable {
    /// Everything the engine reports, in order. One consumer. It finishes after `cancel()`.
    var events: AsyncStream<DictationEvent> { get }
    /// Gets ready and opens the microphone. Returns once it is listening, or has said why it is not.
    func start() async
    /// Stops listening and finalises the words still changing; `.ended` follows when they have arrived.
    func stop()
    /// Stops listening at once and drops everything that was still coming. Safe to call twice.
    func cancel()
}

/// The ordered events of one engine. Thread-safe: results, the audio thread and notifications all send.
final class DictationEventPipe: @unchecked Sendable {
    let stream: AsyncStream<DictationEvent>
    private let continuation: AsyncStream<DictationEvent>.Continuation
    private let lock = NSLock()
    private var closed = false

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: DictationEvent.self, bufferingPolicy: .unbounded)
    }

    func send(_ event: DictationEvent) {
        lock.lock(); let isClosed = closed; lock.unlock()
        if !isClosed { continuation.yield(event) }
    }

    /// No more events: the consumer's loop ends.
    func close() {
        lock.lock(); closed = true; lock.unlock()
        continuation.finish()
    }
}

// MARK: - Permissions

enum DictationPermissions {
    enum Outcome: Equatable { case granted, microphoneDenied, speechDenied }

    /// Asks for the microphone, then for Speech Recognition (the SDK does not say whether SpeechAnalyzer needs
    /// the second, so both are asked for). Each prompt shows once; after a refusal only Settings can change it.
    static func request() async -> Outcome {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: break
        case .denied: return .microphoneDenied
        default:
            guard await AVAudioApplication.requestRecordPermission() else { return .microphoneDenied }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .granted
        case .notDetermined:
            let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            return status == .authorized ? .granted : .speechDenied
        default:
            return .speechDenied
        }
    }
}

// MARK: - What this phone can do

/// The answers `DictationEngineChoice.pick` wants, asked of the phone once per start, and the locale each engine
/// listens for. Mutable: an engine that fails to start is ruled out and `pick` runs again.
struct DictationCapabilities {
    var osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    var transcriberAvailable = false
    var transcriberSupportsLocale = false
    var dictationSupportsLocale = false
    var sfSupportsLocale = false
    var sfOnDevice = false
    var sfAvailable = false
    /// The nearest locale each engine supports for the phone's language.
    var transcriberLocale: Locale?
    var dictationLocale: Locale?
    var sfLocale: Locale?

    func pick(language: String) -> DictationEngineChoice {
        DictationEngineChoice.pick(osMajor: osMajor, transcriberAvailable: transcriberAvailable,
                                   transcriberSupportsLocale: transcriberSupportsLocale,
                                   dictationSupportsLocale: dictationSupportsLocale, sfSupportsLocale: sfSupportsLocale,
                                   sfOnDevice: sfOnDevice, sfAvailable: sfAvailable, language: language)
    }

    /// An engine that failed to start (an unsupported model, no audio format, an install that threw): `pick` moves on.
    mutating func ruleOut(_ choice: DictationEngineChoice) {
        switch choice {
        case .speechTranscriber: transcriberSupportsLocale = false
        case .dictationTranscriber: dictationSupportsLocale = false
        case .recognizerOnDevice, .recognizerServer: sfAvailable = false
        case .unavailable: break
        }
    }

    static func probe(for locale: Locale) async -> DictationCapabilities {
        var caps = DictationCapabilities()
        if caps.osMajor >= DictationEngineChoice.analyzerMajor, #available(iOS 26, *) {
            await caps.probeAnalyzer(locale)
        }
        if let recognizer = nearestRecognizer(for: locale) {
            caps.sfSupportsLocale = true
            caps.sfLocale = recognizer.locale
            caps.sfOnDevice = recognizer.supportsOnDeviceRecognition
            caps.sfAvailable = recognizer.isAvailable
        }
        #if DEBUG
        // `-NWVoiceServer`: the phone has no on-device engine, to try Apple's speech service in the simulator (which
        // cannot load the on-device models). `-NWVoiceFake`: the same, with a scripted engine instead of a microphone
        // (RenderHarnessVoice.swift), to try the controller.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-NWVoiceServer") || arguments.contains("-NWVoiceFake") {
            caps.transcriberAvailable = false
            caps.transcriberSupportsLocale = false
            caps.dictationSupportsLocale = false
            caps.sfOnDevice = false
        }
        if arguments.contains("-NWVoiceFake") {
            caps.sfSupportsLocale = true
            caps.sfAvailable = true
        }
        #endif
        return caps
    }

    @available(iOS 26, *)
    private mutating func probeAnalyzer(_ locale: Locale) async {
        transcriberAvailable = SpeechTranscriber.isAvailable
        if transcriberAvailable, let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = AnalyzerDictationEngine.makeSpeechTranscriber(l)
            // `.unsupported` is the OS saying this device can't use the language's model.
            if await AssetInventory.status(forModules: [module]) != .unsupported {
                transcriberSupportsLocale = true
                transcriberLocale = l
            }
        }
        if let l = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = AnalyzerDictationEngine.makeDictationTranscriber(l)
            if await AssetInventory.status(forModules: [module]) != .unsupported {
                dictationSupportsLocale = true
                dictationLocale = l
            }
        }
    }

    /// `SFSpeechRecognizer(locale:)` is nil for a locale it does not list: try the same language in another region.
    private static func nearestRecognizer(for locale: Locale) -> SFSpeechRecognizer? {
        if let exact = SFSpeechRecognizer(locale: locale) { return exact }
        let language = locale.language.languageCode
        let sameLanguage = SFSpeechRecognizer.supportedLocales().filter { $0.language.languageCode == language && language != nil }
        let region = locale.region
        let best = sameLanguage.first { $0.region == region && region != nil }
            ?? sameLanguage.sorted { $0.identifier < $1.identifier }.first
        return best.flatMap { SFSpeechRecognizer(locale: $0) }
    }

    /// The engine for a choice, or nil for `.unavailable`.
    func makeEngine(_ choice: DictationEngineChoice) -> DictationEngine? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-NWVoiceFake") { return FakeDictationEngine() }
        #endif
        switch choice {
        case .speechTranscriber:
            if #available(iOS 26, *), let l = transcriberLocale { return AnalyzerDictationEngine(kind: .speech, locale: l) }
            return nil
        case .dictationTranscriber:
            if #available(iOS 26, *), let l = dictationLocale { return AnalyzerDictationEngine(kind: .dictation, locale: l) }
            return nil
        case .recognizerOnDevice:
            return sfLocale.map { RecognizerDictationEngine(locale: $0, onDevice: true) }
        case .recognizerServer:
            return sfLocale.map { RecognizerDictationEngine(locale: $0, onDevice: false) }
        case .unavailable:
            return nil
        }
    }
}
