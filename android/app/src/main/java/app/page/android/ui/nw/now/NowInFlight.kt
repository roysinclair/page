@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package app.page.android.ui.nw.now

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.sp
import app.page.android.ui.nw.components.NWCountBadge
import app.page.android.ui.nw.components.NWGlassEdgeLight
import app.page.android.ui.nw.components.NWIconTile
import app.page.android.ui.nw.components.NWJewel
import app.page.android.ui.nw.components.NWSoftTile
import app.page.android.ui.nw.components.nwGlass
import app.page.android.ui.nw.components.nwHueBand
import app.page.android.ui.nw.components.nwJewelSurface
import app.page.android.ui.nw.components.strokeBorder
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.structuralEqualityPolicy
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.model.BudgetCopy
import app.page.android.model.BudgetMeter
import app.page.android.model.FlightHealth
import app.page.android.ui.nw.budget.NWBudgetBar
import androidx.compose.foundation.layout.widthIn
import app.page.android.model.FlightLineStatus
import app.page.android.model.FlightWorkflowLine
import app.page.android.model.InFlightRow
import app.page.android.model.InFlightSection
import app.page.android.model.MotionCurve
import app.page.android.model.NowMotion
import app.page.android.model.NowTipTarget
import app.page.android.model.NWTip
import app.page.android.model.RoomEntry
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWRollingWords
import app.page.android.ui.nw.components.NWTipCallout
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.components.rememberNowChange
import app.page.android.ui.nw.components.rememberNowClock
import app.page.android.ui.nw.theme.LocalAnimationsPaused
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import kotlin.math.roundToInt

// The In flight section of Now. Every card hands its actions to closures; the container routes them (open the
// room, retire a tip). Nothing here types anything: Steer only opens the room with the composer focused.
// (iOS NWInFlight.swift.)

/**
 * "IN FLIGHT 3": a side-scroll strip that summarises every working session, then one full card per session, as
 * big as a Review card, so the whole picture of the work is on one screen. Tapping a card opens its room on
 * Story; "Open" shows its terminal and "Steer" opens the composer. Touching and holding offers the same, and Stop
 * (which opens the room where the 10 s hold lives). In motion ([NowMotion]) on one clock: cards and tiles rise in and
 * fold away, arcs and bars sweep, spring and close, and a finished workflow is said once, politely. [epoch] changes on
 * a reconnect, whose first snapshot is never news.
 */
