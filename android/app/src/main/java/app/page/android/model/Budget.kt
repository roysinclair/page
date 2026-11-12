package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// Budget caps (Designs/budget-caps.md): a project, or one session, may use a share of the weekly Claude limit. The
// Mac measures, stores and enforces; the phone draws what the Mac reports and sends changes back. A port of
// iOS/Page/Models/Budget.swift, string for string: the words, the bar, the picker's steps, the wire. Pure.

/** Swift's `.rounded()`: half away from zero (Kotlin's `roundToInt` is half up, `kotlin.math.round` half even). */
private fun Double.roundedHalfAway(): Int = if (this >= 0) Math.floor(this + 0.5).toInt() else -Math.floor(-this + 0.5).toInt()

/**
 * Where a budget stands, as the Mac reports it: below 80% of the cap, from 80%, or at the cap (Page has stopped it).
 */
enum class BudgetState(val wire: String) {
    OK("ok"), WARN("warn"), OVER("over");

    companion object {
        /** The state the numbers give, when the Mac didn't say. No cap is always ok. */
        fun of(used: Double, cap: Int?): BudgetState {
            if (cap == null || cap <= 0) return OK
            return when {
                used >= cap.toDouble() -> OVER
                used >= cap.toDouble() * BudgetCopy.warnShare -> WARN
                else -> OK
            }
        }

        /** "ok" / "warn" / "over"; anything else reads as null, and the numbers decide. */
        fun fromWire(raw: String?): BudgetState? {
            val t = (raw ?: return null).trim().lowercase()
            return entries.firstOrNull { it.wire == t }
        }
    }
}

// MARK: - Wire (the sessions `list`)

/**
 * The capability a Mac advertises (`caps`) when it measures and enforces budgets. Budget controls are drawn only when
 * it is there; the budget pages (`budget_reached`, `budget_warning`) come over the relay inbox and are drawn whatever
 * the list says.
 */
object BudgetWire {
    const val CAPABILITY = "budget-v1"

    /** The most projects one list carries onto the phone. */
    const val MAX_PROJECTS = 60

    /** A whole-percent budget the Mac would take: 1-100 (null is Off). */
    fun validCap(pct: Int?): Boolean = pct == null || pct in 1..100

    /** A budget read off the wire: a whole number 1-100, else none. */
    fun cap(raw: Double?): Int? {
        if (raw == null || !raw.isFinite() || raw != Math.rint(raw) || raw < 1 || raw > 100) return null
        return raw.toInt()
    }

    /** A share of the week read off the wire, kept in 0-100. */
    fun share(raw: Double?): Double? {
        if (raw == null || !raw.isFinite()) return null
        return minOf(100.0, maxOf(0.0, raw))
    }

    /**
     * The share of the work watched so far, read off the wire (`work`, only while the Mac is measuring): a finite number in
     * 0-100, else none. Unlike [share] a figure outside the range is ignored, not clamped: it is nothing the Mac would send.
     */
    fun work(raw: Double?): Double? {
        if (raw == null || !raw.isFinite() || raw < 0 || raw > 100) return null
        return raw
    }

    /**
     * What a `list` says about budgets once the Mac's capabilities are known: nothing at all without `budget-v1`, so no
     * card, chip or sheet is drawn for a Mac that cannot honour a budget. Pure.
     */
    fun gated(budget: MacBudget?, sessions: List<LiveSession>, caps: Set<String>): Pair<MacBudget?, List<LiveSession>> {
        if (CAPABILITY in caps) {
            if (budget?.measuring != true) return budget to sessions
            // The week is still being measured: a row has no flag of its own, so it takes the header's.
            return budget to sessions.map { s -> val sb = s.budget; if (sb == null || sb.measuring) s else s.copy(budget = sb.copy(measuring = true)) }
        }
        return null to sessions.map { if (it.budget == null) it else it.copy(budget = null) }
    }
}

