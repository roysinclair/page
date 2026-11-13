import Foundation

// Voice input on the Mac: speaking fills the Steer box, and nothing is sent
// until Return (Designs/voice-input.md, "Mac"). The pure parts the panel draws
// from; the engines (Speech, AVFoundation) live in the app target. The phones
// have the same types with the same words (iOS Models/Dictation.swift,
// Android model/Dictation.kt). Foundation only: PageCore also builds on Linux.

/// Where the Steer box's dictation is.
enum DictationPhase: Equatable {
    case idle
    /// Permissions and the recognizer are being set up.
    case preparing
    /// A language model is being fetched by macOS (nil: no percentage to show).
    case downloading(fraction: Double?)
    /// The microphone is open. `level` is the voice level, 0…1. `onDevice` is false on Apple's speech service.
    case listening(level: Double, onDevice: Bool)
    case denied(DictationPermission)
    case unavailable(DictationUnavailable)
    /// Something else took the microphone. The words so far are kept.
    case interrupted

    var isListening: Bool { if case .listening = self { return true } else { return false } }
    /// The mic is open or about to be: the button is a stop button.
    var isActive: Bool {
        switch self {
        case .preparing, .downloading, .listening: return true
        default: return false
        }
    }
    /// A click can't start listening until something changes (System Settings, the language).
    var isBlocked: Bool {
        switch self {
        case .denied, .unavailable: return true
        default: return false
        }
    }
    var level: Double { if case .listening(let l, _) = self { return l } else { return 0 } }
}

enum DictationPermission: Equatable {
    case microphone
    /// macOS's Speech Recognition permission.
    case speech
}

enum DictationUnavailable: Equatable {
    /// No path (on the Mac or Apple's service) supports this language (its display name).
    case language(String)
    /// The Mac has no speech recognizer at all.
    case noRecognizer
}

/// Every word the Mac's voice input shows.
enum DictationCopy {
    enum Tone: Equatable { case listening, quiet, problem }

    /// One line above the Steer box: what the mic is doing, or why it can't.
    struct Line: Equatable {
        var text: String
        var tone: Tone
        /// The line offers Open Settings (a permission was refused).
        var opensSettings = false
        /// A determinate download shows a thin bar.
        var progress: Double?
    }

    static let device = "Mac"
    static let micHelp = "Dictate · ⌘D · nothing is sent until you press Return"
    static let stopHelp = "Stop dictating · ⌘D · your words stay in the box"
    static let micLabel = "Dictate"
    static let stopLabel = "Stop dictating"
    static let listeningPlaceholder = "Listening…"
    static let openSettings = "Open Settings"
    static let preparing = "Getting ready to listen…"
    static let microphoneOff = "Page can't hear you: microphone access is off for Page Studio."
    static let speechOff = "Speech recognition is off for Page Studio."
    static let interrupted = "Stopped listening: something else took the microphone. Your words are kept."
    static let noRecognizer = "This Mac has no speech recognizer, so the mic is off."

    static func listening(onDevice: Bool) -> String {
        (onDevice ? "Listening on this Mac" : "Listening with Apple's speech service") + " · nothing is sent until you press Return"
    }

    static func downloading(language: String, fraction: Double?) -> String {
        let head = "Getting \(language) speech for this Mac"
        guard let f = fraction else { return head + "…" }
        return head + " · \(percent(f))"
    }

    static func language(_ name: String) -> String {
        "Speech in \(name) can't be turned into text on this Mac."
    }

    /// Whole percent, clamped: 0.404 → "40%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// The line for a phase, or nil when the box shows none (idle).
    static func line(for phase: DictationPhase, language: String) -> Line? {
        switch phase {
        case .idle: return nil
        case .preparing: return Line(text: preparing, tone: .quiet)
        case .downloading(let f): return Line(text: downloading(language: language, fraction: f), tone: .quiet, progress: f)
        case .listening(_, let onDevice): return Line(text: listening(onDevice: onDevice), tone: .listening)
        case .denied(.microphone): return Line(text: microphoneOff, tone: .problem, opensSettings: true)
        case .denied(.speech): return Line(text: speechOff, tone: .problem, opensSettings: true)
        case .unavailable(.language(let name)): return Line(text: self.language(name), tone: .quiet)
        case .unavailable(.noRecognizer): return Line(text: noRecognizer, tone: .quiet)
        case .interrupted: return Line(text: interrupted, tone: .quiet)
        }
    }
}