@Composable
fun NWInFlightSection(
    section: InFlightSection,
    modifier: Modifier = Modifier,
    tip: NowTipTarget? = null,
    biometry: String = "fingerprint",
    epoch: Any? = null,
    onOpen: (String, RoomEntry) -> Unit = { _, _ -> },
    onToggle: () -> Unit = {},
    onHeader: () -> Unit = {},
    onDismissTip: (NWTip) -> Unit = {},
    /** "Session budget..." in a card's menu (and TalkBack's actions), with the session's id; null where the Mac doesn't do budgets. */
    onBudget: ((String) -> Unit)? = null,
) {
    val reduce = LocalReduceMotion.current
    val track = rememberFlightTrack(section, epoch)
    val clock = rememberFlightClock(track, reduce)
    val motion = remember(track, clock, reduce) { FlightMotion(track, clock, reduce) }
    // Under the harness's script the section is drawn as it was at the pinned moment.
    val shown = track.section
    // Only the set of cards (a leaving one stays while it folds) and the announcement recompose; the motion is drawn.
    val cards by remember(track, reduce) { derivedStateOf(structuralEqualityPolicy()) { NowMotion.cards(track, clock.value, reduce) } }
    val said by remember(track) { derivedStateOf { NowMotion.said(track, clock.value) } }
    // Under the room (or a sheet) the room's Workflows lens says it itself; an ending heard there is not said again
    // here when the room closes.
    val covered = LocalAnimationsPaused.current
    val hushed = remember { object { var at: Double? = null } }
    if (covered) hushed.at = track.saidAt
    val spoken = said?.takeIf { !covered && track.saidAt != hushed.at }
    Box(modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // "In flight 2": the section's glyph in a tile, the title in words, the count in a badge, and the way to Lanes.
            Row(
                Modifier.fillMaxWidth().padding(top = 20.dp).heightIn(min = 44.dp).clickable(role = Role.Button, onClickLabel = "Goes to Lanes", onClick = onHeader).semantics(mergeDescendants = true) {
                    heading(); contentDescription = "In flight, ${shown.total}"
                },
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                NWIconTile("airplane", NWJewel.teal, size = 30.dp)
                Text("In flight", style = NW.Typo.section, color = NW.Palette.textPrimary.color)
                RollingBadge(shown.total, NW.Palette.teal, reduce)
                Box(Modifier.weight(1f))
                Row(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Lanes", style = NW.Typo.captionStrong, color = NW.Palette.textSecondary.color)
                    Icon(Icons.Outlined.ChevronRight, null, tint = NW.Palette.textSecondary.color, modifier = Modifier.size(14.dp))
                }
            }
            if (shown.showsStrip) NWInFlightStrip(motion, Modifier.layoutFullBleed(), onOpen = { onOpen(it, RoomEntry.STORY) })
            for ((row, leaving) in cards) key(row.id) {
                val m = if (leaving != null) Modifier.flightLeave(motion, leaving).clearAndSetSemantics {} else Modifier.flightRise(motion, track.cardsIn[row.id])
                NWInFlightCardView(row, m, motion, onOpen = { onOpen(row.id, it) }, onBudget = onBudget?.let { b -> { b(row.id) } })
                if (leaving == null && tip != null && tip.anchorId == row.id && tip.tip == NWTip.IN_FLIGHT) NWTipCallout(tip.tip.text(biometry), symbol = tip.tip.symbol, onDismiss = { onDismissTip(tip.tip) })
            }
            if (shown.isCapped) {
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(CircleShape)
                        .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.10f), Color.White.copy(alpha = 0.04f))))
                        .border(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.18f), Color.White.copy(alpha = 0.03f))), CircleShape)
                        .clickable(role = Role.Button, onClickLabel = if (shown.isExpanded) "Shows only the first few" else "Shows every working session", onClick = onToggle),
                    contentAlignment = Alignment.Center,
                ) { Text(if (shown.isExpanded) "Show fewer" else shown.showAllLabel, style = NW.Typo.captionStrong, color = NW.Palette.teal.color) }
            }
        }
        // A workflow that has just finished (or failed, or stopped), said once, politely: "page: Docs sweep finished". At
        // the section's top, where it is on screen whenever the section is.
        Box(Modifier.size(1.dp).semantics { liveRegion = LiveRegionMode.Polite; spoken?.let { contentDescription = it } })
    }
}

/** The strip runs under the stream's gutters, edge to edge. */
private fun Modifier.layoutFullBleed(): Modifier = this.then(
    Modifier.layout { measurable, constraints ->
        val extra = 32.dp.roundToPx()
        val p = measurable.measure(constraints.copy(maxWidth = constraints.maxWidth + extra, minWidth = constraints.maxWidth + extra))
        layout(constraints.maxWidth, p.height) { p.place(-extra / 2, 0) }
    },
)