/** The Mac's budget block for the week (the sessions list header). */
data class MacBudget(
    /** When the weekly limit resets. */
    val resetsAt: Instant?,
    /** Usage capture is on in Page Studio: without it nothing is measured. */
    val capture: Boolean,
    /** Not enough of the week has moved yet to share it out. */
    val measuring: Boolean,
    /** The account's weekly %, for the ring. */
    val weekPct: Double?,
    /** The budget every project without its own gets; null = none. */
    val defaultCap: Int?,
    /** Every project with spend or a budget this week, most used first. */
    val projects: List<BudgetProject>,
) {
    companion object {
        /**
         * Lenient, like every optional part of the list: a block that is not an object is null, a bad project row is
         * dropped, a bad number is missing. Nothing here can fail the list.
         */
        fun decode(element: JsonElement?): MacBudget? {
            val c = element as? JsonObject ?: return null
            return MacBudget(
                resetsAt = PageDate.parseAny(c["resetsAt"]),
                // Usage tracking is on unless the Mac says it is off: a block with no word on it still lists its projects.
                capture = c.bool("capture") ?: true,
                measuring = c.bool("measuring") ?: false,
                weekPct = BudgetWire.share(c.num("weekPct")),
                defaultCap = BudgetWire.cap(c.num("defaultCap")),
                projects = lossyList(c["projects"], BudgetProject::decode)?.elements?.take(BudgetWire.MAX_PROJECTS) ?: emptyList(),
            )
        }
    }
}

/**
 * One project's week. [key] is the Mac's (an absolute folder path); the phone sends it back verbatim and never derives
 * one.
 */
data class BudgetProject(
    val key: String,
    val name: String,
    /** Share of the week, 0-100. */
    val used: Double,
    /** Its own budget; null = none (the default may still apply: [effectiveCap]). */
    val cap: Int?,
    val state: BudgetState,
    /**
     * Its share of the work watched so far (0-100), sent only while the week is still being measured; null otherwise, and
     * for a Mac that doesn't send it. Not a share of the week: it never fills a bar. See [BudgetCopy.measuringLine].
     */
    val work: Double? = null,
) {
    val id: String get() = key

    /** Its own budget, else the default. */
    fun effectiveCap(default: Int?): Int? = cap ?: default

    /** The colour it wears everywhere else: the hue of its home-abbreviated folder, as session cards hash it. */
    val hue: ProjectHue get() = ProjectHue.of(PathDisplay.abbreviatingHome(key))

    companion object {
        /** Needs a key (the Mac's project folder, sent back verbatim) and a share; the rest has a fallback. */
        fun decode(element: JsonElement): BudgetProject? {
            val c = element as? JsonObject ?: return null
            val rawKey = Sw.trimWsNl(c.str("key") ?: "")
            if (rawKey.isEmpty() || Sw.count(rawKey) > 1024) return null
            val used = BudgetWire.share(c.num("used")) ?: return null
            val named = Sw.trimWsNl(c.str("name") ?: "")
            val cap = BudgetWire.cap(c.num("cap"))
            return BudgetProject(
                key = rawKey,
                name = Sw.prefix(if (named.isEmpty()) Sw.lastPathComponent(rawKey) else named, 80),
                used = used, cap = cap,
                state = BudgetState.fromWire(c.str("state")) ?: BudgetState.of(used, cap),
                work = BudgetWire.work(c.num("work")),
            )
        }
    }
}

/**
 * A session's budget (a sessions list row): the binding cap (the lower of its own and its project's) and how much of
 * it is used.
 */
data class SessionBudget(
    val projectKey: String,
    /** The project's share of the week (or the session's, when [scope] is session). */
    val used: Double,
    val cap: Int?,
    val scope: Scope,
    val state: BudgetState,
    /** The session's own share and budget, when it has one. */
    val sessionUsed: Double? = null,
    val sessionCap: Int? = null,
    /**
     * The binding scope's share of the work watched so far (0-100): the session's when [scope] is session, else the
     * project's. Sent only while the Mac is measuring (and has spent something); null otherwise, and for an older Mac.
     */
    val work: Double? = null,
    /** The list header says the week is still being measured ([BudgetWire.gated] sets it; a row has no flag of its own on the wire). */
    val measuring: Boolean = false,
) {
    enum class Scope(val wire: String) { PROJECT("project"), SESSION("session") }

    val meter: BudgetMeter get() = BudgetMeter(used, cap, state)

    /** The week is still being measured (the header says so, or the row carries [work], which is sent only then): the row says so and draws no bar. */
    val isMeasuring: Boolean get() = measuring || work != null

    /** What TalkBack says after a name: the meter's words, or while measuring the work so far and what it means. */
    val spokenDetail: String get() = if (isMeasuring) BudgetCopy.measuringDetail(work) else meter.spokenDetail

    companion object {
        /** Needs the project key and the share; a row whose `budget` is anything else has none. */
        fun decode(element: JsonElement?): SessionBudget? {
            val c = element as? JsonObject ?: return null
            val rawKey = Sw.trimWsNl(c.str("projectKey") ?: "")
            if (rawKey.isEmpty() || Sw.count(rawKey) > 1024) return null
            val used = BudgetWire.share(c.num("used")) ?: return null
            val cap = BudgetWire.cap(c.num("cap"))
            return SessionBudget(
                projectKey = rawKey, used = used, cap = cap,
                scope = Scope.entries.firstOrNull { it.wire == c.str("scope") } ?: Scope.PROJECT,
                state = BudgetState.fromWire(c.str("state")) ?: BudgetState.of(used, cap),
                sessionUsed = BudgetWire.share(c.num("sessionUsed")),
                sessionCap = BudgetWire.cap(c.num("sessionCap")),
                work = BudgetWire.work(c.num("work")),
            )
        }
    }
}

