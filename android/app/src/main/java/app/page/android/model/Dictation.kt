package app.page.android.model

import java.util.Locale

// Voice input: speaking fills the message box, and nothing is sent until Send (Designs/voice-input.md). These are
// the pure parts the views and the controller draw from, with the same names and words as the iPhone's
// iOS/Page/Models/Dictation.swift. The recognizer (android.speech) lives in speech/ and never here, so all of this
// is plain Kotlin that JUnit can run.

/** Where one box's dictation is. */
sealed class DictationPhase {
    object Idle : DictationPhase() { override fun toString() = "Idle" }

    /** Permissions and the recognizer are being set up. */
    object Preparing : DictationPhase() { override fun toString() = "Preparing" }

    /** A language model is being fetched by Android (null: no percentage to show). */
    data class Downloading(val fraction: Double?) : DictationPhase()

    /** The microphone is open. [level] is the voice level, 0..1. [onDevice] is false on the phone's own speech service, which may use the network. */
    data class Listening(override val level: Double, val onDevice: Boolean) : DictationPhase()

    data class Denied(val permission: DictationPermission) : DictationPhase()

    data class Unavailable(val reason: DictationUnavailable) : DictationPhase()

    /** Something else took the microphone (a call, an assistant, an alarm). The words so far are kept. */
    object Interrupted : DictationPhase() { override fun toString() = "Interrupted" }

    val isListening: Boolean get() = this is Listening

    /** The mic is open or about to be: the button is a stop button. */
    val isActive: Boolean get() = this is Preparing || this is Downloading || this is Listening

    /** A tap can't start listening until something changes (Settings, the language, the phone). */
    val isBlocked: Boolean get() = this is Denied || this is Unavailable

    /** The voice level while listening, else 0. */
    open val level: Double get() = 0.0
}

enum class DictationPermission {
    MICROPHONE,

    /** iOS's Speech Recognition permission. Android has only the microphone one; the case is here so both phones share one vocabulary. */
    SPEECH,
}

sealed class DictationUnavailable {
    /** No path (on the phone or its speech service) supports this language (its display name). */
    data class Language(val name: String) : DictationUnavailable()

    /** The phone can't turn speech into text on the device at all. */
    object NoOnDevice : DictationUnavailable() { override fun toString() = "NoOnDevice" }

    /** The phone has no speech recognizer of any kind. */
    object NoRecognizer : DictationUnavailable() { override fun toString() = "NoRecognizer" }
}

/**
 * What the boxes read from the app's one dictation controller: which box is dictating, where it is, and the language
 * it listens for. [noteHidden] is set a few seconds after a note that goes away by itself (the mic stays as it is).
 */
data class DictationState(
    val box: String? = null,
    val phase: DictationPhase = DictationPhase.Idle,
    /** The display name of the language being listened for ("English (United Kingdom)"). */
    val language: String = "English",
    val noteHidden: Boolean = false,
) {
    /** This box's phase: the one box that is dictating (or showing a note) sees it, every other sees Idle. */
    fun phase(forBox: String): DictationPhase = if (box == forBox) phase else DictationPhase.Idle
}

/** Every word the voice input shows. One place, so the two phones say the same thing. */
object DictationCopy {
    enum class Tone { LISTENING, QUIET, PROBLEM }

    /** One line above the box: what the mic is doing, or why it can't. */
    data class Line(
        val text: String,
        val tone: Tone,
        /** The line offers Open Settings (a permission was refused). */
        val opensSettings: Boolean = false,
        /** A determinate download shows a thin bar. */
        val progress: Double? = null,
    )

    /** What the phone is called in a sentence: "this phone". */
    const val DEVICE = "phone"

