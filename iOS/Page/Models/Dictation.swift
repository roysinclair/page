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
    /// The microphone is open. `level` is the voice level, 0…1.
    case listening(level: Double)
    case denied(DictationPermission)
    case unavailable(DictationUnavailable)
    /// Something else took the microphone (a call, Siri, an alarm). The words so far are kept.
    case interrupted

    var isListening: Bool { if case .listening = self { return true } else { return false } }
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

    /// `send` is the box's own button: "Send", "Answer", or "Start" on New task.
    static func listening(device: String, send: String = "Send") -> String {
        "Listening on this \(device) · nothing is sent until you tap \(send)"
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
        case .listening: return Line(text: listening(device: device, send: send), tone: .listening)
        case .denied(.microphone): return Line(text: microphoneOff, tone: .problem, opensSettings: true)
        case .denied(.speech): return Line(text: speechOff, tone: .problem, opensSettings: true)
        case .unavailable(.language(let name)): return Line(text: self.language(name, device: device), tone: .quiet)
        case .unavailable(.noOnDevice): return Line(text: noOnDevice(device: device), tone: .quiet)
        case .interrupted: return Line(text: interrupted, tone: .quiet)
        }
    }
}
