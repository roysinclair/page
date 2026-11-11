package app.page.android.ui.nw.budget

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.page.android.model.BudgetCopy
import app.page.android.model.BudgetMeter
import app.page.android.model.BudgetPercent
import app.page.android.model.BudgetProject
import app.page.android.model.BudgetSaveStatus
import app.page.android.model.BudgetSheetModel
import app.page.android.model.BudgetState
import app.page.android.model.CardOutcome
import app.page.android.model.MacBudget
import app.page.android.model.NowRow
import app.page.android.model.RowAction
import app.page.android.model.waitingText
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWIconTile
import app.page.android.ui.nw.components.NWJewel
import app.page.android.ui.nw.components.NWReceiptLine
import app.page.android.ui.nw.components.NWSegmented
import app.page.android.ui.nw.components.NWSoftTile
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.components.drawSoftGlow
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.components.nwJewelSurface
import app.page.android.ui.nw.components.strokeBorder
import app.page.android.ui.nw.now.CardTopLine
import app.page.android.ui.nw.now.NowRaisedCard
import app.page.android.ui.nw.now.NWOutcomeStrip
import app.page.android.ui.nw.now.RowActions
import app.page.android.ui.nw.now.RowStatus
import app.page.android.ui.nw.shell.NWCappedFontScale
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import java.time.Instant
import java.time.ZoneId

// Budget caps (Designs/budget-caps.md): the bar, the percent picker, the Budget list's rows, the sheet that sets a budget,
// and the card a stopped project sends. Amber and teal only: red stays Irreversible's. (iOS NWBudget.swift.)

/** The colour of a bar: calm teal, warm amber from the warning, and a faint sky for a project with no budget (the whole week). */
val BudgetMeter.Tone.rgba: Rgba
    get() = when (this) {
        BudgetMeter.Tone.QUIET -> NW.Palette.sky.mixed(NW.Palette.textTertiary, 0.55)
        BudgetMeter.Tone.CALM -> NW.Palette.teal
        BudgetMeter.Tone.WARM -> NW.Palette.amber
    }

/**
 * A budget as a bar: the fill is what is used (against the budget, full when Page stops it; against the whole week with no
 * budget), the tick is where Page warns. Drawn (a soft glow of its own colour, not an elevation) and silent: whatever holds it
 * says the numbers in words.
 */
@Composable
fun NWBudgetBar(meter: BudgetMeter, modifier: Modifier = Modifier, height: Dp = 8.dp, onJewel: Boolean = false) {
    val tone = meter.tone.rgba
    Canvas(modifier.fillMaxWidth().height(height + 6.dp).clearAndSetSemantics {}) {
        val h = height.toPx()
        val w = size.width
        val top = (size.height - h) / 2
        val r = h / 2
        drawRoundRect(Color.White.copy(alpha = if (onJewel) 0.2f else 0.09f), Offset(0f, top), Size(w, h), CornerRadius(r))
        val fill = if (meter.fraction > 0) maxOf(h, w * meter.fraction.toFloat()) else 0f
        if (fill > 0f) {
            if (meter.tone != BudgetMeter.Tone.QUIET) {
                drawSoftGlow(tone.opacity(0.55).color, blur = 5.dp.toPx(), corner = r, topLeft = Offset(0f, top), shapeSize = Size(fill, h))
            }
            drawRoundRect(
                Brush.verticalGradient(listOf(tone.mixed(Rgba(1.0, 1.0, 1.0), 0.28).color, tone.color), startY = top, endY = top + h),
                Offset(0f, top), Size(fill, h), CornerRadius(r),
            )
        }
        meter.warnMark?.let { m ->
            val tick = 2.dp.toPx()
            val tall = h + 6.dp.toPx()
            drawRoundRect(
                Color.White.copy(alpha = if (onJewel) 0.9f else 0.75f), Offset(w * m.toFloat() - tick / 2, (size.height - tall) / 2), Size(tick, tall), CornerRadius(tick / 2),
            )
        }
    }
}

/**
 * The budget picker: the value large, - and + in steps of 5, and Off, 10, 25, 50. Every control is 48 dp or more.
 * [enabled] false (a change on its way) holds the value still.
 */
