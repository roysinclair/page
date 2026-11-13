package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Locale
import kotlin.random.Random

/**
 * Voice input's pure logic (Designs/voice-input.md): the draft's joining and one-line rule, the Return-key trap, the
 * edit guard, the engine choice, the copy, the level, the locale match and the silence clock. Checks that need the
 * recognizer itself live on the device, not here.
 */
class DictationTest {

    // MARK: - DictationDraft: joining

    @Test fun `the first words after an empty draft have no leading space`() {
        val d = DictationDraft("")
        d.setVolatile("hello")
        assertEquals("hello", d.text)
        assertEquals("", DictationDraft.joiner(""))
    }

    @Test fun `a draft that ends in a space or a newline gets no extra joiner`() {
        assertEquals("", DictationDraft.joiner("Fix the "))
        assertEquals("", DictationDraft.joiner("Fix the\n"))
        assertEquals("", DictationDraft.joiner("Fix the\t"))

        val spaced = DictationDraft("Fix the ")
        spaced.setVolatile("bug")
        assertEquals("Fix the bug", spaced.text)

        val lined = DictationDraft("Fix the\n")
        lined.setVolatile("bug")
        assertEquals("Fix the\nbug", lined.text)
    }

    @Test fun `a draft with no trailing space gets exactly one joining space`() {
        assertEquals(" ", DictationDraft.joiner("Fix the"))
        val d = DictationDraft("Fix the")
        d.setVolatile("bug")
        assertEquals("Fix the bug", d.text)
    }

    @Test fun `the joiner is only added once there are words`() {
        val d = DictationDraft("Fix the")
        assertEquals("Fix the", d.text)
        assertEquals("", d.spoken)
        d.setVolatile("")
        assertEquals("Fix the", d.text)
        d.commit("")
        assertEquals("Fix the", d.text)
        d.setVolatile("   ")
        assertEquals("Fix the", d.text)
    }

    @Test fun `an empty draft with nothing said is empty`() {
        val d = DictationDraft("")
        assertEquals("", d.text)
        assertEquals("", d.finish())
    }

    // MARK: - DictationDraft: volatile and committed

    @Test fun `a volatile update replaces the volatile part only`() {
        val d = DictationDraft("")
        d.setVolatile("a")
        d.setVolatile("b")
        assertEquals("b", d.volatile)
        assertEquals("b", d.text)
        d.setVolatile("b c d")
        assertEquals("b c d", d.text)
    }

    @Test fun `commits accumulate and clear the volatile part`() {
        val d = DictationDraft("")
        d.setVolatile("hello")
        d.commit("hello there")
        assertEquals("hello there", d.committed)
        assertEquals("", d.volatile)
        assertEquals("hello there", d.text)
        d.setVolatile("general")
        assertEquals("hello there general", d.text)
        d.commit("general kenobi")
        assertEquals("hello there general kenobi", d.committed)
        assertEquals("hello there general kenobi", d.text)
    }

    @Test fun `a commit of nothing keeps what was committed`() {
        val d = DictationDraft("")
        d.commit("one")
        d.commit("")
        assertEquals("one", d.committed)
        d.commit("   ")
        assertEquals("one", d.committed)
    }

    @Test fun `spoken words join after the base with one space, volatile after committed`() {
        val d = DictationDraft("Base")
        d.commit("first")
        d.setVolatile("second")
        assertEquals("first second", d.spoken)
        assertEquals("Base first second", d.text)
    }

    // MARK: - DictationDraft: one line

    @Test fun `newlines and CRLF in a result become single spaces`() {
        assertEquals("a b", DictationDraft.oneLine("a\nb"))
        assertEquals("a b", DictationDraft.oneLine("a\r\nb"))
        assertEquals("a b", DictationDraft.oneLine("a\rb"))
        assertEquals("a b c", DictationDraft.oneLine("a\n\nb\r\n\r\nc"))
    }

