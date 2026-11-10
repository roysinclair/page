package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Budget caps, the pure model (Designs/budget-caps.md sections 1, 3, 4): thresholds, the meter, the picker, the words. */
class BudgetTest {
    private val utc = ZoneId.of("UTC")
    private val monNine: Instant = Instant.parse("2026-11-09T09:00:00Z")

    private fun close(expected: Double, actual: Double?) = assertEquals(expected, actual!!, 1e-9)

    // MARK: BudgetState

    @Test fun `no cap or a zero cap is always ok`() {
        assertEquals(BudgetState.OK, BudgetState.of(0.0, null))
        assertEquals(BudgetState.OK, BudgetState.of(99.0, null))
        assertEquals(BudgetState.OK, BudgetState.of(50.0, 0))
        assertEquals(BudgetState.OK, BudgetState.of(50.0, -5))
    }

    @Test fun `the warning starts at exactly 80 percent of the cap`() {
        assertEquals(BudgetState.OK, BudgetState.of(19.9, 25))
        assertEquals(BudgetState.WARN, BudgetState.of(20.0, 25))
        assertEquals(BudgetState.WARN, BudgetState.of(24.9, 25))
        assertEquals(BudgetState.WARN, BudgetState.of(8.0, 10))
        assertEquals(BudgetState.OK, BudgetState.of(7.9, 10))
    }

    @Test fun `over starts exactly at the cap`() {
        assertEquals(BudgetState.OVER, BudgetState.of(25.0, 25))
        assertEquals(BudgetState.OVER, BudgetState.of(30.0, 25))
        assertEquals(BudgetState.OVER, BudgetState.of(100.0, 100))
    }

    @Test fun `wire states parse leniently and anything else is null`() {
        assertEquals(BudgetState.OK, BudgetState.fromWire("ok"))
        assertEquals(BudgetState.WARN, BudgetState.fromWire("warn"))
        assertEquals(BudgetState.OVER, BudgetState.fromWire(" OVER "))
        assertNull(BudgetState.fromWire("bogus"))
        assertNull(BudgetState.fromWire(""))
        assertNull(BudgetState.fromWire(null))
        assertEquals("over", BudgetState.OVER.wire)
    }

    // MARK: BudgetMeter

    @Test fun `the line pairs used with the budget, or says no budget`() {
        assertEquals("18% of 25%", BudgetMeter(18.4, 25).line)
        assertEquals("18% · no budget", BudgetMeter(18.4, null).line)
        assertEquals("0% of 25%", BudgetMeter(0.0, 25).line)
        assertEquals("<1% of 25%", BudgetMeter(0.4, 25).line)
        assertEquals("<1% · no budget", BudgetMeter(0.4, null).line)
        assertEquals("18%", BudgetMeter(18.4, 25).usedText)
        assertEquals("<1%", BudgetMeter(0.9, 25).usedText)
    }

    @Test fun `the fraction is used over budget, clamped to 0 through 1`() {
        close(0.736, BudgetMeter(18.4, 25).fraction)
        close(1.0, BudgetMeter(30.0, 25).fraction)
        close(1.0, BudgetMeter(25.0, 25).fraction)
        close(0.0, BudgetMeter(-3.0, 25).fraction)
        close(0.0, BudgetMeter(0.0, 25).fraction)
    }

    @Test fun `with no budget the bar is the whole week, clamped too`() {
        close(0.4, BudgetMeter(40.0, null).fraction)
        close(1.0, BudgetMeter(150.0, null).fraction)
        close(0.0, BudgetMeter(-1.0, null).fraction)
        assertNull(BudgetMeter(40.0, null).warnMark)
    }

    @Test fun `the warning tick sits at 80 percent when there is a budget`() {
        close(0.8, BudgetMeter(18.4, 25).warnMark)
        close(0.8, BudgetMeter(30.0, 25).warnMark)
    }