    const val MIC_LABEL = "Dictate"
    const val STOP_LABEL = "Stop dictating"
    /** Announced to TalkBack when the mic opens and when it closes (the same words as the iPhone). */
    const val ANNOUNCE_START = "Listening. Nothing is sent until you tap Send."
    const val ANNOUNCE_STOP = "Stopped listening"
    const val MIC_HINT = "Your words go into the message box. Nothing is sent until you tap Send."
    const val LISTENING_PLACEHOLDER = "Listening…"
    const val OPEN_SETTINGS = "Open Settings"
    const val PREPARING = "Getting ready to listen…"
    const val MICROPHONE_OFF = "Page can't hear you: microphone access is off for Page."
    const val SPEECH_OFF = "Speech recognition is off for Page."
    const val INTERRUPTED = "Stopped listening: something else took the microphone. Your words are kept."
    const val NO_RECOGNIZER = "This phone has no speech recognizer, so the mic is off."

    /**
     * [send] is the box's own button: "Send", "Answer", or "Start" on New task. Off the device the phone's own speech
     * service listens, and the line says so the whole time.
     */
    fun listening(device: String = DEVICE, send: String = "Send", onDevice: Boolean = true): String =
        (if (onDevice) "Listening on this $device" else "Listening with this $device's speech service") + " · nothing is sent until you tap $send"

    fun downloading(language: String, device: String = DEVICE, fraction: Double?): String {
        val head = "Getting $language speech for this $device"
        return if (fraction == null) "$head…" else "$head · ${percent(fraction)}"
    }

    fun language(name: String, device: String = DEVICE): String = "Speech in $name can't be turned into text on this $device."

    fun noOnDevice(device: String = DEVICE): String = "This $device can't turn speech into text on the phone itself, so Page leaves the mic off."

    /** Whole percent, clamped: 0.404 is "40%". */
    fun percent(fraction: Double): String = "${(fraction.coerceIn(0.0, 1.0) * 100).toInt()}%"

    /** The line for a phase, or null when the box shows none (idle). */
    fun line(phase: DictationPhase, device: String = DEVICE, language: String = "English", send: String = "Send"): Line? = when (phase) {
        DictationPhase.Idle -> null
        DictationPhase.Preparing -> Line(PREPARING, Tone.QUIET)
        is DictationPhase.Downloading -> Line(downloading(language, device, phase.fraction), Tone.QUIET, progress = phase.fraction)
        is DictationPhase.Listening -> Line(listening(device, send, phase.onDevice), Tone.LISTENING)
        is DictationPhase.Denied -> when (phase.permission) {
            DictationPermission.MICROPHONE -> Line(MICROPHONE_OFF, Tone.PROBLEM, opensSettings = true)
            DictationPermission.SPEECH -> Line(SPEECH_OFF, Tone.PROBLEM, opensSettings = true)
        }
        is DictationPhase.Unavailable -> when (val why = phase.reason) {
            is DictationUnavailable.Language -> Line(this.language(why.name, device), Tone.QUIET)
            DictationUnavailable.NoOnDevice -> Line(noOnDevice(device), Tone.QUIET)
            DictationUnavailable.NoRecognizer -> Line(NO_RECOGNIZER, Tone.QUIET)
        }
        DictationPhase.Interrupted -> Line(INTERRUPTED, Tone.QUIET)
    }
}

/**
 * The words of one dictation, over the draft the person had. The text is `base + joiner + committed + volatile`:
 * [base] is exactly what was typed (never changed, newlines and all), [committed] the words the recognizer has
 * finished, [volatile] the words still changing. The spoken part is one line: every run of whitespace, newlines
 * included, is a single space, and it is never empty-but-separated, so the text can never be the old draft plus a
 * Return (`DraftSubmit.isReturnKey`) and dictation can never send.
 */
class DictationDraft(val base: String) {
    /** The finished words, joined by single spaces. */
    var committed: String = ""
        private set

    /** The words still changing. */
    var volatile: String = ""
        private set

    /** What has been said so far (finished and changing), or "". */
    val spoken: String get() = join(committed, volatile)

    /** The draft as the box should show it. */
    val text: String
        get() {
            val s = spoken
            return if (s.isEmpty()) base else base + joiner(base) + s
        }

    /** The recognizer's current guess for the words still changing; it replaces the last one. */
    fun setVolatile(s: String) {
        volatile = oneLine(s)
    }

