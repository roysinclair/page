package app.page.android.ui.nw.components

import android.graphics.RuntimeShader
import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.material3.Icon
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import app.page.android.model.CardGlow
import app.page.android.model.ChipKind
import app.page.android.model.JewelRamp
import app.page.android.model.JewelTone
import app.page.android.model.ProjectHue
import app.page.android.ui.nw.theme.LocalCardGlow
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import app.page.android.ui.nw.theme.LocalReduceMotion
import kotlin.math.max
import kotlin.math.min

/** Eased gradient stops for a ramp: `alpha(t)` sampled at `steps + 1` points, so a glow rises with no visible step or band. */
fun nwRampStops(color: Rgba, steps: Int = 14, alpha: (Double) -> Double): Array<Pair<Float, Color>> =
    Array(steps + 1) { i ->
        val t = i.toDouble() / steps
        t.toFloat() to color.opacity(alpha(t).coerceIn(0.0, 1.0)).color
    }

/**
 * The glass of a Night Watch surface, raised off the page: lit from above (a fill a shade lighter at the top, a
 * sheen over the top 40%, a rim that fades down the sides) and casting a soft shadow, so a card reads as an object on
 * the page rather than a box drawn on it. The "Card glow" setting ([glow]) decides whether a soft light also rises
 * from the bottom edge; off (the default) draws no light at all.
 *
 * [tint] gives the surface a state's colour (amber for a stuck session, teal for a finished turn): a radial from the
 * top edge, the rim and a faint glow, **never mixed into the fill**, so the fill keeps its own clean neutral and the
 * colour stays clean (a hue mixed into the grey with alpha is what turned red maroon and amber brown in v4). The tint's
 * own alpha is its strength. That is the card's own colour, not the glow, so it stays with the glow Off.
 *
 * [raised] is false for a surface that sits inside another (an inset, a well): no shadow. Android has no Liquid Glass
 * and no backdrop blur to draw through, so the glass is a lightly translucent fill, a rim and, with the glow on, the
 * glass light. Every shadow is drawn ([drawSoftGlow]), so none depends on API 28's coloured elevation shadows.
 */
fun Modifier.nwGlass(
    radius: Dp = NW.Radius.card,
    fill: Rgba = NW.Palette.surface.opacity(0.92),
    tint: Rgba? = null,
    rim: Boolean = true,
    glow: CardGlow = CardGlow.OFF,
    raised: Boolean = true,
): Modifier = this.drawBehind {
    val r = radius.toPx()
    if (raised) {
        drawSoftGlow(Color.Black.copy(alpha = 0.6f), blur = 20.dp.toPx(), dy = 14.dp.toPx(), corner = r, outsideOnly = true)
        if (tint != null) drawSoftGlow(tint.opacity(0.16 * tint.a).color, blur = 18.dp.toPx(), dy = 8.dp.toPx(), corner = r, outsideOnly = true)
        else drawSoftGlow(Color.Black.copy(alpha = 0.35f), blur = 2.dp.toPx(), dy = 1.dp.toPx(), corner = r, outsideOnly = true)
    }
    val top = fill.mixed(Rgba(1.0, 1.0, 1.0, fill.a), 0.045)
    drawRoundRect(Brush.verticalGradient(listOf(top.color, fill.color)), cornerRadius = CornerRadius(r))
    // Light catching the top of the glass.
    drawRoundRect(Brush.verticalGradient(0f to Color.White.copy(alpha = 0.05f), 0.4f to Color.White.copy(alpha = 0f)), cornerRadius = CornerRadius(r))
    if (tint != null) {
        drawRoundRect(
            Brush.radialGradient(listOf(tint.opacity(0.13 * tint.a).color, tint.opacity(0.0).color), center = Offset(size.width / 2, 0f), radius = 260.dp.toPx()),
            cornerRadius = CornerRadius(r),
        )
    }
    if (glow.isOn) drawCardGlowLight(r, glow)
    if (rim) {
        // The lit lip along the top edge, fading down the sides.
        strokeBorder(
            Brush.verticalGradient(0f to Color.White.copy(alpha = 0.22f), 0.35f to Color.White.copy(alpha = 0.06f), 1f to Color.White.copy(alpha = 0.04f)), r,
        )
        if (tint != null) strokeBorder(Brush.verticalGradient(listOf(tint.opacity(0.62 * tint.a).color, tint.opacity(0.22 * tint.a).color)), r)
        if (glow.isOn) drawCardGlowRim(r, glow)
    }
}

