import AVFoundation
import Foundation

// The microphone for voice input (Designs/voice-input.md): the audio session, one AVAudioEngine tap, the voice
// level, and the ways the phone takes the microphone away. Both speech engines read from here. Nothing is
// written to disk or kept: a buffer lives only while the recognizer takes it.

/// Opens and closes the microphone. Thread-safe: `start` and `stop` come from the main actor, the tap runs on the
/// audio thread, and the notifications arrive anywhere.
final class DictationAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    /// The tap is delivering. Set only once the engine runs, and only if nothing closed it meanwhile.
    private var running = false
    /// `stop()` has been called, even if nothing was running. One `DictationAudio` serves one session, so this is
    /// final: a `start()` that was still waiting for the audio session (a slow `setActive`) when the session was
    /// cancelled must not open the microphone afterwards.
    private var closed = false
    private var observers: [NSObjectProtocol] = []
    private var lastLevelAt = CFAbsoluteTime(0)
    private var peak = 0.0

    /// How often the level is published (about 15 Hz).
    private static let levelInterval: CFAbsoluteTime = 1.0 / 15.0

    enum StartError: Error { case noInput, closed }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// Opens the microphone. `onBuffer` runs on the audio thread for every buffer (it must not block);
    /// `onLevel` is 0…1 at about 15 Hz; `onInterrupted` is called once if something else takes the microphone.
    /// Throws `closed` if `stop()` came first (or while it was waiting), and leaves the audio session as it found it.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping @Sendable (Double) -> Void,
               onInterrupted: @escaping @Sendable () -> Void) throws {
        guard !isClosed else { throw StartError.closed }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        } catch {
            // `record` plays nothing, so ducking is moot: try again without the option rather than fail.
            try session.setCategory(.record, mode: .measurement, options: [])
        }
        // Recording silences haptics and system sounds unless told otherwise: the start and stop ticks must play.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        // The slow part is over. If the session was cancelled while it ran, give the audio session back and stop here.
        func giveBack() { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        guard !isClosed else { giveBack(); throw StartError.closed }

        let input = engine.inputNode
        // After the session is active: before that the format is the previous route's (or empty).
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { giveBack(); throw StartError.noInput }
        lock.lock(); peak = 0; lastLevelAt = 0; lock.unlock()
        // The tap block captures nothing main-actor: it runs on the audio thread.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, !self.isClosed else { return }
            onBuffer(buffer)
            if let level = self.levelToPublish(for: buffer) { onLevel(level) }
        }
        engine.prepare()
        func close() {
            input.removeTap(onBus: 0)
            engine.stop()
            giveBack()
        }
        do {
            try engine.start()
        } catch {
            close()
            throw error
        }
        // Registered once the engine runs, so the start itself is not mistaken for a loss.
        let center = NotificationCenter.default
        let lost: @Sendable (Notification) -> Void = { [weak self] _ in
            guard let self, self.isRunning else { return }
            onInterrupted()
        }
        let observed: [NSObjectProtocol] = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began { lost(note) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
                // The headset or the Bluetooth microphone went away. (Our own category change is not a loss.)
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable { lost(note) }
            },
            // The engine stops itself when the route or the sample rate changes under it.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: lost),
        ]
        // Decided under the lock: either `stop()` came first and this start undoes itself, or `stop()` will find it running.
        lock.lock()
        if closed {
            lock.unlock()
            observed.forEach { center.removeObserver($0) }
            close()
            throw StartError.closed
        }
        running = true
        observers = observed
        lock.unlock()
    }

    /// Closes the microphone and gives the audio session back. Safe to call twice, and before or during `start()`:
    /// a start that has not finished then undoes itself.
    func stop() {
        lock.lock()
        closed = true
        let was = running
        running = false
        let held = observers
        observers = []
        lock.unlock()
        held.forEach { NotificationCenter.default.removeObserver($0) }
        guard was else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Level

    /// Keeps the loudest level since the last publish, and returns it when it is time (about 15 Hz).
    private func levelToPublish(for buffer: AVAudioPCMBuffer) -> Double? {
        let level = Self.level(of: buffer)
        lock.lock(); defer { lock.unlock() }
        peak = max(peak, level)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelAt >= Self.levelInterval else { return nil }
        lastLevelAt = now
        defer { peak = 0 }
        return peak
    }

    /// RMS of the first channel, in dBFS, mapped from -58…-18 dB to 0…1 (speech on the phone's microphone
    /// sits in the middle of that).
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum = 0.0
        if let data = buffer.floatChannelData {
            let samples = data[0]
            for i in 0..<frames { let s = Double(samples[i]); sum += s * s }
        } else if let data = buffer.int16ChannelData {
            let samples = data[0]
            for i in 0..<frames { let s = Double(samples[i]) / 32768; sum += s * s }
        } else {
            return 0
        }
        return mapped(rms: (sum / Double(frames)).squareRoot())
    }

    static func mapped(rms: Double) -> Double {
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 58) / 40, 0), 1)
    }
}

/// Converts the tap's buffers to the format a SpeechAnalyzer wants. One converter, kept across buffers: each call
/// hands over its buffer once, then says "no data now" (never "end of stream", which would end every later call).
final class DictationBufferConverter: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    init(to target: AVAudioFormat) { self.target = target }

    /// A fresh buffer in the target format, or nil when the conversion fails. Call from one thread (the audio thread).
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || source != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
            source = input.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
