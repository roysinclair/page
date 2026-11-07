package app.page.android.model

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

// The Night Watch depth language as plain values, so both apps and their tests share one table: the jewels (the
// saturated surfaces of what needs you, and each project's own colour), the contrast every jewel promises white
// text, where the Runway stops being clear, how a section's title is set, the wait on a decision's clock chip, and
// the light along the desk's edge. No Compose here: the views draw these (`NWJewel`, `NWDesk`, `NWRunway`).
// A port of iOS/Page/Models/NightWatchDepth.swift; the byte values are the same, row for row.

/**
 * A jewel's tone: the risk colours (red Irreversible, sky Considered, green Undoable, amber for a question or a
 * look), teal for working and finished, and the project colours ([ProjectHue]; rose leans plum and white leans
 * indigo, so neither reads as Irreversible's crimson or as grey).
 */
enum class JewelTone {
    RED, SKY, GREEN, AMBER, TEAL, LIME, VIOLET, PLUM, INDIGO;

    /**
     * The ramp, as opaque 0xRRGGBB colours: the lit corner (top leading), the far corner (bottom trailing), the
     * light (its rim, glow and the light in its corner) and how much of that light falls into the corner.
     */
    val ramp: JewelRamp
        get() = when (this) {
            RED -> JewelRamp(top = 0xA3243A, bottom = 0x4A0E1C, light = 0xFF7A8A, lightStrength = 0.32)
            SKY -> JewelRamp(top = 0x1D62AE, bottom = 0x0B2A55, light = 0x7CC8FF, lightStrength = 0.15)
            GREEN -> JewelRamp(top = 0x0B6E51, bottom = 0x05352A, light = 0x5EEAB0, lightStrength = 0.12)
            AMBER -> JewelRamp(top = 0x9A4A08, bottom = 0x451A05, light = 0xFFB347, lightStrength = 0.2)
            TEAL -> JewelRamp(top = 0x0D7A72, bottom = 0x063A40, light = 0x5EEAD4, lightStrength = 0.08)
            LIME -> JewelRamp(top = 0x3A7A12, bottom = 0x17340A, light = 0xBEF264, lightStrength = 0.06)
            VIOLET -> JewelRamp(top = 0x5B3FC4, bottom = 0x261860, light = 0xC4B5FD, lightStrength = 0.2)
            PLUM -> JewelRamp(top = 0x8E2A84, bottom = 0x3D1040, light = 0xF5A8E8, lightStrength = 0.12)
            INDIGO -> JewelRamp(top = 0x3557A8, bottom = 0x16244D, light = 0xA5B8F0, lightStrength = 0.15)
        }

    companion object {
        /** A card's jewel by its chip: Irreversible red, Considered sky, Undoable green, a finished turn teal, anything else that needs a look amber. */
        fun of(chip: ChipKind): JewelTone = when (chip) {
            ChipKind.IRREVERSIBLE -> RED
            ChipKind.CONSIDERED -> SKY
            ChipKind.UNDOABLE -> GREEN
            ChipKind.REVIEW -> TEAL
            ChipKind.LOOKS_STUCK, ChipKind.QUESTION, ChipKind.FORECAST, ChipKind.RATE_LIMITED -> AMBER
        }

        /** A project's jewel. */
        fun of(hue: ProjectHue): JewelTone = when (hue) {
            ProjectHue.TEAL -> TEAL
            ProjectHue.SKY -> SKY
            ProjectHue.LIME -> LIME
            ProjectHue.VIOLET -> VIOLET
            ProjectHue.ROSE -> PLUM
            ProjectHue.WHITE -> INDIGO
        }
    }
}

/** One row of the jewel table: 0xRRGGBB colours, opaque. */
data class JewelRamp(val top: Int, val bottom: Int, val light: Int, val lightStrength: Double) {
    /** The lit corner, where the light falls on the top colour: the lightest point white text ever sits on. Pure. */
    val litCorner: Int get() = Contrast.mix(top, light, lightStrength)
}

/** WCAG 2 contrast, on 0xRRGGBB colours. Pure. */
object Contrast {
    /** The ratio between two colours, 1 ... 21. */
    fun ratio(a: Int, b: Int): Double {
        val la = luminance(a)
        val lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /** Relative luminance, 0 (black) ... 1 (white). */
    fun luminance(c: Int): Double {
        fun lin(v: Int): Double {
            val s = v / 255.0
            return if (s <= 0.04045) s / 12.92 else ((s + 0.055) / 1.055).pow(2.4)
        }
        return 0.2126 * lin((c shr 16) and 0xFF) + 0.7152 * lin((c shr 8) and 0xFF) + 0.0722 * lin(c and 0xFF)
    }

    /** [a] towards [b] by [t] (0 = a, 1 = b), per channel, rounded half away from zero as Swift's `rounded()` does. */
    fun mix(a: Int, b: Int, t: Double): Int {
        fun ch(s: Int): Double {
            val x = ((a shr s) and 0xFF).toDouble()
            val y = ((b shr s) and 0xFF).toDouble()
            return x + (y - x) * t
        }
        // Values are non-negative here (clamped below), where Math.round (half up) equals half away from zero.
        fun q(v: Double): Int = Math.round(max(0.0, min(255.0, v))).toInt()
        return (q(ch(16)) shl 16) or (q(ch(8)) shl 8) or q(ch(0))
    }

    /** The colour 0xFFFFFF at [alpha] laid over [background], as it is seen. */
    fun white(alpha: Double, over: Int): Int = mix(over, 0xFFFFFF, alpha)
}

/**
 * Where the runway stops being clear (the earliest deadline), 0 (now) ... 1; 1 when nothing stops it. The
 * instrument's teal runs to here and amber after. Pure.
 */
val RunwayModel.clearFraction: Double
    get() {
        val until = clearUntil ?: return 1.0
        return markers.firstOrNull { it.at == until }?.fraction ?: markers.minOfOrNull { it.fraction } ?: 1.0
    }

/** How a section, a state or a divider is titled: words, not a tracked all-caps caption. "IN FLIGHT" becomes "In flight", "NEEDS YOU" becomes "Needs you". Pure. */
object SectionTitle {
    fun words(title: String): String = title.take(1).uppercase() + title.drop(1).lowercase()
}

/** The wait on a decision's clock chip: the clock says "waiting", so the chip holds the time alone. "waiting 4m" becomes "4m"; anything else as it is. Pure. */
object WaitChip {
    private const val PREFIX = "waiting "
    fun text(waiting: String): String = if (waiting.startsWith(PREFIX)) waiting.removePrefix(PREFIX) else waiting
}

/**
 * The light along the desk's edge, where the sky (what is only told) meets what needs you: the mood's colour. A
 * problem is amber, or slate for a Mac that is asleep or gone. Pure.
 */
object DeskLight {
    const val SLATE = 0x6B7894
    const val AMBER = 0xF5B14C
    const val TEAL = 0x5EEAD4
    const val VIOLET = 0xA78BFA

    /** Teal half way to sky: the quiet night. */
    val quiet: Int get() = Contrast.mix(TEAL, 0x38BDF8, 0.5)

    fun colour(mood: NowModel.Mood, problem: ProblemTone?): Int {
        if (problem != null) return if (problem == ProblemTone.SLATE) SLATE else AMBER
        return when (mood) {
            NowModel.Mood.NEEDS_YOU -> AMBER
            NowModel.Mood.WORKING -> TEAL
            NowModel.Mood.DUSK -> VIOLET
            NowModel.Mood.QUIET -> quiet
        }
    }

    /** A problem's tone, as the desk reads it. */
    enum class ProblemTone { AMBER, SLATE }
}