/** The side-scroll summary: one small tile per working session (the ribbon), with what it is doing and for how long. A tap opens that session. */
@Composable
fun NWInFlightStrip(motion: FlightMotion, modifier: Modifier = Modifier, onOpen: (String) -> Unit = {}) {
    val track = motion.track
    val tiles by remember(track, motion.reduce) { derivedStateOf(structuralEqualityPolicy()) { NowMotion.stripTiles(track, motion.now, motion.reduce) } }
    // The doors stand on their own glow: the scroll's cross-axis clip allows 30 dp, and the 4 dp here keeps their tops from being cut.
    Row(modifier.horizontalScroll(rememberScrollState()).padding(horizontal = NW.Space.gutter, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        tiles.forEachIndexed { i, (r, leaving) ->
            key(r.id) {
                val m = if (leaving != null) Modifier.flightLeave(motion, leaving, across = true).clearAndSetSemantics {} else Modifier.flightRise(motion, track.tilesIn[r.id])
                StripTile(r, i, motion, m) { onOpen(r.id) }
            }
        }
    }
}

/**
 * A door: the session's project jewel (lift 0.7), crossing to amber as it turns stuck, with its name, what it is doing, its
 * progress or health in a black 28% pill and the time, all in white. Its emblem is the session's own star with a flare (two fine
 * rays and a radial glow) at the bottom trailing corner, running off the edge, clipped to the door.
 */
@Composable
private fun StripTile(r: InFlightRow, index: Int, motion: FlightMotion, modifier: Modifier, onClick: () -> Unit) {
    val time = r.card.turn?.removePrefix("working ") ?: r.age?.let { "$it ago" }
    val track = motion.track
    // The one line the tile shows: the first running, or a ghost while it closes.
    val flow by remember(track, r.id, motion.reduce) { derivedStateOf { NowMotion.tileLine(track, r.id, motion.now, motion.reduce) } }
    val attention = r.card.health.needsAttention
    val amber by remember(track, r.id, motion.reduce) { derivedStateOf { stepped(NowMotion.rowAmber(track, r, motion.now, motion.reduce)) } }
    val jewel = NWJewel.of(r.hue).crossing(NWJewel.amber, amber)
    val glowColour = jewel.light
    val shape = RoundedCornerShape(NW.Radius.row)
    val white = Color.White
    Box(
        modifier.width(212.dp).height(96.dp).nwJewelSurface(jewel, NW.Radius.row, lift = 0.7).clip(shape)
            .clickable(role = Role.Button, onClickLabel = "Opens the session", onClick = onClick).semantics(mergeDescendants = true) { contentDescription = r.spoken },
    ) {
        // Its emblem: the session's own star, large, glowing, and running off the corner.
        Box(Modifier.matchParentSize().clipToBounds(), contentAlignment = Alignment.BottomEnd) {
            Box(
                Modifier.requiredSize(104.dp).offset(30.dp, 30.dp).drawBehind {
                    val c = center
                    drawCircle(Brush.radialGradient(listOf(glowColour.opacity(0.55).color, glowColour.opacity(0.0).color), center = c, radius = 52.dp.toPx()), 52.dp.toPx(), c)
                    // The flare: two fine rays crossing at the star.
                    val ray = Brush.horizontalGradient(listOf(Color.Transparent, white.copy(alpha = 0.85f), Color.Transparent), startX = c.x - 42.dp.toPx(), endX = c.x + 42.dp.toPx())
                    val th = 1.6.dp.toPx()
                    drawRoundRect(ray, Offset(c.x - 42.dp.toPx(), c.y - th / 2), androidx.compose.ui.geometry.Size(84.dp.toPx(), th), androidx.compose.ui.geometry.CornerRadius(th / 2))
                    rotate(90f, c) {
                        drawRoundRect(ray, Offset(c.x - 42.dp.toPx(), c.y - th / 2), androidx.compose.ui.geometry.Size(84.dp.toPx(), th), androidx.compose.ui.geometry.CornerRadius(th / 2))
                    }
                },
                contentAlignment = Alignment.Center,
            ) {
                FlightStar(r.seed, glowColour, NowMotion.live(r, motion.reduce), motion.clock, size = 34.dp, index = index)
                flow?.let { l -> if (l.fraction != null) key(l.key) { FlightRing(motion, r, l, index, size = 52.dp, lineWidth = 3.dp) } }
            }
        }
        Column(Modifier.fillMaxSize().padding(start = 14.dp, top = 12.dp, bottom = 12.dp, end = 50.dp)) {
            Text(r.project, style = NW.Typo.name, color = white, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(r.card.now, style = NW.Typo.metaSmall, color = white.copy(alpha = 0.9f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Box(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                val label = r.card.health.label
                val l = flow
                val word = l?.let { if (motion.reduce) null else NowMotion.endedWord(it.status) }
                val pill = Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.28f)).padding(horizontal = 7.dp, vertical = 2.dp)
                if (attention && label != null) Text(label, style = NW.Typo.captionStrong, color = white, maxLines = 1, modifier = pill)
                else if (l != null && (word != null || l.progress != null)) {
                    RollingText(word ?: l.progress!!.replace(" agents", ""), NW.Typo.captionStrong.copy(fontFeatureSettings = "tnum"), white, motion.reduce, pill)
                }
                if (time != null) Text(time, style = NW.Typo.caption.copy(fontFeatureSettings = "tnum"), color = white.copy(alpha = 0.85f), maxLines = 1)
            }
        }
    }
}

/** A jewel part-way to [other] ([t] 0 is this one): a door turning stuck crosses to amber as one surface, so its glow is never cut by a layer. */
private fun NWJewel.crossing(other: NWJewel, t: Double): NWJewel =
    if (t <= 0.0) this else if (t >= 1.0) other
    else NWJewel(top.mixed(other.top, t), bottom.mixed(other.bottom, t), light.mixed(other.light, t), lightStrength + (other.lightStrength - lightStrength) * t)

/** The section's count in its badge, rolling to a new number as the old slides up and out (a cross-fade under Reduce Motion). */
@Composable
private fun RollingBadge(count: Int, color: Rgba, reduce: Boolean) {
    AnimatedContent(
        count,
        transitionSpec = {
            if (reduce) fadeIn(tween(200)) togetherWith fadeOut(tween(200))
            else (slideInVertically(tween(350)) { it } + fadeIn(tween(350))) togetherWith (slideOutVertically(tween(250)) { -it } + fadeOut(tween(250)))
        },
        label = "badge",
    ) { n -> NWCountBadge(n, color) }
}

/** A cross-fade's share in twentieths, so a tint fading recomposes a few times and never while it holds. */
private fun stepped(x: Double): Double = kotlin.math.round(x.coerceIn(0.0, 1.0) * 20) / 20

/**
 * One working session, as big as a Review card: who and where, what it is doing now and just did, how long, its
 * workflows, how it is doing, and two buttons in words. The body is a button that opens the room on Story; the
 * buttons sit under it, each at least 48 dp. Its star breathes while it works normally, its NOW step rolls on, its
 * workflow bars move, and its health dot breathes or, when it is stuck, ripples amber.
 */
@Composable
fun NWInFlightCardView(row: InFlightRow, modifier: Modifier = Modifier, motion: FlightMotion, onOpen: (RoomEntry) -> Unit = {}, onBudget: (() -> Unit)? = null) {
    val card = row.card
    val track = motion.track
    val reduce = motion.reduce
    // The health tint cross-fades (0.5 s) when it turns.
    val amber by remember(track, row.id, reduce) { derivedStateOf { stepped(NowMotion.rowAmber(track, row, motion.now, reduce)) } }
    val lines by remember(track, row.id, reduce) { derivedStateOf(structuralEqualityPolicy()) { NowMotion.drawn(track, row.id, motion.now, reduce) } }
    var menu by remember { mutableStateOf(false) }
    val jewel = NWJewel.of(row.hue).crossing(NWJewel.amber, amber)
    val glow = app.page.android.ui.nw.theme.LocalCardGlow.current
    // The body carries its project's colour, faintly (surfaceRaised mixed 30% toward the project's deep colour), so band and body read as one card.
    val body = NW.Palette.surfaceRaised.mixed(NWJewel.of(row.hue).bottom, 0.3)
    Box(
        modifier.nwRecedeInStream().fillMaxWidth()
            .semantics {
                customActions = buildList {
                    add(CustomAccessibilityAction("Open") { onOpen(RoomEntry.SCREEN); true })
                    add(CustomAccessibilityAction("Steer") { onOpen(RoomEntry.TYPE); true })
                    if (row.canStop) add(CustomAccessibilityAction("Stop") { onOpen(RoomEntry.STOP); true })
                    if (onBudget != null) add(CustomAccessibilityAction("Session budget") { onBudget(); true })
                }
            }
            .nwGlass(NW.Radius.card, fill = body, tint = if (amber > 0.01) NW.Palette.amber.opacity(amber) else null, glow = glow),
    ) {
        Column {
            Box {
                Column(
                    Modifier.fillMaxWidth().combinedClickable(role = Role.Button, onClickLabel = "Opens the session", onLongClickLabel = if (onBudget != null) "Open, Steer, Session budget or Stop" else "Open, Steer or Stop", onLongClick = { menu = true }, onClick = { onOpen(RoomEntry.STORY) })
                        .semantics(mergeDescendants = true) { contentDescription = row.spoken },
                ) {
                    // The band: the star in a glass tile, the project and where it runs, on its project's jewel (ember once it is stuck), bled to the card's edges.
                    Row(
                        Modifier.fillMaxWidth().nwHueBand(jewel).padding(start = NW.Space.lg, end = NW.Space.lg, top = NW.Space.lg, bottom = 14.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            Modifier.size(44.dp).drawBehind {
                                val r = 13.dp.toPx()
                                drawRoundRect(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.18f), Color.White.copy(alpha = 0.05f))), cornerRadius = androidx.compose.ui.geometry.CornerRadius(r))
                                strokeBorder(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.4f), Color.White.copy(alpha = 0.06f))), r)
                            },
                            contentAlignment = Alignment.Center,
                        ) { FlightStar(row.seed, jewel.light, NowMotion.live(row, reduce), motion.clock, size = 32.dp) }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(row.project, style = NW.Typo.nameLarge, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(listOfNotNull(row.character, row.route ?: row.host, card.model).joinToString(" · "), style = NW.Typo.caption, color = Color.White.copy(alpha = 0.88f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        val h = card.health.label
                        if (card.health.needsAttention && h != null) Text(
                            h.uppercase(), style = NW.Typo.label, color = Color.White, maxLines = 1,
                            modifier = Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.28f)).padding(horizontal = 8.dp, vertical = 4.dp),
                        )
                    }
                    // The facts lead with a tile that says what each is, so no label stands over them.
                    Column(Modifier.padding(start = NW.Space.lg, end = NW.Space.lg, top = 14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Fact("NOW") { NowSteps(row, motion) }
                        card.timeText?.let { t -> Fact("TIME") { TimeText(t) } }
                        // BUDGET: a mini bar and "18% of 25% this week", amber from the warning (Designs/budget-caps.md).
                        row.budget?.let { b -> Fact("BUDGET", tint = if (b.meter.tone == BudgetMeter.Tone.WARM) NW.Palette.amber else NW.Palette.teal) { BudgetFact(b.meter) } }
                        if (lines.isNotEmpty()) {
                            // With only a ghost left, the whole fact folds away with it.
                            val last = lines.singleOrNull()?.takeIf { it.status != FlightLineStatus.RUNNING }
                            Box(if (last != null) Modifier.flightFold(motion, row, last) else Modifier) {
                                Fact("WORKFLOWS") {
                                    Column {
                                        WorkflowHeading(card.workflowHeading, reduce)
                                        // Each line's gap above it folds away with it (as on iOS), so nothing jumps when a ghost goes.
                                        lines.forEachIndexed { i, w ->
                                            key(w.key) { WorkflowLine(row, w, i, motion, (if (last == null) Modifier.flightFold(motion, row, w) else Modifier).padding(top = 8.dp)) }
                                        }
                                    }
                                }
                            }
                        }
                        val hc: Rgba = when (card.health) {
                            FlightHealth.NORMAL -> NW.Palette.green
                            FlightHealth.LONG_RUNNING -> NW.Palette.sky
                            FlightHealth.STUCK, FlightHealth.RATE_LIMITED -> NW.Palette.amber
                        }
                        Fact("HEALTH", tint = if (card.health.needsAttention) NW.Palette.amber else hc) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                                FlightHealthDot(card.health, hc, motion)
                                Text(
                                    card.healthLine ?: "Normal", style = NW.Typo.meta, maxLines = 3, overflow = TextOverflow.Ellipsis,
                                    color = (if (card.health.needsAttention) NW.Palette.amber else NW.Palette.textSecondary).color,
                                )
                            }
                        }
                    }
                }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text("Open") }, { menu = false; onOpen(RoomEntry.SCREEN) })
                    DropdownMenuItem({ Text("Steer") }, { menu = false; onOpen(RoomEntry.TYPE) })
                    if (onBudget != null) DropdownMenuItem({ Text("Session budget…") }, { menu = false; onBudget() })
                    if (row.canStop) DropdownMenuItem({ Text("Stop…") }, { menu = false; onOpen(RoomEntry.STOP) })
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth().padding(start = NW.Space.lg, end = NW.Space.lg, top = 14.dp, bottom = NW.Space.lg)) {
                // A terminal Page cannot mirror or type into is dimmed, not hidden: it still opens the room, which says why.
                // Working, not waiting on you: its buttons stay quiet beside a card that needs you.
                EntryButton(RoomEntry.SCREEN, row.canMirror, NWButtonKind.QUIET, Modifier.weight(1f)) { onOpen(RoomEntry.SCREEN) }
                EntryButton(RoomEntry.TYPE, row.canType, NWButtonKind.SOFT, Modifier.weight(1f)) { onOpen(RoomEntry.TYPE) }
            }
        }
        NWGlassEdgeLight(NW.Radius.card, Modifier.matchParentSize())
    }
}

