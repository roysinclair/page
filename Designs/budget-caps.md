# Budget caps

**Goal.** A project, or a single session, gets a share of the weekly Claude plan limit. Page
shows how much of that share each project has used. It warns at 80% of the share and stops
the project at 100%, so a runaway project can't eat the week that more important ones need.

Decided with the user (2026-11-10):

- **Scope:** caps per project; all its sessions share one cap. A single session can also
  have its own, tighter cap.
- **Window:** the weekly (7-day) limit only. If Claude Code doesn't report a weekly figure,
  nothing is measured and nothing is enforced.
- **At the cap:**
  - At 80% of the cap, a page goes to the phones.
  - At 100%, Page stops the project's sessions, blocks their tool calls, and sends a page with
    "Raise to N%" and "Let this turn finish".
- **Where it's set and seen:** Page Studio on the Mac, the iOS app and the Android app.
  - The Mac owns every value: it measures, stores and enforces.
  - The phones only display what the Mac reports and send changes back.
- **Not in v1:**
  - **Codex sessions:** OpenAI limits are a different plan, and Codex has no PreToolUse hook.
  - **Linux UI:** the core logic is shared, so `paged` measures and enforces too, set with
    `paged config set`.

## 1. Words

- **"Budget":** the share a project may use. "Night Owl's budget is 25% of the week."
- **Used:** always "of the week", never "tokens" or "$". "Night Owl has used 18% of the week."
- **Pairing used with budget:** "18% of 25%".
- **No budget set:** "18% · no budget".
- **Reset:** "resets Mon 09:00", from `seven_day.resets_at`, formatted like the existing Budget rings.
- **The estimate is honest in one place.** The Budget section footnote says: "Estimated from
  Claude Code on this Mac. Chats elsewhere count toward the week, so shares can read a
  little high."

## 2. Measurement (Mac only: PageCore, shared with Linux)

### Source

The status-line wrapper `page-statusline.sh` (`UsageCapture.script`) already saves the
latest status-line JSON to `statusline-input.json`. It also writes
`statusline/<session_id>.json`: atomic, 0600, with the same content. The fields used are:

| Field | Use |
|---|---|
| `session_id` | the session |
| `workspace.project_dir`, else `cwd` | the project (see *Project key*) |
| `cost.total_cost_usd` | the session's running cost: weight only, never shown |
| `rate_limits.seven_day.used_percentage`, `.resets_at` | the account's weekly %, and the window |

- **Usage capture must be on** (Settings ▸ Budget, "Show my Claude usage"). When it is off,
  every budget screen says "Turn on usage tracking in Page Studio to see and set budgets"
  and nothing is enforced.
- **Sessions that never draw a status line are not counted:** `claude -p`, SDK runs, and
  other machines. That is why the footnote's "a little high" matters.

### Ledger (`budget-ledger.json`, 0600, atomic)

Kept per window, keyed by `seven_day.resets_at`:

- `startPct`: the weekly % the first time Page saw this window.
- Per session:
  - `projectKey`
  - `lastCost`: the last `total_cost_usd` seen.
  - `spent`: dollars counted in this window.

Updated on every `Coordinator.refreshUsage` pass (15 s) from the per-session files that changed:

- **First sighting of a session in the window:** `lastCost = cost` and `spent = 0`.
  Spend from before Page saw it, such as a resumed session's history, is not counted.
- **Later sightings:**
  - If `cost ≥ lastCost`: `spent += cost − lastCost`.
  - If `cost < lastCost`, the counter was reset (`/clear`): `spent += cost`.
  - Then `lastCost = cost`.
- **When `resets_at` changes:** start a new window. Every `spent` goes to 0, `startPct` takes
  the new %, and every `lastCost` is re-baselined.
- **Finished sessions** (no file update for 8 days) are dropped. Their `spent` is kept per
  project as `closedSpent`.

### Estimate

Let `W` be the weekly % now, `C` the total `spent` of all sessions this window, and `S` the
`spent` of a project (live sessions plus `closedSpent`) or of one session.

    used(S) = (W − startPct) × S / C        (0 when C = 0)

- **Meaning:** each project gets its share of the rise Page has watched this week.
- **Usage before Page started watching** is attributed to no one.
- **Spend Page can't see** (claude.ai, other machines, `-p` runs) is spread over the projects
  it can see. That pushes shares high, which is the safe direction for a cap.
- **No tick deltas:** the weekly % arrives as an integer, so splitting each 15-second change
  would be mostly zeros and lumps.
- **No figure yet:** until `W − startPct ≥ 1`, Budget shows "Measuring…" for the week and no
  cap can trigger.

