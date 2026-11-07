import SwiftUI

extension RunwayMarker.Tone {
    var color: NightWatch.RGBA {
        switch self {
        case .amber: return NightWatch.Palette.amber
        case .green: return NightWatch.Palette.green
        case .blue: return NightWatch.Palette.sky
        }
    }
}

/// The Runway: a line across the next six hours with a "now" dot at the left
/// and a labelled tick per deadline or event (battery cutoff, 5h limit,
/// resets). On AC the line runs to the end unbroken with a "on AC" note, and
/// no cutoff. Sits on a glass card; a tap opens the Tower, scrolled to Budget.
/// Drawn at one moment of its motion (`NowMotion.RunwayFrame`: the line
/// drawing in, markers popping, gliding and reaching now, the NOW dot's
/// breath); Now runs the clock (`NWNowRunway`), and without a frame (the
/// widgets, Dispatch) it is drawn settled. Its height never changes as it
/// moves, and nothing it draws leaves its card.
struct NWRunwayBar: View {
    var model: RunwayModel
    var frame: NowMotion.RunwayFrame? = nil
    /// Now's instrument (`instrumentBody`): a thick lit track, pinned markers with their labels
    /// in chips, the hours marked. The widgets and Dispatch keep the plain line.
    var instrument = false
    private let labelRow: CGFloat = 16
    private let inset: CGFloat = 22
    private let labelWidth: CGFloat = 92

    var body: some View {
        if instrument { instrumentBody } else { plainBody }
    }

