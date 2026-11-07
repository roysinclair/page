package app.page.android.ui.nw.shell

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import app.page.android.ui.nw.theme.Rgba
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.runtime.State
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.page.android.model.DawnModel
import app.page.android.model.HeaderJump
import app.page.android.model.MotionCurve
import app.page.android.model.NWDestination
import app.page.android.model.NowModel
import app.page.android.model.NowMotion
import app.page.android.model.PulseModel
import app.page.android.ui.nw.components.NWAnimated
import app.page.android.ui.nw.components.NWRollingWords
import app.page.android.ui.nw.components.rememberNowChange
import app.page.android.ui.nw.components.rememberNowClock
import app.page.android.ui.nw.components.NWDawnLight
import app.page.android.ui.nw.components.NWHorizonBand
import app.page.android.ui.nw.components.NWLivingAurora
import app.page.android.ui.nw.components.NWPulseLight
import app.page.android.ui.nw.components.NWPulseOrb
import app.page.android.ui.nw.components.NWPulseStyle
import app.page.android.ui.nw.components.NWShaders
import app.page.android.ui.nw.components.nwClockSeconds
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.LocalDaypart
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.pinned
import app.page.android.ui.nw.theme.starField
import kotlinx.coroutines.delay
import kotlin.math.max
import kotlin.math.min

/** "2 working" in the subline is a button that goes to the In flight cards. */
data class WorkingJump(val jump: String, val rest: String, val onClick: () -> Unit)

/** Caps how far the user's font size scales its content (the Horizon's fixed-height sky must not overflow at the largest sizes). */
@Composable
fun NWCappedFontScale(max: Float, content: @Composable () -> Unit) {
    val d = LocalDensity.current
    CompositionLocalProvider(LocalDensity provides Density(d.density, min(d.fontScale, max)), content = content)
}

/** Where the Horizon puts things, in dp from its own top: the pulse's centre and the band its words sit in. Final approach flies out of the one and passes behind the other. */
object HorizonGeometry {
    fun orbSize(height: Dp): Dp = min(150f, max(96f, height.value - 112f)).dp

    /** The words scale with the system font (capped at 1.3): the Horizon grows by this much so they are never cut off, and the orb keeps its size. */
    fun textRoom(fontScale: Float): Dp = ((min(fontScale, 1.3f) - 1f).coerceAtLeast(0f) * 90f).dp

    /** The pulse's centre. */
    fun pulseY(height: Dp, topInset: Dp): Dp = topInset + 38.dp + orbSize(height) / 2

    /** The headline and subline, between the orb and the Horizon's foot. */
    fun wordsTop(height: Dp, topInset: Dp): Dp = topInset + 38.dp + orbSize(height) + 2.dp
    fun wordsBottom(height: Dp, topInset: Dp, fontScale: Float = 1f): Dp = topInset + height + textRoom(fontScale) - 2.dp

    /** The battery pause's grey band, just under the orb. */
    fun bandY(height: Dp, topInset: Dp): Dp = topInset + 38.dp + orbSize(height) + 4.dp
}

/**
 * The moments the Horizon's one-shots began, on the [nwClockSeconds] base. Plain fields, not state: a change is
 * noticed and its start recorded in the same composition that draws its first frame (a state write there would draw
 * one frame of the new colour first). The clock that is running anyway redraws it.
 */
private class HorizonClocks(var mode: PulseModel.Mode, var dusk: Boolean, var palette: AuroraPalette) {
    var exhaleAt: Double? = null
    var duskAt: Double? = null
    var dawnAt: Double? = null
    /** The palette the sky was on before the dusk fell. */
    var fromPalette: AuroraPalette? = null
}

/**
 * The Horizon: the top of the Now screen. Aurora behind, the pulse in the middle, the one honest sentence below it. It
 * fades into the page, so it has no edge of its own to look cut off. (iOS NWHorizon.) A horizontal drag on it switches
 * between Now and Lanes ([onSwipe]).
 *
 * It plays three of the signature motions on one clock: the pulse itself; the exhale when the last waiting item clears
 * (the pulse turns amber to teal over 800 ms and the aurora settles with it); and dusk and dawn (the aurora fades to
 * dusk at the battery cutoff and a grey band holds under the pulse; when power returns a gold dawn rises from that
 * band). Each change is noticed here as it happens; the render harness pins a moment with [LocalMotionPin]. Remove
 * animations: every change is a cut.
 */