    @Test fun `runs of whitespace collapse to one space and results are trimmed`() {
        assertEquals("a b", DictationDraft.oneLine("a    b"))
        assertEquals("a b", DictationDraft.oneLine("a \t \n  b"))
        assertEquals("Hello world", DictationDraft.oneLine("  Hello \r\n  world  "))
        assertEquals("x", DictationDraft.oneLine("\n\tx\n"))
        assertEquals("a b", DictationDraft.oneLine("a\u0085b"))
    }

    @Test fun `a result that is only whitespace becomes empty`() {
        assertEquals("", DictationDraft.oneLine("\n"))
        assertEquals("", DictationDraft.oneLine(" \n "))
        assertEquals("", DictationDraft.oneLine("\r\n\r\n"))
        assertEquals("", DictationDraft.oneLine(""))
    }

    @Test fun `a newline-only result leaves the draft exactly as it was`() {
        val d = DictationDraft("abc")
        d.setVolatile("\n")
        assertEquals("abc", d.text)
        d.commit(" \n ")
        assertEquals("abc", d.text)
        assertEquals("", d.committed)
    }

    @Test fun `setVolatile and commit store the one-line form`() {
        val d = DictationDraft("")
        d.setVolatile("one\ntwo")
        assertEquals("one two", d.volatile)
        d.commit("three\r\nfour  ")
        assertEquals("three four", d.committed)
    }

    // MARK: - DictationDraft: finish and base

    @Test fun `finish keeps the words still changing and returns the final text`() {
        val d = DictationDraft("Fix")
        d.commit("the")
        d.setVolatile("bug")
        assertEquals("Fix the bug", d.finish())
        assertEquals("", d.volatile)
        assertEquals("Fix the bug", d.text)
    }

    @Test fun `finish with only whitespace volatile returns the base`() {
        val d = DictationDraft("Fix ")
        d.setVolatile("\n")
        assertEquals("Fix ", d.finish())
    }

    @Test fun `the base is kept exactly, newlines and all`() {
        val d = DictationDraft("Line one\n\nLine two  ")
        assertEquals("Line one\n\nLine two  ", d.text)
        d.commit("spoken")
        assertEquals("Line one\n\nLine two  spoken", d.text)
        assertEquals("Line one\n\nLine two  spoken", d.finish())
    }

    // MARK: - The Return-key trap

    private fun trace(base: String, steps: List<Pair<Boolean, String>>): List<String> {
        val d = DictationDraft(base)
        val texts = mutableListOf(d.text)
        for ((commit, s) in steps) {
            if (commit) d.commit(s) else d.setVolatile(s)
            texts += d.text
        }
        return texts
    }

    private fun assertNoReturnKey(label: String, texts: List<String>) {
        for (i in 0 until texts.size - 1) {
            assertFalse("$label: step $i '${texts[i]}' -> '${texts[i + 1]}' looks like Return",
                DraftSubmit.isReturnKey(texts[i], texts[i + 1]))
        }
    }

    @Test fun `results that are just a newline never look like the Return key`() {
        for (base in listOf("", "abc", "abc ", "abc\n")) {
            assertNoReturnKey("base '$base', newlines", trace(base, listOf(
                false to "\n", false to " \n ", true to "\n", true to " \n ", false to "\n\n", true to "\r\n",
            )))
        }
    }

    @Test fun `send with a newline never looks like the Return key`() {
        assertNoReturnKey("send\\n", trace("", listOf(false to "send\n", true to "send\n", false to "send\n\n", true to "send\n")))
        assertNoReturnKey("send\\n on a draft", trace("Please", listOf(false to "send\n", true to "send\n")))
    }

    @Test fun `a dictated update never gains a trailing newline`() {
        val texts = trace("Reply", listOf(false to "hi", true to "hi there\n", false to "later\n", true to "later\n"))
        for (t in texts) assertFalse("'$t' ends with a newline", t.endsWith("\n"))
    }

