package app.page.android.ui.nw.components

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageBitmapConfig
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max

// The soft glows ([drawSoftGlow]) are a stack of 8 to 28 translucent rounded rects. Recorded into a display list they are
// filled again, one on top of another, every frame the GPU draws the card. Here each glow is rendered ONCE (off the main
// thread, the first time it is wanted) and drawn from pixels from then on. Until they are ready the glow is drawn the old,
// layered way, so a first frame looks exactly as it always did.
//
// A glow is the same along a straight edge, so a big shape needs only its four corners and one pixel of each edge, stretched
// ([GlowPatchSpec]): a few hundred KB however big the card, and one set shared by every card of that corner, blur and colour.
// A small shape is rendered whole ([GlowSpec]).

/** What a glow is cached under: [GlowSpec] (the whole glow of a small shape), [GlowPatchSpec] (the corners and edges of a big one). */
internal sealed interface GlowKey

/**
 * Everything that decides a glow's pixels: its colour, blur, offset, corner, the shape it is the glow of, and the
 * pixel [region] (in the draw scope's own coordinates) the bitmap holds. Equal specs give the same bitmap. (The
 * `outsideOnly` cut-out is applied when the bitmap is drawn, so it is not part of the spec.)
 */
internal data class GlowSpec(
    val color: Color,
    val blur: Float,
    val dx: Float,
    val dy: Float,
    val corner: Float,
    val shapeLeft: Float,
    val shapeTop: Float,
    val shapeWidth: Float,
    val shapeHeight: Float,
    val regionLeft: Int,
    val regionTop: Int,
    val regionWidth: Int,
    val regionHeight: Int,
) : GlowKey {
    val pixels: Long get() = regionWidth.toLong() * regionHeight

    companion object {
        /** The most pixels one whole-glow bitmap may hold (a bigger shape is drawn from patches, or layered). */
        const val MAX_PIXELS = 1_000_000L

        /** The whole glow: the shape's rect, moved by [dx], [dy] and grown by [blur] on every side (the outermost layer), plus a pixel for the edge's anti-aliasing. */
        fun full(color: Color, blur: Float, dx: Float, dy: Float, corner: Float, left: Float, top: Float, width: Float, height: Float): GlowSpec? {
            val l = floor(left + dx - blur).toInt() - 1
            val t = floor(top + dy - blur).toInt() - 1
            val r = ceil(left + dx + width + blur).toInt() + 1
            val b = ceil(top + dy + height + blur).toInt() + 1
            return of(color, blur, dx, dy, corner, left, top, width, height, l, t, r - l, b - t)
        }

        /**
         * The top strip of a glow around a shape that is far taller than the strip: [stripBottom] is the last row (in
         * the shape's own coordinates) that is wanted, from the glow's top edge down. The strip is the same for every
         * shape at least [height] tall, so the desk (which is as tall as what is left of the screen) has one bitmap for
         * every scroll position.
         */
        fun topStrip(color: Color, blur: Float, dy: Float, corner: Float, width: Float, height: Float, stripBottom: Float): GlowSpec? {
            val t = floor(dy - blur).toInt() - 1
            val b = ceil(stripBottom).toInt()
            return of(color, blur, 0f, dy, corner, 0f, 0f, width, height, 0, t, ceil(width).toInt(), b - t)
        }

        private fun of(
            color: Color, blur: Float, dx: Float, dy: Float, corner: Float, left: Float, top: Float, width: Float, height: Float,
            rl: Int, rt: Int, rw: Int, rh: Int,
        ): GlowSpec? {
            if (rw <= 0 || rh <= 0 || rw.toLong() * rh > MAX_PIXELS) return null
            return GlowSpec(color, blur, dx, dy, corner, left, top, width, height, rl, rt, rw, rh)
        }
    }
}

/**
 * The corners and edges of the glow of a big shape, as a reference shape of 2 x [pad] + 2 px (plus the shape's own
 * fractions) rendered with the shape's own sub-pixel position: [fx], [fy] are the fractions of the glow's top-left corner
 * (the shape's corner moved by dx and dy), [fw], [fh] those of its size. Two shapes with the same blur, corner, colour and
 * fractions have the same glow at their corners, and the same along their edges, so they share it.
 */
