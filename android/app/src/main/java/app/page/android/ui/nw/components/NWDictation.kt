package app.page.android.ui.nw.components

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.MicOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.page.android.data.AppGraph
import app.page.android.model.DictationCopy
import app.page.android.model.DictationPhase
import app.page.android.model.DictationState
import app.page.android.speech.DictationController
import app.page.android.ui.nw.theme.LocalFixedPhase
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

// Voice input in the message boxes (Designs/voice-input.md): the mic button, and the one line above the box that says
// what the mic is doing. Speaking only fills the draft; Send is unchanged and nothing is sent by voice. Drawn from a
// DictationPhase, the same as iOS's NWDictation.swift.

/**
 * What the boxes need from the app's one dictation controller. Each box has a stable id ("room:<session>",
 * "decision:<row>", "answer:<id>", "dispatch"). Only the box that is listening (or showing a note) sees a phase other
 * than idle. Stable, and it reads [state] only where a phase is asked for, so a voice level moving recomposes only the
 * mic and the line, not the box around them.
 */
@Stable
class NWDictation(
    private val state: State<DictationState>,
    private val onToggle: (box: String, draft: String, onDraft: (String) -> Unit) -> Unit = { _, _, _ -> },
    private val onCancel: (box: String) -> Unit = {},
    private val onObserve: (box: String, text: String) -> Unit = { _, _ -> },
    /** Open Page's own page in Android's Settings, where the microphone is turned on. */
    val openSettings: () -> Unit = {},
    /** What the phone is called in a sentence. */
    val device: String = DictationCopy.DEVICE,
) {
    /** The box the phase belongs to. */
    val box: String? get() = state.value.box
    val phase: DictationPhase get() = state.value.phase

    fun phase(box: String): DictationPhase = state.value.phase(box)

    /** [send] is the word on the box's own button: "Send", "Answer", or "Start" on New task. */
    fun line(box: String, send: String = "Send"): DictationCopy.Line? {
        val st = state.value
        if (st.box != box || st.noteHidden) return null
        return DictationCopy.line(st.phase, device, st.language, send)
    }

    /** Start, or stop and keep the words (the stop button). [draft] is the box's text now and [onDraft] changes it. */
    fun toggle(box: String, draft: String, onDraft: (String) -> Unit) = onToggle(box, draft, onDraft)

    /** Stop without writing anything more: Send, leaving, the box locking. What shows is kept. */
    fun cancel(box: String) = onCancel(box)

    internal fun observe(box: String, text: String) = onObserve(box, text)

    companion object {
        /** No controller: every box is idle and a tap does nothing (a preview). */
        val Inert = NWDictation(mutableStateOf(DictationState()))

        /** A phase held still, for the render harness; a tap does nothing. */
        fun fixed(state: DictationState) = NWDictation(mutableStateOf(state))
    }
}

val LocalDictation = compositionLocalOf { NWDictation.Inert }

/**
 * One message box's voice input: its id, the draft it dictates into, and what the mic and the line need. Reads the
 * phase only where asked, so a box that just asks [isListening] or [isActive] does not recompose with the level.
 */
@Stable
class DictationBox internal constructor(
    val id: String,
    private val dictation: NWDictation,
    private val text: State<String>,
    private val onText: State<(String) -> Unit>,
    private val prepare: () -> Unit,
) {
    val phase: DictationPhase get() = dictation.phase(id)
    val isActive: Boolean by derivedStateOf { phase.isActive }
    val isListening: Boolean by derivedStateOf { phase.isListening }

    /** The line above the box: Listening, the download, or why the mic can't listen. [send] is the box's own button. */
    fun line(send: String = "Send"): DictationCopy.Line? = dictation.line(id, send)

    val openSettings: () -> Unit get() = dictation.openSettings

    /** The mic was tapped: the keyboard goes down, then listening starts, or stops with the words kept. */
    fun toggle() {
        prepare()
        dictation.toggle(id, text.value) { onText.value(it) }
    }

    /** Stop without writing anything more: Send, leaving the box, the box locking. */
    fun cancel() = dictation.cancel(id)

    /** The person touched the field: one input at a time, so listening stops. */
    fun fieldFocused() {
        if (isActive) cancel()
    }
}

