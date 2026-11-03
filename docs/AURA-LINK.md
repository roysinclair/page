# Page Aura link (`aura-link-v1`)

Page Aura (the bring-your-own-key Claude chat app, github.com/roysinclair/page-studio-apps)
can hand its chats to Page, so that:

- the Mac **stays awake** while Page Aura is writing a reply (an API stream dies
  if the Mac sleeps);
- your phone is **paged** when a reply finishes while you're away from the Mac,
  or when a chat asks to use an app on the Mac (a local MCP tool);
- you can **answer from the phone**: Allow once / Deny a tool request, or type a
  message that is sent into that chat.

Page Aura **never talks to the relay**. Page owns the one relay connection, the
pairing, the end-to-end keys and APNs. Page Aura only talks to Page, over a
Unix socket on the same Mac, and only after the user switches it on in Page
Aura's settings. Page treats Page Aura as a third agent backend next to Claude
Code and Codex (`AgentBackendID.aura`, wire `backend: "aura"`, intervention
ids prefixed `aura-`).

```
 iPhone ⇄ relay Worker ⇄ Page.app (AuraBackend) ⇄ aura.sock ⇄ Page Aura (Rust) ⇄ its windows (JS)
```

## 1. Transport

- **Socket:** `~/Library/Application Support/ClaudePowerMode/aura.sock`.
  Page is the server; Page Aura is the client.
- **Page (server):** creates the folder if missing, unlinks a stale socket,
  binds, sets the socket to `0600`. For every accepted connection it checks the
  peer with `getpeereid` and closes it unless the peer uid equals `getuid()`.
  One client at a time: a new connection replaces the old one. When the
  backend is switched off (Preferences) or Page quits, it closes the listener
  and removes the socket file.
- **Page Aura (client):** connects only while the user has switched the link
  on. Before connecting it `lstat`s the path and refuses unless it is a socket
  owned by the current uid. While switched on and disconnected it retries
  every 5 s. macOS only; on other systems the setting is not shown.
- **Framing:** UTF-8 JSON, one object per line, `\n`-terminated. Max line
  256 KiB; a longer line closes the connection (both sides). Readers ignore
  unknown fields and unknown `t` values.

## 2. Page Aura → Page

### `hello` (first line after connect)
```json
{"t":"hello","proto":1,"app":"Page Aura","version":"0.2.1"}
```

### `state` (on every change, and at least every 30 s as a heartbeat)
A full snapshot of the chats that are **busy** (a reply is being written or a
tool is running) or **waiting on a tool approval**. Idle chats are not listed.
```json
{"t":"state","chats":[
  {"id":"k3j9x","title":"Quarterly numbers","model":"claude-opus-5-5",
   "busy":true,"since":1762160000000,
   "approval":null},
  {"id":"p0q1r","title":"Tidy Downloads","model":"claude-sonnet-5-5",
   "busy":false,"since":1762160100000,
   "approval":{"id":"a7f3c2d1","server":"Filesystem","tool":"move_file",
               "args":"{\"from\":\"~/Downloads/a.pdf\",\"to\":\"~/Documents/a.pdf\"}"}}
]}
```
- `id`: Page Aura's chat id (≤ 64 chars, `[A-Za-z0-9_-]`).
- `busy`: `true` while an API stream or tool call is in flight. A chat waiting
  on an approval has `busy:false` and a non-null `approval`.
- `since`: epoch ms the current turn started.
- `approval.id`: unique per approval request (Page Aura generates it when the
  approval card appears). `args`: the tool input as JSON text, ≤ 1500 chars.
- An empty `chats` array means nothing is in flight.

### `finished` (once, when a turn ends)
```json
{"t":"finished","chatId":"k3j9x","title":"Quarterly numbers","ok":true,
 "stopped":false,"snippet":"…the last ≤ 600 characters of the reply…","at":1762160300000}
```
- `ok:false` when the turn ended in an error; `snippet` is then the error.
- `stopped:true` when the user pressed Stop at the Mac (Page raises no page).