// MARK: - The words in the box

/// What dictation has put in the Steer box: the draft that was there (`base`), the words that are
/// final (`committed`) and the words still changing (`volatile`).
///
/// `text` is `base` + one joiner + `committed` + one joiner + `volatile`. A joiner is a single
/// space, left out when the side before it is empty or already ends in whitespace. Every piece the
/// recognizer hands over is cleaned first: newlines become spaces, runs of whitespace collapse to
/// one space, and the ends are trimmed. So dictation never adds a newline, and a dictated update can
/// never read as the Return key. The one exception is `base`, which is the person's own typing and
/// is kept exactly as it was (so `text` holds a newline only if `base` did).
///
/// Nothing here is sent anywhere: the controller only writes `text` into the composer.
struct DictationDraft: Equatable {
    let base: String
    private(set) var committed = ""
    private(set) var volatile = ""

    init(base: String) { self.base = base }

    /// One line: whitespace runs (spaces, tabs, newlines) collapse to a single space, and the ends are trimmed.
    /// "" stays "".
    static func oneLine(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The words still changing: replaces the previous volatile words.
    mutating func setVolatile(_ raw: String) { volatile = Self.oneLine(raw) }

    /// Words that are final: kept for good, and the volatile words they replace are dropped.
    mutating func commit(_ raw: String) {
        let piece = Self.oneLine(raw)
        if !piece.isEmpty { committed = committed.isEmpty ? piece : committed + " " + piece }
        volatile = ""
    }

    /// Everything said so far, final or not.
    var spoken: String { [committed, volatile].filter { !$0.isEmpty }.joined(separator: " ") }

    /// What the box shows now: the base, one joiner, then the spoken words. No joiner when the base is empty or
    /// ends in whitespace, and the base alone until something has been said.
    var text: String {
        let words = spoken
        guard !words.isEmpty else { return base }
        return base + ((base.last?.isWhitespace ?? true) ? "" : " ") + words
    }

    /// The listening is over: the words still changing stay as they stand. Returns the final text.
    func finish() -> String { text }

    /// Whether anything was heard.
    var hasWords: Bool { !committed.isEmpty || !volatile.isEmpty }
}

/// The person typing under the dictation.
enum DictationGuard {
    /// The box no longer holds what dictation last wrote (or, before it wrote anything, the draft
    /// it started from): the person edited it, so listening stops and late results are dropped.
    static func userEdited(current: String, lastWritten: String) -> Bool { current != lastWritten }
}

// MARK: - Which engine listens

enum DictationEngineChoice: Equatable {
    /// macOS 26+: SpeechAnalyzer with SpeechTranscriber, on the Mac.
    case speechTranscriber
    /// macOS 26+: SpeechAnalyzer with DictationTranscriber, on the Mac.
    case dictationTranscriber
    /// SFSpeechRecognizer with `requiresOnDeviceRecognition = true`.
    case recognizerOnDevice
    /// SFSpeechRecognizer on Apple's speech service (decision D1: the last resort, and the line says so).
    case recognizerServer
    case unavailable(DictationUnavailable)

    /// The first major version with SpeechAnalyzer.
    static let analyzerMajor = 26

