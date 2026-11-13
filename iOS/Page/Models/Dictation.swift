import Foundation

// Voice input: speaking fills the message box, and nothing is sent until Send
// (Designs/voice-input.md). These are the pure parts the views draw from; the
// engines (Speech, AVFoundation) live in Services/ and never in Models/, which
// the widget and the logic tests also compile.

/// Where one box's dictation is.
enum DictationPhase: Equatable {
    case idle
    /// Permissions and the recognizer are being set up.
    case preparing
    /// A language model is being fetched by the OS (nil: no percentage to show).
    case downloading(fraction: Double?)
    /// The microphone is open. `level` is the voice level, 0…1. `onDevice` is false when the words are
    /// turned into text by Apple's speech service instead of on the phone (decision D1), and the line says so.
    case listening(level: Double, onDevice: Bool)
    case denied(DictationPermission)
    case unavailable(DictationUnavailable)
    /// Something else took the microphone (a call, Siri, an alarm). The words so far are kept.
    case interrupted

    var isListening: Bool { if case .listening = self { return true } else { return false } }
    /// The voice level while listening, else 0.
    var level: Double { if case .listening(let level, _) = self { return level } else { return 0 } }
    /// False only while listening through Apple's speech service.
    var onDevice: Bool { if case .listening(_, let onDevice) = self { return onDevice } else { return true } }
    /// The mic is open or about to be: the button is a stop button.
    var isActive: Bool {
        switch self {
        case .preparing, .downloading, .listening: return true
        default: return false
        }
    }
    /// A tap can't start listening until something changes (Settings, the language, the phone).
    var isBlocked: Bool {
        switch self {
        case .denied, .unavailable: return true
        default: return false
        }
    }
}

enum DictationPermission: Equatable {
    case microphone
    /// iOS's Speech Recognition permission.
    case speech
}

enum DictationUnavailable: Equatable {
    /// The phone has no on-device model for this language (its display name).
    case language(String)
    /// The phone can't turn speech into text on the device at all.
    case noOnDevice
    /// Neither the on-device recognizer nor the phone's speech service can be used, so the mic is off (D1).
    case noRecognizer
}

/// Every word the voice input shows. One place, so the two phones say the same thing.
enum DictationCopy {
    enum Tone: Equatable { case listening, quiet, problem }

    /// One line above the box: what the mic is doing, or why it can't.
    struct Line: Equatable {
        var text: String
        var tone: Tone
        /// The line offers Open Settings (a permission was refused).
        var opensSettings = false
        /// A determinate download shows a thin bar.
        var progress: Double?
    }

    static let micLabel = "Dictate"
    static let stopLabel = "Stop dictating"
    static let micHint = "Your words go into the message box. Nothing is sent until you tap Send."
    static let listeningPlaceholder = "Listening…"
    static let openSettings = "Open Settings"
    static let preparing = "Getting ready to listen…"
    static let microphoneOff = "Page can't hear you: microphone access is off for Page."
    static let speechOff = "Speech recognition is off for Page."
    static let interrupted = "Stopped listening: something else took the microphone. Your words are kept."
    /// Announced to VoiceOver when the mic opens and when it closes.
    static let announceStart = "Listening. Nothing is sent until you send it."
    static let announceStop = "Stopped listening"

    /// `send` is the box's own button: "Send", "Answer", "Submit all", or "Start" on New task. `onDevice` is false
    /// when Apple's speech service turns the words into text: the line says so the whole time it listens (D1).
    static func listening(device: String, send: String = "Send", onDevice: Bool = true) -> String {
        onDevice ? "Listening on this \(device) · nothing is sent until you tap \(send)"
                 : "Listening with Apple's speech service · nothing is sent until you tap \(send)"
    }

    static func downloading(language: String, device: String, fraction: Double?) -> String {
        let head = "Getting \(language) speech for this \(device)"
        guard let f = fraction else { return head + "…" }
        return head + " · \(percent(f))"
    }

