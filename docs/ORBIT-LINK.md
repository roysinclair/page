# Page Orbit link (`orbit-link-v1`)

Page Orbit (the Managed Agents control room, github.com/roysinclair/page-studio-apps,
`docs/orbit/`) can hand its agent sessions to Page Studio, so that Page Relay
pages your phone:

- your phone is **paged when an agent is waiting for your approval** (a tool
  call the agent's permission policy says to ask about), even when Page Orbit
  is in the background;
- your phone is **paged when an agent finishes** while you're away from the Mac;
- you can **answer from the phone**: Allow once / Deny the tool call, send the
  agent a message, or stop it.

Page Orbit's agents run in Anthropic's cloud, not on your computer, so Page Power
**never keeps the computer awake** for them. Page Orbit never talks to the relay:
Page Studio owns the relay connection, the pairing, the end-to-end keys and APNs,
exactly as for Page Aura.

```
 iPhone ⇄ relay Worker ⇄ Page Studio (AuraBackend, .orbit flavour) ⇄ orbit.sock ⇄ Page Orbit (Rust) ⇄ its window (JS) ⇄ Anthropic API
```

## Same protocol as Page Aura, on its own socket

Page Orbit speaks the Page Aura line protocol ([AURA-LINK.md](AURA-LINK.md)
§1–§4) unchanged, with these differences:

| | Page Aura | Page Orbit |
|---|---|---|
| Socket | `…/ClaudePowerMode/aura.sock` (Linux: `~/.local/share/page/aura.sock`) | `…/ClaudePowerMode/orbit.sock` (Linux: `~/.local/share/page/orbit.sock`; same folder, same 0600 / same-uid rules) |
| `hello` | `"app":"Page Aura"`, `proto` 1 or 2 | `"app":"Page Orbit"`, `"proto":1` |
| A "chat" on the wire is | a Page Aura chat | a Managed Agents **session**: `id` is the session id (`sesn_…`), `title` its title or its agent's name |
| `busy` | an API stream or local tool is running | the session's status is `running` (or `rescheduling`) |
| `approval.id` | Page Aura's own 8-hex id | the **event id** (`sevt_…`) of the `agent.tool_use` / `agent.mcp_tool_use` waiting for confirmation |
| `approval.server` / `tool` | the local app and its tool | the agent's name (or the MCP server's), and the tool (`bash`, `write`, an MCP tool…) |
| `finished` | a reply ended | a session went from running or waiting to idle; `ok` only for `end_turn`; the snippet is the end of the agent's last message |
| `send` | starts a turn in the chat | sends `user.message` to the session (refused while running or waiting on an approval) |
| `approve` | answers the local approval | sends `user.tool_confirmation` (`allow` for `once`, `deny` with a short note for `deny`) |
| `stop` | the Stop button | sends `user.interrupt` |
| Keep-awake | while a chat is busy | **never** |
| Backend id / intervention prefix | `aura` / `aura-…` | `orbit` / `orbit-…` |
| Preferences switch | Agents ▸ Page Aura (`auraBackendEnabled`) | Agents ▸ Page Orbit (`orbitBackendEnabled`), default on |
| Phone Sessions tab (proto 2) | yes | not in v1 (Page Studio never sends `watch` to Page Orbit) |

Page Orbit only lists sessions that are working or waiting on you: it looks at
the sessions created in the last 48 hours every 15 seconds while the link is
on (and straight after any command). A session it has never seen running, and
that has been quiet for 15 minutes, is ignored.

## Where it lives

- **Page Studio:** `AuraBackend` takes a `LinkFlavor` (`.aura`, `.orbit`); the
  Coordinator runs one of each. `AuraLinkServer.path(socketName:)` gives both
  socket paths. Tests: `Tests/ClaudePowerModeTests/OrbitLinkTests.swift`.
- **Relay Worker:** `backend: "orbit"` is accepted on interventions, replies and
  `sync`; `orbit-` ids fall back to it; replies say "Page Orbit".
- **Phones:** `orbit` is a known backend (badge ORBIT, "Page Orbit", its own
  tint); rooms offer the Story lens only.
- **Page Orbit:** `desktop/src-tauri/src/pagelink.rs` (the socket client, shared
  with Page Aura) and `orbit/src/link.js` (what it reports and how it answers).

## What leaves the Mac

The same standard as Page Aura (AURA-LINK.md §6): the page's context (the
tool and a redacted, clipped preview of its input, or the redacted end of the
agent's last message) and the session title go through **your own** relay
Worker to your phone. Nothing else from Page Orbit is sent: no API key, no
transcripts, no files.