    @Test fun `tone is calm under the warning, warm from it, quiet with no budget`() {
        assertEquals(BudgetMeter.Tone.CALM, BudgetMeter(18.4, 25).tone)
        assertEquals(BudgetMeter.Tone.WARM, BudgetMeter(20.0, 25).tone)
        assertEquals(BudgetMeter.Tone.WARM, BudgetMeter(25.0, 25).tone)
        assertEquals(BudgetMeter.Tone.QUIET, BudgetMeter(18.4, null).tone)
    }

    @Test fun `the state the meter carries is the numbers unless the Mac said`() {
        assertEquals(BudgetState.WARN, BudgetMeter(20.0, 25).state)
        assertEquals(BudgetState.OVER, BudgetMeter(20.0, 25, BudgetState.OVER).state)
        assertEquals(BudgetMeter.Tone.WARM, BudgetMeter(20.0, 25, BudgetState.OVER).tone)
    }

    @Test fun `spoken detail says the share, the budget and where it stands`() {
        assertEquals("18% of the week, budget 25%", BudgetMeter(18.4, 25).spokenDetail)
        assertEquals("20% of the week, near its 25% budget", BudgetMeter(20.0, 25).spokenDetail)
        assertEquals("25% of the week, budget 25% reached, stopped", BudgetMeter(25.0, 25).spokenDetail)
        assertEquals("18% of the week, no budget", BudgetMeter(18.4, null).spokenDetail)
        assertEquals("Night Owl, 18% of the week, budget 25%", BudgetMeter(18.4, 25).spoken("Night Owl"))
        assertEquals("Night Owl, 25% of the week, budget 25% reached, stopped", BudgetMeter(25.0, 25).spoken("Night Owl"))
    }

    // MARK: BudgetPercent

    @Test fun `the picker's presets are Off, 10, 25 and 50`() {
        assertEquals(listOf(null, 10, 25, 50), BudgetPercent.presets)
        assertEquals(5, BudgetPercent.STEP)
    }

    @Test fun `up steps to the next multiple of five and never past 100`() {
        assertEquals(5, BudgetPercent.up(null))
        assertEquals(25, BudgetPercent.up(23))
        assertEquals(30, BudgetPercent.up(25))
        assertEquals(100, BudgetPercent.up(95))
        assertEquals(100, BudgetPercent.up(100))
    }

    @Test fun `down steps to the previous multiple of five, and below 5 is Off`() {
        assertEquals(25, BudgetPercent.down(27))
        assertEquals(20, BudgetPercent.down(25))
        assertEquals(95, BudgetPercent.down(100))
        assertEquals(5, BudgetPercent.down(10))
        assertEquals(5, BudgetPercent.down(6))
        assertNull(BudgetPercent.down(5))
        assertNull(BudgetPercent.down(1))
        assertNull(BudgetPercent.down(null))
    }

    @Test fun `text is the percentage or Off`() {
        assertEquals("Off", BudgetPercent.text(null))
        assertEquals("25%", BudgetPercent.text(25))
        assertEquals("100%", BudgetPercent.text(100))
    }

    // MARK: BudgetCopy

    @Test fun `the warning point is 80 percent, rounded half away from zero, never below 1`() {
        assertEquals(20, BudgetCopy.warnAt(25))
        assertEquals(1, BudgetCopy.warnAt(1))
        assertEquals(2, BudgetCopy.warnAt(3))
    }

    @Test fun `pct rounds half away from zero and shows under 1 as less than 1`() {
        assertEquals("18%", BudgetCopy.pct(18.4))
        assertEquals("19%", BudgetCopy.pct(18.5))
        assertEquals("<1%", BudgetCopy.pct(0.4))
    }