/**
 * The inner light: a wide, soft wash plus a stroke that hugs the rounded outline, both masked with an eased
 * bottom-weighted ramp. Drawn inside the shape (clipped to it), so it follows the corners.
 */
private fun DrawScope.drawCardGlowLight(radius: Float, glow: CardGlow) {
    val tint = NW.Palette.glass
    val w = size.width
    val h = size.height
    val outline = Path().apply { addRoundRect(androidx.compose.ui.geometry.RoundRect(0f, 0f, w, h, CornerRadius(radius))) }
    clipPath(outline) {
        // Wash: an ellipse centred on the bottom edge; alpha is strongest there and fades to nothing outwards.
        val ky = max(0.2f, h / max(1f, w))
        val wash = Array(15) { i -> (i / 14f) to tint.opacity(glow.lightAlpha(1 - i / 14.0) * 0.5).color }
        scale(1f, ky, pivot = Offset(w / 2, h)) {
            drawCircle(Brush.radialGradient(*wash, center = Offset(w / 2, h), radius = w * 0.85f), radius = w * 0.85f, center = Offset(w / 2, h))
        }
        // Edge light: the outline, softened inwards, rising with the ramp.
        val reach = glow.reach
        val mask = Brush.verticalGradient(
            *Array(15) { i ->
                val t = i / 14f
                t to tint.opacity((glow.lightAlpha((t - (1 - reach)) / reach) * 1.4).coerceIn(0.0, 1.0)).color
            },
        )
        val outlinePath = outline
        for ((widthK, alphaK) in listOf(10f to 0.25f, 5f to 0.45f, 2.5f to 0.8f)) {
            drawPath(outlinePath, mask, alpha = alphaK, style = Stroke(widthK.dp.toPx()))
        }
    }
}

/** The rim's glow: the outline warms towards the bottom along an eased ramp (zero over the top half). */
private fun DrawScope.drawCardGlowRim(radius: Float, glow: CardGlow) {
    val hair = 1.dp.toPx()
    val tint = NW.Palette.glass
    val stops = Array(15) { i -> (i / 14f) to tint.opacity(glow.rimAlpha(i / 14.0)).color }
    drawRoundRect(
        Brush.verticalGradient(*stops), topLeft = Offset(hair / 2, hair / 2),
        size = androidx.compose.ui.geometry.Size(size.width - hair, size.height - hair), cornerRadius = CornerRadius(radius - hair / 2), style = Stroke(hair),
    )
}

/**
 * glass.glsl's edge light over a glass surface: the rim catches a light from the top-left with a sheen along it
 * and a fine inner highlight. It is a light, so it follows the Card glow setting (Off draws nothing) and it is
 * still: the sheen is set by [sheen], not a clock, so glass costs nothing per frame. API 33+ (AGSL).
 */
@Composable
fun NWGlassEdgeLight(radius: Dp, modifier: Modifier = Modifier, sheen: Double = 0.6) {
    val glow = LocalCardGlow.current
    if (!(NWShaders.available && Build.VERSION.SDK_INT >= 33) || !glow.isOn) return
    val shader = remember { RuntimeShader(NWShaders.GLASS_RIM) }
    Canvas(modifier) {
        shader.setFloatUniform("size", size.width, size.height)
        shader.setFloatUniform("radius", radius.toPx())
        shader.setFloatUniform("sheen", sheen.toFloat())
        shader.setFloatUniform("px", density)
        NWShaders.setColor(shader, "edgeLight", Rgba.hex(0x9FF5E8))
        shader.setFloatUniform("strength", (0.55 * glow.strength).toFloat())
        drawRect(ShaderBrush(shader))
    }
}

