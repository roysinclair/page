package app.page.android.model

import java.io.File
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** The depth language's pure values (iOS NightWatchDepth.swift): the jewel table, its contrast, the runway's clear stretch, titles, the wait chip and the desk's light. */
class NightWatchDepthTest {
    @Test fun tableMatchesTheSpec() {
        val spec = mapOf(
            JewelTone.RED to JewelRamp(0xA3243A, 0x4A0E1C, 0xFF7A8A, 0.32),
            JewelTone.SKY to JewelRamp(0x1D62AE, 0x0B2A55, 0x7CC8FF, 0.15),
            JewelTone.GREEN to JewelRamp(0x0B6E51, 0x05352A, 0x5EEAB0, 0.12),
            JewelTone.AMBER to JewelRamp(0x9A4A08, 0x451A05, 0xFFB347, 0.20),
            JewelTone.TEAL to JewelRamp(0x0D7A72, 0x063A40, 0x5EEAD4, 0.08),
            JewelTone.LIME to JewelRamp(0x3A7A12, 0x17340A, 0xBEF264, 0.06),
            JewelTone.VIOLET to JewelRamp(0x5B3FC4, 0x261860, 0xC4B5FD, 0.20),
            JewelTone.PLUM to JewelRamp(0x8E2A84, 0x3D1040, 0xF5A8E8, 0.12),
            JewelTone.INDIGO to JewelRamp(0x3557A8, 0x16244D, 0xA5B8F0, 0.15),
        )
        assertEquals(9, JewelTone.entries.size)
        for (tone in JewelTone.entries) assertEquals(tone.name, spec[tone], tone.ramp)
    }

