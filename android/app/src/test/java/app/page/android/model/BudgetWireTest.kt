package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Budget caps on the wire (Designs/budget-caps.md section 5): the `list` header and row, the `budget` op, and gating. */
class BudgetWireTest {
    private fun close(expected: Double, actual: Double?) = assertEquals(expected, actual!!, 1e-9)

    private val specHeader = """
        {"window": "week", "resetsAt": 1794852000, "capture": true, "measuring": false, "weekPct": 34,
         "defaultCap": null,
         "projects": [{"key": "/Users/me/projects/night-owl", "name": "Night Owl", "used": 18.4, "cap": 25, "state": "ok"}]}
    """.trimIndent()

    private fun header(json: String) = MacBudget.decode(parseJson(json))

    // MARK: constants

    // MARK: scalar readers

    @Test fun `a budget read off the wire is a whole number from 1 to 100`() {
        assertNull(BudgetWire.cap(null))
        assertNull(BudgetWire.cap(0.0))
        assertNull(BudgetWire.cap(101.0))
        assertNull(BudgetWire.cap(25.5))
        assertNull(BudgetWire.cap(Double.NaN))
        assertNull(BudgetWire.cap(Double.POSITIVE_INFINITY))
        assertEquals(1, BudgetWire.cap(1.0))
        assertEquals(25, BudgetWire.cap(25.0))
        assertEquals(100, BudgetWire.cap(100.0))
    }

    // MARK: MacBudget (the list header)

    @Test fun `the spec's header decodes to its week, projects and defaults`() {
        val b = header(specHeader)!!
        assertEquals(Instant.ofEpochSecond(1794852000), b.resetsAt)
        assertTrue(b.capture)
        assertFalse(b.measuring)
        close(34.0, b.weekPct)
        assertNull(b.defaultCap)
        assertEquals(1, b.projects.size)
        val p = b.projects[0]
        assertEquals("/Users/me/projects/night-owl", p.key)
        assertEquals("Night Owl", p.name)
        close(18.4, p.used)
        assertEquals(25, p.cap)
        assertEquals(BudgetState.OK, p.state)
        assertEquals("/Users/me/projects/night-owl", p.id)
    }

    @Test fun `a block that is not an object is no budget at all`() {
        assertNull(MacBudget.decode(null))
        assertNull(header("\"yes\""))
        assertNull(header("42"))
        assertNull(header("[]"))
        assertNull(header("null"))
    }

    @Test fun `missing header fields take their defaults`() {
        val b = header("""{"projects":[]}""")!!
        assertTrue("no word on capture still lists projects", b.capture)
        assertFalse(b.measuring)
        assertNull(b.weekPct)
        assertNull(b.defaultCap)
        assertNull(b.resetsAt)
        assertTrue(b.projects.isEmpty())
    }

    @Test fun `a week share as a string is missing, and out-of-range shares are clamped`() {
        assertNull(header("""{"weekPct":"34"}""")!!.weekPct)
        close(100.0, header("""{"weekPct":150}""")!!.weekPct)
        close(0.0, header("""{"weekPct":-3}""")!!.weekPct)
    }

    @Test fun `a bad project row is dropped and the good ones survive`() {
        val json = """
            {"projects":[
              {"key":"/a","name":"A","used":10,"cap":20,"state":"ok"},
              {"name":"no key","used":1},
              {"key":"   ","used":1},
              {"key":"/b"},
              "str",
              {"key":"/c","used":"12"},
              {"key":"/d","used":5}
            ]}
        """.trimIndent()
        val keys = header(json)!!.projects.map { it.key }
        assertEquals(listOf("/a", "/d"), keys)
    }

    @Test fun `at most 60 projects come onto the phone`() {
        val many = (0 until 61).joinToString(",") { """{"key":"/p$it","used":1}""" }
        val b = header("""{"projects":[$many]}""")!!
        assertEquals(60, b.projects.size)
        assertEquals("/p0", b.projects.first().key)
        assertEquals("/p59", b.projects.last().key)
    }

    // MARK: BudgetProject (a project row in the header)

    private fun project(json: String) = BudgetProject.decode(parseJson(json)!!)

    @Test fun `a project needs a key and a share, and the name falls back to the folder`() {
        assertNull(project("""{"used":1}"""))
        assertNull(project("""{"key":"/x"}"""))
        assertNull(project("""{"key":"/x","used":"x"}"""))
        assertNull(project("""{"key":"","used":1}"""))
        assertEquals("night-owl", project("""{"key":"/Users/me/projects/night-owl/","used":1}""")!!.name)
        assertEquals("Named", project("""{"key":"/x/y","name":"  Named  ","used":1}""")!!.name)
    }

    @Test fun `a project's used share is clamped to 0 through 100`() {
        close(0.0, project("""{"key":"/x","used":-4}""")!!.used)
        close(100.0, project("""{"key":"/x","used":140}""")!!.used)
    }