internal data class GlowPatchSpec(
    val color: Color,
    val blur: Float,
    val corner: Float,
    val fx: Float,
    val fy: Float,
    val fw: Float,
    val fh: Float,
) : GlowKey {
    /** How far outside the shape's edge the glow reaches, in whole pixels (the blur, and a pixel for the anti-aliasing). */
    val reach: Int get() = reachOf(blur)

    /** How far inside the edge anything but the straight edge's profile reaches: the corner arcs, or the inner layers' square corners. */
    val pad: Int get() = padOf(blur, corner)

    companion object {
        fun reachOf(blur: Float): Int = ceil(blur).toInt() + 1

        /**
         * The fractional part of [x], to 1/256 px (a glow moved by 0.004 px is not a different picture; it is float noise that
         * would otherwise give two cards at different heights each their own patches).
         */
        fun fraction(x: Float): Float = Math.round((x - floor(x)) * 256f) / 256f

        fun padOf(blur: Float, corner: Float): Int = ceil(max(corner, blur)).toInt() + 3

        /** The spec for the glow of a shape of [width] x [height] whose glow's top-left corner is at ([gx], [gy]); null when the shape is too small to have a straight edge. */
        fun of(color: Color, blur: Float, corner: Float, gx: Float, gy: Float, width: Float, height: Float): GlowPatchSpec? {
            val pad = padOf(blur, corner)
            if (width < 2f * pad + 2f || height < 2f * pad + 2f) return null
            return GlowPatchSpec(color, blur, corner, fraction(gx), fraction(gy), fraction(width), fraction(height))
        }
    }
}

/** A cached glow: the whole bitmap of a small shape, or the [GlowPatches] of a big one. */
internal sealed interface GlowArt {
    val bytes: Long

    class Whole(val image: ImageBitmap) : GlowArt {
        override val bytes: Long get() = image.asAndroidBitmap().allocationByteCount.toLong()
    }

    /**
     * The four corner pieces ([reach] outside the edge, [pad] inside it, square), the four edge strips (one pixel across the
     * edge's length, the same [reach] + [pad] deep) and the one pixel the middle is made of.
     */
    class Patches(
        val reach: Int, val pad: Int,
        val topLeft: ImageBitmap, val topRight: ImageBitmap, val bottomLeft: ImageBitmap, val bottomRight: ImageBitmap,
        val top: ImageBitmap, val bottom: ImageBitmap, val left: ImageBitmap, val right: ImageBitmap, val middle: ImageBitmap,
    ) : GlowArt {
        override val bytes: Long
            get() = listOf(topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right, middle).sumOf { it.asAndroidBitmap().allocationByteCount.toLong() }
    }
}

/** A least-recently-used map that holds at most [maxBytes] of values (each sized by [sizeOf]). Not thread-safe: the caller locks. */
internal class ByteBudgetLru<K : Any, V : Any>(private val maxBytes: Long, private val sizeOf: (V) -> Long) {
    private val map = LinkedHashMap<K, V>(64, 0.75f, true)
    var bytes = 0L
        private set
    val size: Int get() = map.size

    operator fun get(key: K): V? = map[key]

    fun containsKey(key: K): Boolean = map.containsKey(key)

    fun put(key: K, value: V) {
        map.put(key, value)?.let { bytes -= sizeOf(it) }
        bytes += sizeOf(value)
        val it = map.entries.iterator()
        // Never evicts the entry just put, even when it alone is over the budget.
        while (bytes > maxBytes && map.size > 1 && it.hasNext()) {
            val e = it.next()
            if (e.key == key) continue
            bytes -= sizeOf(e.value)
            it.remove()
        }
    }
}

internal object NWGlowCache {
    private const val MAX_BYTES = 32L * 1024 * 1024
    private const val MAX_PENDING = 48

