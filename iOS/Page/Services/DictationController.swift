import Combine
import SwiftUI
import UIKit

// Voice input (Designs/voice-input.md): the one controller the whole app shares. It owns at most one listening
// session at a time, picks the engine, writes the words into the box's draft, and stops by itself. Speaking only
// fills the draft: nothing here sends anything. The boxes see it through `\.nwDictation` (NWDictation.swift).

@MainActor
final class DictationController: ObservableObject {
    /// The box the phase belongs to (nil while nothing is listening and no note shows).
    @Published private(set) var box: String?
    @Published private(set) var phase: DictationPhase = .idle

    /// One press of the mic, from the first tap to the last word.
    private final class Session {
        let box: String
        let binding: Binding<String>
        var draft: DictationDraft
        /// What the field held after dictation's last write, read back from the field itself.
        var lastWritten: String
        var clock: DictationClock?
        var engine: DictationEngine?
        var runTask: Task<Void, Never>?
        var starter: Task<Void, Never>?
        var clockTask: Task<Void, Never>?
        var drainTimeout: Task<Void, Never>?
        /// Over: whatever the engine still says is dropped.
        var cancelled = false
        /// The microphone has been open.
        var listening = false

        init(box: String, binding: Binding<String>) {
            self.box = box
            self.binding = binding
            draft = DictationDraft(base: binding.wrappedValue)
            lastWritten = binding.wrappedValue
        }
    }

    /// Getting ready, downloading or listening.
    private var session: Session?
    /// Stopped by the person (or a limit); the microphone is closed and the last words are still arriving.
    private var draining: Session?
    private var noteTask: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()

    /// How long the last words are waited for after a stop.
    private static let drainLimit: TimeInterval = 3
    /// The Interrupted line goes away by itself after this.
    private static let noteLifetime: TimeInterval = 4