    @Test fun `every pair of consecutive texts across many update sequences is not the Return key`() {
        val pool = listOf("", " ", "\n", " \n ", "send\n", "send", "\r\n", "a", "b c", "\n\n", "send\n\n", "x\ty", "  ", "ok\r\n")
        val bases = listOf("", "abc", "abc ", "abc\n", "abc\n\n", " ", "\n", "Please ")
        val rng = Random(20261113)
        for (base in bases) {
            for (run in 0 until 40) {
                val steps = (0 until 25).map { (rng.nextInt(2) == 0) to pool[rng.nextInt(pool.size)] }
                val texts = trace(base, steps)
                assertNoReturnKey("base '$base' run $run", texts)
                for (t in texts) {
                    assertTrue("the text starts with the base: '$t'", t.startsWith(base))
                    assertFalse("the spoken part after the base has no newline: '$t'", t.removePrefix(base).contains('\n'))
                }
            }
        }
    }

    @Test fun `the Return-key check does fire on a real Return, so the trap test can fail`() {
        assertTrue(DraftSubmit.isReturnKey("hello", "hello\n"))
        assertFalse(DraftSubmit.isReturnKey("hello", "hello"))
        assertFalse(DraftSubmit.isReturnKey("hello", "hello \n"))
    }

    // MARK: - DictationGuard

    @Test fun `the same text is not an edit`() {
        assertFalse(DictationGuard.userEdited("Fix the bug", "Fix the bug"))
        assertFalse(DictationGuard.userEdited("", ""))
        assertFalse(DictationGuard.userEdited("Line\n", "Line\n"))
    }

    @Test fun `changed text is an edit`() {
        assertTrue(DictationGuard.userEdited("Fix the bug.", "Fix the bug"))
        assertTrue(DictationGuard.userEdited("Fix the bug ", "Fix the bug"))
        assertTrue(DictationGuard.userEdited("", "a"))
        assertTrue(DictationGuard.userEdited("Line\n", "Line"))
        assertTrue(DictationGuard.userEdited("abc", "ABC"))
    }

    // MARK: - DictationEngineChoice

    private fun pick(api: Int, on: Boolean, lang: DictationOnDevice, rec: Boolean) =
        DictationEngineChoice.pick(api, on, lang, rec)

    @Test fun `API 26 to 30 use the default recognizer when there is one, else no mic`() {
        for (api in 26..30) {
            assertEquals("API $api with recognition", DictationEngine.Default, pick(api, true, DictationOnDevice.Installed, true))
            assertEquals("API $api, no recognition", DictationEngine.Unavailable(DictationUnavailable.NoRecognizer),
                pick(api, false, DictationOnDevice.Installed, false))
        }
    }

    @Test fun `API 26 to 30 never use on-device, whatever the language`() {
        for (api in 26..30) {
            for (lang in DictationOnDevice.values()) {
                assertEquals("API $api, $lang", DictationEngine.Default, pick(api, true, lang, true))
            }
        }
    }

    @Test fun `API 31 and 32 use on-device for an installed or unknown language`() {
        for (api in listOf(31, 32)) {
            assertEquals("API $api installed", DictationEngine.OnDevice, pick(api, true, DictationOnDevice.Installed, true))
            assertEquals("API $api unknown", DictationEngine.OnDevice, pick(api, true, DictationOnDevice.Unknown, true))
        }
    }

    @Test fun `API 33 and up with a downloadable language use on-device after the download`() {
        for (api in listOf(33, 34, 35, 36)) {
            assertEquals("API $api downloadable", DictationEngine.OnDeviceAfterDownload,
                pick(api, true, DictationOnDevice.Downloadable, true))
            assertEquals("API $api downloadable, no default recognizer", DictationEngine.OnDeviceAfterDownload,
                pick(api, true, DictationOnDevice.Downloadable, false))
        }
    }

    @Test fun `an installed or unknown language is on-device from API 31 up`() {
        for (api in listOf(31, 33, 34, 35)) {
            assertEquals("API $api installed", DictationEngine.OnDevice, pick(api, true, DictationOnDevice.Installed, true))
            assertEquals("API $api unknown", DictationEngine.OnDevice, pick(api, true, DictationOnDevice.Unknown, true))
        }
    }

