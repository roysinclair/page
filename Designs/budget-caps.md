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
`statusline/<session_id>.json` next to it: atomic (temp file, then `mv`), 0600 (umask 077),
the same content. The id is taken with `sed` in POSIX sh and kept to `[A-Za-z0-9-]`
(at most 128 characters); with nothing left, no per-session file is written. Files nobody has
touched for 8 days are removed. The fields used are:

| Field | Use |
|---|---|
| `session_id` | the session |
| `workspace.project_dir`, else `cwd` | the project (see *Project key*) |
| `cost.total_cost_usd` | the session's running cost: weight only, never shown |
| `rate_limits.seven_day.used_percentage`, `.resets_at` | the account's weekly %, and the window |

- **Existing installs get the new script at app start.** `UsageCapture.set(true)` returns early
  when settings are already wrapped, so at launch `UsageCapture.refreshWrapper()` rewrites the
  wrapper (0700) if capture is on and the file differs from the current script. Without it
  nothing would be measured on a Mac that turned capture on before budgets existed.
- **Usage capture must be on** (Settings ▸ Budget, "Show my Claude usage"). When it is off,
  every budget screen says "Turn on usage tracking in Page Studio ▸ Budget to set budgets"
  and nothing is enforced: Page removes every marker and allow file and closes its budget pages.
- **Sessions that never draw a status line are not counted:** `claude -p`, SDK runs, and
  other machines. That is why the footnote's "a little high" matters.

### Ledger (`budget-ledger.json`, 0600, atomic)

Kept per window, keyed by `seven_day.resets_at`:

- `startPct`: the weekly % the first time Page saw this window.
- Per session:
  - `projectKey`
  - `lastCost`: the last `total_cost_usd` seen.
  - `spent`: dollars counted in this window.

Updated on every `Coordinator.refreshUsage` pass (15 s) from the per-session files that changed
(by mtime; at most 256 KB read from each, with `BoundedFileRead`):

- **First sighting of a session in the window:** `lastCost = cost` and `spent = 0`.
  Spend from before Page saw it, such as a resumed session's history, is not counted.
- **Later sightings:**
  - If `cost ≥ lastCost`: `spent += cost − lastCost`.
  - If `cost < lastCost`, the counter was reset (`/clear`): `spent += cost`.
  - Then `lastCost = cost`.
- **When `resets_at` changes:** start a new window. Every `spent` goes to 0, `startPct` takes
  the new %, and `lastCost` is kept as the baseline the next sighting is measured from (what a
  session spent across the boundary counts in the new window, where most of it was).
  - A `resets_at` that moved by less than an hour is the same window (jitter); the latest value is kept.
  - The window only moves forward. A file still showing an older `resets_at` moves its session's
    `lastCost` and adds no spend. A file whose `resets_at` is already past, or that Claude Code wrote
    more than 6 hours ago, is ignored.
  - A weekly % that falls below `startPct` starts a new window.
  - Ten minutes after the window's reset with no sample from the next one, the old spend is dropped.
- **Finished sessions** (no file update for 8 days) are dropped. Their `spent` is kept per
  project as `closedSpent`.
- **Warned this window** (marker hashes) is kept in the ledger too, so a restart doesn't page again.

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

- The Mac's canonical key is `workspace.project_dir` with symlinks resolved (`realpath`, so
  `/tmp` is `/private/tmp`, as `pwd -P` says in the gate). If that is missing, it uses `cwd`. A path
  must be absolute and without control characters. A path in a macOS privacy-protected folder
  (Desktop, Documents, …) is left as written: even a stat there can raise the prompt.
- The Mac sends the key in every row. The phones echo it back verbatim and never derive it.
- The display name is what the Mac already calls the project everywhere else
  (`InterventionDetector.projectName`: the folder with a project marker, so `iOS/` reads as its
  parent). Deviation: not the phones' `ProjectLabel`, which names from a folder string alone.
- A running session the status line hasn't reported yet still gets a `list` row (its folder's
  project, used 0 of its own), so a budget can be set before the first status line.