    @Test fun `resets reads the weekday and clock in the given zone`() {
        assertEquals("Mon 09:00", BudgetCopy.resets(monNine, utc))
        assertEquals("Sun 09:00", BudgetCopy.resets(monNine.minusSeconds(86_400), utc))
        assertEquals("Sat 17:30", BudgetCopy.resets(Instant.parse("2026-11-14T17:30:00Z"), utc))
        // Fixed zone: 14:00 UTC on Monday is 09:00 in New York (EST after the November change).
        assertEquals("Mon 09:00", BudgetCopy.resets(Instant.parse("2026-11-09T14:00:00Z"), ZoneId.of("America/New_York")))
    }

    @Test fun `the sheet's plain words for a project budget`() {
        assertEquals(
            "Page warns at 20% and stops Night Owl at 25% of the week. Resets Mon 09:00.",
            BudgetCopy.preview("Night Owl", 25, session = false, resetsAt = monNine, zone = utc),
        )
        assertEquals(
            "Page warns at 20% and stops Night Owl at 25% of the week.",
            BudgetCopy.preview("Night Owl", 25, session = false, resetsAt = null, zone = utc),
        )
        assertEquals(
            "No budget: Night Owl can use any share of the week. Resets Mon 09:00.",
            BudgetCopy.preview("Night Owl", null, session = false, resetsAt = monNine, zone = utc),
        )
    }

    @Test fun `the sheet's plain words for a session budget`() {
        assertEquals(
            "Page warns at 4% and stops this session at 5% of the week. Resets Mon 09:00.",
            BudgetCopy.preview("bottle-flip", 5, session = true, resetsAt = monNine, zone = utc),
        )
        assertEquals(
            "No budget of its own: this session shares bottle-flip's. Resets Mon 09:00.",
            BudgetCopy.preview("bottle-flip", null, session = true, resetsAt = monNine, zone = utc),
        )
    }

    @Test fun `the room chip is the rounded share over the budget, and none with no budget`() {
        assertEquals("Budget 18/25%", BudgetCopy.chip(sb(used = 18.4, cap = 25)))
        assertEquals("Budget 19/25%", BudgetCopy.chip(sb(used = 18.5, cap = 25)))
        assertEquals("Budget 0/25%", BudgetCopy.chip(sb(used = 0.4, cap = 25)))
        assertNull(BudgetCopy.chip(sb(used = 18.4, cap = null)))
    }

    private fun sb(used: Double, cap: Int?) = SessionBudget(
        projectKey = "/Users/me/proj", used = used, cap = cap, scope = SessionBudget.Scope.PROJECT,
        state = BudgetState.of(used, cap),
    )

    @Test fun `the cap-reached line says the share and counts sessions`() {
        assertEquals("about 25% of the week · 1 session stopped", BudgetCopy.reachedLine(25.0, 1))
        assertEquals("about 26% of the week · 2 sessions stopped", BudgetCopy.reachedLine(26.0, 2))
        assertEquals("about 26% of the week · 0 sessions stopped", BudgetCopy.reachedLine(26.0, 0))
    }

    @Test fun `the Mac-offline line is said in these words`() {
        assertEquals("Your Mac is offline — the budget wasn't changed.", BudgetCopy.macOffline)
    }

    @Test fun `answers to a budget page read as what they did`() {
        assertEquals("Raised Night Owl's budget", BudgetCopy.answered("approve", "Night Owl"))
        assertEquals("Let Night Owl's turn finish", BudgetCopy.answered("carry_on", "Night Owl"))
        assertEquals("Kept Night Owl stopped", BudgetCopy.answered("deny", "Night Owl"))
        // Typed text means the same as deny (spec §4): nothing is typed into a session.
        assertEquals("Kept Night Owl stopped", BudgetCopy.answered("custom", "Night Owl"))
        assertNull(BudgetCopy.answered(null, "Night Owl"))
    }