/**
 * TIME ("working 12m · session 2h 10m"): only the numbers that moved roll, as iOS's numericText does, so a minute
 * ticking over moves one or two digits instead of sliding the whole line; new wording cross-fades ([NWRollingWords]).
 * Its own clock, only while a change plays.
 */
@Composable
private fun TimeText(text: String) {
    val change = rememberNowChange(text)
    val clock = rememberNowClock(change.at?.plus(NowMotion.wordsLast(LocalReduceMotion.current)))
    NWRollingWords(AnnotatedString(text), change, clock, NW.Typo.meta.copy(fontFeatureSettings = "tnum"), NW.Palette.textPrimary.color, textAlign = TextAlign.Start, maxLines = 2)
}

/** "2 workflows running", rolling to each new count; the last count while the last line closes. */
@Composable
private fun WorkflowHeading(heading: String?, reduce: Boolean) {
    var last by remember { mutableStateOf(heading) }
    if (heading != null) last = heading
    last?.let { RollingText(it, NW.Typo.captionStrong, NW.Palette.teal.color, reduce) }
}

/** One workflow line: its words (the progress rolls on its own, and a finish reads "✓ done") and its bar in motion. */
@Composable
private fun WorkflowLine(row: InFlightRow, w: FlightWorkflowLine, index: Int, motion: FlightMotion, modifier: Modifier) {
    val ended = if (motion.reduce) null else NowMotion.endedWord(w.status)
    val amber = w.status == FlightLineStatus.FAILED || w.status == FlightLineStatus.STOPPED
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Text(if (ended != null) listOfNotNull(w.name, w.phase).joinToString(" · ") + " · " else w.lead, style = NW.Typo.metaSmall.copy(fontFeatureSettings = "tnum"), color = NW.Palette.textSecondary.color, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            (ended ?: w.progress)?.let { RollingText(it, NW.Typo.metaSmall.copy(fontFeatureSettings = "tnum"), (if (amber && ended != null) NW.Palette.amber else NW.Palette.textSecondary).color, motion.reduce) }
        }
        if (w.fraction != null) FlightBar(motion, row, w, index)
    }
}

