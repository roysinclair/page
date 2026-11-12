package app.page.android.model

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Budget caps while the week is still being measured (Designs/budget-caps.md, "The work so far, while measuring"): each
 * project and session row shows its share of the work watched so far, never a share of the week, and draws no bar.
 */
class BudgetMeasuringTest {
    private fun close(expected: Double, actual: Double?) = assertEquals(expected, actual!!, 1e-9)

    private val help = "Its share of the work this week's sessions have done so far. It becomes a share of your week once the week has risen one whole point."

    private fun row(json: String) = SessionBudget.decode(parseJson(json))

    private fun project(json: String) = BudgetProject.decode(parseJson(json)!!)

    private fun header(json: String) = MacBudget.decode(parseJson(json))

    private fun budgetRow(
        work: Double? = null,
        cap: Int? = 25,
        used: Double = 18.4,
        measuring: Boolean = false,
    ) = SessionBudget(
        projectKey = "/Users/me/projects/night-owl", used = used, cap = cap, scope = SessionBudget.Scope.PROJECT,
        state = BudgetState.OK, work = work, measuring = measuring,
    )

    // MARK: BudgetWire.work (the scalar reader)

    @Test fun `a work share is a finite number from 0 to 100, kept as it is`() {
        assertEquals(0.0, BudgetWire.work(0.0)!!, 0.0)
        assertEquals(100.0, BudgetWire.work(100.0)!!, 0.0)
        assertEquals(63.0, BudgetWire.work(63.0)!!, 0.0)
        assertEquals(42.5, BudgetWire.work(42.5)!!, 0.0)
        assertEquals(0.4, BudgetWire.work(0.4)!!, 0.0)
    }

    @Test fun `a work share outside 0 to 100 is ignored, not clamped`() {
        assertNull(BudgetWire.work(-0.1))
        assertNull(BudgetWire.work(-3.0))
        assertNull(BudgetWire.work(100.1))
        assertNull(BudgetWire.work(150.0))
    }

    @Test fun `a work share that is missing or not a finite number is ignored`() {
        assertNull(BudgetWire.work(null))
        assertNull(BudgetWire.work(Double.NaN))
        assertNull(BudgetWire.work(Double.POSITIVE_INFINITY))
        assertNull(BudgetWire.work(Double.NEGATIVE_INFINITY))
    }

    // MARK: BudgetProject (a project row's work)

    @Test fun `a project row reads its work share, and has none without one`() {
        close(63.0, project("""{"key":"/x","used":18,"cap":25,"work":63}""")!!.work)
        assertNull(project("""{"key":"/x","used":18,"cap":25}""")!!.work)
    }

    @Test fun `a project's work at the edges, 0 and 100, is kept`() {
        close(0.0, project("""{"key":"/x","used":1,"work":0}""")!!.work)
        close(100.0, project("""{"key":"/x","used":1,"work":100}""")!!.work)
    }

    @Test fun `a project's work as a string, a bool or null is ignored`() {
        assertNull(project("""{"key":"/x","used":1,"work":"9"}""")!!.work)
        assertNull(project("""{"key":"/x","used":1,"work":"63"}""")!!.work)
        assertNull(project("""{"key":"/x","used":1,"work":true}""")!!.work)
        assertNull(project("""{"key":"/x","used":1,"work":false}""")!!.work)
        assertNull(project("""{"key":"/x","used":1,"work":null}""")!!.work)
    }

    @Test fun `a project's out-of-range work is ignored and the rest of the row stays`() {
        val p = project("""{"key":"/x","name":"X","used":18,"cap":25,"state":"ok","work":150}""")!!
        assertNull(p.work)
        assertEquals("/x", p.key)
        assertEquals("X", p.name)
        close(18.0, p.used)
        assertEquals(25, p.cap)
        assertEquals(BudgetState.OK, p.state)
        assertNull(project("""{"key":"/x","used":1,"work":-1}""")!!.work)
        assertNull(project("""{"key":"/x","used":1,"work":101}""")!!.work)
    }

    // MARK: MacBudget (the header: its measuring flag and project rows)