    init() {
        // The app going away takes the microphone with it: stop and write nothing more. The permission prompts also
        // make the scene inactive, so inactive only counts once the microphone is open.
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.willResignActiveNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.appLeft(includingPreparing: false) }
        }.store(in: &observers)
        center.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.appLeft(includingPreparing: true) }
        }.store(in: &observers)
    }

    // MARK: What the boxes see

    /// "iPhone", or "iPad" (the app is iPhone-only, so an iPad runs it as a phone).
    static var deviceWord: String { UIDevice.current.model.hasPrefix("iPad") ? "iPad" : "iPhone" }

    /// The phone's language, as it names itself ("English (United Kingdom)").
    static var languageName: String {
        Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
    }

    /// The environment value for the boxes (`\.nwDictation`). Closures are called from view callbacks, on the main thread.
    func nwDictation(device: String? = nil, language: String? = nil) -> NWDictation {
        var d = NWDictation(device: device ?? Self.deviceWord, language: language ?? Self.languageName)
        d.box = box
        d.phase = phase
        d.toggle = { [weak self] box, draft in MainActor.assumeIsolated { self?.toggle(box, draft) } }
        d.cancel = { [weak self] box in MainActor.assumeIsolated { self?.cancel(box) } }
        d.openSettings = { [weak self] in MainActor.assumeIsolated { self?.openSettings() } }
        return d
    }

    // MARK: Start and stop

    /// The mic button. Starts listening into `draft`, or stops (keeping the words) when this box is already listening.
    func toggle(_ box: String, _ draft: Binding<String>) {
        if let s = session, s.box == box {
            finalise(s)
        } else {
            start(box, draft)
        }
    }

    /// Stops without writing anything more: Send, an edit, leaving the screen, the box locking. What shows is kept,
    /// and a note (Settings, language) that was showing goes.
    func cancel(_ box: String) {
        if let s = session, s.box == box { cancelSession(s) }
        if let d = draining, d.box == box { cancelSession(d) }
        if self.box == box, session == nil { show(box: nil, .idle) }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func start(_ box: String, _ binding: Binding<String>) {
        // One input at a time: another box's dictation stops (its words stay), and so does a stop still finishing.
        if let s = session { cancelSession(s) }
        if let d = draining { cancelSession(d) }
        noteTask?.cancel()
        let s = Session(box: box, binding: binding)
        session = s
        show(box: box, .preparing)
        s.runTask = Task { await self.run(s) }
    }

    /// Stop and keep the words: the microphone closes now and the words still changing are finalised.
    private func finalise(_ s: Session) {
        guard s === session else { return }
        guard s.listening, let engine = s.engine else { return cancelSession(s) }   // nothing heard yet
        session = nil
        draining = s
        s.clockTask?.cancel()
        show(box: nil, .idle)
        NWHaptics.tick()
        UIAccessibility.post(notification: .announcement, argument: DictationCopy.announceStop)
        engine.stop()
        s.drainTimeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.drainLimit * 1_000_000_000))
            if self.draining === s { self.finish(s) }
        }
    }

    /// Stop at once; nothing more is written. The words so far stay in the box.
    private func cancelSession(_ s: Session) {
        s.cancelled = true
        teardown(s)
        if session === s { session = nil; show(box: nil, .idle) }
        if draining === s { draining = nil }
    }

    /// The last words have arrived (or the wait ran out).
    private func finish(_ s: Session) {
        s.cancelled = true
        teardown(s)
        if draining === s { draining = nil }
    }

    private func teardown(_ s: Session) {
        s.clockTask?.cancel()
        s.drainTimeout?.cancel()
        s.starter?.cancel()
        s.runTask?.cancel()
        s.engine?.cancel()
    }

    /// The session ends on a note that stays until the next tap (Settings, language) or a while (interrupted).
    private func end(_ s: Session, with note: DictationPhase) {
        s.cancelled = true
        teardown(s)
        guard session === s else { if draining === s { draining = nil }; return }
        session = nil
        show(box: s.box, note)
        guard note == .interrupted else { return }
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.noteLifetime * 1_000_000_000))
            if self.phase == .interrupted, self.box == s.box, self.session == nil { self.show(box: nil, .idle) }
        }
    }

    private func appLeft(includingPreparing: Bool) {
        if let s = session, s.listening || includingPreparing { cancelSession(s) }
        if let d = draining { cancelSession(d) }
        if includingPreparing, session == nil, phase != .idle { show(box: nil, .idle) }
    }

    private func show(box: String?, _ phase: DictationPhase) {
        if self.box != box { self.box = box }
        if self.phase != phase { self.phase = phase }
    }

    // MARK: A session

    private enum Outcome { case done, fallBack }

    private func run(_ s: Session) async {
        switch await DictationPermissions.request() {
        case .granted: break
        case .microphoneDenied: return end(s, with: .denied(.microphone))
        case .speechDenied: return end(s, with: .denied(.speech))
        }
        guard !s.cancelled else { return }
        var caps = await DictationCapabilities.probe(for: Locale.current)
        while !s.cancelled {
            let choice = caps.pick(language: Self.languageName)
            guard let engine = caps.makeEngine(choice) else {
                if case .unavailable(let why) = choice { return end(s, with: .unavailable(why)) }
                return end(s, with: .unavailable(.noRecognizer))
            }
            s.engine = engine
            // An engine that can't start (an unsupported model, an install that failed) hands over to the next.
            if await drive(s, engine) == .fallBack {
                engine.cancel()
                caps.ruleOut(choice)
                continue
            }
            return
        }
    }

    /// Runs one engine and follows what it reports, until it ends.
    private func drive(_ s: Session, _ engine: DictationEngine) async -> Outcome {
        s.starter = Task { await engine.start() }
        for await event in engine.events {
            if s.cancelled { return .done }
            let visible = s === session
            switch event {
            case .preparing:
                if visible { show(box: s.box, .preparing) }
            case .downloading(let fraction):
                if visible, phase != .downloading(fraction: fraction), coarser(fraction) { show(box: s.box, .downloading(fraction: fraction)) }
            case .listening(let onDevice):
                s.listening = true
                s.clock = DictationClock(startedAt: Date())
                startClock(s)
                if visible {
                    show(box: s.box, .listening(level: 0, onDevice: onDevice))
                    NWHaptics.tick()
                    UIAccessibility.post(notification: .announcement, argument: DictationCopy.announceStart)
                }
            case .level(let level):
                if visible, case .listening(let old, let onDevice) = phase, abs(level - old) >= 0.02 {
                    show(box: s.box, .listening(level: level, onDevice: onDevice))
                }
            case .volatile(let words):
                write(s) { $0.setVolatile(words) }
            case .committed(let words):
                write(s) { $0.commit(words) }
            case .interrupted:
                end(s, with: .interrupted)
                return .done
            case .failed:
                if !s.listening { return .fallBack }
                // It died while listening: stop, and the words so far stay.
                cancelSession(s)
                return .done
            case .ended:
                finish(s)
                return .done
            }
        }
        return .done
    }

    /// A download fraction changes the line about once a percent.
    private func coarser(_ fraction: Double?) -> Bool {
        guard case .downloading(let old) = phase, let old, let fraction else { return true }
        return abs(fraction - old) >= 0.01
    }

    /// Puts the words in the box: the person's own draft first, then what was said. If the person changed the box
    /// under the dictation, it stops and the late words are dropped.
    private func write(_ s: Session, _ change: (inout DictationDraft) -> Void) {
        guard !s.cancelled, s === session || s === draining else { return }
        if DictationGuard.userEdited(current: s.binding.wrappedValue, lastWritten: s.lastWritten) {
            return cancelSession(s)
        }
        let before = s.draft.spoken
        change(&s.draft)
        if s.draft.spoken != before { s.clock?.heardWords(at: Date()) }
        guard s.draft.text != s.lastWritten else { return }
        s.binding.wrappedValue = s.draft.text
        // Read back: a field may trim or cap what it is given, and that is not an edit by the person.
        s.lastWritten = s.binding.wrappedValue
    }

    /// 20 s without new words, or 10 min in all: stop, keeping the words.
    private func startClock(_ s: Session) {
        s.clockTask = Task { [weak s] in
            while !Task.isCancelled {
                guard let s, !s.cancelled, let clock = s.clock else { return }
                if clock.expiry(at: Date()) != nil { self.finalise(s); return }
                let wait = max(0.05, clock.nextDeadline.timeIntervalSinceNow)
                // A tight tolerance: the default leeway can add a second to a 20 s sleep.
                try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(100))
            }
        }
    }
}

/// Owns the app's one DictationController and gives the boxes its `NWDictation` (`\.nwDictation`), at the app root.
/// A modifier of its own, so that the controller publishing (the voice level, 15 times a second) redraws only this
/// modifier and the views that read `\.nwDictation`, not the app's root.
struct NWDictationHost: ViewModifier {
    @StateObject private var controller = DictationController()

    func body(content: Content) -> some View {
        content.environment(\.nwDictation, controller.nwDictation())
    }
}