    static func language(_ name: String, device: String) -> String {
        "Speech in \(name) can't be turned into text on this \(device)."
    }

    static func noOnDevice(device: String) -> String {
        "This \(device) can't turn speech into text on the phone itself, so Page leaves the mic off."
    }

    static func noRecognizer(device: String) -> String {
        "This \(device) has no speech recognizer, so the mic is off."
    }

    /// Whole percent, clamped: 0.404 → "40%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// The line for a phase, or nil when the box shows none (idle).
    static func line(for phase: DictationPhase, device: String, language: String, send: String = "Send") -> Line? {
        switch phase {
        case .idle: return nil
        case .preparing: return Line(text: preparing, tone: .quiet)
        case .downloading(let f): return Line(text: downloading(language: language, device: device, fraction: f), tone: .quiet, progress: f)
        case .listening(_, let onDevice): return Line(text: listening(device: device, send: send, onDevice: onDevice), tone: .listening)
        case .denied(.microphone): return Line(text: microphoneOff, tone: .problem, opensSettings: true)
        case .denied(.speech): return Line(text: speechOff, tone: .problem, opensSettings: true)
        case .unavailable(.language(let name)): return Line(text: self.language(name, device: device), tone: .quiet)
        case .unavailable(.noOnDevice): return Line(text: noOnDevice(device: device), tone: .quiet)
        case .unavailable(.noRecognizer): return Line(text: noRecognizer(device: device), tone: .quiet)
        case .interrupted: return Line(text: interrupted, tone: .quiet)
        }
    }
}

// MARK: - The words in the box

/// What dictation has put in a box: the person's own draft (`base`, never touched), the words that are
/// finished (`committed`) and the words still changing (`volatile`). `text` is what the field shows.
///
/// The dictated part is one line: every whitespace run, newlines included, becomes one space, so the
/// dictated part never holds a "\n". The base is the person's own and stays byte for byte as it was.
/// `text` therefore never equals the previous text plus "\n", which is how
/// `DraftSubmit.isReturnKey(old:new:)` recognises the Return key: dictation can never send by accident.
struct DictationDraft: Equatable {
    let base: String
    private(set) var committed = ""
    private(set) var volatile = ""

    init(base: String) { self.base = base }

    /// The words still changing: each update replaces the last one.
    mutating func setVolatile(_ words: String) { volatile = Self.oneLine(words) }

    /// Words that are finished. They are kept, and they take the place of the volatile words.
    mutating func commit(_ words: String) {
        let w = Self.oneLine(words)
        if !w.isEmpty { committed = committed.isEmpty ? w : committed + " " + w }
        volatile = ""
    }

    /// Everything said so far, finished or not.
    var spoken: String { [committed, volatile].filter { !$0.isEmpty }.joined(separator: " ") }

    /// The base, one space, then the spoken words. No space when the base is empty or already ends in
    /// whitespace, and none at all (the base alone) until something has been said.
    var text: String {
        let words = spoken
        guard !words.isEmpty else { return base }
        let joiner = (base.last?.isWhitespace ?? true) ? "" : " "
        return base + joiner + words
    }

    /// What stays in the box when dictation ends: the words still changing are kept as they stand.
    func finish() -> String { text }

    /// One line: whitespace runs (spaces, tabs, newlines) collapse to a single space, and the ends are trimmed.
    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Has the person changed the box under the dictation?
enum DictationGuard {
    /// The field no longer holds what dictation last wrote (read back from the field itself, not from
    /// the draft, because a field may trim what it is given): stop, and drop the late results.
    static func userEdited(current: String, lastWritten: String) -> Bool { current != lastWritten }
}

// MARK: - Which recognizer

/// Which speech engine listens, from what the phone can do. Pure: the controller asks the phone and
/// passes the answers in. On the device first, then Apple's own speech service (decision D1).
/// A runtime failure (a model that won't install, no audio format) calls `pick` again with that
/// engine's input set to false, so the chain lives only here.
enum DictationEngineChoice: Equatable {
    /// iOS 26+: SpeechAnalyzer with SpeechTranscriber, on the device.
    case speechTranscriber
    /// iOS 26+: SpeechAnalyzer with DictationTranscriber, on the device.
    case dictationTranscriber
    /// SFSpeechRecognizer with `requiresOnDeviceRecognition`.
    case recognizerOnDevice
    /// SFSpeechRecognizer through Apple's server (each request ends near a minute, so the engine restarts it).
    case recognizerServer
    case unavailable(DictationUnavailable)