    /// Pure. The engine to use, on the Mac first (decision D1): SpeechTranscriber, DictationTranscriber,
    /// SFSpeechRecognizer on the device, then SFSpeechRecognizer on Apple's server. A language that one path
    /// lacks falls through to the next, so the language line only shows when no path has it. A runtime failure
    /// (a model that won't install) calls `pick` again with that engine's input set to false.
    ///
    /// - Parameters:
    ///   - osMajor: the macOS major version. The transcribers are 26 and later; below that their inputs are ignored.
    ///   - transcriberAvailable: `SpeechTranscriber.isAvailable`.
    ///   - transcriberSupportsLocale: `SpeechTranscriber.supportedLocale(equivalentTo:)` found one, and its model can be had.
    ///   - dictationSupportsLocale: the same for `DictationTranscriber`.
    ///   - sfSupportsLocale: an `SFSpeechRecognizer` exists for the language.
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

    /// The words stay on this Mac (false: Apple's speech service listens, or nothing does).
    var isOnDevice: Bool {
        switch self {
        case .speechTranscriber, .dictationTranscriber, .recognizerOnDevice: return true
        case .recognizerServer, .unavailable: return false
        }
    }
}

/// The nearest language a recognizer lists, by identifier.
enum DictationLocale {
    /// Pure. The identifier in `supported` nearest to `wanted`: the same one (`en_GB` and `en-GB` are the
    /// same), else the same language in the same region, else the same language (the first in sort order).
    /// nil when no supported identifier shares the language.
    static func nearest(to wanted: String, in supported: [String]) -> String? {
        let w = parts(wanted)
        let candidates = supported.map { ($0, parts($0)) }.filter { $0.1.language == w.language }
        if let exact = candidates.first(where: { $0.1 == w }) { return exact.0 }
        if let region = w.region, let same = candidates.first(where: { $0.1.region == region }) { return same.0 }
        return candidates.map(\.0).sorted().first
    }

    /// "en_GB", "en-GB", "zh-Hans_CN": the lower-case language, and the region (two letters or three digits) if any.
    static func parts(_ identifier: String) -> (language: String, region: String?) {
        // "en_US@calendar=gregorian": the part after @ is a setting, not a language or a region.
        let core = identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        let bits = core.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard let first = bits.first else { return ("", nil) }
        let region = bits.dropFirst().last { ($0.count == 2 && $0.allSatisfy(\.isLetter)) || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }
        return (first.lowercased(), region?.uppercased())
    }
}

// MARK: - When listening stops by itself

/// The silence limit and the cap on one listening, as functions of dates: 20 s without new words, and 10 min
/// in all. New words reset the silence, never the cap. The controller feeds it the time and the moments words arrived.
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

// MARK: - The voice level

enum DictationLevel {
    /// Pure. A buffer's RMS (0…1 of full scale) as a bar level 0…1: -55 dB and below is 0, -15 dB and above is 1.
    static func level(rms: Double) -> Double {
        guard rms > 0, rms.isFinite else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 55) / 40))
    }

    /// Pure. The bars rise at once and fall a little at a time, so they read as a voice and not a flicker.
    static func smoothed(previous: Double, next: Double) -> Double {
        next >= previous ? next : max(next, previous * 0.8)
    }
}

// MARK: - Keys

/// What a key means to the voice input while a Steer box is open. Pure, so it is tested without a panel.
enum DictationKeys {
    enum Action: Equatable {
        /// ⌘D: start, or stop and keep the words. The key is ours.
        case toggle
        /// Esc while listening: stop and keep the words. The box stays; the next Esc closes it. The key is ours.
        case stopListening
        /// Return: stop listening and drop anything still arriving, then Return sends what shows, as it does today.
        case stopForSend
    }

    /// Pure. nil when the key is not one the voice input takes.
    static func action(for press: NowKeyPress, composerOpen: Bool, dictating: Bool) -> Action? {
        guard composerOpen, press.phase == .down else { return nil }
        switch press.key {
        case .char("d") where press.command && !press.option && !press.control:
            return press.isRepeat ? nil : .toggle
        case .esc where !press.hasModifiers:
            return dictating ? .stopListening : nil
        case .ret where !press.hasModifiers:
            return .stopForSend
        default:
            return nil
        }
    }
}
