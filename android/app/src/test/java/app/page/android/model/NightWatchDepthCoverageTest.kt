package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gaps in [NightWatchDepthTest], mirrored from iOS LogicTests' "Night Watch v5 depth" section: the contrast
 * symmetry and grey, the jewels' ramp order, every chip and hue given its tone by name, and the desk's quiet light.
 */
class NightWatchDepthCoverageTest {
    @Test fun contrastIsSymmetric() {
        val pairs = listOf(0x000000 to 0xFFFFFF, 0x1D62AE to 0x7CC8FF, 0x123456 to 0xABCDEF)
        for ((a, b) in pairs) assertEquals("$a vs $b", Contrast.ratio(a, b), Contrast.ratio(b, a), 1e-12)
    }

    @Test fun greyHasTheWcagLuminance() {
        // 0x808080: ((128/255 + 0.055) / 1.055)^2.4, about 0.2159.
        assertEquals(0.2159, Contrast.luminance(0x808080), 1e-4)
    }

    @Test fun whiteAtHalfAlphaOverBlackIsMidGrey() {
        assertEquals(0x808080, Contrast.white(0.5, 0x000000))
    }

    @Test fun everyJewelIsDarkerAtItsFarCornerAndLightIsAFraction() {
        for (tone in JewelTone.entries) {
            val r = tone.ramp
            assertTrue(
                "${tone.name} bottom is not darker than top",
                Contrast.luminance(r.bottom) < Contrast.luminance(r.top),
            )
            assertTrue("${tone.name} lightStrength is ${r.lightStrength}", r.lightStrength in 0.0..0.35)
        }
    }

    @Test fun litCornerIsTopLitTowardsTheLight() {
        for (tone in JewelTone.entries) {
            val r = tone.ramp
            assertEquals(tone.name, Contrast.mix(r.top, r.light, r.lightStrength), r.litCorner)
            assertTrue("${tone.name} lit corner is not lighter than top", Contrast.luminance(r.litCorner) > Contrast.luminance(r.top))
        }
    }

    @Test fun everyChipKindIsGivenItsToneByName() {
        val expected = mapOf(
            ChipKind.IRREVERSIBLE to JewelTone.RED,
            ChipKind.CONSIDERED to JewelTone.SKY,
            ChipKind.UNDOABLE to JewelTone.GREEN,
            ChipKind.REVIEW to JewelTone.TEAL,
            ChipKind.LOOKS_STUCK to JewelTone.AMBER,
            ChipKind.QUESTION to JewelTone.AMBER,
            ChipKind.FORECAST to JewelTone.AMBER,
            ChipKind.RATE_LIMITED to JewelTone.AMBER,
            ChipKind.BUDGET to JewelTone.AMBER,
        )
        // A new chip must be given a tone here as well, not fall through unnoticed.
        assertEquals(ChipKind.entries.toSet(), expected.keys)
        for ((chip, tone) in expected) assertEquals(chip.name, tone, JewelTone.of(chip))
    }

    @Test fun everyProjectHueIsGivenItsToneByName() {
        val expected = mapOf(
            ProjectHue.TEAL to JewelTone.TEAL,
            ProjectHue.SKY to JewelTone.SKY,
            ProjectHue.LIME to JewelTone.LIME,
            ProjectHue.VIOLET to JewelTone.VIOLET,
            ProjectHue.ROSE to JewelTone.PLUM,
            ProjectHue.WHITE to JewelTone.INDIGO,
        )
        assertEquals(ProjectHue.entries.toSet(), expected.keys)
        for ((hue, tone) in expected) assertEquals(hue.name, tone, JewelTone.of(hue))
    }

    @Test fun sectionTitleLowersTheRestOfAnyCase() {
        assertEquals("In flight", SectionTitle.words("in flight"))
    }

    @Test fun quietDeskLightIsTealHalfWayToSky() {
        assertEquals(0x4BD4E6, DeskLight.quiet)
        assertEquals(0x4BD4E6, DeskLight.colour(NowModel.Mood.QUIET, null))
    }
}