    private val lock = Any()
    private val cache = ByteBudgetLru<GlowKey, GlowArt>(MAX_BYTES) { it.bytes }
    private val pending = HashSet<GlowKey>()
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "nw-glow").apply { isDaemon = true; priority = Thread.NORM_PRIORITY - 2 } }
    private val main = Handler(Looper.getMainLooper())
    private var bumpScheduled = false

    /**
     * Read in a draw lambda that fell back to the layered glow: it is invalidated when glows have arrived, so the
     * glow is then drawn from pixels. Coalesced to one change per 50 ms however many land.
     */
    val arrivals = mutableIntStateOf(0)

    fun get(key: GlowKey): GlowArt? = synchronized(lock) { cache[key] }

    /** Renders [key] on the worker thread (once), unless the queue is full: the glow is then simply drawn layered. */
    fun request(key: GlowKey) {
        synchronized(lock) {
            if (cache.containsKey(key) || key in pending || pending.size >= MAX_PENDING) return
            pending.add(key)
        }
        worker.execute {
            val art = try { render(key) } catch (_: Throwable) { null }
            synchronized(lock) {
                pending.remove(key)
                if (art != null) cache.put(key, art)
            }
            if (art != null) scheduleArrival()
        }
    }

    private fun scheduleArrival() {
        synchronized(lock) { if (bumpScheduled) return; bumpScheduled = true }
        main.postDelayed({
            synchronized(lock) { bumpScheduled = false }
            arrivals.intValue++
        }, 50)
    }

    /** What a draw that wants [key] has now; when nothing, asks for it and subscribes the draw to [arrivals]. */
    fun ready(key: GlowKey): GlowArt? {
        val art = get(key)
        if (art == null) {
            // Reading the state makes this draw run again when glows arrive.
            arrivals.intValue
            request(key)
        }
        return art
    }

    fun render(key: GlowKey): GlowArt = when (key) {
        is GlowSpec -> GlowArt.Whole(renderWhole(key))
        is GlowPatchSpec -> renderPatches(key)
    }

    /**
     * Layers drawn into a transparent bitmap, in half-float precision and rounded to 8 bits once at the end: 8 to 28 layers
     * of an alpha of a few levels each, rounded to 8 bits at every layer, would drift by several levels from the profile
     * they add up to. (The half-float copy is 8 bytes a pixel and only ever lives here: freed at once.)
     */
    private fun renderLayers(width: Int, height: Int, draw: DrawScope.() -> Unit): Bitmap {
        val precise = ImageBitmap(width, height, ImageBitmapConfig.F16, hasAlpha = true)
        CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, Canvas(precise), Size(width.toFloat(), height.toFloat())) { draw() }
        val half = precise.asAndroidBitmap()
        val bits = half.copy(Bitmap.Config.ARGB_8888, false)
        half.recycle()
        return bits
    }

    private fun renderWhole(spec: GlowSpec): ImageBitmap =
        renderLayers(spec.regionWidth, spec.regionHeight) {
            translate(-spec.regionLeft.toFloat(), -spec.regionTop.toFloat()) {
                glowLayers(spec.color, spec.blur, spec.dy, spec.dx, spec.corner, Offset(spec.shapeLeft, spec.shapeTop), Size(spec.shapeWidth, spec.shapeHeight))
            }
        }.asImageBitmap()

    private fun renderPatches(spec: GlowPatchSpec): GlowArt.Patches {
        val e = spec.reach
        val p = spec.pad
        // The reference shape: 2 x pad + 2 px of straight edge-to-edge, at the sub-pixel position of the real one.
        val rw = 2f * p + 2f + spec.fw
        val rh = 2f * p + 2f + spec.fh
        val bw = e + ceil(spec.fx + rw).toInt() + e
        val bh = e + ceil(spec.fy + rh).toInt() + e
        val ref = renderLayers(bw, bh) {
            glowLayers(spec.color, spec.blur, 0f, 0f, spec.corner, Offset(e + spec.fx, e + spec.fy), Size(rw, rh))
        }
        val c = e + p
        fun piece(x: Int, y: Int, w: Int, h: Int) = Bitmap.createBitmap(ref, x, y, w, h).asImageBitmap()
        // A column and a row clear of both corners' arcs: the profile across the edge, which is the same all along it.
        val col = c + 1
        val row = c + 1
        return GlowArt.Patches(
            e, p,
            topLeft = piece(0, 0, c, c), topRight = piece(bw - c, 0, c, c), bottomLeft = piece(0, bh - c, c, c), bottomRight = piece(bw - c, bh - c, c, c),
            top = piece(col, 0, 1, c), bottom = piece(col, bh - c, 1, c), left = piece(0, row, c, 1), right = piece(bw - c, row, c, 1),
            middle = piece(col, row, 1, 1),
        )
    }
}

/**
 * Draws a glow whose layers' outer rect has its top-left at ([gx], [gy]) and size [w] x [h] from [patches]: the corners
 * where they are, each edge's one pixel stretched along the edge, the middle's one pixel over the middle. Every piece lands on
 * a whole pixel, and the shape's own sub-pixel position is in the pieces ([GlowPatchSpec]).
 */
internal fun DrawScope.drawGlowPatches(patches: GlowArt.Patches, gx: Float, gy: Float, w: Float, h: Float) {
    val l = glowPatchLayout(gx, gy, w, h, patches.reach, patches.pad)
    drawImage(patches.topLeft, topLeft = l.topLeft.topLeftOffset())
    drawImage(patches.topRight, topLeft = l.topRight.topLeftOffset())
    drawImage(patches.bottomLeft, topLeft = l.bottomLeft.topLeftOffset())
    drawImage(patches.bottomRight, topLeft = l.bottomRight.topLeftOffset())
    l.top?.let { stretch(patches.top, it) }
    l.bottom?.let { stretch(patches.bottom, it) }
    l.left?.let { stretch(patches.left, it) }
    l.right?.let { stretch(patches.right, it) }
    l.middle?.let { stretch(patches.middle, it) }
}