/** A glass card around its content ([nwGlass]; [raised] false for one that sits inside another). */
@Composable
fun NWGlassCard(
    modifier: Modifier = Modifier,
    radius: Dp = NW.Radius.card,
    padding: PaddingValues = PaddingValues(NW.Space.lg),
    tint: Rgba? = null,
    raised: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val glow = LocalCardGlow.current
    Box(modifier.fillMaxWidth().nwGlass(radius, tint = tint, glow = glow, raised = raised)) {
        Column(Modifier.fillMaxWidth().padding(padding), content = content)
        NWGlassEdgeLight(radius, Modifier.matchParentSize())
    }
}

// MARK: - Drawing helpers (no API 28 coloured shadows, no API 31 blur: every glow is drawn)

private fun erf(x: Double): Double {
    // Abramowitz and Stegun 7.1.26, good to 1.5e-7.
    val t = 1.0 / (1.0 + 0.3275911 * kotlin.math.abs(x))
    val y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * kotlin.math.exp(-x * x)
    return if (x >= 0) y else -y
}

private fun normalCdf(x: Double) = 0.5 * (1.0 + erf(x / kotlin.math.sqrt(2.0)))

/**
 * A soft shadow or glow of a rounded rectangle, drawn in [color]: what SwiftUI's `.shadow(color, radius: blur, x, y)`
 * does, without a blur filter. It stacks shrinking rounded rects whose alpha is solved so the stack's profile across the edge is the
 * Gaussian blur's (sigma = blur / 2): half strength at the shape's edge, about 2% at [blur] outside it, full a [blur] inside. Plain
 * rounded-rect fills in the glow's own colour, so it works on every API level (`Modifier.shadow`'s coloured shadows need 28,
 * `blur` needs 31; `BlurMaskFilter` and `setShadowLayer` are not drawn by the hardware canvas below 28).
 *
 * [corner] is the shape's corner radius in px and the shape is the draw area unless [topLeft] and [shapeSize] say otherwise.
 * [outsideOnly] clips the shape itself out, for a glow under a translucent body (a soft button, the glass bubble, chrome), where
 * a full-strength glow showing through would tint the fill; SwiftUI scales a shadow by the body's alpha, this does the clean version.
 * Draw it before (under) the body and, in a modifier chain, before any `clip`.
 */
fun DrawScope.drawSoftGlow(
    color: Color, blur: Float, dy: Float = 0f, dx: Float = 0f, corner: Float,
    outsideOnly: Boolean = false, topLeft: Offset = Offset.Zero, shapeSize: androidx.compose.ui.geometry.Size = size,
) {
    val a = color.alpha
    if (a <= 0.004f || blur <= 0.5f) return
    val sigma = blur / 2.0
    val steps = (blur / 1.5f).toInt().coerceIn(8, 28)
    fun layers() {
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
                size = androidx.compose.ui.geometry.Size(w, h), cornerRadius = CornerRadius(max(0f, corner + e0)),
            )
        }
    }
    if (outsideOnly) {
        val hole = Path().apply { addRoundRect(androidx.compose.ui.geometry.RoundRect(topLeft.x, topLeft.y, topLeft.x + shapeSize.width, topLeft.y + shapeSize.height, CornerRadius(corner))) }
        clipPath(hole, androidx.compose.ui.graphics.ClipOp.Difference) { layers() }
    } else {
        layers()
    }
}

/** A border drawn inside the shape (SwiftUI's `strokeBorder`): [brush] along a [width]-px line whose outer edge is the shape's. */
fun DrawScope.strokeBorder(brush: Brush, corner: Float, width: Float = 1.dp.toPx()) {
    drawRoundRect(
        brush, topLeft = Offset(width / 2, width / 2), size = androidx.compose.ui.geometry.Size(size.width - width, size.height - width),
        cornerRadius = CornerRadius(max(0f, corner - width / 2)), style = Stroke(width),
    )
}

