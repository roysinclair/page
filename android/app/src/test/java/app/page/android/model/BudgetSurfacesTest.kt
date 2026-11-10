package app.page.android.model

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Budget caps where they show: the page subtypes, the notification category, the room chip, the rows, Settled and the decision sheet. */
class BudgetSurfacesTest {
    private val mac = "Studio MBP"
    private val claude = AgentCharacter.from(AgentBackend.Known(InterventionBackend.CLAUDE), null)

    private val reachedText = "Night Owl reached its budget: about 26% of the week (budget 25%). Page stopped 2 sessions."
    private val warningText = "Night Owl has used about 20% of the week (budget 25%). Page stops it at 25%."

    private fun budgetPage(id: String, subtype: String, text: String) =
        nwIv(id, InterventionKind.RATE_LIMIT, context = text, subtype = subtype, project = "Night Owl")

    // MARK: subtypes and notification category

    @Test fun `the budget subtypes are these two words`() {
        assertEquals("budget_reached", PageSubtype.BUDGET_REACHED)
        assertEquals("budget_warning", PageSubtype.BUDGET_WARNING)
    }

    @Test fun `only the two budget subtypes are budget pages`() {
        assertTrue(PageSubtype.isBudget("budget_reached"))
        assertTrue(PageSubtype.isBudget("budget_warning"))
        assertFalse(PageSubtype.isBudget(null))
        assertFalse(PageSubtype.isBudget("budget"))
        assertFalse(PageSubtype.isBudget("usage_forecast"))
        assertFalse(PageSubtype.isBudget("plan"))
    }

    @Test fun `a budget page is info for notifications, not a limit to send after reset`() {
        assertEquals(NotificationCategory.INFO, NotificationCategory.forPage(InterventionKind.RATE_LIMIT, "budget_reached"))
        assertEquals(NotificationCategory.INFO, NotificationCategory.forPage(InterventionKind.RATE_LIMIT, "budget_warning"))
        assertEquals(NotificationCategory.LIMIT, NotificationCategory.forPage(InterventionKind.RATE_LIMIT, null))
        assertEquals(NotificationCategory.LIMIT, NotificationCategory.forPage(InterventionKind.RATE_LIMIT, "budget"))
    }

    // MARK: the room's chip

    private fun chips(s: LiveSession, ended: Boolean = false, budget: SessionBudget? = s.budget) =
        RoomHeader.chips(s, claude, ended, null, false, null, nwNow, budget = budget)

    private fun budgetChips(list: List<RoomChip>) = list.filter { it.symbol == BudgetCopy.SYMBOL }

    private fun active(budget: SessionBudget?) = nwSession("s1", state = "active").copy(budget = budget)

    private fun sb(used: Double, cap: Int?, state: BudgetState = BudgetState.of(used, cap)) = SessionBudget(
        projectKey = "/Users/me/proj", used = used, cap = cap, scope = SessionBudget.Scope.PROJECT, state = state,
    )

    @Test fun `a session with a budget has a teal chip under the warning`() {
        val c = budgetChips(chips(active(sb(18.4, 25))))
        assertEquals(1, c.size)
        assertEquals("Budget 18/25%", c[0].text)
        assertEquals(RoomChip.Tone.WORKING, c[0].tone)
        assertEquals("chart.pie.fill", c[0].symbol)
    }

    @Test fun `the chip turns warm from the warning`() {
        val c = budgetChips(chips(active(sb(20.0, 25))))
        assertEquals("Budget 20/25%", c[0].text)
        assertEquals(RoomChip.Tone.WARM, c[0].tone)
    }

    @Test fun `the chip is warm when the project is stopped`() {
        val c = budgetChips(chips(active(sb(26.0, 25))))
        assertEquals("Budget 26/25%", c[0].text)
        assertEquals(RoomChip.Tone.WARM, c[0].tone)
    }

    @Test fun `no budget, or no cap, means no chip`() {
        assertTrue(budgetChips(chips(active(null))).isEmpty())
        assertTrue(budgetChips(chips(active(sb(18.4, null)))).isEmpty())
    }

    @Test fun `an ended session has no budget chip`() {
        assertTrue(budgetChips(chips(active(sb(18.4, 25)), ended = true)).isEmpty())
    }

    // MARK: the rows (the Now stream and the decide card)

    @Test fun `a reached page is a decision, stopped at its budget, with raise and let-finish`() {
        val iv = budgetPage("b1", PageSubtype.BUDGET_REACHED, reachedText)
        val row = NowRowBuilder.row(iv, null, mac)
        assertEquals(NowRow.Section.DECIDE, row.section)
        assertEquals(ChipKind.BUDGET, row.chip)
        assertEquals("Stopped at its budget", row.headline)
        assertEquals("about 26% of the week · 2 sessions stopped", row.summary)
        assertEquals(listOf("Raise to 35%", "Let this turn finish"), row.actions.map { it.label })
        assertEquals(listOf(RowAction.Kind.APPROVE, RowAction.Kind.CARRY_ON), row.actions.map { it.kind })
        assertEquals(RowAction.Kind.APPROVE, row.actions[0].kind)
        assertTrue(row.actions[0].preview!!.startsWith("Page Studio raises Night Owl's budget"))
        assertEquals(BudgetPage(26.0, 25, 2), row.budget)
    }