    @Test fun `the header decodes measuring and projects with and without work`() {
        val json = """
            {"window":"week","resetsAt":1794852000,"capture":true,"measuring":true,"weekPct":3,"defaultCap":25,
             "projects":[
               {"key":"/Users/me/projects/night-owl","name":"Night Owl","used":0.4,"cap":25,"state":"ok","work":63},
               {"key":"/Users/me/projects/relay","name":"relay","used":0.1,"work":0}
             ]}
        """.trimIndent()
        val b = header(json)!!
        assertTrue(b.measuring)
        assertEquals(25, b.defaultCap)
        assertEquals(2, b.projects.size)
        close(63.0, b.projects[0].work)
        close(0.0, b.projects[1].work)
        assertNull(b.projects[1].cap)
    }

    @Test fun `a header with no measuring word is not measuring, and its project rows carry no work`() {
        val b = header("""{"projects":[{"key":"/a","used":10}]}""")!!
        assertFalse(b.measuring)
        assertNull(b.projects[0].work)
    }

    @Test fun `bad work values in header rows drop no row`() {
        val json = """
            {"measuring":true,"projects":[
              {"key":"/a","used":1,"work":"9"},
              {"key":"/b","used":1,"work":150},
              {"key":"/c","used":1,"work":true},
              {"key":"/d","used":1,"work":40}
            ]}
        """.trimIndent()
        val b = header(json)!!
        assertEquals(listOf("/a", "/b", "/c", "/d"), b.projects.map { it.key })
        assertNull(b.projects[0].work)
        assertNull(b.projects[1].work)
        assertNull(b.projects[2].work)
        close(40.0, b.projects[3].work)
    }

    @Test fun `a project row with work but a bad share is still dropped`() {
        assertNull(project("""{"key":"/x","used":"1","work":63}"""))
        assertNull(project("""{"key":"","used":1,"work":63}"""))
    }

    // MARK: SessionBudget (a row's work and measuring)

    @Test fun `a row reads its work share and is measuring`() {
        val r = row("""{"projectKey":"/Users/me/x","used":0.4,"cap":25,"scope":"project","state":"ok","work":63}""")!!
        close(63.0, r.work)
        assertTrue(r.isMeasuring)
        assertFalse("the row has no flag of its own", r.measuring)
    }

    @Test fun `a row without work is not measuring`() {
        val r = row("""{"projectKey":"/Users/me/x","used":18.4,"cap":25}""")!!
        assertNull(r.work)
        assertFalse(r.isMeasuring)
        assertEquals("18% of 25%", r.meter.line)
    }

    @Test fun `a row's work as a numeric string is ignored`() {
        val r = row("""{"projectKey":"/x","used":1,"work":"9"}""")!!
        assertNull(r.work)
        assertFalse(r.isMeasuring)
    }

    @Test fun `a row's out-of-range or non-numeric work is ignored`() {
        assertNull(row("""{"projectKey":"/x","used":1,"work":101}""")!!.work)
        assertNull(row("""{"projectKey":"/x","used":1,"work":-1}""")!!.work)
        assertNull(row("""{"projectKey":"/x","used":1,"work":true}""")!!.work)
        assertNull(row("""{"projectKey":"/x","used":1,"work":null}""")!!.work)
        assertFalse(row("""{"projectKey":"/x","used":1,"work":"x"}""")!!.isMeasuring)
    }

    @Test fun `a row's work of 0 is still measuring, with no spend to show`() {
        val r = row("""{"projectKey":"/x","used":1,"work":0}""")!!
        close(0.0, r.work)
        assertTrue(r.isMeasuring)
        assertEquals("Measuring…", BudgetCopy.measuringLine(r.work))
    }

    @Test fun `a row a measuring header marks is measuring with no work yet`() {
        val r = budgetRow(work = null, measuring = true)
        assertTrue(r.isMeasuring)
        assertTrue(r.spokenDetail.startsWith("Measuring…"))
        assertTrue(r.spokenDetail.endsWith(help))
    }

    @Test fun `a row's work does not depend on its used share`() {
        val r = row("""{"projectKey":"/x","used":26,"cap":25,"work":12}""")!!
        assertEquals(BudgetState.OVER, row("""{"projectKey":"/x","used":26,"cap":25}""")!!.state)
        assertTrue(r.isMeasuring)
        close(12.0, r.work)
    }

    // MARK: BudgetCopy.measuringLine

    @Test fun `no work, zero, negative or not finite is plain Measuring`() {
        assertEquals("Measuring…", BudgetCopy.measuringLine(null))
        assertEquals("Measuring…", BudgetCopy.measuringLine(0.0))
        assertEquals("Measuring…", BudgetCopy.measuringLine(-0.0))
        assertEquals("Measuring…", BudgetCopy.measuringLine(-5.0))
        assertEquals("Measuring…", BudgetCopy.measuringLine(Double.NaN))
        assertEquals("Measuring…", BudgetCopy.measuringLine(Double.POSITIVE_INFINITY))
        assertEquals("Measuring…", BudgetCopy.measuringLine(Double.NEGATIVE_INFINITY))
    }