    @Test fun `an unsupported language falls to the default recognizer, or no mic`() {
        for (api in listOf(26, 30, 31, 32, 33, 34, 35)) {
            assertEquals("API $api unsupported, recognizer", DictationEngine.Default,
                pick(api, true, DictationOnDevice.Unsupported, true))
            assertEquals("API $api unsupported, no recognizer", DictationEngine.Unavailable(DictationUnavailable.NoRecognizer),
                pick(api, true, DictationOnDevice.Unsupported, false))
        }
    }

    @Test fun `no on-device recognizer means the default recognizer, or no mic, for every language`() {
        for (api in listOf(26, 31, 33, 35)) {
            for (lang in DictationOnDevice.values()) {
                assertEquals("API $api $lang, recognizer", DictationEngine.Default, pick(api, false, lang, true))
                assertEquals("API $api $lang, no recognizer", DictationEngine.Unavailable(DictationUnavailable.NoRecognizer),
                    pick(api, false, lang, false))
            }
        }
    }

    @Test fun `on-device comes before the default recognizer`() {
        assertEquals(DictationEngine.OnDevice, pick(35, true, DictationOnDevice.Installed, true))
        assertEquals(DictationEngine.OnDevice, pick(31, true, DictationOnDevice.Unknown, true))
        assertEquals(DictationEngine.OnDeviceAfterDownload, pick(33, true, DictationOnDevice.Downloadable, true))
    }

    @Test fun `on-device does not need the default recognizer to exist`() {
        assertEquals(DictationEngine.OnDevice, pick(31, true, DictationOnDevice.Installed, false))
    }

    @Test fun `the API thresholds are 31, 33 and 34`() {
        assertEquals(31, DictationEngineChoice.ON_DEVICE_API)
        assertEquals(33, DictationEngineChoice.SUPPORT_CHECK_API)
        assertEquals(34, DictationEngineChoice.DOWNLOAD_PROGRESS_API)
    }

    // MARK: - DictationPhase helpers

    @Test fun `only Listening is listening, and its level is the voice level`() {
        assertTrue(DictationPhase.Listening(0.4, true).isListening)
        assertFalse(DictationPhase.Preparing.isListening)
        assertFalse(DictationPhase.Downloading(0.5).isListening)
        assertFalse(DictationPhase.Idle.isListening)
        assertEquals(0.4, DictationPhase.Listening(0.4, true).level, 0.0)
        assertEquals(0.0, DictationPhase.Idle.level, 0.0)
        assertEquals(0.0, DictationPhase.Preparing.level, 0.0)
        assertEquals(0.0, DictationPhase.Denied(DictationPermission.MICROPHONE).level, 0.0)
    }

    @Test fun `active is the mic open or about to be`() {
        assertTrue(DictationPhase.Preparing.isActive)
        assertTrue(DictationPhase.Downloading(null).isActive)
        assertTrue(DictationPhase.Downloading(0.3).isActive)
        assertTrue(DictationPhase.Listening(0.0, false).isActive)
        assertFalse(DictationPhase.Idle.isActive)
        assertFalse(DictationPhase.Interrupted.isActive)
        assertFalse(DictationPhase.Denied(DictationPermission.SPEECH).isActive)
        assertFalse(DictationPhase.Unavailable(DictationUnavailable.NoRecognizer).isActive)
    }

    @Test fun `blocked is denied or unavailable`() {
        assertTrue(DictationPhase.Denied(DictationPermission.MICROPHONE).isBlocked)
        assertTrue(DictationPhase.Denied(DictationPermission.SPEECH).isBlocked)
        assertTrue(DictationPhase.Unavailable(DictationUnavailable.NoOnDevice).isBlocked)
        assertTrue(DictationPhase.Unavailable(DictationUnavailable.Language("Afrikaans")).isBlocked)
        assertFalse(DictationPhase.Listening(0.0, true).isBlocked)
        assertFalse(DictationPhase.Preparing.isBlocked)
        assertFalse(DictationPhase.Interrupted.isBlocked)
        assertFalse(DictationPhase.Idle.isBlocked)
    }