private fun white(alpha: Float) = Color.White.copy(alpha = alpha)

// MARK: - Depth: jewels and the desk

/**
 * The surface of something that needs you: a saturated colour lit from its top corner, the one loud thing on the page.
 * Each is a designed ramp of opaque colours (never a hue faded into the grey surface), and every point of it holds white
 * text at 4.5:1 or better, the lit corner included. One source of truth: the table is [JewelTone] (shared with the iPhone
 * and the tests), and no colour is written here.
 */
@Immutable
data class NWJewel(
    /** The lit corner (top leading) and the far one (bottom trailing). */
    val top: Rgba,
    val bottom: Rgba,
    /** Its rim, its glow and the light that falls into the top corner. */
    val light: Rgba,
    val lightStrength: Double,
) {
    constructor(ramp: JewelRamp) : this(Rgba.hex(ramp.top), Rgba.hex(ramp.bottom), Rgba.hex(ramp.light), ramp.lightStrength)
    constructor(tone: JewelTone) : this(tone.ramp)

    companion object {
        /** Irreversible: crimson. */
        val red = NWJewel(JewelTone.RED)

        /** Considered: deep sky. */
        val sky = NWJewel(JewelTone.SKY)

        /** Undoable: emerald. */
        val green = NWJewel(JewelTone.GREEN)

        /** A question, anything amber: ember. */
        val amber = NWJewel(JewelTone.AMBER)

        /** Working, a finished turn: deep teal. */
        val teal = NWJewel(JewelTone.TEAL)

        // A project's own colours ([ProjectHue]), for its doors and bands. Rose leans plum and white leans indigo, so neither
        // reads as Irreversible's crimson or as grey.
        val lime = NWJewel(JewelTone.LIME)
        val violet = NWJewel(JewelTone.VIOLET)
        val plum = NWJewel(JewelTone.PLUM)
        val indigo = NWJewel(JewelTone.INDIGO)

        fun of(tone: JewelTone): NWJewel = when (tone) {
            JewelTone.RED -> red
            JewelTone.SKY -> sky
            JewelTone.GREEN -> green
            JewelTone.AMBER -> amber
            JewelTone.TEAL -> teal
            JewelTone.LIME -> lime
            JewelTone.VIOLET -> violet
            JewelTone.PLUM -> plum
            JewelTone.INDIGO -> indigo
        }

        /** A card's jewel by its chip ([JewelTone.of]). */
        fun of(chip: ChipKind): NWJewel = of(JewelTone.of(chip))

        /** A project's jewel. */
        fun of(hue: ProjectHue): NWJewel = of(JewelTone.of(hue))

        /** The jewel of a row's colour ([NowRow.tint]) or a section's: amber unless it is one of the status colours. */
        fun of(tint: Rgba?): NWJewel = when (tint) {
            NW.Palette.red -> red
            NW.Palette.sky -> sky
            NW.Palette.green -> green
            NW.Palette.teal -> teal
            NW.Palette.violet -> violet
            else -> amber
        }
    }
}

/**
 * A jewel's surface: its ramp, the light in its top corner, a bright lip, a rim in its own light and a glow of that
 * light under it. Opaque. [lift] is how far it stands off the page: its glow's reach and drop (a Decide card is 1.25,
 * a project's door 0.7). Lift on a dark page is light: its own colour glowing under it, then a short dark contact shadow.
 */
fun Modifier.nwJewelSurface(jewel: NWJewel, radius: Dp = NW.Radius.card, lift: Double = 1.0): Modifier = this.drawBehind {
    val r = radius.toPx()
    val k = lift.toFloat()
    drawSoftGlow(Color.Black.copy(alpha = 0.55f), blur = 4.dp.toPx(), dy = 3.dp.toPx(), corner = r)
    drawSoftGlow(jewel.light.opacity(0.36 * min(1.0, lift)).color, blur = 24.dp.toPx() * k, dy = 14.dp.toPx() * k, corner = r)
    drawJewelBody(jewel, r, lightRadius = 300.dp.toPx())
    // The gloss: light across the top, gone a third of the way down.
    drawRoundRect(Brush.verticalGradient(0f to white(0.06f), 0.35f to white(0f)), cornerRadius = CornerRadius(r))
    strokeBorder(Brush.verticalGradient(listOf(jewel.light.opacity(0.85).color, jewel.light.opacity(0.22).color)), r)
    // The lip: light catching the top edge.
    strokeBorder(Brush.verticalGradient(0f to white(0.42f), 0.3f to white(0f)), r)
}