    @Test fun `plain Measuring is the same in the short form`() {
        assertEquals("Measuring…", BudgetCopy.measuringLine(null, short = true))
        assertEquals("Measuring…", BudgetCopy.measuringLine(0.0, short = true))
        assertEquals("Measuring…", BudgetCopy.measuringLine(Double.NaN, short = true))
    }

    @Test fun `the long form is a whole percent of the work so far`() {
        assertEquals("Measuring · 63% of the work so far", BudgetCopy.measuringLine(63.0))
    }

    @Test fun `the short form is a whole percent of work`() {
        assertEquals("Measuring · 63% of work", BudgetCopy.measuringLine(63.0, short = true))
    }

    @Test fun `halves round away from zero, and 63 point 4999 stays 63`() {
        assertEquals("Measuring · 63% of the work so far", BudgetCopy.measuringLine(63.4999))
        assertEquals("Measuring · 64% of the work so far", BudgetCopy.measuringLine(63.5))
        assertEquals("Measuring · 3% of work", BudgetCopy.measuringLine(2.5, short = true))
        assertEquals("Measuring · 100% of the work so far", BudgetCopy.measuringLine(99.5))
    }

    @Test fun `above 0 and below 1 reads as less than 1 percent`() {
        assertEquals("Measuring · <1% of the work so far", BudgetCopy.measuringLine(0.4))
        assertEquals("Measuring · <1% of the work so far", BudgetCopy.measuringLine(0.99))
        assertEquals("Measuring · <1% of work", BudgetCopy.measuringLine(0.0001, short = true))
    }

    @Test fun `1 is 1 percent, and 100 is 100 percent`() {
        assertEquals("Measuring · 1% of the work so far", BudgetCopy.measuringLine(1.0))
        assertEquals("Measuring · 100% of the work so far", BudgetCopy.measuringLine(100.0))
        assertEquals("Measuring · 100% of work", BudgetCopy.measuringLine(100.0, short = true))
    }

    @Test fun `above 100 reads as 100 percent, never more`() {
        assertEquals("Measuring · 100% of the work so far", BudgetCopy.measuringLine(150.0))
        assertEquals("Measuring · 100% of work", BudgetCopy.measuringLine(100.4, short = true))
    }

    // MARK: copy constants

    @Test fun `the Budget page's measuring note is the spec's words`() {
        assertEquals(
            "Measuring until the week rises one whole point. Meanwhile each project shows its share of the work so far.",
            BudgetCopy.measuring,
        )
    }

    @Test fun `the help text is the spec's words`() {
        assertEquals(
            "Its share of the work this week's sessions have done so far. It becomes a share of your week once the week has risen one whole point.",
            BudgetCopy.measuringHelp,
        )
    }

    // MARK: measuringDetail and measuringSpoken

    @Test fun `the detail is the long line, then the help text`() {
        assertEquals("Measuring · 63% of the work so far. $help", BudgetCopy.measuringDetail(63.0))
    }

    @Test fun `the detail with no work is plain Measuring, then the help text`() {
        assertEquals("Measuring… $help", BudgetCopy.measuringDetail(null))
    }

    @Test fun `the spoken line puts the name first`() {
        assertEquals(
            "payments-api, Measuring · 63% of the work so far. $help",
            BudgetCopy.measuringSpoken("payments-api", 63.0),
        )
    }

    // MARK: SessionBudget.spokenDetail

    @Test fun `a measuring row speaks the measuring detail`() {
        val r = budgetRow(work = 63.0)
        assertEquals(BudgetCopy.measuringDetail(63.0), r.spokenDetail)
        assertFalse("no bar, no share of the week", r.spokenDetail.contains("of the week,"))
    }

    @Test fun `a row flagged measuring by the header speaks the measuring detail`() {
        val r = budgetRow(work = 12.0, measuring = true)
        assertEquals(BudgetCopy.measuringDetail(12.0), r.spokenDetail)
    }

    @Test fun `a row not measuring speaks its meter`() {
        val r = budgetRow(work = null, measuring = false)
        assertEquals("18% of the week, budget 25%", r.spokenDetail)
        assertEquals(r.meter.spokenDetail, r.spokenDetail)
    }

