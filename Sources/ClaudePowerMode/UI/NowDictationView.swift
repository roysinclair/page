import SwiftUI
@testable import PageCore

// Voice input in the panel's Steer boxes (Designs/voice-input.md, "Mac"): the
// mic inside the field and the one line above it. Speaking only fills the box;
// Return is unchanged and nothing is sent by voice. All state lives in
// `NowStore` (`dictation`); the app's DictationController drives it.

/// What the store calls to drive the microphone. Set by the app; the harness leaves them empty.
struct NowDictationActions {
    /// Start, or stop and keep the words (the mic button, ⌥⌘D).
    var toggle: () -> Void = {}
    /// Stop without writing anything more: Return, typing, closing the box. What shows is kept.
    var cancel: () -> Void = {}
    /// System Settings ▸ Privacy & Security ▸ Microphone or Speech Recognition.
    var openSettings: (DictationPermission) -> Void = { _ in }
}

/// The mic inside a Steer field: a 24 pt glyph. While listening it is a teal stop square on a teal disc, with a
/// ring that follows the voice; never the bright fill of Send.
struct NWDictationMicButton: View {
    var phase: DictationPhase
    var action: () -> Void
    @Environment(\.nwReduceMotion) private var reduceMotion
    @State private var hovering = false

    private let size: CGFloat = 24

    var body: some View {
        Button(action: action) {
            ZStack {
                if phase.isListening {
                    Circle().stroke(NightWatch.Palette.teal.opacity(0.35).color, lineWidth: 2)
                        .frame(width: size, height: size)
                        .scaleEffect(reduceMotion ? 1.12 : 1 + 0.22 * min(max(phase.level, 0), 1))
                    Circle().fill(NightWatch.Palette.teal.opacity(0.16).color)
                        .overlay(Circle().strokeBorder(NightWatch.Palette.teal.opacity(0.75).color, lineWidth: 1.2))
                        .frame(width: size, height: size)
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(NightWatch.Palette.teal.color)
                        .frame(width: 8, height: 8)
                } else {
                    Circle().fill(Color.white.opacity(hovering && !phase.isBlocked ? 0.10 : 0.0)).frame(width: size, height: size)
                    Image(systemName: phase.isBlocked ? "mic.slash" : "mic")
                        .font(Font.system(size: 12, weight: .medium))
                        .foregroundColor((phase.isBlocked ? NightWatch.Palette.textQuiet
                                          : hovering ? NightWatch.Palette.textSecondary : NightWatch.Palette.textTertiary).color)
                    ring
                }
            }
            .frame(width: size + 4, height: size + 4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(phase.isActive ? DictationCopy.stopHelp : DictationCopy.micHelp)
        .accessibilityLabel(Text(phase.isActive ? DictationCopy.stopLabel : DictationCopy.micLabel))
    }

    /// Getting ready: a short arc. Downloading: the real fraction.
    @ViewBuilder private var ring: some View {
        switch phase {
        case .preparing, .downloading(fraction: nil):
            Circle().trim(from: 0, to: 0.28)
                .stroke(NightWatch.Palette.teal.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: size, height: size)
        case .downloading(let f?):
            Circle().trim(from: 0, to: min(max(f, 0.02), 1))
                .stroke(NightWatch.Palette.teal.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)
        default:
            EmptyView()
        }
    }
}

/// Five bars that follow the voice level.
struct NWDictationLevelBars: View {
    var level: Double
    @Environment(\.nwReduceMotion) private var reduceMotion
    private static let shape: [Double] = [0.45, 0.8, 1, 0.7, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Self.shape.indices, id: \.self) { i in
                Capsule().fill(NightWatch.Palette.teal.color)
                    .frame(width: 2, height: 3 + 7 * Self.shape[i] * (reduceMotion ? 0.5 : min(max(level, 0), 1)))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

/// The line above the Steer field: Listening, the download, or why the mic can't listen.
struct NWDictationLineView: View {
    var line: DictationCopy.Line
    var level: Double
    var onSettings: () -> Void

    private var tone: NightWatch.RGBA {
        switch line.tone {
        case .listening: return NightWatch.Palette.teal
        case .problem: return NightWatch.Palette.amber
        case .quiet: return NightWatch.Palette.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch line.tone {
                case .listening: NWDictationLevelBars(level: level)
                case .problem: Image(systemName: "mic.slash").font(Font.system(size: 11, weight: .medium)).foregroundColor(tone.color)
                case .quiet:
                    Image(systemName: line.progress != nil ? "arrow.down.circle" : "mic")
                        .font(Font.system(size: 11, weight: .medium)).foregroundColor(tone.color)
                }
                Text(line.text)
                    .font(Font.system(size: 11, weight: line.tone == .listening ? .semibold : .regular))
                    .foregroundColor(tone.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if line.opensSettings {
                    Button(action: onSettings) {
                        Text(DictationCopy.openSettings)
                            .font(Font.system(size: 11, weight: .semibold))
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                    }
                    .buttonStyle(.plain)
                    .help("System Settings ▸ Privacy & Security")
                }
            }
            if let p = line.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule().fill(NightWatch.Palette.teal.color).frame(width: geo.size.width * min(max(p, 0), 1))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tone.opacity(0.09).color))
        .accessibilityElement(children: .combine)
    }
}

/// The line, when the store's dictation has one.
struct NWDictationSlot: View {
    @ObservedObject var store: NowStore

    var body: some View {
        if let line = DictationCopy.line(for: store.dictation, language: store.dictationLanguage) {
            NWDictationLineView(line: line, level: store.dictation.level) {
                if case .denied(let p) = store.dictation { store.dictationActions.openSettings(p) }
            }
        }
    }
}