@Composable
fun NWHorizon(
    palette: AuroraPalette,
    pulse: NWPulseStyle.Style,
    headline: String,
    subline: String,
    modifier: Modifier = Modifier,
    /** A third, quieter line ("Page is keeping watch. Go to sleep."). */
    footnote: String? = null,
    height: Dp = 330.dp,
    /** Space kept clear at the top for the status bar and the Mac chip. */
    topInset: Dp = 0.dp,
    /** The counts behind the pulse (its breath and rings); the style's default when null. */
    model: PulseModel? = null,
    workingJump: WorkingJump? = null,
    /** The pulse orb opens the Tower. */
    onPulseTap: (() -> Unit)? = null,
    onSwipe: ((NWDestination) -> Unit)? = null,
    current: NWDestination = NWDestination.NOW,
) {
    val reduce = LocalReduceMotion.current
    val pin = LocalMotionPin.current
    // The time of day: the stars, and the sky the exhale and the dusk start from.
    val daypart = LocalDaypart.current
    val orbSize = HorizonGeometry.orbSize(height)
    val pulseModel = model ?: pulse.defaultModel
    val isDusk = pulse == NWPulseStyle.Style.DUSK
    val hollow = pulse == NWPulseStyle.Style.HOLLOW_SLATE || pulse == NWPulseStyle.Style.HOLLOW_AMBER
    val drag = remember { mutableFloatStateOf(0f) }
    val swipe by rememberUpdatedState(onSwipe)
    val here by rememberUpdatedState(current)
    val spoken = "$headline. $subline"

    // Notice the changes the motions play on, as they happen.
    val clocks = remember { HorizonClocks(pulseModel.mode, isDusk, palette) }
    var ended by remember { mutableIntStateOf(0) }
    if (clocks.mode != pulseModel.mode) {
        if (!reduce && PulseModel.exhales(clocks.mode, pulseModel.mode)) clocks.exhaleAt = nwClockSeconds()
        clocks.mode = pulseModel.mode
    }
    if (clocks.dusk != isDusk) {
        if (!reduce) {
            val now = nwClockSeconds()
            if (isDusk) { clocks.duskAt = now; clocks.dawnAt = null } else { clocks.dawnAt = now; clocks.duskAt = null }
        }
        clocks.dusk = isDusk
    }
    if (clocks.palette != palette) {
        if (clocks.palette != AuroraPalette.dusk) clocks.fromPalette = clocks.palette
        clocks.palette = palette
    }
    // A one-shot ends: back to the still or steady frame, and its clock stops.
    val exhaleAt = clocks.exhaleAt
    val duskAt = clocks.duskAt
    val dawnAt = clocks.dawnAt
    LaunchedEffect(exhaleAt) {
        val s = exhaleAt ?: return@LaunchedEffect
        delay(((s + PulseModel.exhaleDuration - nwClockSeconds()) * 1000).toLong().coerceAtLeast(0))
        if (clocks.exhaleAt == s) { clocks.exhaleAt = null; ended++ }
    }
    LaunchedEffect(duskAt) {
        // Once the dusk has fallen the night is drawn settled, and its clock stops.
        val s = duskAt ?: return@LaunchedEffect
        delay(((s + DawnModel.duskDuration + 0.1 - nwClockSeconds()) * 1000).toLong().coerceAtLeast(0))
        if (clocks.duskAt == s) { clocks.duskAt = null; ended++ }
    }
    LaunchedEffect(dawnAt) {
        val s = dawnAt ?: return@LaunchedEffect
        delay(((s + DawnModel.sweepDuration + DawnModel.settle - nwClockSeconds()) * 1000).toLong().coerceAtLeast(0))
        if (clocks.dawnAt == s) { clocks.dawnAt = null; ended++ }
    }
    @Suppress("UNUSED_EXPRESSION") ended

    /** Seconds into a motion: pinned by the harness, or since it began here; null when it is not playing. */
    fun elapsed(kind: NWMotionPin.Kind, start: Double?): Double? = pin.pinned(kind) ?: start?.let { max(0.0, nwClockSeconds() - it) }

    // The words: a count that moves rolls ("2 need you" → "3 need you"); new wording cross-fades as it rises.
    val headlineChange = rememberNowChange(headline) { it.headline }
    val sublineChange = rememberNowChange(subline)
    val wordsClock = rememberNowClock(listOfNotNull(headlineChange.at, sublineChange.at).maxOrNull()?.plus(NowMotion.wordsLast(reduce)))

    val bandY = HorizonGeometry.bandY(height, topInset)
    val textRoom = HorizonGeometry.textRoom(LocalDensity.current.fontScale)
    Box(
        modifier
            .fillMaxWidth()
            .height(height + topInset + textRoom)
            .clipToBounds()
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragEnd = {
                        val to = NWDestination.afterDrag(here, drag.floatValue.toDouble(), 0.0)
                        if (to != here) swipe?.invoke(to)
                        drag.floatValue = 0f
                    },
                    onDragCancel = { drag.floatValue = 0f },
                    onHorizontalDrag = { _, dx -> drag.floatValue += dx },
                )
            }
            .semantics(mergeDescendants = true) {
                heading()
                contentDescription = spoken
                if (workingJump != null) customActions = listOf(CustomAccessibilityAction(HeaderJump.accessibilityName) { workingJump.onClick(); true })
            },
    ) {
        // A pause that has settled is a still night: no clock.
        NWAnimated(active = !(isDusk && duskAt == null) && pin.pinned(NWMotionPin.Kind.DUSK) == null) { t ->
            var pal = palette
            var stars = daypart.stars
            var band = 0.0
            var dawn: DawnModel.Dawn? = null
            elapsed(NWMotionPin.Kind.EXHALE, exhaleAt)?.let { e ->
                val x = PulseModel.exhale(e)
                // From the hour's needs-you sky, so the sky never snaps for a frame.
                if (!x.finished) pal = AuroraPalette.of(NowModel.Mood.NEEDS_YOU, daypart).mixedPerceptual(palette, x.aurora)
            }
            if (isDusk) {
                // A pause already under way when the Horizon appeared is drawn settled: through the purple dusk to a
                // near-black night, the stars all but gone.
                val d = DawnModel.dusk(elapsed(NWMotionPin.Kind.DUSK, duskAt) ?: DawnModel.duskDuration)
                pal = (clocks.fromPalette ?: AuroraPalette.of(NowModel.Mood.WORKING, daypart)).towardNight(d.aurora)
                stars = starField(d.aurora, from = daypart.stars)
                band = d.band
            } else {
                elapsed(NWMotionPin.Kind.DAWN, dawnAt)?.let { w ->
                    val d = DawnModel.dawn(w, null)
                    if (!d.finished) {
                        // The night, through the gold of the sunrise, into the live palette. The sweep carries the
                        // gold; the sky behind it only warms a little.
                        val sunrise = AuroraPalette.night.mixed(AuroraPalette.dawn, 0.35 * d.warmth)
                        pal = sunrise.mixed(palette, 1 - d.aurora)
                        stars = starField(d.aurora, from = daypart.stars)
                        band = d.band
                        dawn = d
                    }
                }
            }
            Box(Modifier.fillMaxSize()) {
                NWLivingAurora(pal, t, Modifier.fillMaxSize(), stars = stars)
                dawn?.let { d -> NWDawnLight(d.sweep, d.warmth, Modifier.fillMaxWidth().height(bandY)) }
                // Fade into the page.
                Box(
                    Modifier.fillMaxSize().background(
                        Brush.verticalGradient(
                            0f to androidx.compose.ui.graphics.Color.Transparent,
                            0.35f to NW.Palette.backgroundDeep.opacity(0.0).color,
                            0.88f to NW.Palette.backgroundDeep.opacity(0.85).color,
                            1f to NW.Palette.backgroundDeep.color,
                        ),
                    ),
                )
                // The watch's own scene, in the sky's colours of the moment (so it falls to dusk and rises to dawn with them).
                NWNightScene(pal, HorizonGeometry.pulseY(height, topInset), Modifier.fillMaxSize())
                // Over the fade, so the line holds at full strength (it is all a paused sky shows).
                NWHorizonBand(band, Modifier.offset(y = bandY - 6.dp))
            }
        }
        Column(Modifier.fillMaxSize().padding(horizontal = NW.Space.xl), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Spacer(Modifier.height(topInset + 38.dp))
            // The orb shrinks with a short Horizon so the headline never rides over it.
            val exhaling = exhaleAt != null || pin.pinned(NWMotionPin.Kind.EXHALE) != null
            NWAnimated(fps = if (exhaling) 30.0 else pulseModel.framesPerSecond.takeIf { it > 0 } ?: 20.0, active = !hollow && (pulseModel.isAnimated || exhaleAt != null)) { t ->
                // The exhale's elapsed seconds while it plays (a pinned frame is drawn even at its end).
                val e = elapsed(NWMotionPin.Kind.EXHALE, exhaleAt)?.takeIf { !(PulseModel.exhale(it).finished && pin.pinned(NWMotionPin.Kind.EXHALE) == null) }
                Box(
                    Modifier.size(orbSize).then(if (onPulseTap != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open the Tower", onClick = onPulseTap) else Modifier)
                        .clearAndSetSemantics {},
                    contentAlignment = Alignment.Center,
                ) {
                    if (NWShaders.available && !hollow && !reduce) {
                        NWPulseLight(
                            NWPulseStyle.color(pulse, pulseModel, e), (pulseModel.ripples(t) + farewell(e)).take(4), glow(pulseModel, e, t), t,
                            // Required, so the light reaches past the orb's box (centred over it) instead of being clamped to it.
                            Modifier.requiredSize(orbSize * 1.3f),
                        )
                        NWPulseOrb(pulse, Modifier.size(orbSize), model = pulseModel, exhale = e, halo = false, time = t)
                    } else {
                        NWPulseOrb(pulse, Modifier.size(orbSize), model = pulseModel, exhale = e, time = t)
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            NWCappedFontScale(1.3f) {
                NWRollingWords(AnnotatedString(headline), headlineChange, wordsClock, NW.Typo.hero, NW.Palette.textPrimary.color, textAlign = TextAlign.Center, maxLines = 2)
            }
            NWCappedFontScale(1.3f) { Subline(subline, workingJump, sublineChange, wordsClock) }
            if (footnote != null) {
                Text(footnote, style = NW.Typo.subline, color = NW.Palette.textTertiary.color, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 2.dp, bottom = 14.dp))
            } else {
                Spacer(Modifier.height(14.dp))
            }
        }
    }
}

/** The Horizon's second line. With working sessions on screen its count is a button: it scrolls to the In flight cards. Its count rolls as it changes. */
@Composable
private fun Subline(subline: String, jump: WorkingJump?, change: NowMotion.Change<String>, clock: State<Double>) {
    if (jump != null) {
        Row(horizontalArrangement = Arrangement.Center, modifier = Modifier.fillMaxWidth()) {
            NWRollingWords(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = NW.Palette.teal.color, textDecoration = TextDecoration.Underline)) { append(jump.jump) }
                    withStyle(SpanStyle(color = NW.Palette.textSecondary.color)) { append(jump.rest) }
                },
                change, clock, NW.Typo.subline, NW.Palette.textSecondary.color, textAlign = TextAlign.Center, maxLines = 2,
                modifier = Modifier.heightIn(min = 44.dp).clickable(role = Role.Button, onClickLabel = HeaderJump.accessibilityName, onClick = jump.onClick),
            )
        }
    } else {
        NWRollingWords(AnnotatedString(subline), change, clock, NW.Typo.subline, NW.Palette.textSecondary.color, textAlign = TextAlign.Center, maxLines = 2)
    }
}

