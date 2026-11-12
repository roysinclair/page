# Every session in the Now panel, and dismissing the finished ones

Branch `panel-sessions` (stacked on `budget-caps`). Mac only: Page Studio's menu-bar panel and Preferences ▸ Terminals.

## What the user asked (2026-11-12)

> "Why are the ones that are finished, the icons look weird. They don't look like the ones that are in progress."

> "I definitely have more windows in progress than it's showing."

> "The stuff that's done ... I want to be able to just remove it off that screen so I can see everything that's going on. If I have no intention of getting back into that one ... I want to just be able to swipe it closed. And can we also make it a setting: if I swipe it closed, it actually just kills the terminal window as well?"

## What was wrong

1. **Two card styles.** The panel draws a finished turn (a `.review` row, chip FINISHED) with `NWDecideRowView`. It has small Open and Steer buttons, the chip right after the name, and no "Claude · model · cmux › x" line. A session in flight uses `NWInFlightRowView`, which has full-width buttons, the chip on the right, and the who-line. The `BUDGET` label also wrapped; that was fixed on `budget-caps` (5f05758).
2. **Idle sessions are invisible.** `InFlightRows.build` keeps only `state == .active`. On 2026-11-12, 13 Claude Code sessions were live in cmux: 2 busy and 11 idle at the prompt. Only the 2 with an open finished-turn page showed (as FINISHED rows). The other 9 were in no list.
3. **Nothing can be put away.** A FINISHED row stays until the session starts another turn.

## 1. One card for every session

Finished, idle and working sessions share one card anatomy: the In-flight card's. On a session that isn't working, the steps, workflows and health lines are replaced by LAST TURN:

```
▌ riot-io-teltonika                          FINISHED   ×
▌ Claude · Opus 5.5 · cmux › riot-io-teltonika
LAST TURN
  Changed 3 files                               (monoBody, textSecondary, ≤ 2 lines)
◷ idle 12m · session 6h 45m
[            Open            ] [            Steer            ]
BUDGET ▬▬▬▭  <1% · no budget                    [Set budget]
```