### Project key

- The Mac's canonical key is `workspace.project_dir` with symlinks resolved. If that is
  missing, it uses `cwd`.
- The Mac sends the key in every row. The phones echo it back verbatim and never derive it.
- The display name is the last path component, from the same `ProjectLabel` rule the phones use.

## 3. Caps

- **Project caps:** `Config.budget.projects: [key: pct]`.
  - `Config.budget.defaultPct` is an optional cap for every project that has none of its own.
  - Both are written by Page Studio, `paged config set`, and the phone op `budget`.
- **Session caps:** `budget-session-caps.json` (0600), `sessionId → pct`.
  - Dropped when the session has been gone 8 days.
- **Values:** whole percentages, 1–100. Off means no cap.
- **The binding cap** for a session is the lower of its session cap and its project cap.
  - `state`: `ok` below 80% of the binding cap, `warn` from 80%, `over` at 100%.
- **Raising a cap** (from the cap-reached page, or any control) changes the stored cap for good.
  - "Raise to N%" means the cap plus 10, at most 100.
  - The user can lower it again from any budget control.

## 4. Enforcement

**At `warn`** (once per project and window, or per session for a session cap):
- A page of kind `rate_limit` and subtype `budget_warning`, with session id
  `page-budget-<projectHash>`.
- The text, word for word (the phones read the numbers back with `BudgetPage.parse`):
  "Night Owl has used about 20% of the week (budget 25%). Page stops it at 25%."
- Phone card: the Look tone, headline "Near its budget", line "20% of its 25% budget", the bar,
  and "Raise to 35%".

**At `over`:**

1. **Marker.** Write `budget-over/<hash>.json` (0600) for each project over its cap, and for
   each session over a session cap:

   ```json
   {"project": "<key>", "session": "<id or null>", "name": "Night Owl", "cap": 25, "used": 25, "expiresAt": <weekly resets_at>}
   ```

   Remove the marker when the cap is raised past `used`, when the window resets, or at app
   start when it no longer applies.
2. **Interrupt.** Send Esc to the busy sessions it covers, the same way `stopFromStuckPage`
   does. On hosts that can't take Esc, like Terminal.app, the gate (step 3) stops them at
   their next tool call.
3. **Gate.** `hooks/page-budget-gate.sh` is a new PreToolUse entry, matcher `*`,
   non-blocking, timeout 5 s. It is pure bash with no relay, no Python and no away or bypass
   step-aside.
   - It reads stdin `session_id` and `cwd`.
   - A marker matches when its `session` equals `session_id`, or when it has no `session`
     and `cwd` is the marker's `project` or lies inside it.
   - Expired markers (`expiresAt` < now) are ignored.
   - When a marker matches and the session has no allow marker (step 5), it prints:

     ```json
     {"continue": false, "stopReason": "Page: Night Owl reached its budget (25% of the week). Raise it in Page, or wait for the reset on Mon 09:00."}
     ```

   - Every error, a missing directory or an unreadable file means allow: the gate fails open.
   - Typed prompts are not blocked. The turn they start is stopped at its first tool call,
     with the same message.
4. **Page.** A page of kind `rate_limit` and subtype `budget_reached`.
   - The text, word for word: "Night Owl reached its budget: about 26% of the week (budget 25%).
     Page stopped 2 sessions."
   - The phones parse `about N%`, `budget N%` and `stopped N session` from it. Without
     `budget N%` the raise button reads "Raise by 10%".
   - Reply mapping on the Mac:

     | Action | Effect |
     |---|---|
     | `approve` | Raise to N% |
     | `carry_on` | Let this turn finish |
     | `deny` | Keep stopped (closes the page) |
     | Typed text | Same as `deny` (no text is typed into the session) |

5. **Let this turn finish.**
   - For each session the page covers, write `budget-allow/<sessionId>`. The gate lets that
     session through while the marker exists.
   - The Mac removes the marker when that session next goes idle or waiting, so the following
     turn is gated again.
   - Interrupts are not sent to allowed sessions.

**Older phones** show `budget_*` pages as "Rate limit reached" with a text reply. That is
harmless, because typed text means "keep stopped".

**Hook install.** The canonical hook entries change, so existing installs show as outdated
until "Install agent hooks…" is run again. The installer and its tests include the new entry.

## 5. Wire (encrypted sessions channel; nothing new in the heartbeat)

