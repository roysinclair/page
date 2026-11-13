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
    static let micHelp = "Dictate · ⌥⌘D · nothing is sent until you press Return"
    static let stopHelp = "Stop dictating · ⌥⌘D · your words stay in the box"
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
