package app.page.android.ui.nw

import app.page.android.data.SessionStore
import app.page.android.ui.nw.now.NowSessionSlice
import app.page.android.model.SessionScreen
import app.page.android.model.SessionTranscript
import app.page.android.model.TranscriptEntry
import app.page.android.model.TranscriptRole
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** Now collects only what it shows: frames that change the rest of the session store leave its slice equal, so it does not recompose. */
class NowSessionSliceTest {
    private val base = SessionStore.State(caps = setOf("budget-v1"), relayFeatures = setOf("x"))

    @Test
    fun framesThatOnlyChangeTerminalsTranscriptsOrTimesLeaveTheSliceEqual() {
        val slice = NowSessionSlice.of(base)
        val busy = base.copy(
            lastListAt = Instant.now(), waitTick = 5, workflows = mapOf("s" to emptyList()), hasKey = true,
            clearingDrafts = setOf("c"), macOfflineHint = true,
        )
        assertEquals(slice, NowSessionSlice.of(busy))
        assertEquals(slice.hashCode(), NowSessionSlice.of(busy).hashCode())
    }

    @Test
    fun aTerminalFrameAndATranscriptFrameLeaveTheSliceEqual() {
        val slice = NowSessionSlice.of(base)
        val now = Instant.now()
        val withScreen = base.copy(screens = mapOf("s1" to SessionScreen("s1", listOf("$ swift test", "Test Suite passed"), now)))
        val withTranscript = withScreen.copy(
            transcripts = mapOf("s1" to SessionTranscript("s1", listOf(TranscriptEntry("1", TranscriptRole.USER, "hi", now, null)), false)),
        )
        // And the next frame of each, with new lines in it.
        val next = withTranscript.copy(
            screens = mapOf("s1" to SessionScreen("s1", listOf("$ swift test", "Test Suite passed", "done"), now.plusSeconds(1))),
            transcripts = mapOf("s1" to SessionTranscript("s1", listOf(TranscriptEntry("2", TranscriptRole.USER, "again", now, null)), true)),
        )
        for (state in listOf(withScreen, withTranscript, next)) assertEquals(slice, NowSessionSlice.of(state))
    }

    @Test
    fun whatNowDoesShowStillChangesIt() {
        val slice = NowSessionSlice.of(base)
        assertNotEquals(slice, NowSessionSlice.of(base.copy(caps = emptySet())))
        assertNotEquals(slice, NowSessionSlice.of(base.copy(relayFeatures = null)))
        assertEquals(true, slice.canBudget)
        assertEquals(false, NowSessionSlice.of(base.copy(caps = emptySet())).canBudget)
    }
}
