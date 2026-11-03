package app.page.android.model

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A page's reply the Mac refused for text in the input box: `reply.injected` `reason`, `peekDraft`, and the sheet's one button. */
class ReplyDraftTest {
    private fun result(json: String): CommandResult =
        (SessionsPlaintext.decode("""{"kind":"result","seq":1,"ts":1761300000000,"clientId":"c1",$json}""")!!.update as SessionsUpdate.Result).result

    private val unsent = "There's unsent text in the session's input box on your Mac."
    private val unverified = "Page couldn't see the session's input box on your Mac, so it didn't type anything. Try again in a moment."

    @Test fun `a draft failure says Page's words, not the Mac's raw detail`() {
        val d = ReplyResultFrame.delivery(false, "cmux", "You have a half-typed message in that pane", reason = "draft")
        assertEquals(ReplyDelivery.Failed(unsent, "draft"), d)
        assertEquals(ReplyDelivery.Failed(unverified, "input_unverified"), ReplyResultFrame.delivery(false, "cmux", "No input box", reason = "input_unverified"))
    }

    @Test fun `no reason or an unknown one is as before`() {
        assertEquals(ReplyDelivery.Failed("Nope"), ReplyResultFrame.delivery(false, "cmux", "Nope"))
        assertEquals(ReplyDelivery.Failed("Nope"), ReplyResultFrame.delivery(false, "cmux", "Nope", reason = "something_new"))
        assertEquals(ReplyDelivery.Failed("Your Mac couldn't deliver the reply."), ReplyResultFrame.delivery(false, null, null))
    }

    @Test fun `a reason on a success or a delete changes nothing`() {
        assertEquals(ReplyDelivery.Delivered("ok"), ReplyResultFrame.delivery(true, "cmux", "ok", reason = "draft"))
        assertTrue(ReplyResultFrame.delivery(false, "retracted", null, reason = "draft") is ReplyDelivery.Retracted)
    }

    @Test fun `a synced failure carries the stored reason`() {
        val now = Instant.parse("2026-10-29T12:00:00Z")
        val d = ReplyDelivery.synced(null, "failed", "raw", null, now, deliveryReason = "draft")
        assertEquals(ReplyDelivery.Failed(unsent, "draft"), d)
        assertEquals(ReplyDelivery.Failed("raw"), ReplyDelivery.synced(null, "failed", "raw", null, now))
    }

    @Test fun `the record's deliveryReason is read`() {
        val iv = Intervention.decode(parseJson("""{"id":"i1","sessionId":"s","openedAt":"2026-10-29T12:00:00Z","deliveryStatus":"failed","deliveryReason":"draft"}""")!!)
        assertEquals("draft", iv?.deliveryReason)
    }

    @Test fun `peekDraft goes out with the session and the target check, and no text`() {
        val target = SessionTarget("s9", "page", "Page", "~/projects/page", "cmux", "Studio MBP", "Claude")
        val obj = parseJsonObject(String(SessionCommand.PeekDraft("s9", target).plaintext("c", "v", CMD_NOW), Charsets.UTF_8))!!
        assertEquals("peekDraft", obj.str("op"))
        assertEquals("s9", obj.str("sessionId"))
        assertEquals("~/projects/page", obj.str("expectCwd"))
        assertEquals("Page", obj.str("expectTitle"))
        assertEquals("c", obj.str("clientId"))
        assertNull(obj.str("text"))
        assertNull(parseJsonObject(String(SessionCommand.PeekDraft("s9").plaintext("c", "v", CMD_NOW), Charsets.UTF_8))!!.str("expectCwd"))
    }