    @Test fun `a refusal from the Mac gets Page's words for the known reasons`() {
        assertEquals(
            "Your Mac doesn't have that project or session any more. The budget wasn't changed.",
            BudgetCopy.refusal("not_found", "anything"),
        )
        assertEquals(
            SessionResultCopy.refusal("stale", null, "Your agent"),
            BudgetCopy.refusal("stale", null),
        )
        assertEquals(
            SessionResultCopy.refusal("replay", "x", "Your agent"),
            BudgetCopy.refusal("replay", "x"),
        )
        assertEquals("Pct must be 1-100", BudgetCopy.refusal("invalid", "Pct must be 1-100"))
        assertEquals(
            "Your Mac didn't accept that percentage. The budget wasn't changed.",
            BudgetCopy.refusal("invalid", null),
        )
        assertEquals("Mac says no", BudgetCopy.refusal("something_new", "Mac says no"))
        assertEquals("Your Mac couldn't change the budget.", BudgetCopy.refusal(null, null))
    }

    // MARK: BudgetPage (the page's text, word for word)

    private val reachedText = "Night Owl reached its budget: about 26% of the week (budget 25%). Page stopped 2 sessions."
    private val warningText = "Night Owl has used about 20% of the week (budget 25%). Page stops it at 25%."

    @Test fun `the cap-reached text parses to its share, budget and stopped count`() {
        val p = BudgetPage.parse(reachedText)
        close(26.0, p.used)
        assertEquals(25, p.cap)
        assertEquals(2, p.stopped)
    }

    @Test fun `the warning text parses to its share and budget, with no stopped count`() {
        val p = BudgetPage.parse(warningText)
        close(20.0, p.used)
        assertEquals(25, p.cap)
        assertNull(p.stopped)
    }

    @Test fun `text with no numbers parses to nothing`() {
        val p = BudgetPage.parse("Night Owl is getting close to its limit.")
        assertNull(p.used)
        assertNull(p.cap)
        assertNull(p.stopped)
        assertNull(p.line(reached = true))
        assertNull(p.meter(reached = true))
    }

    @Test fun `the reached card line and the warning card line`() {
        assertEquals("about 26% of the week · 2 sessions stopped", BudgetPage.parse(reachedText).line(reached = true))
        assertEquals("20% of its 25% budget", BudgetPage.parse(warningText).line(reached = false))
        // A page with no share in its text has no line at all.
        assertNull(BudgetPage(used = null, cap = 25).line(reached = false))
    }

    @Test fun `the reached bar is full past the budget and the warning bar is the share`() {
        val reached = BudgetPage.parse(reachedText).meter(reached = true)!!
        assertEquals("26% of 25%", reached.line)
        close(1.0, reached.fraction)
        assertEquals(BudgetState.OVER, reached.state)
        assertEquals(BudgetMeter.Tone.WARM, reached.tone)
        close(0.8, reached.warnMark)

        val warn = BudgetPage.parse(warningText).meter(reached = false)!!
        assertEquals("20% of 25%", warn.line)
        close(0.8, warn.fraction)
        assertEquals(BudgetState.WARN, warn.state)
    }

    @Test fun `a cap-reached page that names no budget is full by definition`() {
        val m = BudgetPage.parse("Night Owl reached its budget: about 26% of the week.").meter(reached = true)!!
        assertEquals(26, m.cap)
        assertEquals(BudgetState.OVER, m.state)
        close(1.0, m.fraction)
    }

    // MARK: BudgetSheetModel

    private val night = BudgetProject(
        key = "/Users/me/projects/night-owl", name = "Night Owl", used = 18.4, cap = 25, state = BudgetState.OK,
    )

    @Test fun `a project's sheet is titled by the project and seeded from its own cap`() {
        val sheet = BudgetSheetModel.project(night, monNine)
        assertEquals("Night Owl’s budget", sheet.title)
        assertEquals("18% of the week so far", sheet.subtitle)
        assertEquals(25, sheet.cap)
        assertEquals("project-/Users/me/projects/night-owl", sheet.id)
        assertNull(sheet.projectKey)
    }