- **`caps`** gains `budget-v1`. Phones draw budget controls only when the Mac advertises it.
- **`list` header** gains `budget`:

  ```json
  {"window": "week", "resetsAt": 1794852000, "capture": true, "measuring": false, "weekPct": 34,
   "defaultCap": null,
   "projects": [{"key": "/Users/me/projects/night-owl", "name": "Night Owl", "used": 18.4, "cap": 25, "state": "ok"}]}
  ```

  - `projects` is sorted by `used`, highest first, and lists every project with spend or a cap
    this window, live or not.
- **`list` row** gains `budget`:

  ```json
  {"projectKey": "…", "used": 18.4, "cap": 25, "scope": "project", "state": "ok", "sessionUsed": 6.1, "sessionCap": null}
  ```

  - `cap` is the binding cap, and `scope` says whether it is the project's cap or the session's.
- **Op `budget`** sets or clears a cap. `pct: null` clears it:

  ```json
  {"op": "budget", "scope": "project" | "session" | "default", "key": "…", "sessionId": "…", "pct": 25 | null}
  ```

  - The Mac replies with `result`, and its next `list` echoes the new value.
  - The relay answers `mac_offline` while the Mac is away. The control shows that and keeps
    the old value.
- **Page replies** use the existing `/reply` with the actions in §4.

## 6. Screens (iOS is the reference; Android and Page Studio port it)

Reference renders are in `Designs/budget-caps/`:
- `ios-tower-budget-projects.png`
- `ios-budget-sheet*.png`
- `ios-now-budget*.png`
- `mac-budget.png`

The iOS views are in `iOS/Page/Design/NightWatch/NWBudget.swift`, and their pure models in
`iOS/Page/Models/Budget.swift`. The Page Studio views are `NWBudgetBoardRowView`,
`NWBudgetStepper` and `NWBudgetBoardBar` in `TowerPages.swift`, with the model `BudgetBoard` in
`PageCore/UIModel/TowerModel.swift`.

**The bar, everywhere:**
- With a budget, the bar *is* the budget: the fill is used ÷ budget, and full means Page
  stopped it. A white tick marks 80%, where Page warns. It is teal below the tick and amber
  from it.
- With no budget, the bar is the whole week, in a faint sky colour, with no tick.

1. **Tower ▸ Budget.**
   - The existing rings stay as they are.
   - Below them, a "Projects this week" list, with "resets Fri 05:12" on the right of its title.
   - Each row has:
     - the project's icon tile, in its hue (a pause glyph once it's stopped);
     - its full name;
     - the bar;
     - one detail line: "21% of 25%", "11% of 15% · default budget", "2% · no budget", or
       "26% of 25% · stopped, raise it to carry on" (amber from `warn`).
   - A "Default for other projects" row with its value, then the honest footnote.
   - Tapping a row opens the budget sheet.
2. **Budget sheet** (project, session or default):
   - The project's name and hue band, and the current used %.
   - The new `NWPercentPicker`: presets Off · 10 · 25 · 50, and − / + in steps of 5, both
     44 pt and built once in `NWControls`.
   - A plain-words preview: "Page warns at 20% and stops Night Owl at 25%. Resets Mon 09:00."
   - A Save button.
   - The session variant is titled "This session only".
3. **In flight card:** a `BUDGET` fact row with a mini bar and "18% of 25%", in amber from
   `warn`, between TIME and WORKFLOWS.
4. **Session room:** a "Budget 18/25%" chip in the header, and a "Session budget…" action
   that opens the sheet in its session variant. The in-flight card's context menu has the same
   "Session budget…" item.
5. **Decide cards:**
   - `budget_reached` (`NWBudgetCard`): an ember jewel with the BUDGET chip and a pie emblem.
     - The project's name stays on the top line, so the title is "Stopped at its budget".
     - The line "about 26% of the week · 2 sessions stopped".
     - The bar is full.
     - Buttons "Let this turn finish" (glass) and "Raise to 35%" (white).
   - `budget_warning`: see §4.
   - A new `ChipKind.budget`: amber, titled "BUDGET", symbol `chart.pie.fill`. Red is never
     used for it.
6. **Page Studio ▸ Budget:** a "Project budgets · this week" card under the usage card. Each row
   has:
   - its tile, its name, the bar and the detail line;
   - an inline − 25% + stepper, in steps of 5. Below 5 it reads Off, or "Default" when the
     default applies.
   - Budgets apply straight away, outside the page's Apply button, and the footnote says so.

Invariants from v5 hold:
- Red only for Irreversible, so budgets use amber and teal.
- Buttons are 44 pt.
- Text contrast is at least 4.5:1.
- No glass outside chrome.
- The estimate's footnote appears once, on Budget.