## 3. Caps

- **Project caps:** `Config.budget.projects: [key: pct]`.
  - `Config.budget.defaultPct` is an optional cap for every project that has none of its own.
  - Both are written by Page Studio, `paged config set`, and the phone op `budget`.
- **Session caps:** `budget-session-caps.json` (0600), `{"<sessionId>": {"pct": 10, "seenAt": <unix seconds>}}`.
  - Dropped when the session has been gone 8 days (`seenAt` is refreshed about hourly while it runs).
- **Values:** whole percentages, 1–100. Off means no cap. `config.json` entries out of range, or whose
  key isn't an absolute folder, are dropped with a note; each entry decodes on its own, so old files load.
- **The binding cap** for a session is the one of its session cap and its project cap (own, else the
  default) that is further along: `over`, then `warn`, then `ok`; on a tie the lower cap; on a tie of
  both the project's. With both below 80% that is the lower cap, as written before; the refinement
  keeps a session the project's cap has stopped from reading `ok` because its own, lower, cap has room.
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
   each session over a session cap. `<hash>` is FNV-1a 64 (16 hex digits) of `p:<project key>` or
   `s:<session id>` (never `hashValue`, which changes on every launch):

   ```json
   {"project": "<key>", "session": "<id or null>", "name": "Night Owl", "cap": 25, "used": 25, "expiresAt": <weekly resets_at>}
   ```

   Beside it, `budget-over/<hash>.gate` (0600): plain `key=value` lines, which is all the hook reads:

   ```
   project=<absolute key, or empty>
   session=<session id, or empty>
   expires=<unix seconds: the window's reset>
   member=<session id>      any number: the ledger's sessions of this project
   spare=<session id>       any number: the ledger's sessions of other projects
   exclude=<absolute key>   any number: known projects nested inside this one
   stop=<the complete, pre-escaped JSON line the hook prints>
   ```

   The last three are only on a project's marker, and are rewritten as the ledger learns
   sessions and projects. They exist because projects nest: Claude Code run from `~/projects`
   is its own project, the parent of `~/projects/page`. A budget on `~/projects` must stop
   only the sessions that are its own, wherever they have cd'd, and never `~/projects/page`.

   A key with a newline gets no marker. Both files are written atomically (the `.gate` last) and
   removed together (the `.gate` first). The markers, the pages open for them, the sessions Page
   stopped and the allows live in `budget-state.json` (0600), so a restart changes nothing.
   Remove the marker when the cap is raised past `used`, when the window resets, when the cap is
   removed, or when capture is off. The first pass after launch recomputes from the loaded books and
   removes markers and allow files that no longer apply (never before the books are loaded).
2. **Interrupt.** Send Esc to the busy sessions it covers (and that hold no allow file), through the
   phone's Stop path (`ClaudeBackend.remoteInterrupt`, the one `stopFromStuckPage` uses), once per
   marker: the gate stops their later turns, and Terminal.app, which can't take Esc, would
   otherwise be retried every pass. The marker is in place before the Esc. A project marker covers
   a session whose ledger key is the project. A session the ledger hasn't seen yet is covered
   when its folder is inside the project but not inside a known nested project (the gate's rule,
   `BudgetGate.projectCovers`).