private fun DrawScope.drawJewelBody(jewel: NWJewel, r: Float, lightRadius: Float) {
    drawRoundRect(Brush.linearGradient(listOf(jewel.top.color, jewel.bottom.color), start = Offset.Zero, end = Offset(size.width, size.height)), cornerRadius = CornerRadius(r))
    drawRoundRect(
        Brush.radialGradient(listOf(jewel.light.opacity(jewel.lightStrength).color, jewel.light.opacity(0.0).color), center = Offset.Zero, radius = lightRadius),
        cornerRadius = CornerRadius(r),
    )
}

/**
 * An icon tile: a small glossy squircle of a jewel with a white glyph, the way a section, a card or a session is marked
 * (corner 0.3 x [size]). [glass] is for a tile that sits on a jewel already: clear glass, so it does not vanish into its
 * own colour, with a glyph glowing in the jewel's light.
 */
@Composable
fun NWIconTile(symbol: String, jewel: NWJewel, modifier: Modifier = Modifier, size: Dp = 30.dp, glass: Boolean = false) {
    Box(
        modifier
            .size(size)
            .drawBehind {
                val r = this.size.minDimension * 0.3f
                if (!glass) drawSoftGlow(jewel.light.opacity(0.45).color, blur = this.size.minDimension * 0.25f, dy = this.size.minDimension * 0.12f, corner = r)
                if (glass) {
                    drawRoundRect(Brush.verticalGradient(listOf(white(0.2f), white(0.07f))), cornerRadius = CornerRadius(r))
                } else {
                    drawRoundRect(
                        Brush.verticalGradient(listOf(jewel.light.mixed(jewel.top, 0.45).color, jewel.top.color, jewel.bottom.color)), cornerRadius = CornerRadius(r),
                    )
                    drawRoundRect(Brush.verticalGradient(0f to white(0.3f), 0.5f to white(0f)), cornerRadius = CornerRadius(r))
                }
                strokeBorder(Brush.verticalGradient(listOf(white(if (glass) 0.45f else 0.5f), white(0.06f))), r)
                // The glass glyph glows in the jewel's light (a text shadow on iOS): a soft radial behind it.
                if (glass) {
                    val c = Offset(this.size.width / 2, this.size.height / 2)
                    val g = this.size.minDimension * 0.22f + 6.dp.toPx()
                    drawCircle(Brush.radialGradient(listOf(jewel.light.opacity(0.5).color, jewel.light.opacity(0.0).color), center = c, radius = g), radius = g, center = c)
                }
            }
            .clearAndSetSemantics {},
        contentAlignment = Alignment.Center,
    ) {
        Icon(nwIcon(symbol), null, tint = Color.White, modifier = Modifier.size(size * 0.5f))
    }
}

/**
 * A soft tile: a faint tint of a colour with the glyph in it, for the quiet rows (a session's facts, Settled), which are
 * marked but never loud: tint 20% to 8% fill, tint 40% to 10% rim.
 */
@Composable
fun NWSoftTile(symbol: String, tint: Rgba, modifier: Modifier = Modifier, size: Dp = 30.dp) {
    Box(
        modifier
            .size(size)
            .drawBehind {
                val r = this.size.minDimension * 0.3f
                drawRoundRect(Brush.verticalGradient(listOf(tint.opacity(0.2).color, tint.opacity(0.08).color)), cornerRadius = CornerRadius(r))
                strokeBorder(Brush.verticalGradient(listOf(tint.opacity(0.4).color, tint.opacity(0.1).color)), r)
            }
            .clearAndSetSemantics {},
        contentAlignment = Alignment.Center,
    ) {
        Icon(nwIcon(symbol), null, tint = tint.color, modifier = Modifier.size(size * 0.48f))
    }
}