@Composable
fun NWPercentPicker(value: Int?, onChange: (Int?) -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Column(modifier.alpha(if (enabled) 1f else 0.6f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            StepButton("minus", "Less", enabled && value != null) { onChange(BudgetPercent.down(value)) }
            // The value is the hero of the sheet: it keeps to one line, so it never grows past what sits between the two steps.
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                NWCappedFontScale(1.15f) {
                    Text(
                        BudgetPercent.text(value), style = NW.Typo.hero.copy(fontFeatureSettings = "tnum"),
                        color = (if (value == null) NW.Palette.textTertiary else NW.Palette.textPrimary).color, textAlign = TextAlign.Center, maxLines = 1,
                        modifier = Modifier.semantics {
                            contentDescription = value?.let { "Budget, $it percent of the week" } ?: "Budget, off"
                            liveRegion = LiveRegionMode.Polite
                        },
                    )
                }
            }
            StepButton("plus", "More", enabled && (value ?: 0) < 100) { onChange(BudgetPercent.up(value)) }
        }
        NWSegmented(BudgetPercent.presets.map { it to BudgetPercent.text(it) }, value, { if (enabled) onChange(it) }, segmentHeight = 48.dp)
    }
}

/** A step of the picker: a soft teal button, 84 by 52 dp. */
@Composable
private fun StepButton(symbol: String, label: String, enabled: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(NW.Radius.button)
    val teal = NW.Palette.teal
    Box(
        Modifier.width(84.dp).heightIn(min = 52.dp).alpha(if (enabled) 1f else 0.45f)
            .clip(shape).background(Brush.verticalGradient(listOf(teal.opacity(0.16).color, teal.opacity(0.07).color)))
            .border(1.dp, teal.opacity(0.32).color, shape)
            .semantics { contentDescription = label }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(nwIcon(symbol), null, tint = teal.color, modifier = Modifier.size(24.dp)) }
}

/** One project in Budget: its colour, name, share and bar. A pause glyph once Page has stopped it. */
@Composable
fun NWBudgetProjectRow(project: BudgetProject, defaultCap: Int?, modifier: Modifier = Modifier, measuring: Boolean = false, onClick: () -> Unit = {}) {
    val cap = project.effectiveCap(defaultCap)
    val meter = BudgetMeter(project.used, cap, project.state)
    val inherited = project.cap == null && defaultCap != null
    Row(
        modifier.fillMaxWidth().heightIn(min = 64.dp)
            .semantics(mergeDescendants = true) { contentDescription = meter.spoken(project.name) }
            .clickable(role = Role.Button, onClickLabel = "Sets its budget", onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        NWIconTile(if (project.state == BudgetState.OVER) "pause.fill" else "folder.fill", NWJewel.of(project.hue), size = 44.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(project.name, style = NW.Typo.name, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!measuring) NWBudgetBar(meter, height = 7.dp)
            Text(
                if (measuring) "Measuring…" else detail(project, meter, inherited), style = NW.Typo.caption.copy(fontFeatureSettings = "tnum"),
                color = (if (meter.tone == BudgetMeter.Tone.WARM) NW.Palette.amber else NW.Palette.textTertiary).color,
            )
        }
        Icon(Icons.Outlined.ChevronRight, null, tint = NW.Palette.textQuiet.color, modifier = Modifier.size(16.dp))
    }
}

/** "26% of 25% · stopped, raise it to carry on"; "11% of 15% · default budget"; "2% · no budget". */
private fun detail(project: BudgetProject, m: BudgetMeter, inherited: Boolean): String {
    if (project.state == BudgetState.OVER) return m.line + " · stopped, raise it to carry on"
    return m.line + (if (inherited) " · default budget" else "")
}

/**
 * Budget's project list: every project with a share or a budget this week, the default, and the one line that says it is an
 * estimate. [onOpen] gets the sheet to set a budget (a project's, or the default).
 */
@Composable
fun NWBudgetProjects(budget: MacBudget, zone: ZoneId, onOpen: (BudgetSheetModel) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 4.dp).semantics(mergeDescendants = true) { heading() },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Projects this week", style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color, modifier = Modifier.weight(1f))
            budget.resetsAt?.let { Text("resets ${BudgetCopy.resets(it, zone)}", style = NW.Typo.caption, color = NW.Palette.textTertiary.color) }
        }
        if (!budget.capture) {
            Note(BudgetCopy.captureOff)
            return@Column
        }
        if (budget.measuring) Note(BudgetCopy.measuring)
        for (p in budget.projects) {
            NWBudgetProjectRow(p, budget.defaultCap, measuring = budget.measuring) { onOpen(BudgetSheetModel.project(p, budget.resetsAt)) }
        }
        Box(Modifier.fillMaxWidth().padding(start = 72.dp).height(1.dp).background(Color.White.copy(alpha = 0.07f)))
        Row(
            Modifier.fillMaxWidth().heightIn(min = 64.dp)
                .semantics(mergeDescendants = true) { contentDescription = "Default for other projects, ${BudgetPercent.text(budget.defaultCap)}" }
                .clickable(role = Role.Button, onClickLabel = "Sets the default budget") { onOpen(BudgetSheetModel.forDefault(budget)) }
                .padding(horizontal = 14.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            NWSoftTile("slider.horizontal.3", NW.Palette.sky, size = 44.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Default for other projects", style = NW.Typo.name, color = NW.Palette.textPrimary.color)
                Text("Any project without a budget of its own", style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
            }
            Text(BudgetPercent.text(budget.defaultCap), style = NW.Typo.captionStrong, color = NW.Palette.teal.color)
            Icon(Icons.Outlined.ChevronRight, null, tint = NW.Palette.textQuiet.color, modifier = Modifier.size(16.dp))
        }
        Note(BudgetCopy.footnote)
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp))
}