    // MARK: BudgetCopy.chip

    @Test fun `no cap means no chip, measuring or not`() {
        assertNull(BudgetCopy.chip(budgetRow(cap = null)))
        assertNull(BudgetCopy.chip(budgetRow(cap = null, work = 63.0)))
        assertNull(BudgetCopy.chip(budgetRow(cap = null, measuring = true)))
    }

    @Test fun `while measuring the chip is the short line`() {
        assertEquals("Measuring · 63% of work", BudgetCopy.chip(budgetRow(work = 63.0)))
        assertEquals("Measuring · <1% of work", BudgetCopy.chip(budgetRow(work = 0.4)))
    }

    @Test fun `while measuring with no work the chip is plain Measuring`() {
        assertEquals("Measuring…", BudgetCopy.chip(budgetRow(work = null, measuring = true)))
        assertEquals("Measuring…", BudgetCopy.chip(budgetRow(work = 0.0)))
    }

    @Test fun `while measuring the chip does not show the used share`() {
        val c = BudgetCopy.chip(budgetRow(work = 63.0, used = 18.0))
        assertNotNull(c)
        assertFalse(c!!.contains("Budget"))
    }

    @Test fun `not measuring the chip is Budget used over cap`() {
        assertEquals("Budget 18/25%", BudgetCopy.chip(budgetRow(used = 18.4)))
        assertEquals("Budget 19/25%", BudgetCopy.chip(budgetRow(used = 18.5)))
        assertEquals("Budget 25/25%", BudgetCopy.chip(budgetRow(used = 25.0)))
    }

    // MARK: BudgetWire.gated

    private fun sessionWith(budget: SessionBudget?, id: String = "s1") = nwSession(id).copy(budget = budget)

    private val measuringHeader = MacBudget(
        resetsAt = null, capture = true, measuring = true, weekPct = 3.0, defaultCap = null, projects = emptyList(),
    )

    private val settledHeader = measuringHeader.copy(measuring = false)

    @Test fun `without budget-v1 a measuring header drops the block and every row budget`() {
        val s = sessionWith(budgetRow(work = 63.0))
        val (b, rows) = BudgetWire.gated(measuringHeader, listOf(s), setOf("hold-v1"))
        assertNull(b)
        assertNull(rows[0].budget)
    }

    @Test fun `with budget-v1 and a measuring header each row with a budget is measuring`() {
        val withBudget = sessionWith(budgetRow(work = 63.0), id = "a")
        val (b, rows) = BudgetWire.gated(measuringHeader, listOf(withBudget), setOf("budget-v1"))
        assertEquals(measuringHeader, b)
        assertTrue(rows[0].budget!!.measuring)
        assertTrue(rows[0].budget!!.isMeasuring)
        close(63.0, rows[0].budget!!.work)
    }

    @Test fun `with budget-v1 and a measuring header a row with no budget stays none`() {
        val none = nwSession("b")
        val (_, rows) = BudgetWire.gated(measuringHeader, listOf(none), setOf("budget-v1"))
        assertNull(rows[0].budget)
    }

    @Test fun `with budget-v1 and a measuring header a row already measuring is unchanged`() {
        val s = sessionWith(budgetRow(work = null, measuring = true))
        val (_, rows) = BudgetWire.gated(measuringHeader, listOf(s), setOf("budget-v1"))
        assertEquals(s, rows[0])
    }

    @Test fun `with budget-v1 and a measuring header the rows are the same otherwise`() {
        val s = sessionWith(budgetRow(work = 63.0, used = 18.4))
        val (_, rows) = BudgetWire.gated(measuringHeader, listOf(s), setOf("budget-v1"))
        assertEquals(s.budget!!.copy(measuring = true), rows[0].budget)
        assertEquals(s.copy(budget = s.budget!!.copy(measuring = true)), rows[0])
    }

    @Test fun `with budget-v1 and a settled header the rows are not made measuring`() {
        val s = sessionWith(budgetRow(work = null))
        val (b, rows) = BudgetWire.gated(settledHeader, listOf(s), setOf("budget-v1"))
        assertEquals(settledHeader, b)
        assertFalse(rows[0].budget!!.measuring)
        assertFalse(rows[0].budget!!.isMeasuring)
    }

