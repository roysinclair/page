package app.page.android.ui.nw.components

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GlowCacheTest {
    private val black = Color.Black.copy(alpha = 0.6f)

    private fun spec(
        color: Color = black, blur: Float = 52f, dx: Float = 0f, dy: Float = 36.4f, corner: Float = 62f,
        left: Float = 0f, top: Float = 0f, w: Float = 900f, h: Float = 400f,
    ) = GlowSpec.full(color, blur, dx, dy, corner, left, top, w, h)!!

    @Test
    fun equalInputsMakeEqualKeysSoCardsOfOneSizeShareABitmap() {
        assertEquals(spec(), spec())
        assertEquals(spec().hashCode(), spec().hashCode())
    }

    @Test
    fun everyInputThatChangesThePixelsChangesTheKey() {
        val base = spec()
        assertNotEquals(base, spec(color = Color.Black.copy(alpha = 0.55f)))
        assertNotEquals(base, spec(color = Color.Red.copy(alpha = 0.6f)))
        assertNotEquals(base, spec(blur = 40f))
        assertNotEquals(base, spec(dx = 3f))
        assertNotEquals(base, spec(dy = 20f))
        assertNotEquals(base, spec(corner = 40f))
        assertNotEquals(base, spec(left = 4f))
        assertNotEquals(base, spec(top = 4f))
        assertNotEquals(base, spec(w = 901f))
        assertNotEquals(base, spec(h = 401f))
    }

    @Test
    fun theRegionHoldsTheWholeGlow() {
        val s = spec(blur = 52f, dx = 0f, dy = 36.4f, w = 900f, h = 400f)
        // The outermost layer reaches `blur` past the shape on every side, moved down by dy.
        assertTrue(s.regionLeft <= -52)
        assertTrue(s.regionTop <= (36.4f - 52f).toInt() - 1)
        assertTrue(s.regionLeft + s.regionWidth >= 900 + 52)
        assertTrue(s.regionTop + s.regionHeight >= (400f + 36.4f + 52f).toInt())
    }

    @Test
    fun aShapeOffsetByAnotherTopLeftKeepsItsFractionInTheKey() {
        // The same size at a fractional position is another picture (its edges fall between pixels differently).
        assertNotEquals(spec(left = 0f), spec(left = 0.5f))
    }

    @Test
    fun aGlowTooBigForABitmapIsDrawnLayered() {
        assertNull(GlowSpec.full(black, 52f, 0f, 0f, 62f, 0f, 0f, 3000f, 3000f))
        assertNotNull(GlowSpec.full(black, 52f, 0f, 0f, 62f, 0f, 0f, 1080f, 600f))
    }

    @Test
    fun theDeskStripIsOneBitmapWhateverTheScrollPosition() {
        val a = GlowSpec.topStrip(Color.Black.copy(alpha = 0.7f), 67.6f, -15.6f, 83.2f, 1080f, 600f, 85.2f)!!
        val b = GlowSpec.topStrip(Color.Black.copy(alpha = 0.7f), 67.6f, -15.6f, 83.2f, 1080f, 600f, 85.2f)!!
        assertEquals(a, b)
        // It is a strip, not the screen: from the glow's top edge down past the corner's cut-out, the full width.
        assertEquals(0, a.regionLeft)
        assertEquals(1080, a.regionWidth)
        assertTrue(a.regionTop <= (-15.6f - 67.6f).toInt())
        assertTrue(a.regionTop + a.regionHeight >= 85)
        assertTrue("a strip of well under a megapixel", a.pixels < 400_000)
    }

    @Test
    fun layerCountFollowsTheBlurAsBefore() {
        assertEquals(8, glowSteps(6f))
        assertEquals(8, glowSteps(12f))
        assertEquals(13, glowSteps(20f))
        assertEquals(28, glowSteps(52f))
        assertEquals(28, glowSteps(200f))
    }

    @Test
    fun theLruEvictsTheLeastRecentlyUsedWhenOverBudget() {
        val lru = ByteBudgetLru<String, Int>(100) { it.toLong() }
        lru.put("a", 40)
        lru.put("b", 40)
        assertEquals(40, lru["a"]) // a is now the most recent
        lru.put("c", 40) // 120 > 100: b (the least recent) goes
        assertFalse(lru.containsKey("b"))
        assertTrue(lru.containsKey("a"))
        assertTrue(lru.containsKey("c"))
        assertEquals(80L, lru.bytes)
    }

    @Test
    fun theLruKeepsAnEntryThatAloneIsOverBudgetAndCountsAReplacementOnce() {
        val lru = ByteBudgetLru<String, Int>(100) { it.toLong() }
        lru.put("big", 500)
        assertTrue(lru.containsKey("big"))
        assertEquals(500L, lru.bytes)
        lru.put("big", 30)
        assertEquals(30L, lru.bytes)
        assertEquals(1, lru.size)
    }

    // MARK: the corners-and-edges form of a big shape's glow

    private fun patchSpec(w: Float = 900f, h: Float = 400f, gx: Float = 0f, gy: Float = 36.4f, blur: Float = 52f, corner: Float = 62f, color: Color = black) =
        GlowPatchSpec.of(color, blur, corner, gx, gy, w, h)

    @Test
    fun bigShapesOfOneCornerAndBlurShareOnePatchSetWhateverTheirSize() {
        val a = patchSpec(w = 900f, h = 400f)!!
        // Another size, the same sub-pixel position: the same corners and edges.
        assertEquals(a, patchSpec(w = 1010f, h = 1027f))
        assertEquals(a, patchSpec(w = 360f, h = 300f, gx = 100f, gy = 236.4f))
    }

    @Test
    fun theSubPixelPositionAndTheOtherInputsStayInThePatchKey() {
        val a = patchSpec()!!
        assertNotEquals(a, patchSpec(gx = 0.5f))
        assertNotEquals(a, patchSpec(gy = 36.9f))
        assertNotEquals(a, patchSpec(w = 900.5f))
        assertNotEquals(a, patchSpec(h = 400.25f))
        assertNotEquals(a, patchSpec(blur = 40f))
        assertNotEquals(a, patchSpec(corner = 40f))
        assertNotEquals(a, patchSpec(color = Color.Black.copy(alpha = 0.5f)))
    }

    @Test
    fun aShapeTooSmallForAStraightEdgeIsRenderedWhole() {
        val pad = GlowPatchSpec.padOf(52f, 62f)
        assertNull(patchSpec(w = 2f * pad, h = 400f))
        assertNull(patchSpec(w = 900f, h = 2f * pad))
        assertNotNull(patchSpec(w = 2f * pad + 2f, h = 2f * pad + 2f))
    }

    @Test
    fun theInnerReachCoversBothTheCornerArcAndTheSquareCornersOfTheInnerLayers() {
        // The arcs end `corner` in from the edge; the inner layers, whose radius has shrunk to nothing, start `blur` in.
        assertTrue(GlowPatchSpec.padOf(blur = 10f, corner = 62f) >= 62)
        assertTrue(GlowPatchSpec.padOf(blur = 62f, corner = 10f) >= 62)
        assertTrue(GlowPatchSpec.reachOf(52f) >= 52)
    }

    /** The nine pieces tile the glow's area exactly: no pixel left out, none drawn twice. */
    private fun assertTiles(gx: Float, gy: Float, w: Float, h: Float, reach: Int, pad: Int) {
        val l = glowPatchLayout(gx, gy, w, h, reach, pad)
        val pieces = listOfNotNull(l.topLeft, l.topRight, l.bottomLeft, l.bottomRight, l.top, l.bottom, l.left, l.right, l.middle)
        assertEquals("all nine", 9, pieces.size)
        val x0 = kotlin.math.floor(gx).toInt() - reach
        val y0 = kotlin.math.floor(gy).toInt() - reach
        val x1 = kotlin.math.ceil(gx + w).toInt() + reach
        val y1 = kotlin.math.ceil(gy + h).toInt() + reach
        val seen = Array(y1 - y0) { IntArray(x1 - x0) }
        for (r in pieces) {
            assertTrue(r.w > 0 && r.h > 0)
            for (y in r.y until r.y + r.h) for (x in r.x until r.x + r.w) {
                assertTrue("inside the glow's area at $x,$y", x in x0 until x1 && y in y0 until y1)
                seen[y - y0][x - x0]++
            }
        }
        for (y in 0 until y1 - y0) for (x in 0 until x1 - x0) assertEquals("pixel ${x + x0},${y + y0} drawn once", 1, seen[y][x])
    }

    @Test
    fun thePatchPiecesTileTheGlowExactlyAtAnySizeAndFraction() {
        val reach = GlowPatchSpec.reachOf(52f)
        val pad = GlowPatchSpec.padOf(52f, 62f)
        for ((w, h) in listOf(900f to 400f, 2f * pad + 2f to 2f * pad + 2f, 1010.4f to 1027.9f, 360f to 300.5f, 700.75f to 2000f)) {
            for ((gx, gy) in listOf(0f to 0f, 0f to 36.4f, 15.5f to 8.25f, -3.7f to -40.2f)) assertTiles(gx, gy, w, h, reach, pad)
        }
    }
}