/**
 * The sheet that sets a budget: the project's colour across the top, how much it has used, the picker, and what Page will do,
 * in words. [status] is the change's own line: while it is on its way the controls hold still, and a refusal is said here
 * with the old value left in place. The picker starts at the budget now ([BudgetSheetModel.cap]).
 */
@Composable
fun NWBudgetSheet(
    model: BudgetSheetModel, zone: ZoneId, status: BudgetSaveStatus, onSave: (Int?) -> Unit, onCancel: () -> Unit, modifier: Modifier = Modifier,
) {
    var value by remember(model.id) { mutableStateOf(model.cap) }
    val jewel = model.hue?.let { NWJewel.of(it) } ?: NWJewel.sky
    val saving = status.isSaving
    Box(
        modifier.fillMaxWidth().drawBehind {
            // The sheet's surface: the project's jewel at the top, fading into raised navy.
            val band = 270.dp.toPx().coerceAtMost(size.height)
            drawRect(NW.Palette.surface.color)
            drawRect(
                Brush.verticalGradient(0f to jewel.top.color, 0.55f to jewel.bottom.color, 1f to jewel.bottom.opacity(0.0).color, startY = 0f, endY = band),
                size = Size(size.width, band),
            )
            drawRect(
                Brush.radialGradient(listOf(jewel.light.opacity(jewel.lightStrength).color, jewel.light.opacity(0.0).color), center = Offset.Zero, radius = 300.dp.toPx()),
                size = Size(size.width, band),
            )
        },
    ) {
        // The host's drag handle sits in the top 28 dp.
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(horizontal = 22.dp).padding(top = 36.dp, bottom = 22.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                NWIconTile(sheetSymbol(model), jewel, size = 52.dp, glass = true)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(model.title, style = NW.Typo.sheetTitle, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.semantics { heading() })
                    Text(model.subtitle, style = NW.Typo.caption, color = Color.White.copy(alpha = 0.88f))
                }
            }
            model.used?.let { used ->
                val meter = BudgetMeter(used, value)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = meter.spoken(model.name.ifEmpty { "This project" }) }) {
                    NWBudgetBar(meter, height = 10.dp, onJewel = true)
                    Text(meter.line, style = NW.Typo.captionStrong.copy(fontFeatureSettings = "tnum"), color = Color.White.copy(alpha = 0.9f))
                }
            }
            NWPercentPicker(value, { value = it }, enabled = !saving)
            Text(model.preview(value, zone), style = NW.Typo.body, color = NW.Palette.textSecondary.color)
            // Why nothing changed (an offline Mac, a refusal), said to TalkBack when it appears.
            status.failure?.let { NWReceiptLine(it, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, failed = true) }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                NWButton("Cancel", onCancel, Modifier.weight(1f).heightIn(min = 48.dp), kind = NWButtonKind.QUIET)
                NWButton(if (saving) "Saving…" else "Save", { onSave(value) }, Modifier.weight(1f).heightIn(min = 48.dp), kind = NWButtonKind.BRIGHT, enabled = !saving)
            }
        }
    }
}