    @Test fun `the peek's answer decides what the sheet offers`() {
        val typed = result(""""ok":false,"code":"refused","reason":"draft","draft":"fix it"""")
        assertEquals(ReplyDraftRecovery.Typed("fix it"), ReplyDraft.afterPeek(typed))
        assertEquals(ReplyDraftRecovery.Unknown, ReplyDraft.afterPeek(result(""""ok":false,"code":"refused","reason":"draft"""")))
        assertEquals(ReplyDraftRecovery.Clear, ReplyDraft.afterPeek(result(""""ok":true,"code":"delivered","detail":"Already clear"""")))
        assertEquals(ReplyDraftRecovery.Unknown, ReplyDraft.afterPeek(result(""""ok":false,"code":"refused","reason":"input_unverified"""")))
        assertEquals(ReplyDraftRecovery.Unknown, ReplyDraft.afterPeek(result(""""ok":false,"code":"refused","reason":"waiting"""")))
        assertEquals(ReplyDraftRecovery.Unknown, ReplyDraft.afterPeek(null))
    }

    @Test fun `the copy names the draft, shortened for display only`() {
        assertEquals("There's “fix it” typed in the session's input box on your Mac.", ReplyDraft.copy(ReplyDraftRecovery.Typed("fix it")))
        assertEquals("There's “" + "a".repeat(40) + "…” typed in the session's input box on your Mac.", ReplyDraft.copy(ReplyDraftRecovery.Typed("a".repeat(60))))
        assertEquals("The input box on your Mac is clear now.", ReplyDraft.copy(ReplyDraftRecovery.Clear))
        assertNull(ReplyDraft.copy(ReplyDraftRecovery.Asking))
        assertNull(ReplyDraft.copy(ReplyDraftRecovery.Unknown))
        assertNull(ReplyDraft.copy(null))
    }

    @Test fun `the sheet shows the recovery's copy only on a draft failure`() {
        val failed = ReplyDelivery.Failed(unsent, "draft")
        assertEquals("There's “x” typed in the session's input box on your Mac.", (ReplyDraft.shown(failed, ReplyDraftRecovery.Typed("x")) as ReplyDelivery.Failed).message)
        assertEquals(failed, ReplyDraft.shown(failed, ReplyDraftRecovery.Asking))
        assertEquals(failed, ReplyDraft.shown(failed, null))
        val other = ReplyDelivery.Failed(unverified, "input_unverified")
        assertEquals(other, ReplyDraft.shown(other, ReplyDraftRecovery.Typed("x")))
        assertNull(ReplyDraft.shown(null, ReplyDraftRecovery.Clear))
    }

    @Test fun `Clear it and send appears with the text, and is dimmed while the clear is out`() {
        val failed = ReplyDelivery.Failed(unsent, "draft")
        val a = ReplyDraft.action(failed, ReplyDraftRecovery.Typed("x"), canResend = true)!!
        assertEquals(ReplyDraft.Action.Kind.CLEAR_AND_SEND, a.kind)
        assertEquals("Clear it and send", a.label)
        assertEquals("Clear the text in the input box on your Mac and send your message", a.spoken)
        assertTrue(a.enabled)
        assertFalse(ReplyDraft.action(failed, ReplyDraftRecovery.Typed("x", clearing = true), canResend = true)!!.enabled)
    }

    @Test fun `Send again appears when the box is clear`() {
        val a = ReplyDraft.action(ReplyDelivery.Failed(unsent, "draft"), ReplyDraftRecovery.Clear, canResend = true)!!
        assertEquals(ReplyDraft.Action.Kind.SEND_AGAIN, a.kind)
        assertEquals("Send again", a.label)
    }

    @Test fun `no button when nothing more is known, for another reason, or with no reply to send`() {
        val failed = ReplyDelivery.Failed(unsent, "draft")
        for (r in listOf(null, ReplyDraftRecovery.Asking, ReplyDraftRecovery.Unknown, ReplyDraftRecovery.Problem("m"))) assertNull(ReplyDraft.action(failed, r, canResend = true))
        assertNull(ReplyDraft.action(failed, ReplyDraftRecovery.Typed("x"), canResend = false))
        assertNull(ReplyDraft.action(ReplyDelivery.Failed(unverified, "input_unverified"), ReplyDraftRecovery.Typed("x"), canResend = true))
        assertNull(ReplyDraft.action(ReplyDelivery.Failed("older Mac"), ReplyDraftRecovery.Clear, canResend = true))
    }

    @Test fun `the clear's answer sends again, offers again, or says why not`() {
        assertNull("cleared", ReplyDraft.afterClear(result(""""ok":true,"code":"delivered","detail":"Cleared""""), "Claude"))
        assertNull("already clear", ReplyDraft.afterClear(result(""""ok":true,"code":"delivered","detail":"Already clear""""), "Claude"))
        assertEquals(ReplyDraftRecovery.Typed("new"), ReplyDraft.afterClear(result(""""ok":false,"code":"refused","reason":"draft","draft":"new""""), "Claude"))
        assertEquals(
            ReplyDraftRecovery.Problem("The text in the input box changed on your Mac, so Page left it alone."),
            ReplyDraft.afterClear(result(""""ok":false,"code":"refused","reason":"draft_changed""""), "Claude"),
        )
        assertEquals(
            ReplyDraftRecovery.Problem("Claude is showing a prompt on your Mac. Answer it from its page instead."),
            ReplyDraft.afterClear(result(""""ok":false,"code":"refused","reason":"waiting""""), "Claude"),
        )
        assertEquals(ReplyDraftRecovery.Problem("It broke"), ReplyDraft.afterClear(result(""""ok":false,"code":"failed","detail":"It broke""""), "Claude"))
        assertTrue(ReplyDraft.afterClear(null, "Claude") is ReplyDraftRecovery.Problem)
    }

    @Test fun `peek, then Clear it and send, then the same reply goes again`() {
        val failed = ReplyResultFrame.delivery(false, "cmux", "You have a half-typed message in that pane", reason = "draft")
        var recovery: ReplyDraftRecovery? = ReplyDraftRecovery.Asking
        assertEquals(failed, ReplyDraft.shown(failed, recovery))
        assertNull(ReplyDraft.action(failed, recovery, canResend = true))

        recovery = ReplyDraft.afterPeek(result(""""ok":false,"code":"refused","reason":"draft","draft":"fix it""""))
        assertEquals("There's “fix it” typed in the session's input box on your Mac.", (ReplyDraft.shown(failed, recovery) as ReplyDelivery.Failed).message)
        assertEquals(ReplyDraft.Action.Kind.CLEAR_AND_SEND, ReplyDraft.action(failed, recovery, canResend = true)!!.kind)

        recovery = (recovery as ReplyDraftRecovery.Typed).copy(clearing = true)
        assertFalse(ReplyDraft.action(failed, recovery, canResend = true)!!.enabled)

        // The Mac cleared it: nothing left to say, and the reply is sent again (the sheet drops the recovery).
        assertNull(ReplyDraft.afterClear(result(""""ok":true,"code":"delivered","detail":"Cleared""""), "Claude"))
    }

    @Test fun `peek finds the box clear, then Send again`() {
        val failed = ReplyResultFrame.delivery(false, "cmux", "raw", reason = "draft")
        val recovery = ReplyDraft.afterPeek(result(""""ok":true,"code":"delivered","detail":"Already clear""""))
        assertEquals("The input box on your Mac is clear now.", (ReplyDraft.shown(failed, recovery) as ReplyDelivery.Failed).message)
        assertEquals(ReplyDraft.Action.Kind.SEND_AGAIN, ReplyDraft.action(failed, recovery, canResend = true)!!.kind)
        assertNull(ReplyDraft.action(failed, recovery, canResend = false))
    }

    @Test fun `no answer to the peek keeps the unsent-text copy and no button`() {
        val failed = ReplyResultFrame.delivery(false, "cmux", "raw", reason = "draft")
        val recovery = ReplyDraft.afterPeek(null)
        assertEquals(ReplyDraft.UNSENT_COPY, (ReplyDraft.shown(failed, recovery) as ReplyDelivery.Failed).message)
        assertNull(ReplyDraft.action(failed, recovery, canResend = true))
    }

    @Test fun `a clear refused again with text offers the new text`() {
        val failed = ReplyDelivery.Failed(unsent, "draft")
        val recovery = ReplyDraft.afterClear(result(""""ok":false,"code":"refused","reason":"draft","draft":"new""""), "Claude")
        assertEquals(ReplyDraftRecovery.Typed("new"), recovery)
        assertTrue(ReplyDraft.action(failed, recovery, canResend = true)!!.enabled)
    }
}