/** A budget as drawn: the words, the bar's fill and tone. */
data class BudgetMeter(
    val used: Double,
    val cap: Int?,
    val state: BudgetState,
    /** "18%" (or "<1%"). */
    val usedText: String,
    /** "18% of 25%"; "18% · no budget". */
    val line: String,
    /**
     * The bar's fill, 0...1. With a budget the bar is the budget (full = stopped); with none it is the whole week.
     */
    val fraction: Double,
    /** The warning tick on the bar, 0...1; null with no budget. */
    val warnMark: Double?,
    val tone: Tone,
) {
    enum class Tone { QUIET, CALM, WARM }

    /** "18% of the week, budget 25%": what TalkBack says after a name. */
    val spokenDetail: String
        get() {
            val base = "$usedText of the week"
            val cap = cap?.takeIf { it > 0 } ?: return "$base, no budget"
            return when (state) {
                BudgetState.OVER -> "$base, budget $cap% reached, stopped"
                BudgetState.WARN -> "$base, near its $cap% budget"
                BudgetState.OK -> "$base, budget $cap%"
            }
        }

    /** "Night Owl, 18% of the week, budget 25%" for TalkBack. */
    fun spoken(name: String): String = "$name, $spokenDetail"

    companion object {
        operator fun invoke(used: Double, cap: Int?, state: BudgetState? = null): BudgetMeter {
            val st = state ?: BudgetState.of(used, cap)
            val usedText = BudgetCopy.pct(used)
            return if (cap != null && cap > 0) {
                BudgetMeter(
                    used, cap, st, usedText, "$usedText of $cap%", minOf(1.0, maxOf(0.0, used / cap.toDouble())),
                    BudgetCopy.warnShare, if (st == BudgetState.OK) Tone.CALM else Tone.WARM,
                )
            } else {
                BudgetMeter(used, cap, st, usedText, "$usedText · no budget", minOf(1.0, maxOf(0.0, used / 100)), null, Tone.QUIET)
            }
        }
    }
}

/** The budget picker's values: Off, the presets, and steps of 5. */
object BudgetPercent {
    val presets: List<Int?> = listOf(null, 10, 25, 50)
    const val STEP = 5

    /** One step up: Off -> 5; 23 -> 25; 25 -> 30; never past 100. */
    fun up(v: Int?): Int {
        if (v == null) return STEP
        return minOf(100, (v / STEP + 1) * STEP)
    }

    /** One step down: 27 -> 25; 25 -> 20; 5 (or less) -> Off. */
    fun down(v: Int?): Int? {
        if (v == null) return null
        val next = if (v % STEP == 0) v - STEP else (v / STEP) * STEP
        return if (next < 1) null else next
    }

    /** The cap-reached page's "Raise to ...": ten more, at most 100. */
    fun raised(cap: Int): Int = minOf(100, cap + 10)

    /** "Off", "25%". */
    fun text(v: Int?): String = v?.let { "$it%" } ?: "Off"
}

object BudgetCopy {
    /** The pie that marks a budget: the BUDGET chip, the room's chip, the in-flight fact. */
    const val SYMBOL = "chart.pie.fill"

    /** A page and amber from this share of the budget. */
    const val warnShare = 0.8