    @Test fun `with budget-v1 and no header block a row is not made measuring`() {
        val s = sessionWith(budgetRow(work = null))
        val (b, rows) = BudgetWire.gated(null, listOf(s), setOf("budget-v1"))
        assertNull(b)
        assertFalse(rows[0].budget!!.measuring)
    }

    @Test fun `a row's work survives gating even against a settled header`() {
        val s = sessionWith(budgetRow(work = 63.0))
        val (_, rows) = BudgetWire.gated(settledHeader, listOf(s), setOf("budget-v1"))
        close(63.0, rows[0].budget!!.work)
        assertTrue(rows[0].budget!!.isMeasuring)
    }

    // MARK: the whole list, from JSON

    private fun list(caps: String, header: String, rowBudget: String) = """
        {"kind":"list","boot":"b1","seq":6,"ts":1761300000000,"macName":"Roy's MacBook",$caps
         "budget":$header,
         "sessions":[
          {"id":"s-claude","backend":"claude","title":"night-owl","cwd":"~/projects/night-owl","state":"active","canType":true,
           "budget":$rowBudget},
          {"id":"s-other","backend":"claude","title":"x","cwd":"~/x","state":"idle","canType":true}
         ]}
    """.trimIndent()

    private val measuringJsonHeader = """
        {"window":"week","resetsAt":1794852000,"capture":true,"measuring":true,"weekPct":0.4,"defaultCap":null,
         "projects":[{"key":"/Users/me/projects/night-owl","name":"Night Owl","used":0.4,"cap":25,"state":"ok","work":63}]}
    """.trimIndent()

    @Test fun `a measuring list from a Mac that does budgets marks its rows measuring from JSON`() {
        val json = list(
            """"caps":["hold-v1","budget-v1"],""",
            measuringJsonHeader,
            """{"projectKey":"/Users/me/projects/night-owl","used":0.4,"cap":25,"scope":"project","state":"ok","work":63}""",
        )
        val u = SessionsPlaintext.decode(json)!!.update as SessionsUpdate.ListUpdate
        assertTrue(u.budget!!.measuring)
        close(63.0, u.budget!!.projects[0].work)
        val row = u.sessions[0].budget!!
        assertTrue(row.measuring)
        assertTrue(row.isMeasuring)
        close(63.0, row.work)
        assertEquals("Measuring · 63% of work", BudgetCopy.chip(row))
        assertNull("a row with no budget stays none", u.sessions[1].budget)
    }

    @Test fun `a measuring list from a Mac without budget-v1 drops the measuring budget`() {
        val json = list(
            """"caps":["hold-v1"],""",
            measuringJsonHeader,
            """{"projectKey":"/Users/me/projects/night-owl","used":0.4,"cap":25,"scope":"project","state":"ok","work":63}""",
        )
        val u = SessionsPlaintext.decode(json)!!.update as SessionsUpdate.ListUpdate
        assertNull(u.budget)
        assertNull(u.sessions[0].budget)
        assertEquals(2, u.sessions.size)
    }

    @Test fun `a list row with a numeric-string work and out-of-range work is not measuring from JSON`() {
        val json = list(
            """"caps":["budget-v1"],""",
            """{"measuring":false,"projects":[]}""",
            """{"projectKey":"/Users/me/projects/night-owl","used":18,"cap":25,"work":"63"}""",
        )
        val u = SessionsPlaintext.decode(json)!!.update as SessionsUpdate.ListUpdate
        assertFalse(u.budget!!.measuring)
        val row = u.sessions[0].budget!!
        assertNull(row.work)
        assertFalse(row.isMeasuring)
        assertEquals("Budget 18/25%", BudgetCopy.chip(row))
    }

    @Test fun `a list row with work above 100 is not measuring from JSON`() {
        val json = list(
            """"caps":["budget-v1"],""",
            """{"measuring":true,"projects":[]}""",
            """{"projectKey":"/Users/me/projects/night-owl","used":0.4,"cap":25,"work":150}""",
        )
        val u = SessionsPlaintext.decode(json)!!.update as SessionsUpdate.ListUpdate
        // The header says measuring, so the row is measuring by the header, but its out-of-range work is ignored.
        val row = u.sessions[0].budget!!
        assertNull(row.work)
        assertTrue(row.isMeasuring)
        assertEquals("Measuring…", BudgetCopy.chip(row))
    }

    // MARK: BudgetSheetModel.subtitle while measuring

    private val night = BudgetProject(
        key = "/Users/me/projects/night-owl", name = "Night Owl", used = 18.4, cap = 25, state = BudgetState.OK,
    )