    /** The recognizer finished these words: they are kept, and nothing is changing any more. */
    fun commit(s: String) {
        volatile = ""
        committed = join(committed, oneLine(s))
    }

    /** Stop: the words still changing are kept as they stand. The final text. */
    fun finish(): String {
        commit(volatile)
        return text
    }

    companion object {
        /** One space between the draft and the first spoken word, unless the draft is empty or already ends in whitespace. */
        fun joiner(base: String): String = if (base.isEmpty() || isSpace(base.last())) "" else " "

        /** The spoken words as one line: every run of whitespace (a newline too) is one space, none at the ends. */
        fun oneLine(s: String): String {
            val out = StringBuilder(s.length)
            var pendingSpace = false
            for (ch in s) {
                if (isSpace(ch)) { pendingSpace = out.isNotEmpty() } else {
                    if (pendingSpace) out.append(' ')
                    pendingSpace = false
                    out.append(ch)
                }
            }
            return out.toString()
        }

        private fun join(a: String, b: String): String = if (a.isEmpty()) b else if (b.isEmpty()) a else "$a $b"

        private fun isSpace(ch: Char): Boolean = ch.isWhitespace() || ch == '\u0085'
    }
}

/** Has the person changed the box since dictation last wrote it? Then listening stops and the late results are dropped. */
object DictationGuard {
    fun userEdited(current: String, lastWritten: String): Boolean = current != lastWritten
}

/** The voice level on screen: the recognizer's `onRmsChanged` dB, -2 to 10, as 0 to 1. */
object DictationLevel {
    const val MIN_DB = -2.0
    const val MAX_DB = 10.0

    fun fromRms(db: Double): Double = if (db.isNaN()) 0.0 else ((db - MIN_DB) / (MAX_DB - MIN_DB)).coerceIn(0.0, 1.0)
}

/** How the on-device recognizer stands for the phone's language (API 33+ can ask; 31 and 32 can't, so it is Unknown). */
enum class DictationOnDevice { Installed, Downloadable, Unsupported, Unknown }

/** Which recognizer to use. */
sealed class DictationEngine {
    /** `createOnDeviceSpeechRecognizer`: the audio stays on the phone. */
    object OnDevice : DictationEngine() { override fun toString() = "OnDevice" }

    /** The on-device recognizer, once the phone has fetched the language (API 33+). */
    object OnDeviceAfterDownload : DictationEngine() { override fun toString() = "OnDeviceAfterDownload" }

    /** `createSpeechRecognizer`: the phone's default recognizer, which may be a server (decision D1). */
    object Default : DictationEngine() { override fun toString() = "Default" }

    data class Unavailable(val reason: DictationUnavailable) : DictationEngine()
}

/**
 * D1, on the device first and then the phone's own speech service: the on-device recognizer when the phone has one
 * (API 31+) and its language is, or can be, installed; the default recognizer otherwise; and no mic when there is
 * neither. A language missing on the device is not "unavailable" here: it falls to the default recognizer, and the
 * language line is only for a language that no path supports (the recognizer's own error says so).
 */
object DictationEngineChoice {
    const val ON_DEVICE_API = 31
    const val SUPPORT_CHECK_API = 33
    const val DOWNLOAD_PROGRESS_API = 34

    fun pick(apiLevel: Int, onDeviceAvailable: Boolean, onDeviceLanguage: DictationOnDevice, recognitionAvailable: Boolean): DictationEngine {
        if (apiLevel >= ON_DEVICE_API && onDeviceAvailable) {
            when (onDeviceLanguage) {
                DictationOnDevice.Installed, DictationOnDevice.Unknown -> return DictationEngine.OnDevice
                DictationOnDevice.Downloadable -> return if (apiLevel >= SUPPORT_CHECK_API) DictationEngine.OnDeviceAfterDownload else DictationEngine.OnDevice
                DictationOnDevice.Unsupported -> Unit
            }
        }
        return if (recognitionAvailable) DictationEngine.Default else DictationEngine.Unavailable(DictationUnavailable.NoRecognizer)
    }
}

