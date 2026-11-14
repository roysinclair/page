# One conversation open in two terminals, and sessions reopened after a restart

## What happened (2026-11-14)

The Mac was restarted. At 07:07:19 cmux's `autoResumeAgentSessions` (on by default) ran
`claude --resume <id>` in all 15 panes it restored. At 07:08:36 the user typed `claude --continue` in a new
window in `~/projects/workspace`. `--continue` opens the newest conversation in that folder, which was the one
cmux had just reopened. So two Claude processes ran conversation `c3da7923` at the same time:

- pid 2992, ttys000: reopened by cmux, mostly idle;
- pid 7835, ttys016: where the work happened.

Both appended to one transcript, and each knew only its own half. The same thing had happened on 2026-11-13.

What Page did with this:

- **The phone row followed the idle copy.** The registry sorts by pid, and `SessionRemote.currentRows`
  keeps the first row for each sessionId, so the row showed pid 2992.
- **26 "idle in workspace" pages** between 07:15 and 12:18. The idle copy's detector saw the shared
  transcript move (the busy copy writing), resolved its page, and opened it again. This cause is likely, not
  proven.
- **Replies would have gone to the idle copy.** A reply to one of those pages would have typed into pid 2992,
  because `pickSession` matches `pagePid`. Typing from the session room was refused with "Session is open in
  more than one terminal — reply at your computer".
- **5 idle pages at 07:08:37** for sessions cmux had reopened and nobody had touched. A reopened process's
  `statusUpdatedAt` is its start time, so `mayOpen`'s "fresh" test passes, and the page opens after
  `idleDelay`.

The user chose: fix both, leave cmux's auto-resume on.

## A. One conversation, several terminals

**Copies.** These are live interactive Claude processes (registry sessions with a TTY, kind interactive)
whose `sessionId` is the same. Background owners (`kind` bg/daemon) and `--print` resumes are not copies.

**The copy Page follows** (the "lead"), picked fresh on every tick by:

1. Status: `waiting`, then `busy`, then `shell`, then `idle`, then `unknown`.
2. Then the latest `statusUpdatedAt`.
3. Then the latest `startedAt`.
4. Then the highest pid.

The pick is a pure function with unit tests.

**What follows the lead:**

- **Pages.** The detector scans only the lead of each conversation. The other copies never open a page.
  When the lead changes, a page held by a copy that is no longer the lead closes, unless the new lead
  carries the same prompt. Closing never cascades to a waiting prompt on the new lead.
- **The phone row and the Mac card.** Their state, preview, `ask` and `canType` / `canHold` come from the
  lead.
- **Typing and replies.**
  - The session room types into the lead. This replaces the "more than one terminal" refusal.
  - A reply to a page types into the page's pid while that pid is still the lead.
  - If the lead has changed since the page opened, the reply is refused with "This conversation moved to
    another terminal — check it on your Mac". A prompt that was answered in one copy must never be answered
    again in another.
  - Every gate re-check (status, foreground, draft box) runs against the lead's pid.
- **The battery pause, budgets and closing a terminal** act on the lead, as they act on a single copy today.
  Budgets count tokens per conversation, so nothing changes there.

**What the person sees.** The aim is one warning that says what is wrong and what to do, with no jargon
(no pid, no tty):

| Where | Copy |
|---|---|
| Phone: Lanes and Now row | small amber line under the title: **Open in 2 terminals** |
| Phone: session room, under the header | amber notice: **Open in 2 terminals on your Mac.** Both write to this conversation and each remembers only its own part. Close the one you’re not using. Messages from here go to the one that’s working. |
| Mac: Now panel card | amber line: **Open in 2 terminals · close one**, with a **Close the other** button (see below) |
| Mac: notification, once per conversation, when a second copy appears | Title **workspace is open twice**. Body: Two terminals are running the same Claude conversation. Each remembers only its own part. Close the one you’re not using. |

- N is the count (2, 3, …). The notification fires again only after the conversation has been back to one
  copy for 60 s.
- **"Close the other"** on the Mac uses the existing close-terminal path (`dismissClosesTerminal` machinery:
  the exact cmux tab or pane, no fallback). It closes every copy that is not the lead, and never a copy that
  is `busy` or `waiting`. It is offered only when every other copy is idle or shell and in cmux. It asks
  first, in the panel's own confirm style: "Close the other workspace terminal? Claude there is idle. Its
  part of the conversation stays in the history." Without cmux, there's no button, only the line.

**Wire (sessions-v1).** The row gains an optional `copies` (integer ≥ 2, present only when above 1).
Phones that don't know it ignore it. docs/SESSIONS-PROTOCOL.md §4 documents it.