/**
 * The band across the top of a session's card: its project's jewel, so each session wears its own colour, lit along its
 * top edge. Top corners [radius], square below. A diagonal ramp, the jewel's radial light, a 7% gloss over the top half, a
 * white 40% lip and a hairline of the jewel's light along the bottom.
 */
fun Modifier.nwHueBand(jewel: NWJewel, radius: Dp = NW.Radius.card): Modifier = this.drawBehind {
    val r = radius.toPx()
    fun outline(inset: Float) = Path().apply {
        addRoundRect(
            androidx.compose.ui.geometry.RoundRect(
                inset, inset, size.width - inset, size.height - inset,
                topLeftCornerRadius = CornerRadius(max(0f, r - inset)), topRightCornerRadius = CornerRadius(max(0f, r - inset)),
                bottomLeftCornerRadius = CornerRadius.Zero, bottomRightCornerRadius = CornerRadius.Zero,
            ),
        )
    }
    val shape = outline(0f)
    drawPath(shape, Brush.linearGradient(listOf(jewel.top.color, jewel.bottom.color), start = Offset.Zero, end = Offset(size.width, size.height)))
    drawPath(shape, Brush.radialGradient(listOf(jewel.light.opacity(jewel.lightStrength).color, jewel.light.opacity(0.0).color), center = Offset.Zero, radius = 260.dp.toPx()))
    drawPath(shape, Brush.verticalGradient(0f to white(0.07f), 0.5f to white(0f)))
    val hair = 1.dp.toPx()
    drawPath(
        outline(hair / 2),
        Brush.verticalGradient(0f to white(0.4f), 0.4f to jewel.light.opacity(0.3).color, 1f to jewel.light.opacity(0.0).color),
        style = Stroke(hair),
    )
    drawRect(jewel.light.opacity(0.35).color, topLeft = Offset(0f, size.height - hair), size = androidx.compose.ui.geometry.Size(size.width, hair))
}

/**
 * The desk: the raised surface the work sits on, below the sky. Its top edge is where the information above (the Horizon,
 * the Runway) ends and what needs you begins: a lit lip with the mood's [light] along it, like the line where the sky
 * meets the ground. Top corners [radius] (32), the ramp #0E1322, #0A0E1A at 10%, #070A13; the mood's light a radial
 * (12%, radius 280) from the top centre; a white 13% lip fading over 70; a horizon line; a black 70% shadow, radius 26,
 * rising up 6 over what is above. Draw it behind the stream, with the shadow free to leave the bounds.
 */
fun Modifier.nwDesk(light: Rgba, radius: Dp = NW.Radius.desk): Modifier = this.drawBehind { drawDesk(light, radius) }