    /// The words are turned into text on the phone itself.
    var isOnDevice: Bool {
        switch self {
        case .speechTranscriber, .dictationTranscriber, .recognizerOnDevice: return true
        case .recognizerServer, .unavailable: return false
        }
    }

    /// The first major version with SpeechAnalyzer.
    static let analyzerMajor = 26

    /// - Parameters:
    ///   - osMajor: the OS's major version (17 … 27).
    ///   - transcriberAvailable: `SpeechTranscriber.isAvailable`.
    ///   - transcriberSupportsLocale: SpeechTranscriber has the language, and its assets are not `.unsupported`.
    ///   - dictationSupportsLocale: DictationTranscriber has the language, and its assets are not `.unsupported`.
    ///   - sfSupportsLocale: `SFSpeechRecognizer(locale:)` exists for the language.
    ///   - sfOnDevice: that recognizer's `supportsOnDeviceRecognition`.
    ///   - sfAvailable: that recognizer's `isAvailable`.
    ///   - language: the language's display name, for the "can't be turned into text" line.
    static func pick(osMajor: Int, transcriberAvailable: Bool, transcriberSupportsLocale: Bool,
                     dictationSupportsLocale: Bool, sfSupportsLocale: Bool, sfOnDevice: Bool, sfAvailable: Bool,
                     language: String) -> DictationEngineChoice {
        let analyzer = osMajor >= analyzerMajor
        if analyzer, transcriberAvailable, transcriberSupportsLocale { return .speechTranscriber }
        if analyzer, dictationSupportsLocale { return .dictationTranscriber }
        if sfSupportsLocale, sfAvailable { return sfOnDevice ? .recognizerOnDevice : .recognizerServer }
        // Nothing can listen. A language no path knows is its own line; the rest is "no recognizer".
        let someoneKnowsIt = sfSupportsLocale || (analyzer && (transcriberSupportsLocale || dictationSupportsLocale))
        return .unavailable(someoneKnowsIt ? .noRecognizer : .language(language))
    }
}

// MARK: - When to stop by itself

/// The two limits on one listening session, as functions of timestamps: 20 s without new words, and
/// 10 min in all. New words reset the silence, never the cap.
struct DictationClock: Equatable {
    static let silenceLimit: TimeInterval = 20
    static let capLimit: TimeInterval = 10 * 60

    enum Expiry: Equatable { case silence, cap }

    let startedAt: Date
    private(set) var lastWordsAt: Date

    /// `startedAt` is when the microphone opened: silence is counted from there until the first words.
    init(startedAt: Date) {
        self.startedAt = startedAt
        lastWordsAt = startedAt
    }

    /// New words were heard. An earlier time than the last is ignored.
    mutating func heardWords(at time: Date) { if time > lastWordsAt { lastWordsAt = time } }

    var silenceDeadline: Date { lastWordsAt.addingTimeInterval(Self.silenceLimit) }
    var capDeadline: Date { startedAt.addingTimeInterval(Self.capLimit) }
    /// The soonest moment either limit could be reached (it moves later when words arrive).
    var nextDeadline: Date { min(silenceDeadline, capDeadline) }

    /// Which limit has been reached at `now`, if any. The cap wins when both have.
    func expiry(at now: Date) -> Expiry? {
        if now >= capDeadline { return .cap }
        if now >= silenceDeadline { return .silence }
        return nil
    }
}
