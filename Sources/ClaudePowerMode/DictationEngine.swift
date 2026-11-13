import Foundation

// What the controller needs from a speech engine, so the macOS 26 analyzer and SFSpeechRecognizer
// look the same to it. An engine owns the microphone for as long as it runs.

/// What an engine tells the controller. Every closure is called on the main thread, and an engine
/// says nothing more once it has been cancelled or has ended.
struct DictationEngineEvents {
    /// A language model is being fetched by macOS (nil: no percentage to show).
    var downloading: (Double?) -> Void
    /// The microphone is open and the recognizer is running.
    var listening: () -> Void
    /// The words still changing (replaces the last ones).
    var volatile: (String) -> Void
    /// Words that are final.
    var commit: (String) -> Void
    var ended: (DictationEngineEnd) -> Void
}

enum DictationEngineEnd: Equatable {
    /// Done after `stop()`: the last words have been delivered.
    case finished
    /// Never started listening (the language's model is unsupported or could not be fetched, the
    /// recognizer is not available): the controller tries the next engine.
    case cannotStart
    /// The default input changed or failed, or the recognizer gave up, while listening or opening the
    /// microphone. What was heard has been delivered.
    case interrupted
    /// The recognizer is there but will not run (Dictation is off in System Settings, say).
    case refused
}

protocol DictationEngine: AnyObject {
    /// The voice level, 0…1. Safe to read from the main thread at any time.
    var level: Double { get }
    /// Starts asynchronously and reports through its events.
    func start()
    /// Closes the microphone now, finalises what was heard, delivers it and ends with `.finished`.
    func stop()
    /// Closes the microphone now and drops everything: no more events.
    func cancel()
}