    @Test fun `the box sees its own phase and Idle everywhere else`() {
        val s = DictationState(box = "room", phase = DictationPhase.Listening(0.2, true))
        assertEquals(DictationPhase.Listening(0.2, true), s.phase("room"))
        assertEquals(DictationPhase.Idle, s.phase("reply"))
        assertEquals(DictationPhase.Idle, DictationState().phase("room"))
    }

    // MARK: - DictationCopy: lines per phase

    private fun line(p: DictationPhase, language: String = "English", send: String = "Send") =
        DictationCopy.line(p, language = language, send = send)

    @Test fun `idle has no line`() {
        assertNull(line(DictationPhase.Idle))
    }

    @Test fun `preparing is a quiet getting-ready line`() {
        val l = line(DictationPhase.Preparing)!!
        assertEquals("Getting ready to listen…", l.text)
        assertEquals(DictationCopy.Tone.QUIET, l.tone)
        assertFalse(l.opensSettings)
        assertNull(l.progress)
    }

    @Test fun `listening is teal and has no settings or progress`() {
        val l = line(DictationPhase.Listening(0.5, true))!!
        assertEquals(DictationCopy.Tone.LISTENING, l.tone)
        assertFalse(l.opensSettings)
        assertNull(l.progress)
    }

    @Test fun `a refused microphone is a problem line that opens Settings`() {
        val l = line(DictationPhase.Denied(DictationPermission.MICROPHONE))!!
        assertEquals("Page can't hear you: microphone access is off for Page.", l.text)
        assertEquals(DictationCopy.Tone.PROBLEM, l.tone)
        assertTrue(l.opensSettings)
    }

    @Test fun `refused speech recognition is a problem line that opens Settings`() {
        val l = line(DictationPhase.Denied(DictationPermission.SPEECH))!!
        assertEquals("Speech recognition is off for Page.", l.text)
        assertEquals(DictationCopy.Tone.PROBLEM, l.tone)
        assertTrue(l.opensSettings)
    }

    @Test fun `a download is quiet and carries its fraction as the progress`() {
        val l = line(DictationPhase.Downloading(0.4), language = "English (United Kingdom)")!!
        assertEquals("Getting English (United Kingdom) speech for this phone · 40%", l.text)
        assertEquals(DictationCopy.Tone.QUIET, l.tone)
        assertEquals(0.4, l.progress!!, 0.0)
        assertFalse(l.opensSettings)
    }

    @Test fun `a download with no fraction shows no percentage and no progress`() {
        val l = line(DictationPhase.Downloading(null), language = "Afrikaans")!!
        assertEquals("Getting Afrikaans speech for this phone…", l.text)
        assertNull(l.progress)
        assertEquals(DictationCopy.Tone.QUIET, l.tone)
    }

    @Test fun `a language with no path is a quiet line that names the language`() {
        val l = line(DictationPhase.Unavailable(DictationUnavailable.Language("Afrikaans")))!!
        assertEquals("Speech in Afrikaans can't be turned into text on this phone.", l.text)
        assertEquals(DictationCopy.Tone.QUIET, l.tone)
        assertFalse(l.opensSettings)
    }

    @Test fun `no on-device speech is a quiet line`() {
        val l = line(DictationPhase.Unavailable(DictationUnavailable.NoOnDevice))!!
        assertEquals("This phone can't turn speech into text on the phone itself, so Page leaves the mic off.", l.text)
        assertEquals(DictationCopy.Tone.QUIET, l.tone)
        assertFalse(l.opensSettings)
    }

    @Test fun `no recognizer is a quiet line with the exact words`() {
        val l = line(DictationPhase.Unavailable(DictationUnavailable.NoRecognizer))!!
        assertEquals("This phone has no speech recognizer, so the mic is off.", l.text)
        assertEquals(DictationCopy.Tone.QUIET, l.tone)
        assertFalse(l.opensSettings)
    }