3. **Gate.** `hooks/page-budget-gate.sh` is a new PreToolUse entry, matcher `*`,
   non-blocking, timeout 5 s, installed by `HookInstaller` (Claude only; paged on Linux leaves it out
   until `install-linux.sh` ships the script). It is pure bash, runs under macOS `/bin/bash` 3.2, has no
   relay, no Python and no away or bypass step-aside.
   - Its folder is found as `page-notify.sh` finds its support folder (macOS, Linux XDG), or `PAGE_BUDGET_DIR`.
     With no `budget-over/` folder or no `*.gate` in it, it drains stdin and exits 0.
   - It reads the start of stdin (16 KB) and takes the first `session_id` and `cwd` strings, so text inside
     a tool's input that looks like those keys is never used. (Deviation: bash parameter expansion rather than
     `sed`, because a `sed` with a leading `.*` takes the last occurrence.) A `cwd` with a backslash is allowed.
   - A marker matches when its `session` equals `session_id`. A project marker (no `session`)
     matches a `member` wherever its `cwd` is, never a `spare`, and otherwise a call whose `cwd` is the
     marker's `project` or lies inside it, at a path boundary (`/x/proj` is not `/x/proj2`), but not
     inside an `exclude`. The `cwd` is also tried as `pwd -P` says it, since the key has its symlinks
     resolved.
   - Expired markers (`expires` < now) and malformed `.gate` files are ignored.
   - When a marker matches and the session has no allow file (`budget-allow/<session id>`, step 5), it prints
     the `stop` line:

     ```json
     {"continue":false,"stopReason":"Page: Night Owl reached its budget (25% of the week). Raise it in Page, or wait for the reset on Mon 09:00."}
     ```

     A session cap says "this session" in place of the project's name.
   - Every error, a missing directory or an unreadable file means allow: the gate fails open and always exits 0.
   - Typed prompts are not blocked. The turn they start is stopped at its first tool call,
     with the same message.
4. **Page.** A page of kind `rate_limit` and subtype `budget_reached`, id
   `page-budget-<hash>-stop-<reset epoch>`, session id `page-budget-<hash>` (`BudgetPages.isPageId`
   is the prefix `page-budget-`). Its card is closed when it stops applying: the cap raised past
   `used`, the window reset, capture turned off.
   - The text, word for word: "Night Owl reached its budget: about 26% of the week (budget 25%).
     Page stopped 2 sessions."
   - The phones parse `about N%`, `budget N%` and `stopped N session` from it. Without
     `budget N%` the raise button reads "Raise by 10%".
   - Reply mapping on the Mac (`Coordinator.route` takes budget page ids before `deliver`, so typed text
     can never reach a session):

     | Action | Effect |
     |---|---|
     | `approve` | Raise the binding cap by 10 (at most 100), for good, then carry on (below) |
     | `carry_on` | Let this turn finish, then carry on (below) |
     | `deny` | Keep stopped (closes the page) |
     | Typed text | Same as `deny` (no text is typed into the session) |

   - "The binding cap" a raise changes: a project's own cap; when it came from the default, the project's own
     cap becomes default + 10; a session's cap for a session marker. A cap already at 100 can't be raised.
   - **Carrying on.** Page pressed Esc, so both "Raise" and "Let this turn finish" resume the sessions Page
     stopped for that marker (the ones it interrupted, and those seen working while the marker stood), through
     the battery resume's `resumePausedSessions` path (only an idle session the user hasn't typed in since):
     "Page: budget raised to 35% — carry on where you left off." or "Page: you can finish this turn — carry on
     where you left off." A raise removes the marker before the message is typed; if the project has already
     spent past the new cap it stays stopped and the reply says so.
   - Every reply to the relay carries a human `detail`: "Raised Night Owl to 35%", "Night Owl can finish this
     turn", "Kept Night Owl stopped", or why it was refused.
   - The warning page, `page-budget-<hash>-warn-<reset epoch>`, is sent once per budget and window
     (`budget_warning`), and closed when the budget goes back below 80% or is reached. `approve` raises the
     cap as above; every other reply closes it.

5. **Let this turn finish.**
   - For each session the page covers that is stopped, or working now, write `budget-allow/<sessionId>`.
     The gate lets that session through while the file exists.
   - The Mac removes the file once that session has been seen working and is idle or waiting again, so
     the following turn is gated again; or after 30 minutes without it becoming busy; or when no marker
     covers it any more, or it is gone.
   - Interrupts are not sent to allowed sessions.

**Older phones** show `budget_*` pages as "Rate limit reached" with a text reply. That is
harmless, because typed text means "keep stopped".