/** The exhale lets one last ring go as the pulse turns teal. */
private fun farewell(exhale: Double?): List<PulseModel.Ripple> {
    val e = exhale ?: return emptyList()
    if (e >= PulseModel.exhaleDuration) return emptyList()
    val p = MotionCurve.easeOut(e / PulseModel.exhaleDuration)
    return listOf(PulseModel.Ripple(p, 1 - p))
}

/** The light behind the glyph: dim at dusk and when quiet, breathing while agents work, swelling once on the exhale. */
private fun glow(m: PulseModel, exhale: Double?, t: Double): Double {
    val swell = exhale?.let { PulseModel.exhale(it).swell } ?: 0.0
    return when (m.mode) {
        PulseModel.Mode.DUSK -> 0.35
        PulseModel.Mode.QUIET -> 0.7 + 0.5 * swell
        PulseModel.Mode.WORKING -> 0.85 + 0.15 * m.breath(t) + 0.5 * swell
        PulseModel.Mode.WAITING -> 1.0
    }
}

/**
 * The Night Watch scene under the aurora (iOS `NWNightScene`): two ranges of mountains, the far one hazed and rimmed with the
 * sky's light, the near one dark, their peaks to the sides so the pulse hangs over the valley between them; and a still lake
 * below that mirrors the near range, with a thread of light along the waterline. Drawn from the sky's own colours, so it follows
 * the mood and the hour; it holds no words. Each range is ONE path: down the left edge, along the crest, down the right edge.
 * No blur (it redraws with the aurora): the far crest is three strokes of different widths. Still under Reduce Motion with the sky.
 */