    @Test fun `a project with no budget of its own seeds the sheet with none, not the default`() {
        val p = night.copy(cap = null, state = BudgetState.OK)
        val sheet = BudgetSheetModel.project(p, null)
        assertNull(sheet.cap)
        assertEquals("No budget: Night Owl can use any share of the week.", sheet.preview(null, utc))
    }

    @Test fun `a project's command is the op for its key, and a clear is still a command`() {
        val sheet = BudgetSheetModel.project(night, monNine)
        assertEquals(
            SessionCommand.Budget(BudgetOpScope.PROJECT, "/Users/me/projects/night-owl", null, 30),
            sheet.command(30),
        )
        assertEquals(
            SessionCommand.Budget(BudgetOpScope.PROJECT, "/Users/me/projects/night-owl", null, null),
            sheet.command(null),
        )
    }

    @Test fun `a project's preview is the plain words for its value`() {
        val sheet = BudgetSheetModel.project(night, monNine)
        assertEquals("Page warns at 24% and stops Night Owl at 30% of the week. Resets Mon 09:00.", sheet.preview(30, utc))
    }

    @Test fun `the default's sheet has its own title, subtitle and preview`() {
        val d = BudgetSheetModel.forDefault(MacBudget(monNine, true, false, 34.0, 25, emptyList()))
        assertEquals("Default budget", d.title)
        assertEquals("For every project without a budget of its own", d.subtitle)
        assertEquals(25, d.cap)
        assertEquals("defaultCap-default", d.id)
        assertEquals(
            "Every project without its own budget stops at 25% of the week, with a warning at 20%. Resets Mon 09:00.",
            d.preview(25, utc),
        )
        assertEquals("No default: projects without a budget can use any share of the week. Resets Mon 09:00.", d.preview(null, utc))
    }

    @Test fun `the default's command needs no key`() {
        val d = BudgetSheetModel.forDefault(MacBudget(null, true, false, null, null, emptyList()))
        assertEquals(SessionCommand.Budget(BudgetOpScope.DEFAULT, null, null, 10), d.command(10))
        assertEquals(SessionCommand.Budget(BudgetOpScope.DEFAULT, null, null, null), d.command(null))
        assertNull(d.command(0))
        assertNull(d.command(101))
    }

    @Test fun `a command outside 1 to 100 is never sent`() {
        val sheet = BudgetSheetModel.project(night, monNine)
        assertNull(sheet.command(0))
        assertNull(sheet.command(-1))
        assertNull(sheet.command(101))
        assertNotNull(sheet.command(1))
        assertNotNull(sheet.command(100))
    }

    @Test fun `a project with no key to send back has no command`() {
        val sheet = BudgetSheetModel.project(night.copy(key = ""), monNine)
        assertNull(sheet.command(25))
        assertNull(BudgetSheetModel(BudgetSheetModel.Scope.PROJECT, "x", null, null, null, 25, null).command(25))
    }

    @Test fun `a session's sheet is seeded from its own cap, not the binding cap`() {
        val s = nwSession("s1", title = "bottle-flip", cwd = "~/code/bottle-flip").copy(
            budget = SessionBudget(
                projectKey = "/Users/me/code/bottle-flip", used = 18.4, cap = 8, scope = SessionBudget.Scope.PROJECT,
                state = BudgetState.OVER, sessionUsed = 6.1, sessionCap = 10,
            ),
        )
        val sheet = BudgetSheetModel.session(s, monNine)
        assertEquals(10, sheet.cap)
        close(6.1, sheet.used)
        assertEquals("This session only", sheet.title)
        assertEquals("s1", sheet.key)
        assertEquals("/Users/me/code/bottle-flip", sheet.projectKey)
        assertEquals("bottle-flip · 6% of the week so far", sheet.subtitle)
        assertEquals("session-s1", sheet.id)
    }