**Hook install.** The canonical hook entries change (a Claude-only `PreToolUse` group, matcher `*`, timeout 5, command the
quoted path of `page-budget-gate.sh` beside `page-notify.sh`), so existing installs show as outdated
until "Install agent hooks…" is run again. Page recognises the gate's entry as its own (status, update,
uninstall, the bundle move), the build and installer ship the script beside `page-notify.sh`, and the
installer's tests include the new entry.

## 5. Wire (encrypted sessions channel; nothing new in the heartbeat)

- **`caps`** gains `budget-v1`. Phones draw budget controls only when the Mac advertises it.
- **`list` header** gains `budget`:

  ```json
  {"window": "week", "resetsAt": 1794852000, "capture": true, "measuring": false, "weekPct": 34,
   "defaultCap": null,
   "projects": [{"key": "/Users/me/projects/night-owl", "name": "Night Owl", "used": 18.4, "cap": 25, "state": "ok"}]}
  ```

  - `projects` is sorted by `used`, highest first, and lists every project with spend or a cap
    this window, live or not (at most 60). With capture off the block is still sent, with
    `"capture": false` and no projects.
- **`list` row** gains `budget`:

  ```json
  {"projectKey": "…", "used": 18.4, "cap": 25, "scope": "project", "state": "ok", "sessionUsed": 6.1, "sessionCap": null}
  ```

  - `cap` is the binding cap, and `scope` says whether it is the project's cap or the session's.
  - Every running Claude session has one while capture is on; none while it is off.
- **Op `budget`** sets or clears a cap. `pct: null` clears it:

  ```json
  {"op": "budget", "scope": "project" | "session" | "default", "key": "…", "sessionId": "…", "pct": 25 | null}
  ```

  - The phones send `{"op":"budget","scope":"project","key":"/Users/me/projects/night-owl","pct":30}`,
    `{"op":"budget","scope":"session","sessionId":"s1","key":"<the row's projectKey>","pct":10}` (the key is
    ignored) and `{"op":"budget","scope":"default","pct":null}`. A `pct` that is missing or `null` clears;
    a boolean, a fraction or a value outside 1–100 is refused, as is a `key` that isn't an absolute folder path
    (at most 1024 characters, no newline; trailing slashes are dropped) or a session id outside `[A-Za-z0-9-]`.
  - The Mac replies with `result`, and its next `list` echoes the new value. With capture off it refuses
    (`disabled`). The detail is a short sentence: "Night Owl's budget is now 30%".
  - Every edit, from the phone, Page Studio or the panel, goes through one `Coordinator.setBudget`: it
    loads config.json fresh (and refuses if it can't be read), writes, applies, and re-evaluates the markers at once.
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
   - With capture off the card is replaced by one line saying to turn on "Show my Claude usage".
7. **Menu-bar panel (the Now popover):** a slim **BUDGET** row under Open and Steer on every In-flight card
   and every finished-turn row (Claude sessions):
   - the mini bar (the same rules as the Page Studio bar), the detail line ("21% of 25%", "2% · no budget",
     amber from `warn`), and a **Set budget** button on the right in the same style as Open and Steer.
   - With usage capture off, only the label and the button; expanding says "Turn on usage tracking in
     Page Studio ▸ Budget to set budgets."
   - **Set budget** opens an editor inside the card (state in `NowStore`, no nested popover): a two-way toggle,
     "Project (all its sessions)" or "This session only"; presets Off · 10 · 25 · 50; a − N% + stepper in
     steps of 5; the plain-words preview line (`BudgetCopy.preview`, the same sentences as the iOS sheet);
     Cancel and Save. Save writes straight through `Coordinator.setBudget` and closes the editor. Esc cancels
     (before the panel's own Esc), Return saves, and no other key acts under it (so a "1" is never an approval).
   - One editor or composer at a time; a half-typed message, or an unsaved budget change, is never thrown away
     by opening the other.

Invariants from v5 hold:
- Red only for Irreversible, so budgets use amber and teal.
- Buttons are 44 pt.
- Text contrast is at least 4.5:1.
- No glass outside chrome.
- The estimate's footnote appears once, on Budget.