/**
 * The box's voice input, over the box's own draft ([text] and how to change it, [onText]; the latest of both is always
 * used). Tells the controller what the box shows after each composition, so the person's own edit stops listening, and
 * cancels when the box leaves the screen.
 */
@Composable
fun rememberDictationBox(id: String, text: String, onText: (String) -> Unit): DictationBox {
    val dictation = LocalDictation.current
    val latestText = rememberUpdatedState(text)
    val latestOnText = rememberUpdatedState(onText)
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val haptics = rememberHaptics()
    val box = remember(id, dictation) {
        DictationBox(id, dictation, latestText, latestOnText) {
            haptics.light()
            // Tapping the mic drops the keyboard: one input at a time. It also ends any word the keyboard was still composing.
            focus.clearFocus()
            keyboard?.hide()
        }
    }
    SideEffect { dictation.observe(id, text) }
    DisposableEffect(id, dictation) { onDispose { dictation.cancel(id) } }
    return box
}

/** The mic in a box: [NWMicButton] over the box's own phase. 44 dp in the boxes, 36 dp in Dispatch. */
@Composable
fun NWMic(box: DictationBox, size: Dp = 44.dp, modifier: Modifier = Modifier) {
    NWMicButton(box.phase, size, box::toggle, modifier)
}

/** The line above a box, from its own phase. Nothing while the box has no line. [send] is the box's own button. */
@Composable
fun NWDictationLine(box: DictationBox, modifier: Modifier = Modifier, send: String = "Send") {
    val line = box.line(send) ?: return
    NWDictationLine(line, modifier, box.phase.level, box.openSettings)
}

private val teal: Rgba get() = NW.Palette.teal

/**
 * The mic: a circle the size of the photo button. While listening it is teal on dark, a stop square, and a ring that
 * follows the voice (never Send's bright gradient: the two sit side by side); while the recognizer is being made ready
 * an arc goes round it, and while a language downloads a ring fills. The touch target is at least 48 dp.
 */
@Composable
fun NWMicButton(phase: DictationPhase, size: Dp = 44.dp, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val reduce = LocalReduceMotion.current
    val blocked = phase.isBlocked
    val active = phase.isActive
    val listening = phase.isListening
    val level by animateFloatAsState(if (reduce) 0f else phase.level.coerceIn(0.0, 1.0).toFloat(), tween(120), label = "mic-level")
    val touch = maxOf(size, 48.dp)
    val view = LocalView.current
    // TalkBack is told when the mic opens and when it closes (nothing when it only changes engine).
    var wasListening by remember { mutableStateOf(listening) }
    LaunchedEffect(listening, active) {
        if (listening && !wasListening) view.announceForAccessibility(DictationCopy.ANNOUNCE_START)
        if (!active && wasListening) view.announceForAccessibility(DictationCopy.ANNOUNCE_STOP)
        wasListening = listening || (wasListening && active)
    }
    Box(
        modifier.size(touch).drawBehind {
            // The ring outside the disc, 1.0 to 1.22 times its size with the voice (still, under Reduce Motion).
            if (listening) {
                val scale = if (reduce) 1.12f else 1f + 0.22f * level
                val stroke = 3.dp.toPx()
                drawCircle(teal.opacity(0.35).color, radius = size.toPx() / 2 * scale - stroke / 2, style = Stroke(stroke))
            }
        },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(touch).clip(CircleShape)
                .clickable(role = Role.Button, onClickLabel = DictationCopy.MIC_HINT, onClick = onClick)
                .semantics {
                    contentDescription = if (active) DictationCopy.STOP_LABEL else DictationCopy.MIC_LABEL
                    if (blocked) stateDescription = "Unavailable"
                },
            contentAlignment = Alignment.Center,
        ) {
            if (listening) {
                // Teal on dark, never Send's bright fill.
                Box(Modifier.size(size).clip(CircleShape).background(teal.opacity(0.16).color).border(1.5.dp, teal.opacity(0.75).color, CircleShape))
                Box(Modifier.size(size * 0.3f).clip(RoundedCornerShape(3.dp)).background(teal.color))
            } else {
                Box(Modifier.size(size).clip(CircleShape).background(Color.White.copy(alpha = if (blocked) 0.05f else 0.10f)))
                Icon(
                    if (blocked) Icons.Outlined.MicOff else Icons.Outlined.Mic, null, modifier = Modifier.size(size * 0.5f),
                    tint = (if (blocked) NW.Palette.textQuiet else NW.Palette.textSecondary).color,
                )
                MicRing(phase, size, reduce)
            }
        }
    }
}