    @ViewBuilder private var plainBody: some View {
        let lanes = (model.markers.map(\.lane).max() ?? 0) + 1
        let lineY = CGFloat(lanes) * labelRow + 10
        let f = frame ?? NowMotion.RunwayFrame.settled(model)
        GeometryReader { geo in
            let w = geo.size.width - inset * 2
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: [NightWatch.Palette.teal.opacity(model.onAC ? 0.55 : 0.5).color,
                                 NightWatch.Palette.teal.opacity(model.onAC ? 0.55 : 0.22).color],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: w, height: 3)
                    .shadow(color: NightWatch.Palette.teal.opacity(0.6).color, radius: 4)
                    // It draws in from the NOW dot, the gradient staying where it lies.
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * CGFloat(min(1, f.line)))) }
                    .offset(x: inset, y: lineY - 1)
                nowDot(breath: f.breath)
                    .offset(x: inset - 6, y: lineY - 6)
                ForEach(f.markers, id: \.key) { mf in
                    let m = mf.marker
                    let x = inset + CGFloat(mf.x) * w
                    if let g = mf.flash {
                        Circle().fill(m.tone.color.opacity(g.opacity).color)
                            .frame(width: 12 * CGFloat(g.scale), height: 12 * CGFloat(g.scale)).blur(radius: 3)
                            .offset(x: x - 6 * CGFloat(g.scale), y: lineY - 6 * CGFloat(g.scale))
                    }
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(m.tone.color.color)
                        .frame(width: 3, height: 16)
                        .scaleEffect(CGFloat(mf.scale))
                        .opacity(mf.opacity)
                        .offset(x: x - 1.5, y: lineY - 8)
                    // Labels sit right of their tick; near the end they flip to its left. A
                    // marker on its way out keeps to the lanes there are.
                    let flip = mf.x > 0.72
                    Text(m.label)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundColor(m.tone.color.color)
                        .lineLimit(1)
                        .frame(width: labelWidth, alignment: flip ? .trailing : .leading)
                        .opacity(mf.opacity)
                        .offset(x: flip ? x - 5 - labelWidth : x + 5, y: CGFloat(min(m.lane, lanes - 1)) * labelRow)
                }
                Text("NOW")
                    .font(NightWatch.Typo.label).kerning(0.8)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .offset(x: inset - 6, y: lineY + 11)
                if model.onAC {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                        Text("on AC").font(.system(.caption2, weight: .medium))
                    }
                    .foregroundColor(NightWatch.Palette.teal.opacity(0.9).color)
                    .frame(width: 70, alignment: .trailing)
                    .opacity(f.line)
                    .offset(x: inset + w - 70, y: lineY + 10)
                }
            }
        }
        .frame(height: lineY + 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    // MARK: Now's instrument

    /// A lane of chips, growing with the text size.
    @ScaledMetric(relativeTo: .caption2) private var chipRow: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var chipHeight: CGFloat = 18
    private static let chipWidth: CGFloat = 132

    /// Where the runway stops being clear (the earliest deadline), 0 ... 1; 1 when nothing stops it.
    private var clearFraction: Double {
        guard let until = model.clearUntil else { return 1 }
        return model.markers.first { $0.at == until }?.fraction ?? model.markers.map(\.fraction).min() ?? 1
    }

    private var instrumentBody: some View {
        let lanes = (model.markers.map(\.lane).max() ?? 0) + 1
        let lineY = 4 + CGFloat(lanes) * chipRow + 10
        let f = frame ?? NowMotion.RunwayFrame.settled(model)
        let clear = CGFloat(clearFraction)
        let track: CGFloat = 8
        return GeometryReader { geo in
            let w = geo.size.width - inset * 2
            ZStack(alignment: .topLeading) {
                // The track: clear runway in teal running to sky, past the first deadline in amber; it draws in from now.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07)).frame(width: w, height: track)
                    Capsule().fill(LinearGradient(colors: [NightWatch.Palette.amber.opacity(0.55).color, NightWatch.Palette.amber.opacity(0.18).color],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * (1 - clear) + track, height: track)
                        .offset(x: w * clear - track)
                        .opacity(clear < 1 ? 1 : 0)
                    Capsule().fill(LinearGradient(colors: [NightWatch.Palette.teal.color, NightWatch.Palette.sky.color],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(track, w * clear), height: track)
                        .shadow(color: NightWatch.Palette.teal.opacity(0.65).color, radius: 6)
                    // Light along the track's top.
                    Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .frame(width: w, height: track / 2).offset(y: -track / 4)
                        .mask(Capsule().frame(width: w, height: track))
                }
                .mask(alignment: .leading) { Rectangle().frame(width: max(0, (w + 12) * CGFloat(min(1, f.line)))) }
                .offset(x: inset, y: lineY - track / 2)
                // The hours, under the track.
                // The last hour gives way to "on AC" at the end of the track.
                ForEach(1..<(model.onAC ? 5 : 6), id: \.self) { h in
                    let x = inset + w * CGFloat(h) / 6
                    Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1, height: 5).offset(x: x, y: lineY + track / 2 + 3)
                    Text("\(h)h").font(.system(.caption2, weight: .medium)).monospacedDigit()
                        .foregroundColor(NightWatch.Palette.textQuiet.color)
                        .frame(width: 30).offset(x: x - 15, y: lineY + track / 2 + 9)
                        .opacity(f.line)
                }
                ForEach(f.markers, id: \.key) { mf in
                    let m = mf.marker
                    let x = inset + CGFloat(mf.x) * w
                    let laneY = 4 + CGFloat(min(m.lane, lanes - 1)) * chipRow
                    let flip = mf.x > 0.66
                    if let g = mf.flash {
                        Circle().fill(m.tone.color.opacity(g.opacity).color)
                            .frame(width: 16 * CGFloat(g.scale), height: 16 * CGFloat(g.scale)).blur(radius: 4)
                            .offset(x: x - 8 * CGFloat(g.scale), y: lineY - 8 * CGFloat(g.scale))
                    }
                    // The pin, from its chip down to the track.
                    Rectangle().fill(LinearGradient(colors: [m.tone.color.opacity(0.9).color, m.tone.color.opacity(0.35).color], startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.5, height: max(0, lineY - laneY - chipHeight))
                        .offset(x: x - 0.75, y: laneY + chipHeight)
                        .opacity(mf.opacity)
                    // Its dot on the track.
                    Circle().fill(m.tone.color.color)
                        .overlay(Circle().fill(Color.white.opacity(0.9)).frame(width: 4, height: 4))
                        .frame(width: 12, height: 12)
                        .shadow(color: m.tone.color.opacity(0.8).color, radius: 5)
                        .scaleEffect(CGFloat(mf.scale))
                        .opacity(mf.opacity)
                        .offset(x: x - 6, y: lineY - 6)
                    // Its words, in a chip of its colour, beside the pin (to its left near the end).
                    Text(m.label)
                        .font(.system(.caption2, weight: .semibold)).monospacedDigit()
                        .foregroundColor(m.tone.color.mixed(with: .init(1, 1, 1), 0.15).color)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).frame(height: chipHeight)
                        .background(Capsule().fill(m.tone.color.opacity(0.16).color)
                            .overlay(Capsule().strokeBorder(m.tone.color.opacity(0.4).color, lineWidth: 1)))
                        .frame(width: Self.chipWidth, alignment: flip ? .trailing : .leading)
                        .opacity(mf.opacity)
                        .offset(x: flip ? x + 6 - Self.chipWidth : x - 6, y: laneY)
                }
                // Now.
                nowDot(breath: f.breath).scaleEffect(1.2)
                    .offset(x: inset - 6, y: lineY - 6)
                Text("NOW")
                    .font(NightWatch.Typo.label).kerning(0.8)
                    .foregroundColor(NightWatch.Palette.textSecondary.color)
                    .offset(x: inset - 8, y: lineY + track / 2 + 9)
                if model.onAC {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                        Text("on AC").font(.system(.caption2, weight: .semibold))
                    }
                    .foregroundColor(NightWatch.Palette.teal.color)
                    .frame(width: 70, alignment: .trailing)
                    .opacity(f.line)
                    .offset(x: inset + w - 70, y: lineY + track / 2 + 9)
                }
            }
        }
        .frame(height: lineY + track / 2 + 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// The white NOW dot; while agents work it breathes with the pulse (the lens's scale and halo).
    private func nowDot(breath: Double?) -> some View {
        ZStack {
            if let b = breath {
                Circle().fill(Color.white.opacity(WorkflowMotion.haloLow + (WorkflowMotion.haloHigh - WorkflowMotion.haloLow) * b))
                    .frame(width: 22, height: 22).blur(radius: 4)
            }
            Circle().fill(Color.white)
                .frame(width: 12, height: 12)
                .shadow(color: Color.white.opacity(0.5), radius: 3)
                .scaleEffect(1 + CGFloat(WorkflowMotion.breathScale * (breath ?? 0)))
        }
        .frame(width: 12, height: 12)
    }

    /// What VoiceOver reads.
    var accessibilityText: String {
        let power = model.onAC ? "on power" : "on battery"
        return model.markers.isEmpty ? "Runway: nothing ahead in the next six hours, \(power)"
            : "Runway, \(power): " + model.markers.map(\.label).joined(separator: ", ")
    }
}