@Composable
fun NWNightScene(palette: AuroraPalette, orbY: Dp, modifier: Modifier = Modifier) {
    Canvas(modifier.clearAndSetSemantics {}) {
        val w = size.width
        val h = size.height
        val d = density
        // The land takes the top of the sky, darkened: cool at night and by day, warm when something needs you.
        val light = palette.c1
        val deep = palette.skyTop.mixed(NW.Palette.backgroundDeep, 0.55)
        val glow = max(0.45, palette.intensity).toFloat()
        val room = max(60f * d, h * 0.82f - orbY.toPx())
        val water = orbY.toPx() + room
        val farAmp = min(64f * d, room * 0.55f)
        val nearAmp = min(40f * d, room * 0.32f)

        fun range(peaks: List<Triple<Double, Double, Double>>, base: Float, amp: Float, grain: Double): List<Offset> =
            (0..96).map { i ->
                val u = i / 96.0
                var y = peaks.sumOf { (c, wd, ht) -> ht * exp(-((u - c) / wd).pow(2)) }
                y = min(1.1, y) + 0.035 * sin(u * 41 + grain) + 0.02 * sin(u * 97 + grain * 2)
                Offset(w * u.toFloat(), base - amp * y.toFloat())
            }

        /** One subpath: down the left edge, along the crest, down the right edge. */
        fun land(top: List<Offset>, down: Float): Path = Path().apply {
            moveTo(0f, down)
            for (p in top) lineTo(p.x, p.y)
            lineTo(w, down)
            close()
        }

        fun crest(pts: List<Offset>): Path = Path().apply {
            moveTo(pts[0].x, pts[0].y)
            for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
        }

        val farTop = range(FAR, water - 6f * d, farAmp, 1.3)
        val nearTop = range(NEAR, water + 2f * d, nearAmp, 4.1)
        val nearColour = deep.mixed(Rgba(0.0, 0.0, 0.0), 0.5)

        // Far range: hazed by the aurora, lighter at the crest, its rim catching the sky's light.
        drawPath(
            land(farTop, water + d),
            Brush.verticalGradient(listOf(deep.mixed(light, 0.2).color, deep.mixed(light, 0.05).color), startY = water - farAmp, endY = water),
        )
        // The rim: a wide faint stroke under a fine bright one (no blur: this redraws with the aurora).
        val farCrest = crest(farTop)
        drawPath(farCrest, light.opacity(0.12 * glow).color, style = Stroke(5f * d))
        drawPath(farCrest, light.opacity(0.16 * glow).color, style = Stroke(2.4f * d))
        drawPath(farCrest, light.opacity(0.26 * glow).color, style = Stroke(0.8f * d))
        // Near range: dark, in front.
        drawPath(land(nearTop, water + d), nearColour.color)
        drawPath(crest(nearTop), light.opacity(0.1 * glow).color, style = Stroke(0.8f * d))

        // The lake, holding a little of the sky's colour; into the page's own colour at the Horizon's foot, so a bright daytime sky leaves no seam.
        val lakeH = max(0f, h - water)
        drawRect(
            Brush.verticalGradient(listOf(deep.mixed(light, 0.12).color, NW.Palette.backgroundDeep.color), startY = water, endY = h),
            topLeft = Offset(0f, water), size = Size(w, lakeH),
        )
        // The near range, mirrored in the still water and fading with depth.
        clipRect(0f, water, w, h) {
            val mirrored = nearTop.map { Offset(it.x, water + (water - it.y) * 0.8f) }
            drawPath(
                land(mirrored, water),
                Brush.verticalGradient(listOf(nearColour.opacity(0.85).color, nearColour.opacity(0.0).color), startY = water, endY = water + nearAmp * 0.8f),
            )
        }
        // The waterline: a thread of light where the sky meets the lake.
        drawRect(
            Brush.horizontalGradient(listOf(light.opacity(0.0).color, light.opacity(0.38 * glow).color, light.opacity(0.0).color), startX = w * 0.1f, endX = w * 0.9f),
            topLeft = Offset(0f, water - 0.5f * d), size = Size(w, d),
        )
    }
}

/** A range as a few smooth peaks: (centre 0...1, width, height 0...1). */
private val FAR = listOf(
    Triple(0.04, 0.09, 0.62), Triple(0.2, 0.11, 1.0), Triple(0.36, 0.07, 0.6), Triple(0.5, 0.1, 0.34),
    Triple(0.66, 0.08, 0.66), Triple(0.82, 0.12, 0.95), Triple(0.98, 0.08, 0.7),
)
private val NEAR = listOf(
    Triple(0.0, 0.16, 0.95), Triple(0.18, 0.08, 0.55), Triple(0.34, 0.1, 0.3),
    Triple(0.72, 0.09, 0.45), Triple(0.9, 0.12, 0.85), Triple(1.04, 0.1, 0.7),
)
