package app.page.android.speech

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.MainThread
import androidx.annotation.RequiresApi
import androidx.annotation.VisibleForTesting
import androidx.core.content.ContextCompat
import app.page.android.model.DictationClock
import app.page.android.model.DictationDraft
import app.page.android.model.DictationEngine
import app.page.android.model.DictationEngineChoice
import app.page.android.model.DictationGuard
import app.page.android.model.DictationLevel
import app.page.android.model.DictationLocale
import app.page.android.model.DictationOnDevice
import app.page.android.model.DictationPermission
import app.page.android.model.DictationPhase
import app.page.android.model.DictationState
import app.page.android.model.DictationUnavailable
import java.util.Locale
import kotlin.math.abs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Voice input: the app's one dictation controller (Designs/voice-input.md). Speaking only fills a message box's draft;
 * nothing here can send. At most one box dictates at a time: starting in another box cancels the first, and what it
 * had written stays. Everything runs on the main thread: the recognizer is created, used and destroyed there, and its
 * callbacks arrive there.
 *
 * Which recognizer (decision D1, on the device first): API 31+ with an on-device recognizer uses
 * `createOnDeviceSpeechRecognizer`, after (API 33+) asking it whether the phone's language is installed, can be
 * fetched, or is not supported; a language that can be fetched is fetched (API 34 reports the progress), and one that
 * is not supported, an older phone, or no on-device recognizer falls to the default `createSpeechRecognizer`, which
 * may use the network, and the line says so the whole time ([DictationPhase.Listening.onDevice] false). With neither,
 * the mic says so. The choice itself is [DictationEngineChoice.pick].
 *
 * One recognition ends at a pause, so a result is committed and listening starts again, until the person stops, 20 s
 * pass with no new words, or 10 min have passed ([DictationClock]). The person's own edits win: when the draft is not
 * what dictation last wrote ([DictationGuard]), listening stops and late results are dropped.
 *
 * The microphone permission is asked for through [attach]'s request (the host composable owns the launcher).
 */