    /** The Kotlin table is the Swift one, byte for byte: parsed out of the iOS source when this repo has it. */
    @Test fun tableMatchesTheSwiftSource() {
        val swift = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "iOS/Page/Models/NightWatchDepth.swift") }.firstOrNull { it.exists() }
        assumeTrue("the iOS source is not beside this checkout", swift != null)
        val row = Regex("""case \.(\w+): return JewelRamp\(top: 0x(\w+), bottom: 0x(\w+), light: 0x(\w+), lightStrength: ([0-9.]+)\)""")
        val rows = row.findAll(swift!!.readText()).toList()
        assertEquals(9, rows.size)
        for (m in rows) {
            val (name, top, bottom, light, strength) = m.destructured
            val tone = JewelTone.valueOf(name.uppercase())
            assertEquals(name, JewelRamp(top.toInt(16), bottom.toInt(16), light.toInt(16), strength.toDouble()), tone.ramp)
        }
    }

    @Test fun whiteHoldsFourPointFiveOnEveryPointOfEveryJewel() {
        for (tone in JewelTone.entries) {
            val r = tone.ramp
            for ((where, c) in listOf("top" to r.top, "bottom" to r.bottom, "lit corner" to r.litCorner)) {
                val ratio = Contrast.ratio(0xFFFFFF, c)
                assertTrue("${tone.name} $where is ${"%.2f".format(ratio)}:1", ratio >= 4.5)
            }
        }
    }

    @Test fun chipsMapToTones() {
        assertEquals(JewelTone.RED, JewelTone.of(ChipKind.IRREVERSIBLE))
        assertEquals(JewelTone.SKY, JewelTone.of(ChipKind.CONSIDERED))
        assertEquals(JewelTone.GREEN, JewelTone.of(ChipKind.UNDOABLE))
        assertEquals(JewelTone.TEAL, JewelTone.of(ChipKind.REVIEW))
        for (c in listOf(ChipKind.LOOKS_STUCK, ChipKind.QUESTION, ChipKind.FORECAST, ChipKind.RATE_LIMITED)) assertEquals(JewelTone.AMBER, JewelTone.of(c))
        // Only an Irreversible card is red.
        assertEquals(listOf(ChipKind.IRREVERSIBLE), ChipKind.entries.filter { JewelTone.of(it) == JewelTone.RED })
    }

    @Test fun projectHuesMapToTonesAndRoseNeverReadsAsRed() {
        assertEquals(JewelTone.TEAL, JewelTone.of(ProjectHue.TEAL))
        assertEquals(JewelTone.SKY, JewelTone.of(ProjectHue.SKY))
        assertEquals(JewelTone.LIME, JewelTone.of(ProjectHue.LIME))
        assertEquals(JewelTone.VIOLET, JewelTone.of(ProjectHue.VIOLET))
        assertEquals(JewelTone.PLUM, JewelTone.of(ProjectHue.ROSE))
        assertEquals(JewelTone.INDIGO, JewelTone.of(ProjectHue.WHITE))
        assertTrue(ProjectHue.entries.none { JewelTone.of(it) == JewelTone.RED })
    }

    @Test fun mixAndRatio() {
        assertEquals(0x000000, Contrast.mix(0x000000, 0xFFFFFF, 0.0))
        assertEquals(0xFFFFFF, Contrast.mix(0x000000, 0xFFFFFF, 1.0))
        assertEquals(0x808080, Contrast.mix(0x000000, 0xFFFFFF, 0.5))
        // A tie rounds away from zero as Swift's rounded() does (126.5 is 127), never to the even 126.
        assertEquals(0x7F7F7F, Contrast.mix(0x000000, 0xFDFDFD, 0.5))
        assertEquals(21.0, Contrast.ratio(0x000000, 0xFFFFFF), 1e-9)
        assertEquals(1.0, Contrast.ratio(0x123456, 0x123456), 1e-9)
        assertEquals(1.0, Contrast.luminance(0xFFFFFF), 1e-9)
        assertEquals(0.0, Contrast.luminance(0x000000), 1e-9)
        assertEquals(0xFFFFFF, Contrast.white(1.0, 0x04060A))
        assertEquals(0x04060A, Contrast.white(0.0, 0x04060A))
    }

    private fun marker(id: String, at: Instant, fraction: Double) =
        RunwayMarker(id, RunwayMarker.Kind.USAGE_LIMIT, id, at, fraction, RunwayMarker.Tone.AMBER)

    @Test fun clearFractionIsWhereTheRunwayStops() {
        val t0 = Instant.parse("2026-10-27T01:12:00Z")
        val a = marker("a", t0.plusSeconds(5400), 0.25)
        val b = marker("b", t0.plusSeconds(9000), 0.4)
        // Nothing stops it: clear all the way.
        assertEquals(1.0, RunwayModel(listOf(a, b), true, null).clearFraction, 0.0)
        assertEquals(1.0, RunwayModel.empty.clearFraction, 0.0)
        // The marker at the deadline.
        assertEquals(0.4, RunwayModel(listOf(a, b), false, b.at).clearFraction, 0.0)
        // A deadline with no marker of its own: the earliest marker.
        assertEquals(0.25, RunwayModel(listOf(b, a), false, t0.plusSeconds(1)).clearFraction, 0.0)
        // No markers at all: clear.
        assertEquals(1.0, RunwayModel(emptyList(), false, t0).clearFraction, 0.0)
    }

    @Test fun titlesAreWords() {
        assertEquals("In flight", SectionTitle.words("IN FLIGHT"))
        assertEquals("Needs you", SectionTitle.words("NEEDS YOU"))
        assertEquals("Decide", SectionTitle.words("decide"))
        assertEquals("", SectionTitle.words(""))
        assertEquals("A", SectionTitle.words("a"))
    }

    @Test fun waitChipHoldsTheTimeAlone() {
        assertEquals("4m", WaitChip.text("waiting 4m"))
        assertEquals("finished 2m", WaitChip.text("finished 2m"))
        assertEquals("waiting", WaitChip.text("waiting"))
        assertEquals("1h 5m", WaitChip.text("waiting 1h 5m"))
    }

    @Test fun deskLightFollowsTheMoodAndAProblem() {
        assertEquals(0xF5B14C, DeskLight.colour(NowModel.Mood.NEEDS_YOU, null))
        assertEquals(0x5EEAD4, DeskLight.colour(NowModel.Mood.WORKING, null))
        assertEquals(0xA78BFA, DeskLight.colour(NowModel.Mood.DUSK, null))
        assertEquals(Contrast.mix(0x5EEAD4, 0x38BDF8, 0.5), DeskLight.colour(NowModel.Mood.QUIET, null))
        // A problem outranks the mood: amber, or slate when the Mac is asleep or gone.
        assertEquals(0xF5B14C, DeskLight.colour(NowModel.Mood.WORKING, DeskLight.ProblemTone.AMBER))
        assertEquals(0x6B7894, DeskLight.colour(NowModel.Mood.NEEDS_YOU, DeskLight.ProblemTone.SLATE))
    }
}