/** Matching the phone's language to the ones a recognizer lists, as BCP 47 tags ("en-GB", "en-US", "af"). */
object DictationLocale {
    data class Support(val state: DictationOnDevice, /** The listed tag to listen for (and to download), or null when none. */ val tag: String?)

    /**
     * The listed tag nearest to [wanted]: the same tag, else one with the same language and region, else the same
     * language in another region (the same script when both say one), preferring the bare language ("en") and then
     * the shortest, first by name. Null when no listed tag is the phone's language at all.
     */
    fun nearest(wanted: String, available: Collection<String>): String? {
        val want = parse(wanted) ?: return null
        val candidates = available.mapNotNull { tag -> parse(tag)?.let { tag to it } }.filter { (_, l) -> l.language == want.language && (l.script.isEmpty() || want.script.isEmpty() || l.script == want.script) }
        if (candidates.isEmpty()) return null
        candidates.firstOrNull { (_, l) -> l.country == want.country && l.script == want.script }?.let { return it.first }
        candidates.firstOrNull { (_, l) -> l.country == want.country }?.let { return it.first }
        return candidates.sortedWith(compareBy({ it.second.country.isNotEmpty() }, { it.first.length }, { it.first })).first().first
    }

    /** How the on-device recognizer stands for [wanted], from what it lists as installed, supported and pending. */
    fun support(wanted: String, installed: Collection<String>, supported: Collection<String>, pending: Collection<String>): Support {
        nearest(wanted, installed)?.let { return Support(DictationOnDevice.Installed, it) }
        nearest(wanted, supported + pending)?.let { return Support(DictationOnDevice.Downloadable, it) }
        return Support(DictationOnDevice.Unsupported, null)
    }

    /** The language's name in the phone's own language ("English (United Kingdom)"). */
    fun displayName(tag: String, inLocale: Locale = Locale.getDefault()): String {
        val name = Locale.forLanguageTag(tag.replace('_', '-')).getDisplayName(inLocale)
        return if (name.isNullOrBlank()) tag else name
    }

    private data class Parsed(val language: String, val script: String, val country: String)

    private fun parse(tag: String): Parsed? {
        val l = Locale.forLanguageTag(tag.trim().replace('_', '-'))
        if (l.language.isEmpty()) return null
        val language = l.language.lowercase()
        val country = l.country.uppercase()
        // Chinese says its script by region when the tag does not: Taiwan, Hong Kong and Macau write Traditional.
        val script = l.script.ifEmpty { if (language == "zh") (if (country in setOf("TW", "HK", "MO")) "Hant" else "Hans") else "" }
        return Parsed(language, script.lowercase(), country)
    }
}

/**
 * Listening stops by itself after [SILENCE_LIMIT_MS] with no new words, and after [CAP_MS] in all. Pure functions of
 * millisecond timestamps. The silence is counted from when the microphone opened ([lastWordsAt] null: not listening
 * yet, as while a language downloads), and a recognizer's "no match" or "speech timeout" does not reset it.
 */
object DictationClock {
    const val SILENCE_LIMIT_MS = 20_000L
    const val CAP_MS = 600_000L

    enum class Expiry { SILENCE, CAP }

    /** Why listening should stop now, or null. The cap wins when both are due. */
    fun expiry(startedAt: Long, lastWordsAt: Long?, now: Long): Expiry? = when {
        now - startedAt >= CAP_MS -> Expiry.CAP
        lastWordsAt != null && now - lastWordsAt >= SILENCE_LIMIT_MS -> Expiry.SILENCE
        else -> null
    }

    /** When to look again (milliseconds from [now]): the nearer of the two limits, never negative. */
    fun nextCheckIn(startedAt: Long, lastWordsAt: Long?, now: Long): Long {
        val cap = startedAt + CAP_MS
        val due = if (lastWordsAt == null) cap else minOf(cap, lastWordsAt + SILENCE_LIMIT_MS)
        return (due - now).coerceAtLeast(0L)
    }
}