    /** Where Page warns for a budget: 25 -> 20. */
    fun warnAt(cap: Int): Int = maxOf(1, (cap.toDouble() * warnShare).roundedHalfAway())

    /** "18%", "<1%", "100%". */
    fun pct(v: Double): String {
        if (v > 0 && v < 1) return "<1%"
        return "${v.roundedHalfAway()}%"
    }

    private val weekdays = listOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")

    /** "Mon 09:00". */
    fun resets(date: Instant, zone: ZoneId): String {
        val day = weekdays[date.atZone(zone).dayOfWeek.value % 7]
        return "$day ${NowFormat.clock(date, zone = zone)}"
    }

    /**
     * The budget sheet's plain-words line.
     * "Page warns at 20% and stops Night Owl at 25% of the week. Resets Mon 09:00."
     */
    fun preview(name: String, cap: Int?, session: Boolean, resetsAt: Instant?, zone: ZoneId): String {
        val reset = resetsAt?.let { " Resets ${resets(it, zone)}." } ?: ""
        val who = if (session) "this session" else name
        if (cap == null) {
            return if (session) "No budget of its own: this session shares $name's.$reset" else "No budget: $name can use any share of the week.$reset"
        }
        return "Page warns at ${warnAt(cap)}% and stops $who at $cap% of the week.$reset"
    }

    /** The one honest line, under the Budget list. */
    const val footnote = "Estimated from Claude Code on this Mac. Chats elsewhere count toward the week, so shares can read a little high."

    /** Budget with usage tracking off. */
    const val captureOff = "Turn on usage tracking in Page Studio ▸ Budget to see and set budgets."

    /** The Budget page's note while the week is still being measured. */
    const val measuring = "Measuring until the week rises one whole point. Meanwhile each project shows its share of the work so far."

    /** What "Measuring · 63% of the work so far" means: the accessibility help for a project or session row. */
    const val measuringHelp = "Its share of the work this week's sessions have done so far. It becomes a share of your week once the week has risen one whole point."

    /**
     * What a project or session says while the week is being measured (Designs/budget-caps.md): its share of the work
     * watched so far, never of the week.
     * - [work] known: "Measuring · 63% of the work so far", a whole percent, "<1%" above 0 and below 1.
     * - [short] (a compact one-line place): "Measuring · 63% of work".
     * - [work] null, 0 or not a finite number (nothing spent yet, an older Mac): plain "Measuring…".
     * A figure above 100 reads as 100%. Pure.
     */
    fun measuringLine(work: Double?, short: Boolean = false): String {
        if (work == null || !work.isFinite() || work <= 0) return "Measuring…"
        return "Measuring · ${pct(minOf(100.0, work))} of ${if (short) "work" else "the work so far"}"
    }

    /** What TalkBack says after a name for a measuring row: the long form, then [measuringHelp]. */
    fun measuringDetail(work: Double?): String {
        val line = measuringLine(work)
        // "Measuring…" already ends its sentence: no full stop after the ellipsis.
        return if (line.endsWith("…")) "$line $measuringHelp" else "$line. $measuringHelp"
    }

    /** "payments-api, Measuring · 63% of the work so far. Its share of the work this week's sessions have done so far. It becomes…". */
    fun measuringSpoken(name: String, work: Double?): String = "$name, ${measuringDetail(work)}"

    /**
     * The Session room's chip: "Budget 18/25%"; null with no budget. While the week is being measured ([SessionBudget.isMeasuring]) the
     * chip is a compact one-liner of the short form: "Measuring · 63% of work".
     */
    fun chip(b: SessionBudget): String? {
        val cap = b.cap ?: return null
        if (b.isMeasuring) return measuringLine(b.work, short = true)
        return "Budget ${b.used.roundedHalfAway()}/$cap%"
    }

    /** The cap-reached card's line: "about 25% of the week · 2 sessions stopped"; just "about 25% of the week" when the count is unknown. */
    fun reachedLine(used: Double, stopped: Int?): String {
        val week = "about ${pct(used)} of the week"
        if (stopped == null) return week
        return week + " · " + (if (stopped == 1) "1 session stopped" else "$stopped sessions stopped")
    }

    /** A change that could not reach the Mac: said once, in these words. */
    const val macOffline = "Your Mac is offline — the budget wasn't changed."