    @Test fun `a project measuring with work says its share of the work so far`() {
        val sheet = BudgetSheetModel.project(night.copy(work = 63.0), null)
        assertTrue(sheet.measuring)
        assertEquals("Measuring · 63% of the work so far", sheet.subtitle)
    }

    @Test fun `a project measuring without work says plain Measuring`() {
        val sheet = BudgetSheetModel.project(night.copy(work = null), null)
        assertFalse(sheet.measuring)
        assertEquals("18% of the week so far", sheet.subtitle)
    }

    @Test fun `a project measuring with 0 work says plain Measuring`() {
        val sheet = BudgetSheetModel.project(night.copy(work = 0.0), null)
        assertTrue(sheet.measuring)
        assertEquals("Measuring…", sheet.subtitle)
    }

    @Test fun `a sheet built to be measuring with no work says plain Measuring`() {
        val sheet = BudgetSheetModel(
            BudgetSheetModel.Scope.PROJECT, "Night Owl", "/x", null, 18.4, 25, null, measuring = true, work = null,
        )
        assertEquals("Measuring…", sheet.subtitle)
    }

    @Test fun `a project not measuring says its share of the week so far`() {
        val sheet = BudgetSheetModel.project(night, null)
        assertFalse(sheet.measuring)
        assertEquals("18% of the week so far", sheet.subtitle)
    }

    @Test fun `a measuring project's subtitle is the work, not the week`() {
        val sheet = BudgetSheetModel.project(night.copy(work = 12.0), null)
        assertFalse("the used share is not shown while measuring", sheet.subtitle.contains("of the week"))
    }

    @Test fun `a session measuring with its own work names the session and says its work`() {
        val s = nwSession("s1").copy(
            budget = SessionBudget(
                projectKey = "/Users/me/projects/night-owl", used = 18.4, cap = 25, scope = SessionBudget.Scope.SESSION,
                state = BudgetState.OK, sessionUsed = 6.1, sessionCap = 10, work = 40.0,
            ),
        )
        val sheet = BudgetSheetModel.session(s, null)
        assertTrue(sheet.measuring)
        assertEquals(40.0, sheet.work!!, 0.0)
        assertEquals("${sheet.name} · Measuring · 40% of the work so far", sheet.subtitle)
    }

    @Test fun `a session measuring on its project's work says plain Measuring, not the project's share`() {
        val s = nwSession("s1").copy(
            budget = SessionBudget(
                projectKey = "/Users/me/projects/night-owl", used = 18.4, cap = 25, scope = SessionBudget.Scope.PROJECT,
                state = BudgetState.OK, work = 40.0,
            ),
        )
        val sheet = BudgetSheetModel.session(s, null)
        assertTrue(sheet.measuring)
        assertNull("the project's work is not the session's", sheet.work)
        assertEquals("${sheet.name} · Measuring…", sheet.subtitle)
    }

    @Test fun `a session measuring by the header with no work says plain Measuring`() {
        val s = nwSession("s1").copy(
            budget = SessionBudget(
                projectKey = "/Users/me/projects/night-owl", used = 18.4, cap = 25, scope = SessionBudget.Scope.SESSION,
                state = BudgetState.OK, sessionUsed = 6.1, measuring = true,
            ),
        )
        val sheet = BudgetSheetModel.session(s, null)
        assertTrue(sheet.measuring)
        assertEquals("${sheet.name} · Measuring…", sheet.subtitle)
    }

    @Test fun `a session not measuring says its share of the week so far`() {
        val s = nwSession("s1").copy(
            budget = SessionBudget(
                projectKey = "/Users/me/projects/night-owl", used = 18.4, cap = 25, scope = SessionBudget.Scope.SESSION,
                state = BudgetState.OK, sessionUsed = 6.1, sessionCap = 10,
            ),
        )
        val sheet = BudgetSheetModel.session(s, null)
        assertFalse(sheet.measuring)
        assertNull(sheet.work)
        assertEquals("${sheet.name} · 6% of the week so far", sheet.subtitle)
    }

    @Test fun `the default budget's subtitle is its purpose, measuring or not`() {
        val b = MacBudget(
            resetsAt = null, capture = true, measuring = true, weekPct = 3.0, defaultCap = 25, projects = emptyList(),
        )
        val sheet = BudgetSheetModel.forDefault(b)
        assertFalse(sheet.measuring)
        assertEquals("For every project without a budget of its own", sheet.subtitle)
    }
}
