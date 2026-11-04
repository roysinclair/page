import Foundation

/// What the menu-bar glyph says (v4 spec, macMenuBar.GLYPH). One of the modes
/// plus three independent modifiers.
struct GlyphState: Equatable {
    enum Mode: Equatable {
        /// Page is not keeping the Mac awake and nothing is running: a hollow ring.
        case off
        /// Awake but nothing working (holding for a page, a local model): a still star-white dot.
        case quiet
        /// Agents working: teal, breathing.
        case working(agents: Int)
        /// Something is blocked: amber ripple with a count.
        case needsYou(count: Int)
        /// Paused for battery: a flat horizon under a dimmed dot.
        case paused
    }

    var mode: Mode
    /// Lid-closed awake is in force: a moon tick.
    var lidClosedAwake: Bool = false
    /// Battery headroom to the cutoff, 0...1; nil on AC or without a battery.
    var headroom: Double? = nil
    /// Phone paging is armed (relay up and you're away): a small phone badge.
    var phoneArmed: Bool = false
    /// Pages still waiting while paused for battery: the glyph keeps the amber
    /// count beside the dimmed dot. Ignored in every other mode (they carry
    /// their own count).
    var waiting: Int = 0

    /// Pure. Share of the charge above the cutoff that is left:
    /// (percent - cutoff) / (100 - cutoff), clamped to 0...1.
    static func headroom(power: PowerSnapshot, cutoff: Int) -> Double? {
        guard power.hasBattery, !power.onAC, power.percent >= 0 else { return nil }
        let span = Double(100 - cutoff)
        guard span > 0 else { return nil }
        return min(1, max(0, Double(power.percent - cutoff) / span))
    }

    /// Pure. The mode with the highest precedence: paused, then needs-you,
    /// then working, then quiet, then off.
    static func mode(paused: Bool, needYou: Int, working: Int, keepingAwake: Bool) -> Mode {
        if paused { return .paused }
        if needYou > 0 { return .needsYou(count: needYou) }
        if working > 0 { return .working(agents: working) }
        return keepingAwake ? .quiet : .off
    }
}
