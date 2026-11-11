import Foundation

// The Night Watch depth language as plain values, so both apps and their
// tests share one table: the jewels (the saturated surfaces of what needs you,
// and each project's own colour), the contrast every jewel promises white
// text, where the Runway stops being clear, how a section's title is set, the
// wait on a decision's clock chip, and the light along the desk's edge. No
// SwiftUI here: the views draw these (`NWJewel`, `NWDesk`, `NWRunwayBar`).

/// A jewel's tone: the risk colours (red Irreversible, sky Considered, green
/// Undoable, amber for a question or a look), teal for working and finished,
/// and the project colours (`ProjectHue`; rose leans plum and white leans
/// indigo, so neither reads as Irreversible's crimson or as grey).
enum JewelTone: String, CaseIterable, Equatable {
    case red, sky, green, amber, teal, lime, violet, plum, indigo

    /// The ramp, as opaque 0xRRGGBB colours: the lit corner (top leading),
    /// the far corner (bottom trailing), the light (its rim, glow and the
    /// light in its corner) and how much of that light falls into the corner.
    var ramp: JewelRamp {
        switch self {
        case .red: return JewelRamp(top: 0xA3243A, bottom: 0x4A0E1C, light: 0xFF7A8A, lightStrength: 0.32)
        case .sky: return JewelRamp(top: 0x1D62AE, bottom: 0x0B2A55, light: 0x7CC8FF, lightStrength: 0.15)
        case .green: return JewelRamp(top: 0x0B6E51, bottom: 0x05352A, light: 0x5EEAB0, lightStrength: 0.12)
        case .amber: return JewelRamp(top: 0x9A4A08, bottom: 0x451A05, light: 0xFFB347, lightStrength: 0.2)
        case .teal: return JewelRamp(top: 0x0D7A72, bottom: 0x063A40, light: 0x5EEAD4, lightStrength: 0.08)
        case .lime: return JewelRamp(top: 0x3A7A12, bottom: 0x17340A, light: 0xBEF264, lightStrength: 0.06)
        case .violet: return JewelRamp(top: 0x5B3FC4, bottom: 0x261860, light: 0xC4B5FD, lightStrength: 0.2)
        case .plum: return JewelRamp(top: 0x8E2A84, bottom: 0x3D1040, light: 0xF5A8E8, lightStrength: 0.12)
        case .indigo: return JewelRamp(top: 0x3557A8, bottom: 0x16244D, light: 0xA5B8F0, lightStrength: 0.15)
        }
    }

    /// A card's jewel by its chip: Irreversible red, Considered sky, Undoable
    /// green, a finished turn teal, anything else that needs a look amber.
    init(chip: ChipKind) {
        switch chip {
        case .irreversible: self = .red
        case .considered: self = .sky
        case .undoable: self = .green
        case .review: self = .teal
        case .looksStuck, .question, .forecast, .rateLimited, .budget: self = .amber
        }
    }

    /// A project's jewel.
    init(hue: ProjectHue) {
        switch hue {
        case .teal: self = .teal
        case .sky: self = .sky
        case .lime: self = .lime
        case .violet: self = .violet
        case .rose: self = .plum
        case .white: self = .indigo
        }
    }
}

struct JewelRamp: Equatable {
    let top: UInt32
    let bottom: UInt32
    let light: UInt32
    let lightStrength: Double

    /// The lit corner, where the light falls on the top colour: the lightest
    /// point white text ever sits on. Pure.
    var litCorner: UInt32 { Contrast.mix(top, light, lightStrength) }
}

/// WCAG 2 contrast, on 0xRRGGBB colours. Pure.
enum Contrast {
    /// The ratio between two colours, 1 ... 21.
    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Relative luminance, 0 (black) ... 1 (white).
    static func luminance(_ c: UInt32) -> Double {
        func lin(_ v: UInt32) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((c >> 16) & 0xFF) + 0.7152 * lin((c >> 8) & 0xFF) + 0.0722 * lin(c & 0xFF)
    }

    /// `a` towards `b` by `t` (0 = a, 1 = b), per channel, rounded.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ s: UInt32) -> Double { Double((a >> s) & 0xFF) + (Double((b >> s) & 0xFF) - Double((a >> s) & 0xFF)) * t }
        func q(_ v: Double) -> UInt32 { UInt32(max(0, min(255, v.rounded()))) }
        return q(ch(16)) << 16 | q(ch(8)) << 8 | q(ch(0))
    }

    /// White at `alpha` laid over `background`, as it is seen.
    static func white(alpha: Double, over background: UInt32) -> UInt32 { mix(background, 0xFFFFFF, alpha) }
}

extension RunwayModel {
    /// Where the runway stops being clear (the earliest deadline), 0 (now) ... 1;
    /// 1 when nothing stops it. The instrument's teal runs to here and amber
    /// after. Pure.
    var clearFraction: Double {
        guard let until = clearUntil else { return 1 }
        return markers.first { $0.at == until }?.fraction ?? markers.map(\.fraction).min() ?? 1
    }
}

/// How a section, a state or a divider is titled: words, not a tracked
/// all-caps caption. "IN FLIGHT" → "In flight", "NEEDS YOU" → "Needs you". Pure.
enum SectionTitle {
    static func words(_ title: String) -> String {
        title.prefix(1).uppercased() + title.dropFirst().lowercased()
    }
}

/// The wait on a decision's clock chip: the clock says "waiting", so the
/// chip holds the time alone. "waiting 4m" → "4m"; anything else as it is. Pure.
enum WaitChip {
    static func text(_ waiting: String) -> String {
        waiting.hasPrefix("waiting ") ? String(waiting.dropFirst("waiting ".count)) : waiting
    }
}

/// The light along the desk's edge, where the sky (what is only told) meets
/// what needs you: the mood's colour. A problem is amber, or slate for a Mac
/// that is asleep or gone. Pure.
enum DeskLight {
    static let slate: UInt32 = 0x6B7894
    static let amber: UInt32 = 0xF5B14C
    static let teal: UInt32 = 0x5EEAD4
    static let violet: UInt32 = 0xA78BFA
    /// Teal half way to sky: the quiet night.
    static var quiet: UInt32 { Contrast.mix(teal, 0x38BDF8, 0.5) }

    static func colour(mood: NowModel.Mood, problem: ProblemTone?) -> UInt32 {
        if let problem { return problem == .slate ? slate : amber }
        switch mood {
        case .needsYou: return amber
        case .working: return teal
        case .dusk: return violet
        case .quiet: return quiet
        }
    }

    /// A problem's tone, as the desk reads it.
    enum ProblemTone: Equatable { case amber, slate }
}
