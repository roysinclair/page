# Page Power on Linux (`paged`)

`paged` is Page Power for Linux: a headless daemon with a command-line
interface, run as a systemd user service. It shares its core (`PageCore`)
with the Mac app: the same detection, pages, approvals, reply delivery,
battery policy, live sessions and relay protocol. It has no tray or window
yet.

It pairs with the same phone apps and the same relay Worker as the Mac. The
phone apps still say "Mac" in places (see [Limits](#limits)).

## Install

You need a Swift 6 toolchain ([swift.org/install/linux](https://www.swift.org/install/linux/)),
plus `bash`, `curl` and `jq` for the hook script. Then, as your normal user (never root):

```sh
git clone https://github.com/roysinclair/page.git && cd page
./install-linux.sh
```

This builds `paged` in release mode (the Swift runtime linked in) and installs:

| What | Where |
|---|---|
| The daemon and CLI | `~/.local/bin/paged` |
| The hook scripts | `~/.local/share/page/hooks/` |
| The systemd user unit, enabled and started | `~/.config/systemd/user/paged.service` |

It never uses `sudo`. `./install-linux.sh --no-service` skips the unit, and
`./install-linux.sh --uninstall` removes the binary, hooks and unit. Your
config and pairing are kept.

Then:

```sh
paged config set relayURL https://<your-worker>.workers.dev   # docs/SELF-HOSTING.md
paged config set relayEnabled true
paged pair            # QR in the terminal; scan it in the Page app
paged install-hooks   # shows the change to ~/.claude/settings.json / ~/.codex/hooks.json first
paged status
```

**Servers and logging out.** systemd stops user services when your last
session ends. To keep `paged` running on a server, or after you log out,
enable lingering for your user once:

```sh
loginctl enable-linger "$USER"
```

polkit allows this for your own account on most desktops. On a locked-down
server an administrator may have to run it. Page itself never asks for root.

## Commands

| Command | What it does |
|---|---|
| `paged run` | The daemon in the foreground (what the unit runs). One instance per user. |
| `paged start` / `paged stop` | Through `systemctl --user` when the unit is installed, otherwise directly. |
| `paged status` | Relay, sessions, waiting pages, keep-awake (and why not), battery, presence. |
| `paged pair [--png FILE] [--regenerate] [--plain]` | Prints the pairing QR with Unicode half blocks (black on white, so it scans on any theme; `--plain` for no colours) and writes a PNG (0600; default `~/.local/share/page/pairing-qr.png`). `--regenerate` makes a new token and session key: the daemon retires the old token on the relay and reconnects, and paired phones must scan again. |
| `paged install-hooks [--agent claude\|codex\|all] [--uninstall] [--yes]` | Adds Page's hook to Claude Code and Codex. It shows the diff and asks first. |
| `paged logs [-f] [-n N]` | The daemon's log. |
| `paged config [path\|show\|get KEY\|set KEY VALUE]` | Reads or changes `config.json`. Values are type-checked and validated before anything is written, and the daemon reloads them (SIGHUP). |

Signals: `SIGTERM`/`SIGINT` release the inhibitors and stop, `SIGHUP` reloads
the config, `SIGUSR1` follows a regenerated token.

## Files

`paged` follows the XDG base directories:

| | Path | Contents |
|---|---|---|
| Config | `$XDG_CONFIG_HOME/page` (`~/.config/page`) | `config.json` (same keys as the Mac app's) |
| Data | `$XDG_DATA_HOME/page` (`~/.local/share/page`) | `relay_token.txt` and `session_key.txt` (both 0600), `aura.sock` and `orbit.sock`, hook holds, held messages, resume jobs, the hook scripts |
| State | `$XDG_STATE_HOME/page` (`~/.local/state/page`) | `paged.log`, `page-hook.log`, `status.json`, resume logs |

The three folders are created 0700. Secrets stay in 0600 files, as on the
Mac, so a headless server needs no keyring.

## What works

- **Detection and pages.** Claude Code and Codex sessions, approvals,
  questions, idle turns and rate limits page your phone through your relay,
  exactly as on the Mac. Pages and replies are TLS to the relay, and the relay
  can read them. Only the live-sessions channel is end-to-end encrypted. See
  the README's privacy section.
- **Approvals through the hook.** `PermissionRequest` and the Codex hooks
  block and wait for your phone, with no terminal injection. This works in
  any terminal.
- **Typed replies and live sessions** in **tmux**, **WezTerm** (`wezterm
  cli`), **kitty** (`kitten @`, with remote control enabled), **Herdr** and
  **Claude Squad**, with the same safety checks as on the Mac: never type into
  the wrong session, never press Return on an open menu, and hold a message
  while you are typing.
- **Keep-awake** with logind inhibitors. While agents work, `paged` holds an
  `idle:sleep` inhibitor. With the lid option on AC (`keepAwakeLidClosedOnAC`)
  it also holds `handle-lid-switch`. With the opt-in lid-closed-on-battery
  option it holds `handle-lid-switch` on battery too, under the same
  battery-margin and heat blockers as the Mac. Each inhibitor is held by a
  `systemd-inhibit` child that runs `tail --pid=<paged>`, so it ends when
  `paged` ends, even after a crash or SIGKILL, and nothing persists. There is
  no `pmset`-style setting to restore and no watchdog. If logind is not
  there (a container, a non-systemd distro without elogind), `paged` says so
  in the log and in `paged status`, and keeps paging.
- **Battery** from `/sys/class/power_supply` (several batteries are combined,
  and a mouse's battery is ignored), with UPower as the fallback (a USB UPS).
  It feeds the same low-battery policy: a graceful pause at the cutoff, the
  forecast, and resume when power is back. Heat comes from
  `/sys/class/thermal` trip points.
- **Presence**, so that pages are held while you are at the keyboard. It
  reads `xprintidle` on X11, GNOME's Mutter IdleMonitor on X11 or Wayland, or
  logind's IdleHint. With no graphical session (a server, ssh, a text
  console) you count as away, so every page goes to the phone. The hook
  script uses the same rules.
- **Rate-limit resume** with a one-shot systemd user timer and service per
  session (`~/.config/systemd/user/local.Page.resume.<session>.timer`, with
  `Persistent=true`).
- **Process inspection** from `/proc`: argv and the allowlisted environment
  variables only, open files in place of `lsof`, listening ports from
  `/proc/net/tcp`, and job control from `stat`.
- **Notifications** with `notify-send` when there is a desktop session.
  Without one there are none.
- **Page Aura / Page Orbit link** on `~/.local/share/page/aura.sock` and
  `orbit.sock`. These use the same JSON-lines protocol
  ([AURA-LINK.md](AURA-LINK.md)), are mode 0600, and check that the peer has
  the same uid (`SO_PEERCRED`). Page Aura's Linux build connects there.
- **The relay connection** uses swift-nio (WebSocketKit). Ubuntu 24.04's
  libcurl has no WebSocket support, so Foundation's URLSession WebSocket
  cannot connect. `HTTPS_PROXY` and `NO_PROXY` are honoured.

## Limits

- **No tray or window yet.** Use `paged status` and the phone. A Tauri tray
  is the next step.
- **Terminals.** GNOME Terminal and Konsole have no safe way to send text.
  Konsole's D-Bus `sendText` is often disabled, and `TIOCSTI` is off since
  Linux 6.2. Run your agents inside **tmux** (or WezTerm, kitty, Herdr) for
  typed replies and live sessions. Approvals through the hook work
  everywhere. Terminal.app, iTerm2 and cmux are macOS only.
- **The lid on GNOME and KDE.** Some desktops handle the lid themselves.
  GNOME's settings daemon and KDE's PowerDevil take their own lid inhibitor
  and then ask logind to suspend. `paged`'s `idle:sleep` inhibitor also
  blocks that suspend while agents work, but a desktop that suspends with
  "ignore inhibitors", or a policy set in its power settings, can still put
  the machine to sleep. Check your desktop's lid setting if a closed laptop
  sleeps.
- **`idle:sleep` also holds a sleep you ask for** while agents work. On macOS,
  Page's idle assertion lets you sleep the Mac from the menu. On Linux your
  desktop shows that Page is inhibiting sleep and usually lets you override
  it.
- **Wayland idle.** There is no standard way to read idle time on Wayland.
  GNOME works through Mutter. On KDE, Sway and others `paged` falls back to
  logind's IdleHint, which only changes after your desktop's idle timeout. If
  none of these answers while a desktop session exists, the daemon counts
  you as away and the hook script counts you as present (the safe default
  for the agent's own dialog), the same split as on the Mac.
- **Waking from suspend for a resume.** A user service cannot schedule a
  wake (`WakeSystem=` needs a system timer). The resume timer runs as soon as
  the machine is awake again, and the job's own lateness check decides
  whether it is still worth carrying on.
- **Photos from the phone** are checked at the header level: type by magic
  bytes, size, frame count, no location data. The pixels are not decoded
  (macOS uses ImageIO for that), and Claude Code decodes the image itself.
- **Local models.** Ollama, LM Studio and llama.cpp servers are found through
  `/proc`. The GPU sampler is Apple-only, so on Linux it shows no GPU
  utilisation.
- **Phone wording.** The phone apps and the relay still say "your Mac". The
  wire names (`role: "mac"`, `mac.status`, the `page-mac` User-Agent) stay as
  they are for compatibility. `paged` sends `page-mac/<version> (Linux …;
  paged)`.

## Building and testing

```sh
swift build                    # PageCore, PageLinux, paged
swift test                     # PageCoreTests (the portable suite) and PageLinuxTests
swift build -c release --product paged --static-swift-stdlib
```

On Linux, `Package.swift` declares `PageCore`, `PageLinux`, `paged` and their
tests. On macOS it declares `PageCore` and the app, widgets and their tests.
`PageLinuxTests` run the Linux parsers over fixture files
(`Tests/PageLinuxTests/Fixtures`: `/proc`, sysfs, UPower, loginctl and
systemctl output), so they need no logind, battery or desktop.