    @Test fun `a project's cap is a whole percentage or none`() {
        assertEquals(25, project("""{"key":"/x","used":1,"cap":25}""")!!.cap)
        assertEquals(25, project("""{"key":"/x","used":1,"cap":25.0}""")!!.cap)
        assertNull(project("""{"key":"/x","used":1,"cap":0}""")!!.cap)
        assertNull(project("""{"key":"/x","used":1,"cap":101}""")!!.cap)
        assertNull(project("""{"key":"/x","used":1,"cap":25.5}""")!!.cap)
        assertNull(project("""{"key":"/x","used":1,"cap":"25"}""")!!.cap)
        assertNull(project("""{"key":"/x","used":1,"cap":true}""")!!.cap)
        assertNull(project("""{"key":"/x","used":1}""")!!.cap)
    }

    @Test fun `a project's state is the Mac's word, or the numbers when it has none`() {
        assertEquals(BudgetState.WARN, project("""{"key":"/x","used":20,"cap":25}""")!!.state)
        assertEquals(BudgetState.OVER, project("""{"key":"/x","used":25,"cap":25}""")!!.state)
        assertEquals(BudgetState.OK, project("""{"key":"/x","used":18,"cap":25}""")!!.state)
        assertEquals("the Mac's word wins", BudgetState.OVER, project("""{"key":"/x","used":1,"cap":25,"state":"over"}""")!!.state)
        assertEquals("an unknown word is no word", BudgetState.OK, project("""{"key":"/x","used":1,"cap":25,"state":"nonsense"}""")!!.state)
        assertEquals(BudgetState.OK, project("""{"key":"/x","used":99}""")!!.state)
    }

    // MARK: SessionBudget (a row's budget)

    private fun row(json: String) = SessionBudget.decode(parseJson(json))

    @Test fun `a row's budget reads its project, share, cap and session share`() {
        val r = row("""{"projectKey":"/Users/me/x","used":18.4,"cap":25,"scope":"session","state":"warn","sessionUsed":6.1,"sessionCap":10}""")!!
        assertEquals("/Users/me/x", r.projectKey)
        close(18.4, r.used)
        assertEquals(25, r.cap)
        assertEquals(SessionBudget.Scope.SESSION, r.scope)
        assertEquals(BudgetState.WARN, r.state)
        close(6.1, r.sessionUsed)
        assertEquals(10, r.sessionCap)
        assertEquals("18% of 25%", r.meter.line)
    }

    @Test fun `a row's scope is project unless it says session`() {
        assertEquals(SessionBudget.Scope.PROJECT, row("""{"projectKey":"/x","used":1}""")!!.scope)
        assertEquals(SessionBudget.Scope.PROJECT, row("""{"projectKey":"/x","used":1,"scope":"weird"}""")!!.scope)
        assertEquals(SessionBudget.Scope.PROJECT, row("""{"projectKey":"/x","used":1,"scope":"project"}""")!!.scope)
    }

    @Test fun `a row with no key or no share has no budget`() {
        assertNull(row("""{"used":1,"cap":25}"""))
        assertNull(row("""{"projectKey":"","used":1}"""))
        assertNull(row("""{"projectKey":"/x"}"""))
        assertNull(row("""{"projectKey":"/x","used":"1"}"""))
        assertNull(SessionBudget.decode(null))
        assertNull(SessionBudget.decode(JsonPrimitive("budget")))
    }

    @Test fun `a row's bad cap is no cap, and its state comes from the numbers`() {
        val r = row("""{"projectKey":"/x","used":26,"cap":0,"sessionCap":0}""")!!
        assertNull(r.cap)
        assertNull(r.sessionCap)
        assertEquals(BudgetState.OK, r.state)
        assertEquals(BudgetState.OVER, row("""{"projectKey":"/x","used":26,"cap":25}""")!!.state)
        assertNull(row("""{"projectKey":"/x","used":1}""")!!.sessionUsed)
    }

    // MARK: gating

    private val budget = header(specHeader)!!

    private fun sessionWithBudget(id: String = "s1") = nwSession(id).copy(
        budget = SessionBudget(
            projectKey = "/Users/me/projects/night-owl", used = 18.4, cap = 25, scope = SessionBudget.Scope.PROJECT,
            state = BudgetState.OK, sessionUsed = 6.1, sessionCap = null,
        ),
    )

    @Test fun `without budget-v1 nothing budget survives the list`() {
        val s = sessionWithBudget()
        val (b, rows) = BudgetWire.gated(budget, listOf(s), setOf("hold-v1"))
        assertNull(b)
        assertEquals(1, rows.size)
        assertNull(rows[0].budget)
        assertEquals(s.copy(budget = null), rows[0])
    }

    @Test fun `with budget-v1 the block and the rows are kept as they came`() {
        val s = sessionWithBudget()
        val (b, rows) = BudgetWire.gated(budget, listOf(s), setOf("hold-v1", "budget-v1"))
        assertEquals(budget, b)
        assertEquals(listOf(s), rows)
    }

