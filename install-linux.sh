#!/bin/bash
# Builds paged (Page Power's Linux daemon) and installs it for this user:
#   ~/.local/bin/paged                       the daemon and CLI
#   ~/.local/share/page/hooks/               page-notify.sh + page-extract-context.py
#   ~/.config/systemd/user/paged.service     a systemd user unit, enabled and started
#
# Never uses sudo: everything goes in your home folder.
#
#   ./install-linux.sh                build (release), install, enable the service
#   ./install-linux.sh --no-service   install only; run `paged start` yourself
#   ./install-linux.sh --uninstall    stop and remove the service, binary and hooks
#                                     (config and pairing in ~/.config/page and
#                                     ~/.local/share/page are kept)
#
# Needs a Swift 6 toolchain on PATH (https://www.swift.org/install/linux/).
set -euo pipefail
cd "$(dirname "$0")"

xdg() { case "${1:-}" in /*) printf '%s' "$1" ;; *) printf '%s' "$HOME/$2" ;; esac; }
BIN_DIR="$HOME/.local/bin"
DATA_DIR="$(xdg "${XDG_DATA_HOME:-}" .local/share)/page"
CONFIG_DIR="$(xdg "${XDG_CONFIG_HOME:-}" .config)/page"
STATE_DIR="$(xdg "${XDG_STATE_HOME:-}" .local/state)/page"
UNIT_DIR="$(xdg "${XDG_CONFIG_HOME:-}" .config)/systemd/user"
UNIT="$UNIT_DIR/paged.service"
HOOK_DIR="$DATA_DIR/hooks"

MODE=install
SERVICE=1
for arg in "$@"; do
    case "$arg" in
        --uninstall) MODE=uninstall ;;
        --no-service) SERVICE=0 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" = "0" ]; then
    echo "!! Run this as the user whose agents Page should watch, not as root." >&2
    echo "   (Running as root installs into /root and watches root's sessions.)" >&2
    [ "${PAGE_ALLOW_ROOT:-}" = "1" ] || exit 1
fi

have_systemd_user() {
    command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

if [ "$MODE" = "uninstall" ]; then
    if have_systemd_user; then
        systemctl --user disable --now paged.service >/dev/null 2>&1 || true
    fi
    [ -x "$BIN_DIR/paged" ] && "$BIN_DIR/paged" stop >/dev/null 2>&1 || true
    rm -f "$UNIT" "$BIN_DIR/paged"
    rm -rf "$HOOK_DIR"
    have_systemd_user && systemctl --user daemon-reload || true
    echo "Uninstalled paged. Config and pairing remain in $CONFIG_DIR and $DATA_DIR."
    echo "Remove Page's hook from Claude Code / Codex first if you installed it:"
    echo "  (before uninstalling) paged install-hooks --uninstall"
    exit 0
fi

command -v swift >/dev/null 2>&1 || {
    echo "!! swift not found on PATH. Install a Swift 6 toolchain: https://www.swift.org/install/linux/" >&2
    exit 1
}
for tool in bash curl jq; do
    command -v "$tool" >/dev/null 2>&1 || echo "note: '$tool' isn't installed; the hook script needs it (apt install $tool)" >&2
done

# The Swift runtime is linked in, so paged keeps working if the toolchain moves.
echo "==> swift build -c release --product paged --static-swift-stdlib"
swift build -c release --product paged --static-swift-stdlib
BIN="$(swift build -c release --show-bin-path)/paged"

echo "==> Installing to $BIN_DIR/paged"
mkdir -p "$BIN_DIR"
install -m 0755 "$BIN" "$BIN_DIR/paged.new"
mv -f "$BIN_DIR/paged.new" "$BIN_DIR/paged"

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR"
chmod 700 "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR"
mkdir -p "$HOOK_DIR"
install -m 0755 hooks/page-notify.sh "$HOOK_DIR/page-notify.sh"
install -m 0644 hooks/page-extract-context.py "$HOOK_DIR/page-extract-context.py"
echo "==> Hook scripts in $HOOK_DIR"

if [ "$SERVICE" = "1" ]; then
    if ! have_systemd_user; then
        echo "note: no systemd user session here; skipping the service. Start it with: paged start" >&2
    else
        mkdir -p "$UNIT_DIR"
        # systemd quoting for the path: \ and " escaped, % and $ doubled.
        exe=$(printf '%s' "$BIN_DIR/paged" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g' -e 's/\$/$$/g')
        cat > "$UNIT.new" <<EOF
# Written by Page's install-linux.sh.
[Unit]
Description=Page Power: pages your phone when coding agents need you
Documentation=https://github.com/roysinclair/page/blob/main/docs/LINUX.md

[Service]
Type=simple
ExecStart="$exe" run
Restart=on-failure
RestartSec=5
# The default control-group kill also ends the logind inhibitor helpers.
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF
        mv -f "$UNIT.new" "$UNIT"
        systemctl --user daemon-reload
        systemctl --user enable --now paged.service
        systemctl --user restart paged.service
        echo "==> Enabled and started paged.service"
    fi
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR isn't on your PATH; add it, or call $BIN_DIR/paged" >&2 ;;
esac

cat <<EOF

Next:
  1. Point paged at your relay (docs/SELF-HOSTING.md):
       paged config set relayURL https://<your-worker>.workers.dev
       paged config set relayEnabled true
  2. Pair your phone:            paged pair
  3. Add the hook to your agents: paged install-hooks
  4. Check on it:                paged status    (log: paged logs -f)

On a server (or to keep paging after you log out), let your user services
run without a login session:
  loginctl enable-linger $(id -un)
polkit allows this for your own user on most desktops; on a server it may
need an administrator, once. Page itself never asks for root.
EOF
