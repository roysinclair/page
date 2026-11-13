import SwiftUI

// Voice input in the message boxes (Designs/voice-input.md): the mic button,
// and the one line above the box that says what the mic is doing. Speaking
// only fills the draft; Send is unchanged and nothing is sent by voice.

/// What the boxes need from the app's one dictation controller. Each box has a
/// stable id ("room:<session>", "decision:<row>", "answer:<page>", "dispatch").
/// Only the box that is listening (or showing a note) sees a phase other than idle.
struct NWDictation {
    /// The box the phase belongs to.
    var box: String?
    var phase: DictationPhase = .idle
    /// "iPhone" or "iPad".
    var device = "iPhone"
    /// The display name of the language being listened for ("English (UK)").
    var language = "English"
    /// Start, or stop and keep the words (the stop button).
    var toggle: (_ box: String, _ draft: Binding<String>) -> Void = { _, _ in }
    /// Stop without writing anything more: Send, an edit, leaving, the box locking. What shows is kept.
    var cancel: (_ box: String) -> Void = { _ in }
    var openSettings: () -> Void = {}

    func phase(for box: String) -> DictationPhase { self.box == box ? phase : .idle }
    /// `send` is the word on the box's own button: "Send", "Answer", or "Start" on New task.
    func line(for box: String, send: String = "Send") -> DictationCopy.Line? {
        DictationCopy.line(for: phase(for: box), device: device, language: language, send: send)
    }
}

private struct NWDictationKey: EnvironmentKey { static let defaultValue = NWDictation() }

extension EnvironmentValues {
    var nwDictation: NWDictation {
        get { self[NWDictationKey.self] }
        set { self[NWDictationKey.self] = newValue }
    }
}

/// The mic: a circle the size of the photo button. While listening it is Send's teal, a stop square, and a
/// ring that follows the voice; while a model downloads, a teal ring fills around it.
struct NWMicButton: View {
    var phase: DictationPhase
    var size: CGFloat = 44
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if case .listening = phase {
                    let level = phase.level
                    Circle().stroke(NightWatch.Palette.teal.opacity(0.35).color, lineWidth: 3)
                        .frame(width: size, height: size)
                        .scaleEffect(reduceMotion ? 1.12 : 1 + 0.22 * min(max(level, 0), 1))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
                    // Teal on dark, never Send's bright fill: the two sit side by side and must not be mistaken.
                    Circle().fill(NightWatch.Palette.teal.opacity(0.16).color)
                        .overlay(Circle().strokeBorder(NightWatch.Palette.teal.opacity(0.75).color, lineWidth: 1.5))
                        .frame(width: size, height: size)
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(NightWatch.Palette.teal.color)
                        .frame(width: size * 0.3, height: size * 0.3)
                } else {
                    Circle().fill(Color.white.opacity(phase.isBlocked ? 0.05 : 0.10)).frame(width: size, height: size)
                    Image(systemName: phase.isBlocked ? "mic.slash" : "mic").font(.system(.body, weight: .medium))
                        .foregroundColor((phase.isBlocked ? NightWatch.Palette.textQuiet : NightWatch.Palette.textSecondary).color)
                    ring
                }
            }
            .frame(width: max(size, 44), height: max(size, 44))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(phase.isActive ? DictationCopy.stopLabel : DictationCopy.micLabel))
        .accessibilityHint(Text(DictationCopy.micHint))
        .accessibilityValue(Text(phase.isBlocked ? "Unavailable" : ""))
    }

    /// Getting ready: a short arc going round. Downloading: the real fraction.
    @ViewBuilder private var ring: some View {
        switch phase {
        case .preparing, .downloading(fraction: nil):
            Circle().trim(from: 0, to: 0.28)
                .stroke(NightWatch.Palette.teal.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: size - 2, height: size - 2)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
                }
        case .downloading(let f?):
            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 2)
                Circle().trim(from: 0, to: min(max(f, 0.02), 1))
                    .stroke(NightWatch.Palette.teal.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size - 2, height: size - 2)
        default:
            EmptyView()
        }
    }
}

/// Five bars that follow the voice level.
struct NWLevelBars: View {
    var level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let shape: [Double] = [0.45, 0.8, 1, 0.7, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.shape.indices, id: \.self) { i in
                let l = reduceMotion ? 0.5 : min(max(level, 0), 1)
                Capsule().fill(NightWatch.Palette.teal.color)
                    .frame(width: 3, height: 4 + 10 * Self.shape[i] * l)
            }
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// The one line above the box: Listening, the download, or why the mic can't listen.
struct NWDictationLine: View {
    var line: DictationCopy.Line
    var level: Double = 0
    var onSettings: () -> Void = {}

    private var tone: NightWatch.RGBA {
        switch line.tone {
        case .listening: return NightWatch.Palette.teal
        case .problem: return NightWatch.Palette.amber
        case .quiet: return NightWatch.Palette.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                switch line.tone {
                case .listening: NWLevelBars(level: level)
                case .problem: Image(systemName: "mic.slash").foregroundColor(tone.color)
                case .quiet:
                    if line.progress == nil, line.text.hasSuffix("…") {
                        ProgressView().controlSize(.small).tint(tone.color)
                    } else {
                        Image(systemName: line.progress != nil ? "arrow.down.circle" : "mic").foregroundColor(tone.color)
                    }
                }
                Text(line.text)
                    .font(line.tone == .listening ? NightWatch.Typo.captionStrong : NightWatch.Typo.caption)
                    .foregroundColor(tone.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if line.opensSettings {
                    Button(DictationCopy.openSettings, action: onSettings)
                        .font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                        .buttonStyle(.plain).frame(minHeight: 44).contentShape(Rectangle())
                }
            }
            if let p = line.progress {
                ProgressView(value: min(max(p, 0), 1)).tint(NightWatch.Palette.teal.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, line.opensSettings ? 2 : 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.opacity(0.09).color))
        .accessibilityElement(children: .combine)
    }
}