- **Chip**, on the right like LONG STEP: `FINISHED` (teal, as now) for a row with a finished-turn page; `IDLE` (textTertiary) for an idle session without one.
- **× (dismiss)**: 22×22, after the chip. It is textQuiet, and textSecondary on hover or when the card is selected. Only finished and idle cards have it, never a working card or a Decide or Look row. Tooltip: "Dismiss · ⌫ · hides it until its next turn". With the setting on (§4): "Dismiss · ⌫ · also closes its cmux tab" (the host's name, from the route).
- **Who-line**: backend · model · route, the same as In flight. A FINISHED row takes it from that session's idle row (`store.sessionCard(for: sessionId)`). Without one, the line is left out.
- **LAST TURN**: the page's summary on a FINISHED card. On an IDLE card it is the turn headline when Page has one (`InFlightCardInfo.lastTurn`); otherwise the section is left out.
- **Time line**: "idle 12m · session 6h 45m" (`InFlightCardInfo.idleTimeLine`). The session part only when the start is known.
- **Buttons**: full width (`fills: true`), as on In flight. A FINISHED card keeps its own actions: Open is `.openTerminal`, Steer is `.tellInstead` (the reply composer). An IDLE card uses the In-flight actions: Open, and Steer with `NWFlightComposer`, which types a plain message and starts a turn.
- The budget slot is unchanged.
- Selected border, hover, fold and receipt-thread motion stay as they are for each kind.

## 2. Idle sessions get a place: the IDLE group

A new group comes right after IN FLIGHT, in both `rowsBody` and `quietBody`. It also shows when nothing is in flight.

```
⌄ ● IDLE · 9                                    2 dismissed · Show
  [card] [card] [card]
  Show all 9
```

- **Header**: as IN FLIGHT's, but with a textQuiet dot. Collapsed, it shows the names after the count. Expanded, it shows the first `InFlightLayout.cap` (3) cards, then "Show all N" or "Show fewer".
  - New state in `NowPanelState`: `idleCollapsed` (default false) and `idleExpanded` (default false).
- **Contents**: `model.idle`, minus any session that has a row in `model.rows` (its FINISHED or Decide card already shows it), minus dismissed sessions, minus pending dismissals.
- **"N dismissed · Show"**, trailing, textTertiary. Shown only when the ledger hides at least one live session. It clears the ledger, so they all come back.
- **Order**: most recent activity first (`lastActivityAt` descending, then project, then id). A just-finished session sits at the top.
- **Keys**: ↑ and ↓ move through pages, then In flight, then IDLE. O, T and ⌫ act on the selected idle card.

### Model

- `NowModel.idle: [InFlightRow]`, from `InFlightRows.buildIdle(_ s:hosts:facts:now:)`.
  - **Included**:
    - sessions with `state == .idle`;
    - sessions with `state == .waitingOnUser` whose open pages are all finished-turn pages (`DecideRow.Section.review`). A session with an open finished-turn page is `.waitingOnUser`.
  - Codex and Claude are both included. Local models, Aura and Orbit are not.
  - **Row fields**:
    - `id = "idle-" + sessionId` (`InFlightRow.idlePrefix`); `kind .session`; `working false`;
    - `doing`: the last-turn headline, else "idle";
    - `since = lastActivityAt`;
    - `actions` and `target` as `build` makes them;
    - `card` from `InFlightCardInfo.makeIdle(facts:backend:idleSince:now:)`.
  - **Sort**: as above.
- The Mac probes routes and facts for idle sessions as it does for working ones (`AppDelegate.refreshRoutes`, `refreshActivity`), but less often for idle ones: when `lastActivityAt` changes, or every 30 s while the panel is up. Never on every tick.

## 3. Dismiss

There are four ways in:
- **Swipe sideways** with two fingers on the trackpad, either direction.
- **Click-drag** the card sideways with a mouse.
- **The × button.**
- **⌫** on the selected card.

VoiceOver gets the same as a named action, "Dismiss". No action depends on the gesture alone.

**What dismissing does:**
1. The card leaves at once. Its slot closes with the existing gap motion (`NowMotion.gaps`). Under Reduce Motion it fades.
2. For 5 seconds the panel's status line reads `Dismissed riot-io-teltonika · Undo`, or with the setting on `Closing riot-io-teltonika's cmux tab in 5s · Undo`. Undo puts the card back and nothing else happens.
3. After 5 seconds the dismissal commits. The timer lives in the controller (AppDelegate), so it commits even if the panel closes.
   - A ledger entry hides the session until its next turn.
   - A FINISHED row's page closes everywhere: the backend marks it dismissed, so it isn't reopened for the same turn, and closes it on the relay with reason `dismissed_at_mac`. The phone's page goes away too. Nothing is typed into the session, ever.
   - With the setting on, its terminal closes (§4).

**The ledger** is `SessionDismissals` in PageCore, persisted to `dismissed-sessions.json` in Application Support with mode 0600.
- It stores `[sessionId: SessionDismissal(sessionId, backend, at, pageId?)]`.
- `hides(_ session: AgentSession, openPageIds: Set<String>) -> Bool` is true while the session is neither `.active` nor `.waitingOnApproval`, and no page other than the dismissed one is open for it.
- `prune(live:openPages:)` drops an entry when:
  - its session is gone;
  - it became `.active` or `.waitingOnApproval`;
  - a different page opened for it.

  So the next time the session finishes, it shows again.
- Dismissable: `InFlightRow` with `working == false`, and `DecideRow` with `section == .review`. Nothing else.

**Swipe**
- A pure `SwipeDismissModel` in PageCore: `shouldDismiss(offset:width:velocity:) -> Bool`. It is true when |offset| ≥ 0.35 × width, or when |velocity| ≥ 900 pt/s and |offset| ≥ 40.
- `rubberBand(offset:)` resists past the threshold for a card that can't be dismissed. That case shouldn't arise: only dismissable cards take the gesture.
- **Trackpad**: the panel controller installs a local `scrollWheel` monitor while the panel is shown.
  - On `phase == .began` with |Δx| > 1.5·|Δy| over the hovered dismissable card (the store tracks it), it captures the gesture.
  - From then on it feeds `store.swipe = (rowId, offset)` and returns nil, so the ScrollView doesn't move.
  - On `.ended` or `.cancelled` it decides with the model and springs back or dismisses. Momentum events after a capture are swallowed.
  - Vertical gestures pass through untouched.
- **Mouse**: `DragGesture(minimumDistance: 12)` on the card. It is horizontal only and gives way to the card's tap-to-Open.
- **While swiping**, the card moves with the finger. Behind it, on the side it uncovers, a label shows:
  - `Dismiss` with an `xmark` symbol, teal;
  - with the setting on, `Dismiss · close tab`, amber.

## 4. The setting: also close its terminal

- **Config**: `dismissClosesTerminal: Bool = false`, top level, decoded and validated like the other booleans.
- **Preferences ▸ Terminals** gets a toggle: "Dismissing a session also closes its terminal tab".
  - Detail: "Swipe, × or ⌫ in the Now panel. Once its 5 seconds to undo are up, Page closes only that session's own cmux tab (or its workspace, when the tab is alone there), tmux pane, Terminal window, iTerm2 session, WezTerm pane or kitty window. That ends the agent there; pick it up later with `claude --resume`. A working session is never closed."
  - It's added to the `TowerControlHome` checklist if that list must cover new controls.
- **Exact target only.** There is no fallback ("activate any terminal" belongs to Open, never here). `TerminalClose` lives in PageCore:
  - Pure `plan(for host: <InjectionExecutor's host enum>) -> TerminalClosePlan`:
    - **cmux**: the tab and its workspace, via `CmuxBridge`. At run time Page lists the workspace's tabs (`--json --id-format uuids list-panels --workspace <ws>`):
      - another tab is there: `close-surface --surface <id> --workspace <ws> --force`;
      - the tab is alone: `close-workspace --workspace <ws> --force`, because cmux won't close a workspace's last tab;
      - the tab isn't listed: nothing closes.

      Checked against cmux 0.65.2 on 2026-11-12. Both commands ask for confirmation while a process runs, hence `--force`.
    - **tmux**: `kill-pane -t <%N>`. `isSafePane` is checked.
    - **Terminal.app**: AppleScript that closes the window whose only tab has the tty. If that tab shares its window, refuse: "Terminal can only close whole windows, and this tab shares one". `isSafeTTY` is checked.
    - **iTerm2**: AppleScript that closes the session with the tty. `isSafeTTY` is checked.
    - **WezTerm**: `cli kill-pane --pane-id <id>`.
    - **kitty**: `@ --to <socket> close-window --match id:<id>`.
    - **herdr, unreachable, unsupported, unknown, or no tty**: `.refuse("Page can't close <host> tabs")`.
  - Pure `eligible(_ status: ClaudeSessionStatus) -> Bool`: true only for `.idle` and `.shell`.
  - Blocking `close(sessionId:)`, run off main and only at commit time. It re-reads the live sessions and re-resolves the host. It refuses if:
    - the session is gone;
    - its status isn't eligible;
    - its pid changed;
    - the plan refuses.
- **Codex** sessions: refuse with "Page can close only Claude Code terminals for now". The dismissal itself still commits.
- **Outcomes** in the status line:
  - `Closed riot-io-teltonika's cmux tab`;
  - `Dismissed riot-io-teltonika · didn't close its tab: it started working again`;
  - `Dismissed riot-io-teltonika · Page can't close Ghostty tabs`.

  The same outcome goes in the log.
- **Coordinator API**:
  - `dismissSession(sessionId:backend:pageId:)`;
  - `closeTerminal(sessionId:backend:completion:)`;
  - `restoreDismissed()`.

## 5. Shortcuts

`ShortcutCatalog` ▸ IN THE NOW PANEL gets `⌫`: "Dismiss a finished or idle session". Detail: "Hides it until its next turn, with 5 seconds to undo. Swiping a card sideways or clicking its × does the same. With “also closes its terminal tab” on, its tab closes too". The panel's key handler maps Delete (and forward delete) to it.

## 6. Renders (demo names only)

These are new surfaces in the Mac render harness:
- `popover-sessions-rest`: one FINISHED card in the new style, two in flight, and the IDLE group with 3 of 5.
- `popover-sessions-idle-collapsed`.
- `popover-sessions-idle-all`.
- `popover-sessions-swipe`: a FINISHED card 120 pt into a swipe, with `Dismiss` showing.
- `popover-sessions-swipe-close`: the same with the setting on, showing `Dismiss · close tab`.
- `popover-sessions-undo`: the status line with Undo.
- `popover-sessions-closed`: the status line after a close.
- `popover-sessions-dismissed-show`: the header with "2 dismissed · Show".
- `tower-terminals`, re-rendered with the new toggle.

## 7. Not in this change

- No phone UI. A dismissed FINISHED page simply closes on the phone, like a page answered at the Mac.
- No Linux.
- No closing of working sessions, ever.