private fun sheetSymbol(model: BudgetSheetModel): String = when (model.scope) {
    BudgetSheetModel.Scope.PROJECT -> "folder.fill"
    BudgetSheetModel.Scope.SESSION -> "person.crop.circle.badge.clock"
    BudgetSheetModel.Scope.DEFAULT_CAP -> "slider.horizontal.3"
}

/**
 * The card a budget page draws. Reached (Decide): an ember jewel, the bar full, "Raise to 35%" and "Let this turn finish". Near
 * it (Look): the Look card's raised navy, the bar, and the raise. Every action goes through [actions] and the one reply path:
 * [RowActions.approve] raises the budget, [RowActions.looksGood] lets the stopped turn finish.
 */
@Composable
fun NWBudgetCard(row: NowRow, now: Instant, status: RowStatus, actions: RowActions, modifier: Modifier = Modifier) {
    val reached = row.section == NowRow.Section.DECIDE
    val meter = row.budget?.meter(reached)
    val busy = status.outcome != CardOutcome.None
    val raise = row.action(RowAction.Kind.APPROVE)
    val finish = row.action(RowAction.Kind.CARRY_ON)
    val a11y = buildList {
        add(CustomAccessibilityAction("Open") { actions.open(); true })
        if (!busy) {
            if (finish != null) add(CustomAccessibilityAction(finish.label) { actions.looksGood(); true })
            if (raise != null) add(CustomAccessibilityAction(raise.label) { actions.approve(); true })
        }
    }
    if (reached) {
        // The jewel: the one loud thing on the page.
        Box(modifier.fillMaxWidth().nwJewelSurface(NWJewel.amber, lift = 1.25)) {
            Column(Modifier.padding(NW.Space.lg), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Column(
                    Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Opens the decision", onClick = actions.open).semantics { customActions = a11y },
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    CardTopLine(row, now)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        NWIconTile(BudgetCopy.SYMBOL, NWJewel.amber, size = 44.dp, glass = true)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(row.headline, style = NW.Typo.headline, color = Color.White)
                            Text(row.summary, style = NW.Typo.caption, color = Color.White.copy(alpha = 0.9f))
                        }
                    }
                    meter?.let { NWBudgetBar(it, height = 10.dp, onJewel = true) }
                }
                if (busy) NWOutcomeStrip(status, now, actions.cancel)
                else BoxWithConstraints(Modifier.fillMaxWidth()) {
                    // Side by side while both labels fit (the longer, "Let this turn finish", is about 128 dp at 1x); stacked, the raise first, when they would not.
                    val fs = LocalDensity.current.fontScale
                    val stacked = finish != null && raise != null && maxWidth < (128.dp * fs + 32.dp) * 2 + 10.dp
                    if (stacked) Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                        raise?.let { NWButton(it.label, actions.approve, Modifier.fillMaxWidth().heightIn(min = 48.dp), kind = NWButtonKind.WHITE) }
                        finish?.let { NWButton(it.label, actions.looksGood, Modifier.fillMaxWidth().heightIn(min = 48.dp), kind = NWButtonKind.GLASS) }
                    } else Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                        finish?.let { NWButton(it.label, actions.looksGood, Modifier.weight(1f).heightIn(min = 48.dp), kind = NWButtonKind.GLASS) }
                        raise?.let { NWButton(it.label, actions.approve, Modifier.weight(1f).heightIn(min = 48.dp), kind = NWButtonKind.WHITE) }
                    }
                }
            }
        }
    } else {
        NowRaisedCard(modifier, tint = NW.Palette.amber, padding = androidx.compose.foundation.layout.PaddingValues(NW.Space.md)) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(
                    Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Opens the page", onClick = actions.open).semantics { customActions = a11y },
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        NWIconTile(BudgetCopy.SYMBOL, NWJewel.amber, size = 48.dp)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(row.headline, style = NW.Typo.title, color = NW.Palette.textPrimary.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Text("${row.projectName} · ${row.summary} · ${row.waitingText(now)}", style = NW.Typo.caption, color = NW.Palette.textSecondary.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    meter?.let { NWBudgetBar(it, height = 8.dp) }
                }
                if (busy) NWOutcomeStrip(status, now, actions.cancel)
                else raise?.let { NWButton(it.label, actions.approve, Modifier.fillMaxWidth().heightIn(min = 48.dp), kind = NWButtonKind.AMBER) }
            }
        }
    }
}