## B. Sessions reopened after a restart

A Claude process opened on an existing conversation (`--resume`, `--continue`, cmux auto-resume) whose
transcript's last finished turn ended before the process started has done nothing yet in this run. It
doesn't open an idle page.

The rule is pure: an idle page needs the last assistant turn's end (its timestamp in the transcript) to be at
or after the process's `startedAt`. It is checked only when both are known. Approvals and questions
(`waiting`) are not affected. Once the person types into it and a turn ends, it pages as usual.

## C. Renamed windows and tabs come through

The user asked on 2026-11-14 that when they rename windows, tabs and the like, the new name shows in Page.

**Today:**
- A Claude session's title is always its folder name (`InterventionDetector.projectName(forCwd:)`). Page
  ignores:
  - Claude Code's `/rename`, which writes a `custom-title` entry to the transcript;
  - cmux renames: `workspace list` shows `custom_title` and `has_custom_title`. The user named their
    workspace window "Workspace-App" that morning.
- Codex rows already use the thread's name (`displayTitle`), and Aura rows use the chat title.

**The name Page shows for a Claude session.** The rule is pure, takes the first that exists, and has unit
tests:

1. **The cmux tab's own name**, set with rename-tab or in the UI. Use it only if cmux marks it as custom. Check
   this in a throwaway cmux workspace, never one of the user's.
2. **The name given with Claude Code `/rename`**: the latest `custom-title` in the transcript, read only when
   the file changes. A sessions-file `name` whose `nameSource` isn't `derived` also counts.
3. **The cmux workspace's custom name** (`custom_title` when `has_custom_title`).
4. **The cmux window's custom name**, if cmux exposes one.
5. **A tmux window the person renamed** (`automatic-rename` off).
6. **Otherwise the folder name**, as today.

Automatic titles never count: the topic summaries Claude sets as the terminal title, `user@host:path`, and
cmux's process titles. Page can't read Terminal.app, iTerm2 and Ghostty tab names, so the folder name shows
there. The guides say so.

**Where the name goes:**
- the phone row title (Lanes, Now, the room header);
- the Mac panel card;
- new pages and notifications ("idle in Workspace-App");
- the two-copies warning ("Workspace-App is open twice").

The folder stays visible on the row's second line, so a renamed session still shows where it runs. Pages that
are already open keep the title they were sent with; the next page uses the new name.

**How soon:**
- cmux names are read with one `workspace list` call, at most every 5 s, and only while a phone is looking,
  the panel is open, or a page is about to open.
- A rename shows within about 5 s, through the normal list update.
- Names travel only where folder names travel today, inside the encrypted session list and pages, and are
  clipped to the same `maxTitle`.

## Renders (demo names only)

- **iOS:** `lanes-copies` (one row with the amber line among normal rows), `now-copies`, `room-copies`
  (the notice under the header, composer visible).
- **Android:** `lanes-copies`, `room-copies`, matching iOS.
- **Mac:** `popover-sessions-copies` (a card with the amber line and Close the other),
  `popover-sessions-copies-confirm` (the confirm), `popover-sessions-copies-busy` (other copy busy: line
  only, no button).

## Design decision (2026-11-14)

The user approved the renders in `Designs/session-copies/` (iOS and Mac) with two changes:

- **iOS Lanes:** a row title wraps onto a second line instead of being cut off at the title column ("Workspace-…").
- **Mac:** the "Close the other" button hides while its confirm is showing.

Where a renamed session's name goes:

- **Mac card:** in the title. The second line keeps `Claude · model · cmux › <folder>`.
- **iOS room and Now card:** in the title. The folder stays on the subtitle line.
- **iOS Lanes:** in the row title. The folder stays in the group header.

**Android:** written to match iOS, but neither compiled nor rendered yet. The Android SDK lives on `/Volumes/projects`, which was locked; the user is unlocking it.

## Build plan

1. Renders for approval: the views with fixtures.
2. **Sonnet, Mac:**
   - the lead pick in the registry or backend;
   - the detector scanning only leads;
   - lead-change page closing;
   - `pickSession` and the gate;
   - `copies` on the row;
   - the notification;
   - Close the other;
   - rule B.
3. **Sonnet, phones:** decode `copies` and wire the views on iOS and Android.
4. **Haiku:** unit tests:
   - the lead pick;
   - B's rule;
   - no idle page from a non-lead;
   - the reply refused after a lead change;
   - `copies` on the wire;
   - phone decoding.
5. **Opus:** verify with a real two-copy session on this Mac, using a throwaway folder, never the user's
   sessions. Then renders, docs and a PR. No merging.