### `ack` (answer to every command, exactly once)
```json
{"t":"ack","ref":"<command id>","ok":true,"detail":"Sent to Page Aura"}
```
`detail` is short, human and shown on the phone.

## 3. Page → Page Aura

| Command | Meaning | Page Aura's rules |
|---|---|---|
| `{"t":"send","id":"c1","chatId":"k3j9x","text":"…"}` | Send a message into the chat, as if typed there. `text` ≤ 8000 chars. | Unknown chat → `ok:false` "That chat no longer exists". Chat busy or waiting on an approval → `ok:false` "Page Aura is still working in that chat". No API key → `ok:false` "Page Aura needs its API key". Otherwise start the turn and ack `ok:true` once it has started (not when it finishes). The composer's draft is left alone. |
| `{"t":"approve","id":"c2","chatId":"p0q1r","approvalId":"a7f3c2d1","decision":"once"}` | Answer a tool approval. `decision` is `once` or `deny` only; "always allow" is never offered remotely. | Only if that chat's current approval has that id; otherwise `ok:false` "That request was already answered". |
| `{"t":"stop","id":"c3","chatId":"k3j9x"}` | Stop the chat's turn (the Stop button). | Unknown or idle chat → `ok:true` "Nothing to stop". |

Page Aura validates every command (known `t`, ids ≤ 64 chars of
`[A-Za-z0-9_-]`, `text` length, `decision` value) and drops anything else.

## 4. How Page uses it (AuraBackend)

- **Sessions:** each listed chat is an `AgentSession` (backend `.aura`,
  source `.desktop`, title = chat title, state `.active` when busy,
  `.waitingOnApproval` when an approval is pending).
- **Keep-awake:** `wantsPowerAssertion` while connected and any chat is busy.
  On disconnect everything clears and the assertion is released.
- **Permission page:** an approval becomes a `permission` intervention,
  id `aura-<chatId>-perm-<approvalId>`, context "Use <server> · <tool> on this
  Mac" plus the redacted, clipped args. It's gated like Claude's permission
  pages. It closes (`user_resolved_in_terminal`) when the approval disappears
  from `state`.
- **Idle page:** a `finished` with `ok` and not `stopped` becomes a pending
  candidate; on every tick it opens an `idle` intervention (id
  `aura-<chatId>-idle-<at>`, context = the redacted snippet) once the turn has
  been over for `idlePageDelaySeconds` and the user has been away for
  `idlePageOnlyWhenAwaySeconds`, as for Claude. A newer `finished`, the chat
  starting a new turn, a disconnect, or 4 h of waiting drops the candidate; an
  open page closes (`session_resolved`) when the chat becomes busy again or a
  newer page for it opens.
- **Replies:** permission + approve → `approve once`; + deny → `approve deny`;
  anything else on a permission page fails "Page Aura tool requests take Allow
  or Deny". Idle + text → `send`; + carry_on → `send "Carry on."`;
  approve/deny on an idle page fails. Not connected → fails "Page Aura isn't
  open on your Mac". Page waits up to 20 s for the `ack`, reports it with
  `sendReplyInjected(method: "aura-link")` and closes the page with `replied`
  on success.
- **Disconnect:** open Page Aura pages close with `stale`.
- **Battery pause:** not in v1. Streams in flight normally finish within the
  low-battery grace period.
- **Off switch:** Preferences ▸ Agents ▸ "Page Aura" (`auraBackendEnabled`,
  default on, since it only opens a local socket; the opt-in lives in Page
  Aura).

## 5. What leaves the Mac

Same standard as Claude Code pages (see `PROTOCOL.md`): the intervention's
`context` (a redacted, clipped snippet of the reply, or the tool name and
redacted args) and the chat title go through **your own** relay Worker to your
phone. The first 180 characters of `context` can appear in the push
notification. Nothing else from Page Aura (no history, attachments, API key)
is sent. Page Aura's setting says this in plain words.