/**
 * The NOW step and the two before it. A new step rises in (0.35 s, spring) as the old slides up 6 dp and fades
 * (0.25 s); the earlier steps shift down on the stream's spring, the newest of them fading in and the oldest falling
 * off with a fade. Under Reduce Motion the steps cross-fade in place over 0.2 s and the oldest simply goes.
 */
@Composable
private fun NowSteps(row: InFlightRow, motion: FlightMotion) {
    val card = row.card
    val track = motion.track
    val reduce = motion.reduce
    val change by remember(track, row.id, reduce) { derivedStateOf { NowMotion.step(track, row.id, motion.now, reduce)?.first } }
    val pitch = remember { mutableFloatStateOf(0f) }
    val gap = with(LocalDensity.current) { 6.dp.toPx() }
    val style = NW.Typo.activity
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box {
            val s = change
            if (s != null) Text(s.now, style = style, color = NW.Palette.textPrimary.color, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.clearAndSetSemantics {}.graphicsLayer {
                val k = NowMotion.stepOld(motion.now - s.at, reduce)
                translationY = k.offset.dp.toPx()
                alpha = k.opacity.toFloat()
            })
            Text(card.now, style = style, color = NW.Palette.textPrimary.color, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = if (s == null) Modifier else Modifier.graphicsLayer {
                val k = NowMotion.stepNew(motion.now - s.at, reduce)
                translationY = k.offset.dp.toPx()
                alpha = k.opacity.toFloat()
            })
        }
        val s = change
        val falling = s?.previous?.withIndex()?.filter { (_, old) -> old !in card.previous && old != card.now } ?: emptyList()
        // Clipped, so the oldest slides out under the list's edge instead of over the TIME fact below.
        if (card.previous.isNotEmpty() || falling.isNotEmpty()) Box(Modifier.clipToBounds()) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                card.previous.forEachIndexed { i, step ->
                    val was = s?.previous?.indexOf(step) ?: -1
                    val m = when {
                        s == null -> Modifier
                        was >= 0 -> Modifier.graphicsLayer { translationY = (was - i) * pitch.floatValue * (1 - NowMotion.stepShift(motion.now - s.at, reduce)).toFloat() }
                        // The newest fades in as the row it replaces moves out of its place, never stacked on it.
                        else -> Modifier.graphicsLayer {
                            val e = motion.now - s.at
                            val k = MotionCurve.clamp01(NowMotion.stepShift(e, reduce))
                            alpha = (if (reduce) NowMotion.stepNew(e, true).opacity else k * k).toFloat()
                        }
                    }
                    PreviousStep(step, i, m.then(if (i == 0) Modifier.onSizeChanged { pitch.floatValue = it.height + gap } else Modifier))
                }
            }
            // The oldest falls off below the others as they shift down, fading, taking no room.
            if (s != null) for ((j, old) in falling) {
                val slot = card.previous.size
                PreviousStep(old, slot, Modifier.clearAndSetSemantics {}.layout { m, c ->
                    val p = m.measure(c)
                    layout(0, 0) {
                        p.placeWithLayer(0, (slot * pitch.floatValue).roundToInt()) {
                            val e = motion.now - s.at
                            translationY = (j - slot) * pitch.floatValue * (1 - NowMotion.stepShift(e, reduce)).toFloat()
                            alpha = NowMotion.stepOld(e, reduce).opacity.toFloat()
                        }
                    }
                })
            }
        }
    }
}