/** A rectangle of whole pixels: [x], [y] of its top-left and its [w] x [h]. */
internal data class PixelRect(val x: Int, val y: Int, val w: Int, val h: Int) {
    fun topLeftOffset() = Offset(x.toFloat(), y.toFloat())
}

/**
 * Where the nine pieces of a glow of a shape's outer rect (top-left ([gx], [gy]), [w] x [h]) land: all on whole pixels,
 * tiling exactly the area from [reach] outside the rect's pixel bounds to [reach] outside the far side. The edge strips and the middle are null when the
 * shape is so narrow that the corners already meet. Pure.
 */
internal data class GlowPatchLayout(
    val topLeft: PixelRect, val topRight: PixelRect, val bottomLeft: PixelRect, val bottomRight: PixelRect,
    val top: PixelRect?, val bottom: PixelRect?, val left: PixelRect?, val right: PixelRect?, val middle: PixelRect?,
)

internal fun glowPatchLayout(gx: Float, gy: Float, w: Float, h: Float, reach: Int, pad: Int): GlowPatchLayout {
    val e = reach
    val p = pad
    val ox = floor(gx).toInt()
    val oy = floor(gy).toInt()
    val rx = ceil(gx + w).toInt()
    val by = ceil(gy + h).toInt()
    val c = e + p
    val innerW = rx - p - (ox + p)
    val innerH = by - p - (oy + p)
    return GlowPatchLayout(
        topLeft = PixelRect(ox - e, oy - e, c, c), topRight = PixelRect(rx - p, oy - e, c, c),
        bottomLeft = PixelRect(ox - e, by - p, c, c), bottomRight = PixelRect(rx - p, by - p, c, c),
        top = if (innerW > 0) PixelRect(ox + p, oy - e, innerW, c) else null,
        bottom = if (innerW > 0) PixelRect(ox + p, by - p, innerW, c) else null,
        left = if (innerH > 0) PixelRect(ox - e, oy + p, c, innerH) else null,
        right = if (innerH > 0) PixelRect(rx - p, oy + p, c, innerH) else null,
        middle = if (innerW > 0 && innerH > 0) PixelRect(ox + p, oy + p, innerW, innerH) else null,
    )
}

/** [image] over the pixels of [to], nearest-neighbour so a stretched pixel never takes its neighbour's colour. */
private fun DrawScope.stretch(image: ImageBitmap, to: PixelRect) {
    drawImage(
        image, srcOffset = IntOffset.Zero, srcSize = IntSize(image.width, image.height),
        dstOffset = IntOffset(to.x, to.y), dstSize = IntSize(to.w, to.h), filterQuality = FilterQuality.None,
    )
}

/** The layers of a soft glow: shrinking rounded rects whose alpha is solved so the stack's profile is the Gaussian's (see [drawSoftGlow]). */
internal fun DrawScope.glowLayers(color: Color, blur: Float, dy: Float, dx: Float, corner: Float, topLeft: Offset, shapeSize: Size) {
    val a = color.alpha
    val sigma = blur / 2.0
    val steps = glowSteps(blur)
    var covered = 0.0
    for (i in 0 until steps) {
        val e0 = blur - 2f * blur * i / steps
        val e1 = blur - 2f * blur * (i + 1) / steps
        // The cumulative alpha wanted in the band between this layer's edge and the next one's, at its middle.
        val target = a * normalCdf(-((e0 + e1) / 2.0) / sigma)
        val layerAlpha = (1.0 - (1.0 - target) / (1.0 - covered)).coerceIn(0.0, 1.0)
        covered = target.coerceAtLeast(covered)
        val w = shapeSize.width + 2 * e0
        val h = shapeSize.height + 2 * e0
        if (w <= 0f || h <= 0f || layerAlpha <= 0.0005) continue
        drawRoundRect(
            color.copy(alpha = layerAlpha.toFloat()), topLeft = Offset(topLeft.x + dx - e0, topLeft.y + dy - e0),
            size = Size(w, h), cornerRadius = CornerRadius(max(0f, corner + e0)),
        )
    }
}

/** How many layers a glow of [blur] px stacks: one per 1.5 px, 8 to 28. */
internal fun glowSteps(blur: Float): Int = (blur / 1.5f).toInt().coerceIn(8, 28)
