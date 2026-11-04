package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Clear it and send": the `draft` field, the two new refusal reasons, the `clearDraft` op and the banner's button. */
class DraftClearTest {
    private fun result(json: String): CommandResult =
        (SessionsPlaintext.decode("""{"kind":"result","seq":1,"ts":1761300000000,"clientId":"c1",$json}""")!!.update as SessionsUpdate.Result).result

    private fun refusedDraft(draft: String?) =
        result(""""ok":false,"code":"refused","reason":"draft"${draft?.let { ""","draft":"$it"""" } ?: ""}""")

    @Test fun `a draft reason carries the text the Mac read`() {
        assertEquals("0", refusedDraft("0").draft)
        assertEquals("fix the build", refusedDraft("fix the build").draft)
        assertNull(refusedDraft(null).draft)
    }

    @Test fun `a draft that breaks the Mac's own promise is dropped, never repaired`() {
        assertNull("empty", refusedDraft("").draft)
        assertNull("surrounding space", refusedDraft(" 0").draft)
        assertNull("trailing space", refusedDraft("0 ").draft)
        assertNull("two lines", refusedDraft("a\\nb").draft)
        assertNull("over 200", refusedDraft("x".repeat(201)).draft)
        assertEquals("exactly 200", "x".repeat(200), refusedDraft("x".repeat(200)).draft)
    }

    @Test fun `the field only counts with the draft reason`() {
        assertNull(result(""""ok":false,"code":"refused","reason":"input_unverified","draft":"0"""").draft)
        assertNull(result(""""ok":true,"code":"delivered","draft":"0"""").draft)
    }

    @Test fun `the copy names the draft, shortened for display only`() {
        assertEquals("There's “0” typed in the session's input box on your computer.", SessionResultCopy.refusal("draft", null, "Claude", "0"))
        assertEquals(
            "There's unsent text in the session's input box on your computer. Clear it there, then try again.",
            SessionResultCopy.refusal("draft", null, "Claude"),
        )
        val long = "a".repeat(60)
        assertEquals("a".repeat(40) + "…", SessionResultCopy.shownDraft(long))
        assertEquals("a".repeat(40), SessionResultCopy.shownDraft("a".repeat(40)))
        assertEquals("short", SessionResultCopy.shownDraft("short"))
    }

    @Test fun `the two new reasons have the agreed copy`() {
        assertEquals(
            "Page Studio couldn't see the session's input box on your computer, so it didn't type anything. Try again in a moment.",
            SessionResultCopy.refusal("input_unverified", null, "Claude"),
        )
        assertEquals("The text in the input box changed on your computer, so Page Studio left it alone.", SessionResultCopy.refusal("draft_changed", null, "Claude"))
    }

    @Test fun `a refusal keeps the draft only for the draft reason`() {
        val s = SessionDeliveryState.Sending.applying(refusedDraft("0"), "Claude") as SessionDeliveryState.Refused
        assertEquals("0", s.draft)
        val unverified = SessionDeliveryState.Sending.applying(result(""""ok":false,"code":"refused","reason":"input_unverified""""), "Claude") as SessionDeliveryState.Refused
        assertNull(unverified.draft)
    }

    @Test fun `clearDraft goes out with the session, the exact text and the target check`() {
        val target = SessionTarget("s9", "page", "Page", "~/projects/page", "cmux", "Studio MBP", "Claude")
        val obj = parseJsonObject(String(SessionCommand.ClearDraft("s9", "0", target).plaintext("c", "v", CMD_NOW), Charsets.UTF_8))!!
        assertEquals("clearDraft", obj.str("op"))
        assertEquals("s9", obj.str("sessionId"))
        assertEquals("0", obj.str("text"))
        assertEquals("~/projects/page", obj.str("expectCwd"))
        assertEquals("Page", obj.str("expectTitle"))
        assertEquals("c", obj.str("clientId"))
        assertNull(parseJsonObject(String(SessionCommand.ClearDraft("s9", "0").plaintext("c", "v", CMD_NOW), Charsets.UTF_8))!!.str("expectCwd"))
    }

    private fun sent(state: SessionDeliveryState, photos: Int = 0) =
        SentSessionCommand("m1", "s", SessionCommandKind.INPUT, "hello", CMD_NOW, state, target = SessionTarget("s", "page", "Page", "~/p", "cmux", "Studio MBP", "Claude"), photos = photos)

    @Test fun `the banner offers Clear it and send for a text message refused with a draft`() {
        val c = sent(SessionDeliveryState.Refused("draft", "There's “0” typed in the session's input box on your computer.", "0"))
        val r = SendReceipt.build(c, "Claude", CMD_NOW)!!
        assertEquals(SendReceipt.Action.CLEAR_AND_SEND, r.action)
        assertEquals("Clear it and send", r.action!!.label)
        assertTrue(r.actionEnabled)
        assertFalse("disabled while the clear is in flight", SendReceipt.build(c, "Claude", CMD_NOW, clearing = true)!!.actionEnabled)
    }

    @Test fun `no button without the draft, for another reason, or for photos`() {
        assertNull(SendReceipt.build(sent(SessionDeliveryState.Refused("draft", "m")), "Claude", CMD_NOW)!!.action)
        assertNull(SendReceipt.build(sent(SessionDeliveryState.Refused("input_unverified", "m")), "Claude", CMD_NOW)!!.action)
        assertNull(SendReceipt.build(sent(SessionDeliveryState.Refused("draft", "m", "0"), photos = 2), "Claude", CMD_NOW)!!.action)
    }

    @Test fun `the limit counts what the user sees, not UTF-16 units`() {
        val thumbs = "👍" // one emoji: two UTF-16 units, one character
        assertEquals("200 emoji fit", thumbs.repeat(200), CommandResult.readDraft(thumbs.repeat(200)))
        assertNull("201 emoji do not", CommandResult.readDraft(thumbs.repeat(201)))
        assertEquals(thumbs.repeat(40) + "…", SessionResultCopy.shownDraft(thumbs.repeat(60)))
    }

    @Test fun `a held message's refusal never offers the draft`() {
        val held = result(""""ok":false,"code":"refused","reason":"draft","draft":"0"""").copy(fromHold = true)
        val s = SessionDeliveryState.Sending.applying(held, "Claude") as SessionDeliveryState.Refused
        assertNull(s.draft)
        assertEquals("Refused", SessionDeliveryState.Refused("draft", "m").label(SessionCommandKind.INPUT))
    }

    @Test fun `draft_changed and input_unverified never offer the button, even with a draft`() {
        val changed = SessionDeliveryState.Sending.applying(result(""""ok":false,"code":"refused","reason":"draft_changed","draft":"0""""), "Claude") as SessionDeliveryState.Refused
        assertNull(changed.draft)
        assertNull(SendReceipt.build(sent(changed), "Claude", CMD_NOW)!!.action)
        assertNull(SendReceipt.build(sent(SessionDeliveryState.Refused("input_unverified", "m", "0")), "Claude", CMD_NOW)!!.action)
    }
}