    @Test fun `an interruption is a quiet line that keeps the words`() {
        val l = line(DictationPhase.Interrupted)!!
        assertEquals("Stopped listening: something else took the microphone. Your words are kept.", l.text)
        assertEquals(DictationCopy.Tone.QUIET, l.tone)
    }

    @Test fun `the fixed words are exact`() {
        assertEquals("Dictate", DictationCopy.MIC_LABEL)
        assertEquals("Stop dictating", DictationCopy.STOP_LABEL)
        assertEquals("Listening. Nothing is sent until you tap Send.", DictationCopy.ANNOUNCE_START)
        assertEquals("Stopped listening", DictationCopy.ANNOUNCE_STOP)
        assertEquals("Your words go into the message box. Nothing is sent until you tap Send.", DictationCopy.MIC_HINT)
        assertEquals("Listening…", DictationCopy.LISTENING_PLACEHOLDER)
        assertEquals("Open Settings", DictationCopy.OPEN_SETTINGS)
        assertEquals("phone", DictationCopy.DEVICE)
    }

    // MARK: - DictationCopy: listening line

    @Test fun `listening on the device says so`() {
        assertEquals("Listening on this phone · nothing is sent until you tap Send", DictationCopy.listening())
        assertEquals("Listening on this iPhone · nothing is sent until you tap Send", DictationCopy.listening("iPhone"))
    }

    @Test fun `listening on the phone's speech service says so the whole time`() {
        assertEquals(
            "Listening with this phone's speech service · nothing is sent until you tap Send",
            DictationCopy.listening(onDevice = false),
        )
        assertEquals(
            "Listening with this phone's speech service · nothing is sent until you tap Send",
            line(DictationPhase.Listening(0.0, false))!!.text,
        )
    }

    @Test fun `the box's own send word is used on both lines`() {
        assertEquals("Listening on this phone · nothing is sent until you tap Start", DictationCopy.listening(send = "Start"))
        assertEquals("Listening on this phone · nothing is sent until you tap Submit all", DictationCopy.listening(send = "Submit all"))
        assertEquals("Listening on this phone · nothing is sent until you tap Answer", DictationCopy.listening(send = "Answer"))
        assertEquals(
            "Listening with this phone's speech service · nothing is sent until you tap Start",
            DictationCopy.listening(send = "Start", onDevice = false),
        )
        assertTrue(line(DictationPhase.Listening(0.1, true), send = "Start")!!.text.endsWith("until you tap Start"))
    }

    // MARK: - DictationCopy: percent

    @Test fun `percent is whole and clamped`() {
        assertEquals("40%", DictationCopy.percent(0.404))
        assertEquals("100%", DictationCopy.percent(1.2))
        assertEquals("0%", DictationCopy.percent(-1.0))
        assertEquals("0%", DictationCopy.percent(0.0))
        assertEquals("100%", DictationCopy.percent(1.0))
        assertEquals("57%", DictationCopy.percent(0.5799))
    }

    // MARK: - DictationCopy: other lines

    @Test fun `the language line names the language on this device`() {
        assertEquals("Speech in Afrikaans can't be turned into text on this phone.", DictationCopy.language("Afrikaans"))
        assertEquals("Speech in Afrikaans can't be turned into text on this iPad.", DictationCopy.language("Afrikaans", device = "iPad"))
    }

    @Test fun `the download line uses the device word`() {
        assertEquals("Getting English speech for this iPad · 5%", DictationCopy.downloading("English", "iPad", 0.05))
        assertEquals("Getting English speech for this iPad…", DictationCopy.downloading("English", "iPad", null))
    }

    @Test fun `the no-on-device line uses the device word`() {
        assertEquals(
            "This iPad can't turn speech into text on the phone itself, so Page leaves the mic off.",
            DictationCopy.noOnDevice("iPad"),
        )
    }

    // MARK: - DictationLevel

