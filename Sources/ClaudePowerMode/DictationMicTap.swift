import Foundation
import AVFoundation
@testable import PageCore

// The microphone for voice input: an AVAudioEngine input tap, shared by both engines. macOS has no
// AVAudioSession, so the engine reads the default input device directly. Nothing here writes audio to
// disk or sends it anywhere: each buffer goes straight to the recognizer that asked for it, and the tap
// is removed the moment listening stops (the microphone is open only while the stop button shows).
//
// AVAudioEngine raises Objective-C exceptions (which Swift cannot catch) for a tap installed twice, a tap
// whose format differs from the hardware's, and an input with no sample rate or no channels (a Mac without
// a microphone). So the tap is always removed first, installed with the input's own format, and only
// installed when that format is usable.

final class DictationMicTap {
    struct Failure: Error, Equatable {
        let reason: String
    }

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var smoothed = 0.0

    /// The voice level, 0…1, as of the last buffer. Safe to read from any thread.
    var level: Double {
        lock.lock(); defer { lock.unlock() }
        return smoothed
    }

    /// The default input changed or the engine stopped under us (a headset connected, a device removed).
    /// Called on the main thread. The tap is already stopped.
    var onInterrupt: (() -> Void)?

    deinit { stop() }

    /// Opens the microphone. `onBuffer` is called on the audio thread for every buffer.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure(reason: "no usable input") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.measure(buffer)
            onBuffer(buffer)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.engine != nil else { return }
            self.stop()
            self.onInterrupt?()
        }
        self.engine = engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw Failure(reason: error.localizedDescription)
        }
    }

    /// Closes the microphone. Safe to call twice.
    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        lock.lock(); smoothed = 0; lock.unlock()
    }

    /// The RMS of channel 0, as a bar level (`DictationLevel`).
    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        let samples = channels[0]
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let rms = Double((sum / Float(n)).squareRoot())
        let next = DictationLevel.level(rms: rms)
        lock.lock()
        smoothed = DictationLevel.smoothed(previous: smoothed, next: next)
        lock.unlock()
    }
}

/// Converts the microphone's buffers to the format the analyzer wants. Used on the audio thread only.
final class DictationBufferConverter: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    init(to target: AVAudioFormat) { self.target = target }

    /// A new buffer in the target format, or nil if this one could not be converted.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || source != buffer.format {
            source = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter, buffer.format.sampleRate > 0 else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