/** The desk drawn into this scope's whole size ([nwDesk]); wrap it in `inset(top = ...)` to draw it from a line down the scope. */
fun DrawScope.drawDesk(light: Rgba, radius: Dp = NW.Radius.desk) {
    val r = radius.toPx()
    val w = size.width
    val shape = Path().apply {
        addRoundRect(
            androidx.compose.ui.geometry.RoundRect(
                0f, 0f, w, size.height, topLeftCornerRadius = CornerRadius(r), topRightCornerRadius = CornerRadius(r),
                bottomLeftCornerRadius = CornerRadius.Zero, bottomRightCornerRadius = CornerRadius.Zero,
            ),
        )
    }
    // The shadow goes up, over the sky: a glow of the desk's own outline, clear of the desk.
    clipPath(shape, androidx.compose.ui.graphics.ClipOp.Difference) {
        drawSoftGlow(Color.Black.copy(alpha = 0.7f), blur = 26.dp.toPx(), dy = (-6).dp.toPx(), corner = r, shapeSize = androidx.compose.ui.geometry.Size(w, size.height))
    }
    drawPath(shape, Brush.verticalGradient(0f to Rgba.hex(0x0E1322).color, 0.1f to Rgba.hex(0x0A0E1A).color, 1f to Rgba.hex(0x070A13).color))
    // The mood's light, washing a little way down from the edge and gone before the wash's own edge.
    clipPath(shape) {
        drawRect(
            Brush.radialGradient(listOf(light.opacity(0.12).color, light.opacity(0.0).color), center = Offset(w / 2, 0f), radius = 280.dp.toPx()),
            size = androidx.compose.ui.geometry.Size(w, min(300.dp.toPx(), size.height)),
        )
    }
    // The lip, only along the top.
    val hair = 1.dp.toPx()
    val inner = Path().apply {
        addRoundRect(
            androidx.compose.ui.geometry.RoundRect(
                hair / 2, hair / 2, w - hair / 2, size.height + hair, topLeftCornerRadius = CornerRadius(r - hair / 2), topRightCornerRadius = CornerRadius(r - hair / 2),
                bottomLeftCornerRadius = CornerRadius.Zero, bottomRightCornerRadius = CornerRadius.Zero,
            ),
        )
    }
    drawPath(inner, Brush.verticalGradient(listOf(white(0.13f), white(0f)), startY = 0f, endY = 70.dp.toPx()), style = Stroke(hair))
    // The horizon line: brightest in the middle, gone at the corners; a soft bloom of the same under it.
    val inset = r + 8.dp.toPx()
    if (w > inset * 2) {
        val across = Brush.horizontalGradient(listOf(light.opacity(0.0).color, light.opacity(1.0).color, light.opacity(0.0).color), startX = inset, endX = w - inset)
        val cy = 0.6.dp.toPx()
        for ((h, a) in listOf(7.dp.toPx() to 0.12f, 5.dp.toPx() to 0.16f, 3.dp.toPx() to 0.22f)) {
            drawRoundRect(across, topLeft = Offset(inset, cy - h / 2 + 2.dp.toPx()), size = androidx.compose.ui.geometry.Size(w - 2 * inset, h), cornerRadius = CornerRadius(h / 2), alpha = a)
        }
        drawRoundRect(across, topLeft = Offset(inset, cy), size = androidx.compose.ui.geometry.Size(w - 2 * inset, 1.2.dp.toPx()), cornerRadius = CornerRadius(1.dp.toPx()), alpha = 0.9f)
    }
}

/**
 * The Runway's glass: an instrument lifted off the sky, floating across the desk's edge. Smoked glass lit from above,
 * standing on the mood's [light]. It holds only information, so it carries no colour of its own: the smoke ramp #182035
 * at 94% to #0B1020 at 96%, a 7% sheen, a mood-light radial from the bottom, a rim of white 26% to 7% to the light at 35%,
 * the light's glow (22%, radius 26, y 16) and a black shadow (65%, radius 14, y 10).
 */
fun Modifier.nwInstrumentGlass(light: Rgba, radius: Dp = 24.dp): Modifier = this.drawBehind {
    val r = radius.toPx()
    drawSoftGlow(light.opacity(0.22).color, blur = 26.dp.toPx(), dy = 16.dp.toPx(), corner = r, outsideOnly = true)
    drawSoftGlow(Color.Black.copy(alpha = 0.65f), blur = 14.dp.toPx(), dy = 10.dp.toPx(), corner = r, outsideOnly = true)
    drawRoundRect(Brush.verticalGradient(listOf(Rgba.hex(0x182035, 0.94).color, Rgba.hex(0x0B1020, 0.96).color)), cornerRadius = CornerRadius(r))
    drawRoundRect(Brush.verticalGradient(0f to white(0.07f), 0.45f to white(0f)), cornerRadius = CornerRadius(r))
    drawRoundRect(
        Brush.radialGradient(listOf(light.opacity(0.1).color, light.opacity(0.0).color), center = Offset(size.width / 2, size.height), radius = 220.dp.toPx()),
        cornerRadius = CornerRadius(r),
    )
    strokeBorder(Brush.verticalGradient(0f to white(0.26f), 0.4f to white(0.07f), 1f to light.opacity(0.35).color), r)
}