    @Test fun `a session's command carries its project key and its own id`() {
        val s = nwSession("s1", title = "bottle-flip", cwd = "~/code/bottle-flip").copy(
            budget = SessionBudget(
                projectKey = "/Users/me/code/bottle-flip", used = 18.4, cap = 25, scope = SessionBudget.Scope.PROJECT,
                state = BudgetState.OK, sessionUsed = 6.1, sessionCap = null,
            ),
        )
        val sheet = BudgetSheetModel.session(s, monNine)
        assertNull(sheet.cap)
        assertEquals(
            SessionCommand.Budget(BudgetOpScope.SESSION, "/Users/me/code/bottle-flip", "s1", 5),
            sheet.command(5),
        )
        assertEquals("Page warns at 4% and stops this session at 5% of the week. Resets Mon 09:00.", sheet.preview(5, utc))
        assertEquals("No budget of its own: this session shares bottle-flip's. Resets Mon 09:00.", sheet.preview(null, utc))
    }

    // MARK: BudgetSaveStatus

    @Test fun `the Mac being away and the relay being busy are said in words`() {
        assertEquals(BudgetSaveStatus.Failed(BudgetCopy.macOffline), BudgetSaveStatus.afterPost(SessionCommandOutcome.from(503, "")))
        assertEquals(BudgetSaveStatus.Failed(BudgetCopy.rateLimited), BudgetSaveStatus.afterPost(SessionCommandOutcome.from(429, "")))
    }

    @Test fun `a 202 means the Mac has it, so the sheet keeps waiting`() {
        assertNull(BudgetSaveStatus.afterPost(SessionCommandOutcome.from(202, "")))
        assertNull(BudgetSaveStatus.afterPost(SessionCommandOutcome.Accepted))
    }

    @Test fun `an old relay and a bad pairing get their own words`() {
        assertEquals(
            BudgetSaveStatus.Failed("Your relay doesn't support live sessions yet. Update your Cloudflare Worker."),
            BudgetSaveStatus.afterPost(SessionCommandOutcome.from(404, "")),
        )
        assertEquals(
            BudgetSaveStatus.Failed("The budget wasn't changed. The relay no longer accepts this pairing. Re-pair with your computer."),
            BudgetSaveStatus.afterPost(SessionCommandOutcome.from(401, "")),
        )
        assertEquals(
            BudgetSaveStatus.Failed("The budget wasn't changed. The relay returned an error (HTTP 500)."),
            BudgetSaveStatus.afterPost(SessionCommandOutcome.from(500, "")),
        )
        assertTrue(BudgetSaveStatus.afterPost(SessionCommandOutcome.from(400, "")) is BudgetSaveStatus.Failed)
    }

    @Test fun `the Mac's answer saves or says why it refused`() {
        assertEquals(BudgetSaveStatus.Saved, BudgetSaveStatus.from(result(ok = true)))
        assertEquals(
            BudgetSaveStatus.Failed("Your Mac doesn't have that project or session any more. The budget wasn't changed."),
            BudgetSaveStatus.from(result(ok = false, reason = "not_found")),
        )
        assertEquals(BudgetSaveStatus.Failed("Pct must be 1-100"), BudgetSaveStatus.from(result(ok = false, reason = "invalid", detail = "Pct must be 1-100")))
        assertEquals(BudgetSaveStatus.Failed("Your Mac couldn't change the budget."), BudgetSaveStatus.from(result(ok = false, reason = "other")))
        assertEquals(BudgetSaveStatus.Failed("Night Owl is busy"), BudgetSaveStatus.from(result(ok = false, reason = "other", detail = "Night Owl is busy")))
    }

    private fun result(ok: Boolean, reason: String? = null, detail: String? = null) = CommandResult(
        clientId = "c1", ok = ok, code = if (ok) CommandResult.Code.DELIVERED else CommandResult.Code.REFUSED,
        reason = reason, detail = detail, interventionId = null,
    )

}