    @Test fun `the voice level maps minus 2 to 10 dB onto 0 to 1, clamped`() {
        assertEquals(0.0, DictationLevel.fromRms(-2.0), 1e-9)
        assertEquals(1.0, DictationLevel.fromRms(10.0), 1e-9)
        assertEquals(0.5, DictationLevel.fromRms(4.0), 1e-9)
        assertEquals(0.0, DictationLevel.fromRms(-5.0), 0.0)
        assertEquals(1.0, DictationLevel.fromRms(20.0), 0.0)
        assertEquals(0.0, DictationLevel.fromRms(Double.NEGATIVE_INFINITY), 0.0)
        assertEquals(1.0, DictationLevel.fromRms(Double.POSITIVE_INFINITY), 0.0)
        assertEquals(0.0, DictationLevel.fromRms(Double.NaN), 0.0)
        assertEquals(-2.0, DictationLevel.MIN_DB, 0.0)
        assertEquals(10.0, DictationLevel.MAX_DB, 0.0)
    }

    // MARK: - DictationLocale

    @Test fun `an exact tag wins and is returned as listed`() {
        assertEquals("en-GB", DictationLocale.nearest("en-GB", listOf("en-US", "en-GB")))
        assertEquals("EN-gb", DictationLocale.nearest("en-GB", listOf("EN-gb")))
        assertEquals("en-GB", DictationLocale.nearest("en_GB", listOf("en-GB")))
    }

    @Test fun `en-ZA matches a listed English region when en-ZA is not offered`() {
        assertEquals("en-GB", DictationLocale.nearest("en-ZA", listOf("en-US", "en-GB")))
        assertEquals("en-AU", DictationLocale.nearest("en-ZA", listOf("en-US", "en-AU")))
    }

    @Test fun `the bare language is preferred over a region`() {
        assertEquals("en", DictationLocale.nearest("en-GB", listOf("en-US", "en")))
        assertEquals("en", DictationLocale.nearest("en-GB", listOf("en", "en-US")))
    }

    @Test fun `a bare wanted language takes the shortest, then first by name, region`() {
        assertEquals("en-GB", DictationLocale.nearest("en", listOf("en-US", "en-GB")))
        assertEquals("en", DictationLocale.nearest("en", listOf("en-US", "en")))
    }

    @Test fun `no listed tag in the phone's language gives null`() {
        assertNull(DictationLocale.nearest("af", listOf("en-GB", "en-US")))
        assertNull(DictationLocale.nearest("en-GB", emptyList()))
        assertNull(DictationLocale.nearest("", listOf("en")))
    }

    @Test fun `Chinese matches by script when both say one`() {
        assertEquals("zh-Hant-TW", DictationLocale.nearest("zh-TW", listOf("zh-Hans", "zh-Hant-TW")))
        assertEquals("zh-TW", DictationLocale.nearest("zh-HK", listOf("zh-TW", "zh-CN")))
        assertNull("Simplified is not matched by Traditional alone", DictationLocale.nearest("zh-CN", listOf("zh-TW", "zh-Hant")))
    }

    @Test fun `support says installed first, then downloadable, then unsupported`() {
        val installed = DictationLocale.support("en-ZA", listOf("en-GB"), listOf("af-ZA"), emptyList())
        assertEquals(DictationOnDevice.Installed, installed.state)
        assertEquals("en-GB", installed.tag)

        val supported = DictationLocale.support("af-ZA", listOf("en-GB"), listOf("af-ZA"), emptyList())
        assertEquals(DictationOnDevice.Downloadable, supported.state)
        assertEquals("af-ZA", supported.tag)

        val pending = DictationLocale.support("af", emptyList(), emptyList(), listOf("af-ZA"))
        assertEquals(DictationOnDevice.Downloadable, pending.state)
        assertEquals("af-ZA", pending.tag)

        val none = DictationLocale.support("af", emptyList(), listOf("en-GB"), emptyList())
        assertEquals(DictationOnDevice.Unsupported, none.state)
        assertNull(none.tag)
    }

    @Test fun `an installed match beats a downloadable one`() {
        val s = DictationLocale.support("en-GB", listOf("en-US"), listOf("en-GB"), emptyList())
        assertEquals(DictationOnDevice.Installed, s.state)
        assertEquals("en-US", s.tag)
    }