    @Test fun `a warning is a look, near its budget, with one raise`() {
        val iv = budgetPage("b2", PageSubtype.BUDGET_WARNING, warningText)
        val row = NowRowBuilder.row(iv, null, mac)
        assertEquals(NowRow.Section.LOOK, row.section)
        assertEquals(ChipKind.BUDGET, row.chip)
        assertEquals("Near its budget", row.headline)
        assertEquals("20% of its 25% budget", row.summary)
        assertEquals(listOf("Raise to 35%"), row.actions.map { it.label })
        assertEquals(listOf(RowAction.Kind.APPROVE), row.actions.map { it.kind })
    }

    @Test fun `a budget page that names no budget offers raise by ten`() {
        val iv = budgetPage("b3", PageSubtype.BUDGET_REACHED, "Night Owl reached its budget.")
        val row = NowRowBuilder.row(iv, null, mac)
        assertEquals("Raise by 10%", row.actions[0].label)
        assertEquals(BudgetPage(), row.budget)
    }

    @Test fun `text with no numbers keeps its own first line as the summary`() {
        val iv = budgetPage("b4", PageSubtype.BUDGET_WARNING, "Night Owl is getting close.")
        val row = NowRowBuilder.row(iv, null, mac)
        assertEquals("Night Owl is getting close.", row.summary)
    }

    @Test fun `a rate limit that is not a budget keeps its own chip`() {
        val iv = nwIv("r1", InterventionKind.RATE_LIMIT, context = "Usage limit reached", session = "s1", subtype = null)
        val row = NowRowBuilder.row(iv, null, mac)
        assertEquals(ChipKind.RATE_LIMITED, row.chip)
        assertNull(row.budget)
    }

    // MARK: Settled (what a budget answer reads as)

    private fun answered(subtype: String, action: String, status: String? = "delivered") = budgetPage("a-$action", subtype, reachedText).copy(
        repliedAt = Instant.ofEpochSecond((NW_T0 + 60).toLong()),
        repliedAction = action,
        deliveryStatus = status,
    )

    @Test fun `raising a budget reads as what it did, in the settled log`() {
        val line = SettledLog.line(answered("budget_reached", "approve"), nwNow)
        assertEquals("Raised Night Owl's budget", line.text)
        assertEquals(SettledLine.Tone.APPROVED, line.tone)
        assertEquals("delivered ✓", line.status)
    }

    @Test fun `letting a turn finish reads as sent, and keeping it stopped as neutral`() {
        val carried = SettledLog.line(answered("budget_reached", "carry_on"), nwNow)
        assertEquals("Let Night Owl's turn finish", carried.text)
        assertEquals(SettledLine.Tone.SENT, carried.tone)

        val kept = SettledLog.line(answered("budget_reached", "deny"), nwNow)
        assertEquals("Kept Night Owl stopped", kept.text)
        assertEquals(SettledLine.Tone.NEUTRAL, kept.tone)
    }

    @Test fun `a budget answer is never an approval of its numbers`() {
        val line = SettledLog.line(answered("budget_warning", "approve", status = "sent"), nwNow)
        assertEquals("Raised Night Owl's budget", line.text)
        assertEquals("sent", line.status)
        assertFalse(line.text.startsWith("Approved"))
    }

    @Test fun `an unanswered budget page says how it closed, not a reply`() {
        val open = budgetPage("u1", PageSubtype.BUDGET_REACHED, reachedText)
        val line = SettledLog.line(open, nwNow)
        assertNull(line.status)
        assertEquals(SettledLine.Tone.NEUTRAL, line.tone)
    }

    // MARK: the decision sheet

    private fun content(iv: Intervention) = DecisionContent.build(iv, NowRowBuilder.row(iv, null, mac), null, mac)

    @Test fun `the decision sheet says the Mac changes the budget and nothing is typed`() {
        val c = content(budgetPage("d1", PageSubtype.BUDGET_REACHED, reachedText))
        assertEquals("Page Studio changes the budget on $mac. Nothing is typed into a session.", c.footer)
        assertEquals(ChipKind.BUDGET, c.chip)
    }

    @Test fun `the decision sheet's bar is full for a reached page and the share for a warning`() {
        val reached = content(budgetPage("d2", PageSubtype.BUDGET_REACHED, reachedText))
        assertNotNull(reached.budgetMeter)
        assertEquals("26% of 25%", reached.budgetMeter!!.line)
        assertEquals(1.0, reached.budgetMeter!!.fraction, 1e-9)

        val warn = content(budgetPage("d3", PageSubtype.BUDGET_WARNING, warningText))
        assertEquals("20% of 25%", warn.budgetMeter!!.line)
        assertEquals(0.8, warn.budgetMeter!!.fraction, 1e-9)
    }

    @Test fun `a page that is not a budget has no budget bar`() {
        val plain = content(nwIv("p1", InterventionKind.APPROVAL, "[Bash] ls", session = "s1"))
        assertNull(plain.budgetMeter)
        assertNull(plain.budget)
    }
}