    /** The Mac didn't answer in time. */
    const val noAnswer = "Your Mac didn't confirm the change, so the budget may not have changed. Check again in a moment."

    /** The relay is too busy to take another change. */
    const val rateLimited = "Too many changes in a minute. Wait a moment and try again. The budget wasn't changed."

    /** A change the phone could not form (no key to send back, or a percentage the Mac would not take). */
    const val notSent = "That budget can't be sent. Nothing was changed."

    /**
     * What an answer to a budget page did, in words, for the receipts, Settled and History: "Raised Night Owl's budget",
     * "Let Night Owl's turn finish", "Kept Night Owl stopped". null for any other reply.
     */
    fun answered(action: String?, projectName: String): String? = when (action) {
        "approve" -> "Raised $projectName's budget"
        "carry_on" -> "Let $projectName's turn finish"
        // Typed text means the same as deny: nothing is typed into a session.
        null -> null
        else -> "Kept $projectName stopped"
    }

    /** The Decision sheet's "Delivered" line when the Mac said nothing more (nothing is typed for a budget page). */
    const val deliveredFallback = "Page Studio changed the budget on your computer"

    /** The Mac refused or failed the op. */
    fun refusal(reason: String?, detail: String?): String = when (reason) {
        "not_found" -> "Your Mac doesn't have that project or session any more. The budget wasn't changed."
        "stale", "replay" -> SessionResultCopy.refusal(reason, detail, "Your agent")
        "invalid" -> detail ?: "Your Mac didn't accept that percentage. The budget wasn't changed."
        else -> detail ?: "Your Mac couldn't change the budget."
    }
}

/**
 * What a budget page's text says. The Mac writes it in words ("Night Owl reached its budget: about 25% of the week
 * (budget 25%). Page stopped 2 sessions."); the phone reads back the numbers it needs for the card. Missing numbers
 * stay null.
 */
data class BudgetPage(val used: Double? = null, val cap: Int? = null, val stopped: Int? = null) {
    /**
     * The bar a budget page draws: the used share against the budget the text names. A cap-reached page that names none
     * is full by definition (it stopped at the budget); a warning without one has no bar.
     */
    fun meter(reached: Boolean): BudgetMeter? {
        val used = used ?: return null
        cap?.let { return BudgetMeter(used, it) }
        if (!reached) return null
        return BudgetMeter(used, maxOf(1, used.roundedHalfAway()), BudgetState.OVER)
    }

    /**
     * The card's line: "about 25% of the week · 2 sessions stopped" (reached), "20% of its 25% budget" (warning); null
     * when the text had no numbers.
     */
    fun line(reached: Boolean): String? {
        val used = used
        if (reached && used != null) return BudgetCopy.reachedLine(used, stopped)
        if (used != null && cap != null) return "${BudgetCopy.pct(used)} of its $cap% budget"
        return null
    }

    companion object {
        private val aboutUsed = Rx.compile("""(?i)about \d+(\.\d+)?%""")
        private val budgetCap = Rx.compile("""(?i)budget \d+%""")
        private val stoppedCount = Rx.compile("""(?i)stopped \d+ session""")

        fun parse(text: String): BudgetPage {
            fun number(p: java.util.regex.Pattern): Double? {
                val m = p.matcher(text)
                if (!m.find()) return null
                return m.group().filter { it.isDigit() || it == '.' }.toDoubleOrNull()
            }
            return BudgetPage(number(aboutUsed), number(budgetCap)?.toInt(), number(stoppedCount)?.toInt())
        }
    }
}

/** What a `budget` op edits, as the wire names it. */
enum class BudgetOpScope(val wire: String) { PROJECT("project"), SESSION("session"), DEFAULT("default") }