    @Test fun `the display name is in the phone's own language`() {
        assertEquals("English (United Kingdom)", DictationLocale.displayName("en-GB", Locale.ENGLISH))
        assertEquals("English (United Kingdom)", DictationLocale.displayName("en_GB", Locale.ENGLISH))
        assertEquals("Afrikaans (South Africa)", DictationLocale.displayName("af-ZA", Locale.ENGLISH))
    }

    // MARK: - DictationClock

    @Test fun `silence is due at 20 s, not before`() {
        assertNull(DictationClock.expiry(0, 0, 19_900))
        assertNull(DictationClock.expiry(0, 0, 19_999))
        assertEquals(DictationClock.Expiry.SILENCE, DictationClock.expiry(0, 0, 20_000))
        assertEquals(DictationClock.Expiry.SILENCE, DictationClock.expiry(0, 0, 25_000))
        assertEquals(20_000L, DictationClock.SILENCE_LIMIT_MS)
    }

    @Test fun `new words reset the silence`() {
        assertNull("words at 15 s, now 30 s: 15 s of quiet", DictationClock.expiry(0, 15_000, 30_000))
        assertNull(DictationClock.expiry(0, 15_000, 34_999))
        assertEquals(DictationClock.Expiry.SILENCE, DictationClock.expiry(0, 15_000, 35_000))
    }

    @Test fun `before the mic opens (lastWordsAt null while a download runs) only the cap applies`() {
        assertNull("not listening yet, while a download runs", DictationClock.expiry(0, null, 100_000))
        assertNull(DictationClock.expiry(0, null, 599_999))
        assertEquals(DictationClock.Expiry.CAP, DictationClock.expiry(0, null, 600_000))
    }

    @Test fun `the cap is at 600 s`() {
        assertEquals(600_000L, DictationClock.CAP_MS)
        assertNull(DictationClock.expiry(0, 599_000, 599_999))
        assertEquals(DictationClock.Expiry.CAP, DictationClock.expiry(0, 599_000, 600_000))
    }

    @Test fun `the cap wins when both are due`() {
        assertEquals(DictationClock.Expiry.CAP, DictationClock.expiry(0, 0, 600_000))
        assertEquals(DictationClock.Expiry.CAP, DictationClock.expiry(0, 590_000, 610_000))
    }

    @Test fun `the next check is the nearer deadline and never negative`() {
        assertEquals(600_000L, DictationClock.nextCheckIn(0, null, 0))
        assertEquals(599_000L, DictationClock.nextCheckIn(0, null, 1_000))
        assertEquals(20_000L, DictationClock.nextCheckIn(0, 5_000, 5_000))
        assertEquals(0L, DictationClock.nextCheckIn(0, 5_000, 25_000))
        assertEquals(0L, DictationClock.nextCheckIn(0, 5_000, 30_000))
        assertEquals(5_000L, DictationClock.nextCheckIn(0, 590_000, 595_000))
        assertEquals(500L, DictationClock.nextCheckIn(0, 599_000, 599_500))
    }

    // MARK: - DictationState

    @Test fun `DictationState defaults to no box, idle, English`() {
        val s = DictationState()
        assertNull(s.box)
        assertEquals(DictationPhase.Idle, s.phase)
        assertEquals("English", s.language)
        assertFalse(s.noteHidden)
    }

    // MARK: - Purity

    @Test fun `the Dictation source imports nothing from android`() {
        val file = listOf(
            File("src/main/java/app/page/android/model/Dictation.kt"),
            File("app/src/main/java/app/page/android/model/Dictation.kt"),
        ).firstOrNull { it.isFile }
        assertTrue("the unit tests run from the app module", file != null)
        val androidImports = file!!.readLines().filter { it.trimStart().startsWith("import android.") }
        assertEquals("Dictation.kt must be plain Kotlin: $androidImports", emptyList<String>(), androidImports)
    }
}