/** Getting ready: a short arc going round. Downloading: the real fraction. */
@Composable
private fun MicRing(phase: DictationPhase, size: Dp, reduce: Boolean) {
    val fraction = (phase as? DictationPhase.Downloading)?.fraction
    when {
        phase is DictationPhase.Preparing || (phase is DictationPhase.Downloading && fraction == null) -> {
            val pinned = LocalFixedPhase.current
            val angle = if (pinned != null) ((pinned % 1.0) * 360.0).toFloat() else if (reduce) 0f else {
                val spin = rememberInfiniteTransition(label = "mic-spin")
                val a by spin.animateFloat(0f, 360f, infiniteRepeatable(tween(1000, easing = LinearEasing), RepeatMode.Restart), label = "mic-angle")
                a
            }
            Canvas(Modifier.size(size - 2.dp)) {
                val w = 2.dp.toPx()
                drawArc(teal.color, startAngle = angle - 90f, sweepAngle = 0.28f * 360f, useCenter = false, topLeft = Offset(w / 2, w / 2), size = Size(this.size.width - w, this.size.height - w), style = Stroke(w, cap = StrokeCap.Round))
            }
        }
        fraction != null -> Canvas(Modifier.size(size - 2.dp)) {
            val w = 2.dp.toPx()
            val box = Size(this.size.width - w, this.size.height - w)
            drawArc(Color.White.copy(alpha = 0.10f), 0f, 360f, false, Offset(w / 2, w / 2), box, style = Stroke(w))
            drawArc(teal.color, -90f, 360f * fraction.coerceIn(0.02, 1.0).toFloat(), false, Offset(w / 2, w / 2), box, style = Stroke(w, cap = StrokeCap.Round))
        }
    }
}

/** Five bars that follow the voice level. */
@Composable
fun NWLevelBars(level: Double, modifier: Modifier = Modifier) {
    val reduce = LocalReduceMotion.current
    val l by animateFloatAsState(if (reduce) 0.5f else level.coerceIn(0.0, 1.0).toFloat(), tween(120), label = "bars-level")
    Canvas(modifier.size(width = 23.dp, height = 14.dp).clearAndSetSemantics {}) {
        val barW = 3.dp.toPx()
        val gap = 2.dp.toPx()
        BAR_SHAPE.forEachIndexed { i, shape ->
            val h = (4.dp.toPx() + 10.dp.toPx() * shape * l)
            drawRoundRect(teal.color, topLeft = Offset(i * (barW + gap), (size.height - h) / 2), size = Size(barW, h), cornerRadius = CornerRadius(barW / 2))
        }
    }
}

private val BAR_SHAPE = floatArrayOf(0.45f, 0.8f, 1f, 0.7f, 0.5f)

/**
 * The one line above the box: Listening (teal, with the bars), the download (with its thin bar), why the mic can't
 * listen (quiet), or that the microphone is off (amber, with Open Settings).
 */