/** What the budget sheet edits: a project's budget, one session's, or the default. */
data class BudgetSheetModel(
    val scope: Scope,
    /** The project's name ("Night Owl"); unused for the default. */
    val name: String,
    /** The Mac's project key, or the session id: sent back verbatim. */
    val key: String?,
    /** The project's colour; null for the default. */
    val hue: ProjectHue?,
    /** The share of the week used so far; null for the default. */
    val used: Double?,
    /** The budget now. */
    val cap: Int?,
    val resetsAt: Instant?,
    /** A session's project key ([SessionBudget.projectKey]): sent with the session's own budget. */
    val projectKey: String? = null,
    /** The Mac is still measuring the week: [used] is not a share yet, [work] may say what share of the work it did. */
    val measuring: Boolean = false,
    /** Its share of the work so far, while measuring ([BudgetProject.work]); null when unknown. */
    val work: Double? = null,
) {
    enum class Scope(val raw: String) { PROJECT("project"), SESSION("session"), DEFAULT_CAP("defaultCap") }

    val id: String get() = "${scope.raw}-${key ?: "default"}"

    val title: String
        get() = when (scope) {
            Scope.PROJECT -> "$name’s budget"
            Scope.SESSION -> "This session only"
            Scope.DEFAULT_CAP -> "Default budget"
        }

    /** "18% of the week so far"; the default's purpose. */
    val subtitle: String
        get() = when (scope) {
            Scope.DEFAULT_CAP -> "For every project without a budget of its own"
            Scope.PROJECT, Scope.SESSION -> {
                val u = if (measuring) BudgetCopy.measuringLine(work)
                else used?.let { "${BudgetCopy.pct(it)} of the week so far" } ?: "Nothing used this week yet"
                if (scope == Scope.SESSION) "$name · $u" else u
            }
        }

    fun preview(value: Int?, zone: ZoneId): String {
        if (scope == Scope.DEFAULT_CAP) {
            val reset = resetsAt?.let { " Resets ${BudgetCopy.resets(it, zone)}." } ?: ""
            if (value == null) return "No default: projects without a budget can use any share of the week.$reset"
            return "Every project without its own budget stops at $value% of the week, with a warning at ${BudgetCopy.warnAt(value)}%.$reset"
        }
        return BudgetCopy.preview(name, value, scope == Scope.SESSION, resetsAt, zone)
    }

    /**
     * The `budget` op that saves [pct] (null = Off), or null when none can be sent: a project or session with no key to
     * send back, or a percentage the Mac would not take (outside 1-100).
     */
    fun command(pct: Int?): SessionCommand.Budget? {
        if (!BudgetWire.validCap(pct)) return null
        return when (scope) {
            Scope.PROJECT -> {
                val key = key?.takeIf { it.isNotEmpty() } ?: return null
                SessionCommand.Budget(BudgetOpScope.PROJECT, key, null, pct)
            }
            Scope.SESSION -> {
                val key = key?.takeIf { it.isNotEmpty() } ?: return null
                SessionCommand.Budget(BudgetOpScope.SESSION, projectKey, key, pct)
            }
            Scope.DEFAULT_CAP -> SessionCommand.Budget(BudgetOpScope.DEFAULT, null, null, pct)
        }
    }

    companion object {
        /** A project's sheet: its own budget (not the default it may be using) is what is edited. */
        fun project(p: BudgetProject, resetsAt: Instant?): BudgetSheetModel =
            BudgetSheetModel(Scope.PROJECT, p.name, p.key, p.hue, p.used, p.cap, resetsAt, measuring = p.work != null, work = p.work)

        /** The default for projects with none of their own. */
        fun forDefault(b: MacBudget): BudgetSheetModel = BudgetSheetModel(Scope.DEFAULT_CAP, "", null, null, null, b.defaultCap, b.resetsAt)

        /**
         * "This session only": the session's own budget and share, never the binding cap (saving that unchanged would
         * quietly give the session a budget equal to its project's).
         */
        fun session(s: LiveSession, resetsAt: Instant?): BudgetSheetModel = BudgetSheetModel(
            Scope.SESSION, SkyModel.projectName(s.cwd, s.title), s.id, ProjectHue.of(if (s.cwd.isEmpty()) s.title else s.cwd),
            s.budget?.sessionUsed, s.budget?.sessionCap, resetsAt, s.budget?.projectKey,
            measuring = s.budget?.isMeasuring == true,
            // A row's work is the binding scope's: the session's own only when its own budget binds.
            work = s.budget?.takeIf { it.scope == SessionBudget.Scope.SESSION }?.work,
        )
    }
}

/**
 * Where a budget change stands, for the sheet's own line. The sheet keeps the old value until the Mac answers; [Saved]
 * closes it, [Failed] says why under the picker and leaves the old value in place.
 */
sealed interface BudgetSaveStatus {
    data object Idle : BudgetSaveStatus
    data object Saving : BudgetSaveStatus
    data object Saved : BudgetSaveStatus
    data class Failed(val why: String) : BudgetSaveStatus