class DictationController(private val app: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val executor = ContextCompat.getMainExecutor(app)
    private val _state = MutableStateFlow(DictationState())

    /** The box that is dictating, or showing a note, and where it is. */
    val state: StateFlow<DictationState> = _state.asStateFlow()

    private class Request(val box: String, val draft: String, val onDraft: (String) -> Unit)

    private inner class Session(val request: Request) {
        val box: String get() = request.box
        val draft = DictationDraft(request.draft)
        val startedAt = now()

        /** What dictation last put in the box: anything else there is the person's. */
        var lastWritten: String = request.draft
        var recognizer: SpeechRecognizer? = null
        var onDeviceAvailable = false
        var recognitionAvailable = false
        var onDevice = true
        var defaultTried = false
        var busyRetried = false

        /** The language the recognizer is asked for, and its name for the line. */
        var tag: String = Locale.getDefault().toLanguageTag()
        var language: String = DictationLocale.displayName(tag)

        /** The recognizer has been told to listen and has not yet answered. */
        var recording = false
        var stopping = false
        var edited = false
        var ended = false

        /** When the microphone opened, then when the words last changed; null until it has opened. */
        var lastWordsAt: Long? = null
        var level = 0.0
        var levelAt = 0L
        var clockCheck: Runnable? = null
        var finalizeTimeout: Runnable? = null
        var poller: Runnable? = null
        val listener: RecognitionListener by lazy { listener(this) }

        fun alive(): Boolean = session === this && !ended
    }

    /** The live session's recognition callbacks, for the debug render harness to feed scripted results through the real handlers (`room-voice-script`). */
    @VisibleForTesting
    internal val activeListener: RecognitionListener? get() = session?.takeIf { it.alive() }?.listener

    private var askMicrophone: (() -> Unit)? = null
    private var awaitingPermission: Request? = null
    private var session: Session? = null
    private var noteTimer: Runnable? = null

    private fun now(): Long = SystemClock.elapsedRealtime()

    // region Host

    /** The host composable gives the controller a way to ask for the microphone (it owns the permission launcher). */
    @MainThread
    fun attach(askMicrophone: () -> Unit) {
        this.askMicrophone = askMicrophone
    }

    @MainThread
    fun detach() {
        askMicrophone = null
        awaitingPermission = null
    }

    /** The permission dialog answered. A refusal is the Microphone off note, with Open Settings. */
    @MainThread
    fun onMicrophoneResult(granted: Boolean) {
        val request = awaitingPermission ?: return
        awaitingPermission = null
        if (granted || hasMicrophone()) begin(request) else publish(request.box, DictationPhase.Denied(DictationPermission.MICROPHONE))
    }

    // endregion

    // region The boxes

    /**
     * The mic was tapped in [box]: stop (keeping the words) when it is listening there; otherwise start, first
     * cancelling any other box's dictation. [draft] is the box's text now and [onDraft] how to change it. A tap on a
     * blocked mic (a refused permission, a language) tries again, and the note comes back if nothing changed.
     */
    @MainThread
    fun toggle(box: String, draft: String, onDraft: (String) -> Unit) {
        val current = _state.value
        if (current.box == box && current.phase.isActive) {
            stop()
            return
        }
        endAll()
        val request = Request(box, draft, onDraft)
        publish(box, DictationPhase.Preparing, DictationLocale.displayName(Locale.getDefault().toLanguageTag()))
        if (hasMicrophone()) begin(request) else requestMicrophone(request)
    }

    /** The stop button: the words still changing are kept and the final ones are waited for. */
    @MainThread
    fun stop() {
        val waiting = awaitingPermission
        if (waiting != null) {
            awaitingPermission = null
            publish(waiting.box, DictationPhase.Idle)
            return
        }
        val s = session
        if (s != null) stopSession(s) else publish(null, DictationPhase.Idle)
    }

    /** Stop without writing anything more (Send, leaving the box, the box locking). What shows is kept. Only acts on [box]'s own dictation. */
    @MainThread
    fun cancel(box: String) {
        if (awaitingPermission?.box == box) awaitingPermission = null
        session?.takeIf { it.box == box }?.let { cancelSession(it) }
        val now = _state.value
        if (now.box == box && now.phase != DictationPhase.Idle) publish(null, DictationPhase.Idle)
    }

    /** The app went to the background (or the phone locked): whatever is listening or getting ready stops. A note stays. */
    @MainThread
    fun cancelActive() {
        awaitingPermission = null
        session?.let { cancelSession(it) }
        val now = _state.value
        if (now.phase.isActive) publish(null, DictationPhase.Idle)
    }

    /** A box reports what it shows after each composition: the draft is not what dictation wrote, so the person has edited it. */
    @MainThread
    fun observe(box: String, text: String) {
        val s = session ?: return
        if (s.box != box || s.ended || s.edited) return
        if (DictationGuard.userEdited(text, s.lastWritten)) {
            s.edited = true
            cancelSession(s)
            publish(null, DictationPhase.Idle)
        }
    }

    // endregion

    // region Starting

    private fun hasMicrophone(): Boolean = ContextCompat.checkSelfPermission(app, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestMicrophone(request: Request) {
        val ask = askMicrophone
        if (ask == null) {
            publish(request.box, DictationPhase.Denied(DictationPermission.MICROPHONE))
            return
        }
        awaitingPermission = request
        ask()
    }

    private fun endAll() {
        awaitingPermission = null
        session?.let { cancelSession(it) }
    }

    private fun begin(request: Request) {
        val s = Session(request)
        session = s
        publish(s, DictationPhase.Preparing)
        scheduleClock(s)
        s.recognitionAvailable = SpeechRecognizer.isRecognitionAvailable(app)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            s.onDeviceAvailable = runCatching { OnDeviceSpeech.available(app) }.getOrDefault(false)
            if (s.onDeviceAvailable) {
                s.recognizer = runCatching { OnDeviceSpeech.create(app) }.getOrNull()
                if (s.recognizer == null) s.onDeviceAvailable = false
            }
        }
        val r = s.recognizer
        if (r != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Is the phone's language installed, fetchable, or not supported on the device?
            OnDeviceSupport.check(
                r, intent(s.tag), executor,
                result = { l -> if (s.alive()) resolve(s, DictationLocale.support(s.tag, l.installed, l.supported, l.pending)) },
                failed = { if (s.alive()) resolve(s, DictationLocale.Support(DictationOnDevice.Unknown, null)) },
            )
        } else {
            resolve(s, DictationLocale.Support(DictationOnDevice.Unknown, null))
        }
    }

    private fun resolve(s: Session, support: DictationLocale.Support) {
        support.tag?.let { s.tag = it; s.language = DictationLocale.displayName(it) }
        when (val engine = DictationEngineChoice.pick(Build.VERSION.SDK_INT, s.onDeviceAvailable, support.state, s.recognitionAvailable)) {
            DictationEngine.OnDevice -> { s.onDevice = true; listen(s) }
            DictationEngine.OnDeviceAfterDownload ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) download(s) else { s.onDevice = true; listen(s) }
            DictationEngine.Default -> useDefault(s)
            is DictationEngine.Unavailable -> finish(s, DictationPhase.Unavailable(engine.reason))
        }
    }

    /** The phone fetches the language once (Android keeps it, not Page); listening starts by itself when it is there. */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun download(s: Session) {
        val r = s.recognizer ?: return fallBackOrFinish(s)
        publish(s, DictationPhase.Downloading(null))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            OnDeviceDownload.trigger(
                r, intent(s.tag), executor,
                progress = { p -> if (s.alive() && !s.stopping) publish(s, DictationPhase.Downloading((p / 100.0).coerceIn(0.0, 1.0))) },
                scheduled = { if (s.alive() && !s.stopping) publish(s, DictationPhase.Downloading(null)) },
                succeeded = { if (s.alive() && !s.stopping) { s.onDevice = true; listen(s) } },
                failed = { error ->
                    if (s.alive() && !s.stopping) {
                        // The recognizer can't report this download, but it may still be happening: ask until it is there.
                        if (error == SpeechRecognizer.ERROR_CANNOT_LISTEN_TO_DOWNLOAD_EVENTS) pollForLanguage(s) else fallBackOrFinish(s)
                    }
                },
            )
        } else {
            // API 33 starts it and says nothing more.
            runCatching { OnDeviceSupport.triggerDownload(r, intent(s.tag)) }
            pollForLanguage(s)
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun pollForLanguage(s: Session) {
        val r = s.recognizer ?: return
        lateinit var poll: Runnable
        poll = Runnable {
            if (!s.alive() || s.stopping) return@Runnable
            OnDeviceSupport.check(
                r, intent(s.tag), executor,
                result = { l ->
                    if (s.alive() && !s.stopping) {
                        if (DictationLocale.nearest(s.tag, l.installed) != null) { s.onDevice = true; listen(s) } else main.postDelayed(poll, POLL_MS)
                    }
                },
                failed = { if (s.alive() && !s.stopping) main.postDelayed(poll, POLL_MS) },
            )
        }
        s.poller = poll
        main.postDelayed(poll, POLL_MS)
    }

    /** The phone's default recognizer, which may be a server's. The line says "this phone's speech service". */
    private fun useDefault(s: Session) {
        s.defaultTried = true
        s.onDevice = false
        s.tag = Locale.getDefault().toLanguageTag()
        s.language = DictationLocale.displayName(s.tag)
        val old = s.recognizer
        s.recognizer = null
        if (old != null) main.post { runCatching { old.destroy() } }
        val fresh = if (s.recognitionAvailable) runCatching { SpeechRecognizer.createSpeechRecognizer(app) }.getOrNull() else null
        if (fresh == null) {
            finish(s, DictationPhase.Unavailable(DictationUnavailable.NoRecognizer))
            return
        }
        s.recognizer = fresh
        publish(s, DictationPhase.Preparing)
        listen(s)
    }

    private fun fallBackOrFinish(s: Session) {
        if (!s.defaultTried && s.recognitionAvailable) useDefault(s) else finish(s, DictationPhase.Unavailable(DictationUnavailable.Language(s.language)))
    }

    private fun intent(tag: String): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        .putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag)
        .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, app.packageName)

    // endregion

    // region Listening

    private fun listen(s: Session) {
        if (!s.alive() || s.stopping) return
        val r = s.recognizer ?: return fallBackOrFinish(s)
        r.setRecognitionListener(s.listener)
        s.recording = true
        try {
            r.startListening(intent(s.tag))
        } catch (e: Exception) {
            s.recording = false
            fallBackOrFinish(s)
        }
    }

    private fun restart(s: Session, afterMs: Long) {
        main.postDelayed({ if (s.alive() && !s.stopping) listen(s) }, afterMs)
    }

    private fun listener(s: Session) = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            if (!s.alive()) return
            s.busyRetried = false
            // The silence is counted from the moment the mic opened; a restart does not reset it, only new words do.
            if (s.lastWordsAt == null) s.lastWordsAt = now()
            // (After a fall back to the phone's speech service the line changes with it: it never says "on this phone" while it is not.)
            val phase = _state.value.phase
            if (!s.stopping && !(phase is DictationPhase.Listening && phase.onDevice == s.onDevice)) publish(s, DictationPhase.Listening(0.0, s.onDevice))
            scheduleClock(s)
        }

        override fun onBeginningOfSpeech() = Unit

        override fun onRmsChanged(rmsdB: Float) {
            if (!s.alive() || s.stopping) return
            val raw = DictationLevel.fromRms(rmsdB.toDouble())
            s.level = if (raw > s.level) raw else s.level * 0.6 + raw * 0.4
            val t = now()
            val phase = _state.value.phase as? DictationPhase.Listening ?: return
            // About 15 times a second, and only when the bars would visibly move.
            if (t - s.levelAt < LEVEL_INTERVAL_MS || abs(phase.level - s.level) < LEVEL_STEP) return
            s.levelAt = t
            publish(s, DictationPhase.Listening(s.level, s.onDevice))
        }

        override fun onBufferReceived(buffer: ByteArray?) = Unit

        override fun onEndOfSpeech() = Unit

        override fun onEvent(eventType: Int, params: Bundle?) = Unit

        override fun onPartialResults(partialResults: Bundle?) {
            if (!s.alive()) return
            val text = firstResult(partialResults) ?: return
            write(s) { s.draft.setVolatile(text) }
        }

        override fun onResults(results: Bundle?) {
            if (!s.alive()) return
            s.recording = false
            val text = firstResult(results)
            write(s) { s.draft.commit(if (text.isNullOrBlank()) s.draft.volatile else text) }
            if (s.stopping) end(s) else restart(s, RESTART_MS)
        }

        override fun onError(error: Int) {
            if (!s.alive()) return
            s.recording = false
            handleError(s, error)
        }
    }

    private fun firstResult(bundle: Bundle?): String? = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

    /** Changes the dictated words and puts the draft in the box, unless the person has edited it (then nothing is written). */
    private fun write(s: Session, change: () -> Unit) {
        if (s.edited) return
        val before = s.draft.spoken
        change()
        if (s.draft.spoken != before) {
            // New words reset the silence.
            if (s.lastWordsAt != null) s.lastWordsAt = now()
            scheduleClock(s)
        }
        val text = s.draft.text
        if (text != s.lastWritten) {
            s.lastWritten = text
            s.request.onDraft(text)
        }
    }

    private fun handleError(s: Session, error: Int) {
        if (s.stopping) {
            // A stop is on its way: whatever the recognizer says now (ERROR_CLIENT, no match), what shows is final.
            write(s) { s.draft.commit(s.draft.volatile) }
            end(s)
            return
        }
        when (error) {
            // Nothing heard, or a pause: keep what shows and listen again. It counts toward the silence.
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
                write(s) { s.draft.commit(s.draft.volatile) }
                restart(s, RESTART_MS)
            }
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> finish(s, DictationPhase.Denied(DictationPermission.MICROPHONE))
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> fallBackOrFinish(s)
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
                if (!s.busyRetried) { s.busyRetried = true; restart(s, BUSY_RETRY_MS) } else finish(s, DictationPhase.Interrupted)
            SpeechRecognizer.ERROR_AUDIO -> finish(s, DictationPhase.Interrupted)
            // A recognizer that is gone, or a network or server that did not answer: the default recognizer if it was not tried, else stop.
            else -> if (!s.defaultTried && s.onDevice && s.recognitionAvailable) useDefault(s) else finish(s, DictationPhase.Interrupted)
        }
    }

    // endregion

    // region Ending

    /** Stop and keep the words: the recognizer finishes what it is hearing, and the last result is written. */
    private fun stopSession(s: Session) {
        if (s.stopping || s.ended) return
        s.stopping = true
        // The button is a mic again at once; the last words still land (unless the person edits first).
        publish(null, DictationPhase.Idle)
        s.poller?.let { main.removeCallbacks(it) }
        s.clockCheck?.let { main.removeCallbacks(it) }
        if (s.recording) {
            try {
                s.recognizer?.stopListening()
            } catch (e: Exception) {
                write(s) { s.draft.commit(s.draft.volatile) }
                end(s)
                return
            }
            val timeout = Runnable { if (s.alive()) { write(s) { s.draft.commit(s.draft.volatile) }; end(s) } }
            s.finalizeTimeout = timeout
            main.postDelayed(timeout, FINALIZE_MS)
        } else {
            write(s) { s.draft.commit(s.draft.volatile) }
            end(s)
        }
    }

    /** Keep the words, end the session and show [phase] (a refused permission, a language, an interruption). */
    private fun finish(s: Session, phase: DictationPhase) {
        if (!s.alive()) return
        write(s) { s.draft.commit(s.draft.volatile) }
        val box = s.box
        val language = s.language
        end(s)
        publish(box, phase, language)
    }

    /** The recognizer is done: release it (`destroy()`). The phase is whatever was published. */
    private fun end(s: Session) = release(s, cancel = false)

    /** Stop now and write nothing more: `cancel()`, then `destroy()`. */
    private fun cancelSession(s: Session) = release(s, cancel = true)

    private fun release(s: Session, cancel: Boolean) {
        if (s.ended) return
        s.ended = true
        s.clockCheck?.let { main.removeCallbacks(it) }
        s.finalizeTimeout?.let { main.removeCallbacks(it) }
        s.poller?.let { main.removeCallbacks(it) }
        val r = s.recognizer
        s.recognizer = null
        if (cancel) runCatching { r?.cancel() }
        runCatching { r?.destroy() }
        if (session === s) session = null
    }

    /** The 20 s of silence and the 10 min cap ([DictationClock]): checked when the nearer one is due, and again when new words move it. */
    private fun scheduleClock(s: Session) {
        s.clockCheck?.let { main.removeCallbacks(it) }
        val check = Runnable {
            if (!s.alive() || s.stopping) return@Runnable
            if (DictationClock.expiry(s.startedAt, s.lastWordsAt, now()) != null) stopSession(s) else scheduleClock(s)
        }
        s.clockCheck = check
        main.postDelayed(check, DictationClock.nextCheckIn(s.startedAt, s.lastWordsAt, now()).coerceAtLeast(CLOCK_MIN_MS))
    }

    // endregion

    // region State

    private fun publish(s: Session, phase: DictationPhase) = publish(s.box, phase, s.language)

    /** Publishes [phase] for [box] (null: nothing is dictating). Interruptions and unavailable notes go away by themselves after 4 s. */
    private fun publish(box: String?, phase: DictationPhase, language: String = _state.value.language) {
        noteTimer?.let { main.removeCallbacks(it) }
        noteTimer = null
        _state.value = DictationState(if (phase == DictationPhase.Idle) null else box, phase, language)
        if (box == null) return
        when (phase) {
            DictationPhase.Interrupted -> scheduleNoteEnd(box, phase) { publish(null, DictationPhase.Idle) }
            is DictationPhase.Unavailable -> scheduleNoteEnd(box, phase) { _state.value = _state.value.copy(noteHidden = true) }
            else -> Unit
        }
    }

    private fun scheduleNoteEnd(box: String, phase: DictationPhase, then: () -> Unit) {
        val end = Runnable {
            val st = _state.value
            if (st.box == box && st.phase == phase) then()
        }
        noteTimer = end
        main.postDelayed(end, NOTE_MS)
    }

    // endregion

    companion object {
        /** The request code of the microphone permission dialog (lower 16 bits only, as the platform call wants). */
        const val REQUEST_MICROPHONE = 0x4D1C

        /** Listening starts again this soon after a result, so the recognizer is never asked from inside its own callback. */
        private const val RESTART_MS = 150L
        private const val BUSY_RETRY_MS = 500L
        private const val POLL_MS = 3_000L

        /** How long a stop waits for the recognizer's last words before keeping what shows. */
        private const val FINALIZE_MS = 1_800L
        private const val LEVEL_INTERVAL_MS = 66L
        private const val LEVEL_STEP = 0.04
        private const val CLOCK_MIN_MS = 250L
        private const val NOTE_MS = 4_000L
    }
}
