import SwiftUI

#if DEBUG

/// `-NWRender voice-live`: the real DictationController on a bare message box. Not one of the fixture screens (it is
/// not in `RenderHarness.screens`), so a plain render run does not draw it. The simulator cannot load the speech
/// models (SpeechTranscriber is unavailable, DictationTranscriber has no audio format, SFSpeechRecognizer fails with
/// kLSRErrorDomain 300), so a real recognizer is tried on a device; here `-NWVoiceFake` swaps in a scripted engine.
///   -NWVoiceAutostart      taps the mic once the screen has appeared
///   -NWVoiceBase <text>    the draft the person had already typed
///   -NWVoiceScript <name>  what the "person" does while it listens: stop (taps stop), edit (types a character),
///                          send (taps Send), quiet (says nothing: the 20 s silence stops it)
/// Every phase change and every change to the box is appended to `Caches/voice-live.log` in the app's container. The
/// Send button only counts its taps: nothing is sent, and nothing may be sent by speaking.
struct HarnessVoiceLive: View {
    @StateObject private var controller = DictationController()
    @State private var draft = ""
    @State private var sends = 0
    private static let box = "voice-live"
    private static let started = Date()

    var body: some View {
        let dictation = controller.nwDictation()
        let phase = dictation.phase(for: Self.box)
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice, live").font(.title2.bold()).foregroundColor(.white)
            if let line = dictation.line(for: Self.box) {
                NWDictationLine(line: line, level: phase.level, onSettings: dictation.openSettings)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(phase.isListening && draft.isEmpty ? DictationCopy.listeningPlaceholder : "Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6).foregroundColor(.white)
                    .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                NWMicButton(phase: phase) { dictation.toggle(Self.box, $draft) }
                Button("Send") { dictation.cancel(Self.box); sends += 1 }.buttonStyle(.borderedProminent)
            }
            Text("Sends: \(sends) · phase: \(String(describing: phase))").font(.caption.monospaced()).foregroundColor(.gray)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 60)
        .environment(\.nwDictation, dictation)
        .onChange(of: draft) { _, text in Self.record("draft=\(text)") }
        .onChange(of: String(describing: phase)) { _, text in Self.record("phase=\(text)") }
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if let i = arguments.firstIndex(of: "-NWVoiceBase"), arguments.indices.contains(i + 1) { draft = arguments[i + 1] }
            guard arguments.contains("-NWVoiceAutostart") else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            dictation.toggle(Self.box, $draft)
            guard let i = arguments.firstIndex(of: "-NWVoiceScript"), arguments.indices.contains(i + 1) else { return }
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            switch arguments[i + 1] {
            case "stop": Self.record("person taps stop"); dictation.toggle(Self.box, $draft)
            case "edit": Self.record("person types"); draft += "!"
            case "send": Self.record("person taps Send"); dictation.cancel(Self.box); sends += 1
            default: break
            }
        }
    }

    private static func record(_ line: String) {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("voice-live.log")
        let stamped = String(format: "%5.1f ", Date().timeIntervalSince(started)) + line.replacingOccurrences(of: "\n", with: "\\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(stamped.utf8)); try? handle.close()
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// A scripted engine: no microphone and no recognizer, only the events a real one reports. It "says" a sentence a
/// word at a time (the words still changing, then finished at the end of each clause), and, when stopped, finalises
/// the words still changing. `-NWVoiceScript quiet` says nothing.
final class FakeDictationEngine: DictationEngine, @unchecked Sendable {
    private let pipe = DictationEventPipe()
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var pending = ""

    var events: AsyncStream<DictationEvent> { pipe.stream }

    func start() async {
        pipe.send(.preparing)
        try? await Task.sleep(nanoseconds: 300_000_000)
        pipe.send(.listening(onDevice: false))
        let quiet = ProcessInfo.processInfo.arguments.contains("quiet")
        if ProcessInfo.processInfo.arguments.contains("interrupt") {
            Task { [pipe] in try? await Task.sleep(nanoseconds: 3_000_000_000); pipe.send(.interrupted) }
        }
        let clauses = [["Run", "the", "tests", "again,"], ["and", "then", "tell", "me", "which", "ones", "still", "fail.\nThanks"]]
        let task = Task { [weak self] in
            guard let self, !quiet else { return }
            var level = 0.2
            for clause in clauses {
                var said: [String] = []
                for word in clause {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if Task.isCancelled { return }
                    said.append(word)
                    level = level > 0.5 ? 0.15 : level + 0.2
                    lock.withLock { self.pending = said.joined(separator: " ") }
                    pipe.send(.level(level))
                    pipe.send(.volatile(said.joined(separator: " ")))
                }
                lock.withLock { self.pending = "" }
                pipe.send(.committed(said.joined(separator: " ")))
            }
        }
        lock.withLock { self.task = task }
    }

    func stop() {
        let (words, task) = lock.withLock { () -> (String, Task<Void, Never>?) in
            let w = pending
            pending = ""
            return (w, self.task)
        }
        task?.cancel()
        Task { [pipe] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !words.isEmpty { pipe.send(.committed(words + " (finalised)")) }
            pipe.send(.ended)
        }
    }

    func cancel() {
        lock.withLock { self.task }?.cancel()
        pipe.close()
    }
}

#endif