    val isSaving: Boolean get() = this == Saving
    val failure: String? get() = (this as? Failed)?.why

    companion object {
        /** How long the Mac has to answer. */
        val RESULT_TIMEOUT: Double get() = SessionDeliveryState.RESULT_TIMEOUT

        /**
         * The relay answered the POST. Only a refusal says anything: 202 means the Mac has it, and its `result` is the
         * answer (null = keep waiting). A Mac that is away is said in the spec's words.
         */
        fun afterPost(outcome: SessionCommandOutcome): BudgetSaveStatus? = when (outcome) {
            SessionCommandOutcome.Accepted -> null
            SessionCommandOutcome.MacOffline -> Failed(BudgetCopy.macOffline)
            SessionCommandOutcome.RateLimited -> Failed(BudgetCopy.rateLimited)
            SessionCommandOutcome.RelayTooOld -> Failed("Your relay doesn't support live sessions yet. Update your Cloudflare Worker.")
            else -> Failed(listOfNotNull("The budget wasn't changed.", outcome.failureMessage).joinToString(" "))
        }

        /** The Mac's `result` for the op: ok is saved; anything else is its words, or Page's for a known reason. */
        fun from(result: CommandResult): BudgetSaveStatus =
            if (result.ok) Saved else Failed(BudgetCopy.refusal(result.reason, result.detail))

        /** The Mac never answered within the wait. */
        val noAnswer: BudgetSaveStatus = Failed(BudgetCopy.noAnswer)
    }
}

/**
 * What a `budget` op does to the Mac's last report, for the demo's pretend Mac (a real Mac answers with its next
 * `list`). Pure.
 */
object BudgetEdit {
    fun applying(budget: MacBudget?, sessions: List<LiveSession>, op: SessionCommand.Budget): Pair<MacBudget?, List<LiveSession>> {
        val cap = op.pct
        fun bound(own: Int?, other: Int?): Int? = listOfNotNull(own, other).minOrNull()
        return when (op.scope) {
            BudgetOpScope.DEFAULT -> {
                val b = budget?.copy(defaultCap = cap)
                // Projects without their own budget follow the default.
                b to sessions.map { s ->
                    val sb = s.budget ?: return@map s
                    val projectOwn = b?.projects?.firstOrNull { it.key == sb.projectKey }?.cap
                    val effective = bound(projectOwn ?: cap, sb.sessionCap)
                    s.copy(budget = sb.copy(cap = effective, state = BudgetState.of(sb.used, effective)))
                }
            }
            BudgetOpScope.PROJECT -> {
                val b = budget?.copy(projects = budget.projects.map { p ->
                    if (p.key != op.key) p else p.copy(cap = cap, state = BudgetState.of(p.used, cap ?: budget.defaultCap))
                })
                b to sessions.map { s ->
                    val sb = s.budget ?: return@map s
                    if (sb.projectKey != op.key) return@map s
                    val effective = bound(cap ?: budget?.defaultCap, sb.sessionCap)
                    s.copy(budget = sb.copy(cap = effective, state = BudgetState.of(sb.used, effective)))
                }
            }
            BudgetOpScope.SESSION -> budget to sessions.map { s ->
                val sb = s.budget
                if (s.id != op.sessionId || sb == null) return@map s
                val project = budget?.projects?.firstOrNull { it.key == sb.projectKey }
                // The binding budget is the one further along; the lower cap on a tie (as the Mac decides).
                val pCap = project?.cap ?: budget?.defaultCap
                val pUsed = project?.used ?: if (sb.scope == SessionBudget.Scope.PROJECT) sb.used else 0.0
                val pState = BudgetState.of(pUsed, pCap)
                val sUsed = sb.sessionUsed ?: 0.0
                val sState = BudgetState.of(sUsed, cap)
                val sessionBinds = cap != null && (pCap == null || sState.ordinal > pState.ordinal || (sState == pState && cap < pCap))
                s.copy(budget = if (sessionBinds) sb.copy(scope = SessionBudget.Scope.SESSION, used = sUsed, cap = cap, sessionCap = cap, state = sState)
                                else sb.copy(scope = SessionBudget.Scope.PROJECT, used = pUsed, cap = pCap, sessionCap = cap, state = pState))
            }
        }
    }
}