@Composable
private fun PreviousStep(step: String, i: Int, modifier: Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(5.dp).clip(CircleShape).background(NW.Palette.textQuiet.opacity((1 - 0.22 * i).coerceAtLeast(0.2)).color))
        Text(step, style = NW.Typo.metaSmall.copy(fontSize = 11.sp), color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun EntryButton(entry: RoomEntry, enabled: Boolean, kind: NWButtonKind, modifier: Modifier, onClick: () -> Unit) {
    val hint = if (enabled) (if (entry == RoomEntry.TYPE) "Opens the session with the keyboard up" else "Shows its terminal")
    else (if (entry == RoomEntry.TYPE) "Page Studio can't type into this terminal; opens the session to say why" else "Page Studio can't mirror this terminal; opens the session")
    Box(modifier.semantics { stateDescription = hint }) {
        NWButton(entry.buttonTitle, onClick, Modifier.fillMaxWidth().then(if (enabled) Modifier else Modifier.padding(0.dp)), kind = if (enabled) kind else NWButtonKind.QUIET, alpha = if (enabled) 1f else 0.55f)
    }
}

/** "18% of 25% this week", and the bar under it (amber from the warning). */
@Composable
private fun BudgetFact(m: BudgetMeter) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            m.line + " this week", style = NW.Typo.meta.copy(fontFeatureSettings = "tnum"), maxLines = 2,
            color = (if (m.tone == BudgetMeter.Tone.WARM) NW.Palette.amber else NW.Palette.textPrimary).color,
        )
        NWBudgetBar(m, Modifier.widthIn(max = 200.dp), height = 6.dp)
    }
}