@Composable
fun NWDictationLine(line: DictationCopy.Line, modifier: Modifier = Modifier, level: Double = 0.0, onSettings: () -> Unit = {}) {
    val tone: Rgba = when (line.tone) {
        DictationCopy.Tone.LISTENING -> NW.Palette.teal
        DictationCopy.Tone.PROBLEM -> NW.Palette.amber
        DictationCopy.Tone.QUIET -> NW.Palette.textSecondary
    }
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier.fillMaxWidth().clip(shape).background(tone.opacity(0.09).color)
            .padding(horizontal = 14.dp, vertical = if (line.opensSettings) 2.dp else 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            when (line.tone) {
                DictationCopy.Tone.LISTENING -> NWLevelBars(level)
                DictationCopy.Tone.PROBLEM -> Icon(Icons.Outlined.MicOff, null, tint = tone.color, modifier = Modifier.size(18.dp))
                DictationCopy.Tone.QUIET ->
                    if (line.progress == null && line.text.endsWith("…")) CircularProgressIndicator(Modifier.size(16.dp), color = tone.color, strokeWidth = 2.dp)
                    else Icon(if (line.progress != null) Icons.Outlined.ArrowCircleDown else Icons.Outlined.Mic, null, tint = tone.color, modifier = Modifier.size(18.dp))
            }
            Text(
                line.text, style = if (line.tone == DictationCopy.Tone.LISTENING) NW.Typo.captionStrong else NW.Typo.caption, color = tone.color,
                // Listening is announced by the mic (ANNOUNCE_START); every other line is read out as it appears.
                modifier = Modifier.weight(1f).then(if (line.tone == DictationCopy.Tone.LISTENING) Modifier else Modifier.semantics { liveRegion = LiveRegionMode.Polite }),
            )
            if (line.opensSettings) {
                Box(
                    Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).clickable(role = Role.Button, onClick = onSettings).padding(horizontal = 4.dp),
                    contentAlignment = Alignment.Center,
                ) { Text(DictationCopy.OPEN_SETTINGS, style = NW.Typo.captionStrong, color = NW.Palette.textPrimary.color) }
            }
        }
        line.progress?.let { p ->
            Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.10f)).clearAndSetSemantics {}) {
                Box(Modifier.fillMaxHeight().fillMaxWidth(p.coerceIn(0.0, 1.0).toFloat()).background(teal.color))
            }
        }
    }
}

/**
 * Provides the app's dictation to everything below. [fixed] holds one phase still for the render harness (a tap does
 * nothing); otherwise it is the live controller: the host asks for the microphone when the first mic is tapped, and
 * the app going to the background (the phone locking) stops whatever is listening.
 */
@Composable
fun ProvideDictation(fixed: DictationState? = null, content: @Composable () -> Unit) {
    if (fixed != null) {
        val dictation = remember(fixed) { NWDictation.fixed(fixed) }
        CompositionLocalProvider(LocalDictation provides dictation, content = content)
    } else {
        LiveDictation(content)
    }
}

@Composable
private fun LiveDictation(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val controller = remember { AppGraph.dictation }
    val state = controller.state.collectAsState()
    // The microphone is asked for with the platform call and a small request code, and the answer comes back through
    // MainActivity.onRequestPermissionsResult: the activity-result launcher (rememberLauncherForActivityResult) throws
    // "Can only use lower 16 bits for requestCode" under FragmentActivity 1.2.5, which this build's dependency lock pins.
    DisposableEffect(controller, context) {
        controller.attach {
            val activity = context.findActivity()
            if (activity != null) ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.RECORD_AUDIO), DictationController.REQUEST_MICROPHONE)
            else controller.onMicrophoneResult(false)
        }
        onDispose { controller.detach() }
    }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(controller, owner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) controller.cancelActive() }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    val dictation = remember(controller, state, context) {
        NWDictation(state, controller::toggle, controller::cancel, controller::observe, { openAppSettings(context) })
    }
    CompositionLocalProvider(LocalDictation provides dictation, content = content)
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

/** Page's own page in Android's Settings (App info), where Permissions has the microphone. */
private fun openAppSettings(context: Context) {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    runCatching { context.startActivity(intent) }
}