    @Test fun `no caps at all gates the block away`() {
        val (b, _) = BudgetWire.gated(budget, emptyList(), emptySet())
        assertNull(b)
    }

    // MARK: SessionsPlaintext (the whole list)

    private fun list(caps: String, budgetJson: String = specHeader) = """
        {"kind":"list","boot":"b1","seq":5,"ts":1761300000000,"macName":"Roy's MacBook",$caps
         "budget":$budgetJson,
         "sessions":[
          {"id":"s-claude","backend":"claude","title":"night-owl","cwd":"~/projects/night-owl","state":"active","canType":true,
           "budget":{"projectKey":"/Users/me/projects/night-owl","used":18.4,"cap":25,"scope":"project","state":"ok"}},
          {"id":"s-other","backend":"claude","title":"x","cwd":"~/x","state":"idle","canType":true}
         ]}
    """.trimIndent()

    @Test fun `a list from a Mac that does budgets carries the block and the row budget`() {
        val u = SessionsPlaintext.decode(list(""""caps":["hold-v1","budget-v1"],"""))!!.update as SessionsUpdate.ListUpdate
        assertTrue("budget-v1" in u.caps)
        val b = u.budget!!
        assertEquals(1, b.projects.size)
        assertEquals("Night Owl", b.projects[0].name)
        assertEquals(2, u.sessions.size)
        assertEquals(25, u.sessions[0].budget!!.cap)
        assertNull(u.sessions[1].budget)
    }

    @Test fun `a list from a Mac without budget-v1 drops every budget`() {
        val u = SessionsPlaintext.decode(list(""""caps":["hold-v1"],"""))!!.update as SessionsUpdate.ListUpdate
        assertNull(u.budget)
        assertNull(u.sessions[0].budget)
        assertEquals(2, u.sessions.size)
        assertEquals("the rest of the list is intact", "night-owl", u.sessions[0].title)
    }

    @Test fun `a list with no caps field at all drops every budget`() {
        val u = SessionsPlaintext.decode(list(""))!!.update as SessionsUpdate.ListUpdate
        assertNull(u.budget)
        assertNull(u.sessions[0].budget)
    }

    @Test fun `a budget block that is not an object does not fail the list`() {
        val p = SessionsPlaintext.decode(list(""""caps":["budget-v1"],""", budgetJson = "\"yes\""))
        assertNotNull(p)
        val u = p!!.update as SessionsUpdate.ListUpdate
        assertNull(u.budget)
        assertEquals(2, u.sessions.size)
        assertEquals(25, u.sessions[0].budget!!.cap)
    }

    // MARK: the `budget` op, as the phone sends it

    private val viewer = "viewer1"

    private fun op(cmd: SessionCommand.Budget): JsonObject =
        parseJsonObject(String(cmd.plaintext("c1", viewer, CMD_NOW), Charsets.UTF_8))!!

    @Test fun `a project op carries the key, the scope and the percentage`() {
        val o = op(SessionCommand.Budget(BudgetOpScope.PROJECT, "/Users/me/projects/night-owl", null, 30))
        assertEquals("budget", o["op"].asString())
        assertEquals("c1", o["clientId"].asString())
        assertEquals(viewer, o["viewer"].asString())
        assertEquals(1761300000000.0, o["ts"].asNumber()!!, 0.0)
        assertEquals("project", o["scope"].asString())
        assertEquals("/Users/me/projects/night-owl", o["key"].asString())
        assertEquals(30.0, o["pct"].asNumber()!!, 0.0)
        assertFalse("no session id on a project op", o.containsKey("sessionId"))
    }

    @Test fun `a clear sends an explicit null pct, so the Mac clears it`() {
        val o = op(SessionCommand.Budget(BudgetOpScope.PROJECT, "/Users/me/projects/night-owl", null, null))
        assertTrue("pct is present", o.containsKey("pct"))
        assertEquals(JsonNull, o["pct"])
        assertEquals("project", o["scope"].asString())
    }

    @Test fun `a session op carries the session id and the project key`() {
        val o = op(SessionCommand.Budget(BudgetOpScope.SESSION, "/Users/me/projects/night-owl", "s1", 10))
        assertEquals("budget", o["op"].asString())
        assertEquals("session", o["scope"].asString())
        assertEquals("s1", o["sessionId"].asString())
        assertEquals("/Users/me/projects/night-owl", o["key"].asString())
        assertEquals(10.0, o["pct"].asNumber()!!, 0.0)
    }

    @Test fun `a default op has neither key nor session id`() {
        val o = op(SessionCommand.Budget(BudgetOpScope.DEFAULT, null, null, 25))
        assertEquals("default", o["scope"].asString())
        assertEquals(25.0, o["pct"].asNumber()!!, 0.0)
        assertFalse(o.containsKey("key"))
        assertFalse(o.containsKey("sessionId"))
        assertEquals(setOf("op", "clientId", "ts", "viewer", "scope", "pct"), o.keys)
    }

}