/**
 * A fact, led by a soft tile that says what it is (what it is doing, how long, its workflows, how it is doing), so no label stands
 * over it. [tint] is the tile's colour; the tile is not read (the words are).
 */
@Composable
private fun Fact(title: String, tint: Rgba? = null, content: @Composable () -> Unit) {
    val (symbol, colour) = when (title) {
        "NOW" -> "waveform" to NW.Palette.teal
        "TIME" -> "clock.fill" to NW.Palette.sky
        "WORKFLOWS" -> "square.stack.3d.up.fill" to NW.Palette.violet
        "BUDGET" -> BudgetCopy.SYMBOL to (tint ?: NW.Palette.teal)
        else -> "heart.fill" to (tint ?: NW.Palette.green)
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
        NWSoftTile(symbol, colour, size = 30.dp)
        Box(Modifier.weight(1f).padding(top = 5.dp)) { content() }
    }
}

/** What a card in the In flight section needs to recede with the stream: its scroll, and where the stream's top is in the window. Set by the Now screen. */
class StreamRecede(val state: androidx.compose.foundation.lazy.LazyListState, val top: () -> Float)

val LocalStreamRecede = androidx.compose.runtime.staticCompositionLocalOf<StreamRecede?> { null }

/**
 * [app.page.android.ui.nw.components.nwRecede] for a card that sits inside a bigger item (the In flight cards are one item of
 * the stream): the card leaving the top scales to 0.94 (anchored at its bottom) and fades to 0.55 as it goes, and comes forward on
 * return; still under Reduce Motion. Its place is read as the layer is drawn, so a scroll recomposes nothing.
 */
@Composable
fun Modifier.nwRecedeInStream(): Modifier {
    val stream = LocalStreamRecede.current ?: return this
    if (LocalReduceMotion.current) return this
    val at = remember { arrayOfNulls<androidx.compose.ui.layout.LayoutCoordinates>(1) }
    return this.onGloballyPositioned { at[0] = it }.graphicsLayer {
        stream.state.layoutInfo
        val c = at[0] ?: return@graphicsLayer
        if (!c.isAttached || size.height <= 0f) return@graphicsLayer
        val gone = stream.top() - c.positionInRoot().y
        if (gone <= 0f) return@graphicsLayer
        val p = (gone / size.height).coerceIn(0f, 1f)
        transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0.5f, 1f)
        val k = 1f - 0.06f * p
        scaleX = k
        scaleY = k
        alpha = 1f - 0.45f * p
    }
}