// MARK: - Chrome glass

/**
 * One piece of chrome that floats over the sky (the nav capsule, the Mac chip, a close button, a room's tabs). Android has
 * no Liquid Glass, so chrome is translucent smoke ([NW.Palette.chromeGlass], #04060A at 34%) over what is under it, a
 * little light from above, a lit rim (white 30% to 6%) and a soft shadow; the selected place inside it is a
 * [nwGlassBubble]. [radius] null is a capsule. (Backdrop blur on API 31+ is allowed by the spec but not drawn: it would
 * need `RenderEffect`, and the smoke reads on its own.)
 */
fun Modifier.nwChromeGlass(radius: Dp? = null, tint: Rgba = NW.Palette.chromeGlass, shadow: Boolean = true): Modifier = this.drawBehind {
    val r = radius?.toPx() ?: (size.height / 2)
    if (shadow) drawSoftGlow(Color.Black.copy(alpha = 0.35f), blur = 16.dp.toPx(), dy = 8.dp.toPx(), corner = r, outsideOnly = true)
    drawRoundRect(tint.color, cornerRadius = CornerRadius(r))
    drawRoundRect(Brush.verticalGradient(0f to white(0.07f), 0.5f to white(0f)), cornerRadius = CornerRadius(r))
    strokeBorder(Brush.verticalGradient(listOf(white(0.30f), white(0.06f))), r)
}

/**
 * The selected place in a bar of glass (the nav capsule's side, a room's lens): a brighter bubble of glass inside it, lit
 * along its top edge: white 20% to 8% fill, white 42% to 6% stroke, a black 25% shadow (radius 6, y 3). [radius] null is a capsule.
 */
fun Modifier.nwGlassBubble(radius: Dp? = null): Modifier = this.drawBehind {
    val r = radius?.toPx() ?: (size.height / 2)
    drawSoftGlow(Color.Black.copy(alpha = 0.25f), blur = 6.dp.toPx(), dy = 3.dp.toPx(), corner = r, outsideOnly = true)
    drawRoundRect(Brush.verticalGradient(listOf(white(0.2f), white(0.08f))), cornerRadius = CornerRadius(r))
    strokeBorder(Brush.verticalGradient(listOf(white(0.42f), white(0.06f))), r)
}

/** The bubble as a composable, for a place of its own (a `Box` behind the selected label). */
@Composable
fun NWGlassBubble(modifier: Modifier = Modifier, radius: Dp? = null) {
    Box(modifier.nwGlassBubble(radius))
}

// MARK: - Depth while scrolling

/**
 * Depth while scrolling: a card leaving the top of the stream recedes into the sky, a little smaller and dimmer (scale to
 * 0.94 anchored at its bottom, alpha to 0.55, in step with how far it has left), and comes forward again as it returns.
 * Only at the top edge, so nothing under the nav capsule is ever distorted; still under Reduce Motion
 * ([LocalReduceMotion]). The item's offset is read as the layer is drawn (the stream's layout info), so a scroll
 * redraws the layer and recomposes nothing. Give it the stream's [state] and the item's [key] (the one passed to `item(key = ...)`).
 */
@Composable
fun Modifier.nwRecede(state: LazyListState, key: Any): Modifier {
    if (LocalReduceMotion.current) return this
    return this.graphicsLayer {
        val info = state.layoutInfo.visibleItemsInfo.firstOrNull { it.key == key } ?: return@graphicsLayer
        val gone = (-info.offset).toFloat()
        if (gone <= 0f || info.size <= 0) return@graphicsLayer
        val p = (gone / info.size).coerceIn(0f, 1f)
        transformOrigin = TransformOrigin(0.5f, 1f)
        val s = 1f - 0.06f * p
        scaleX = s
        scaleY = s
        alpha = 1f - 0.45f * p
    }
}
