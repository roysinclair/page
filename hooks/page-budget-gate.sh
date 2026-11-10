#!/bin/bash
# Page Studio: budget gate (Claude Code PreToolUse hook)
#
# When a project, or one session, has used its whole budget (Page Studio >
# Budget), Page Studio writes a small marker for it. This hook stops that
# project's tool calls: at a matching call it prints
#
#   {"continue":false,"stopReason":"Page: Night Owl reached its budget ..."}
#
# which ends the turn with that message. Raise the budget in Page Studio (or on
# your phone), or wait for the weekly reset, and it lets the calls through again.
#
# DUMB ON PURPOSE. It never talks to the relay or the phone, never runs python or
# jq, and has no away or bypass step-aside. It reads two folders next to Page
# Studio's other files and fails OPEN: any error, a missing folder, an unreadable
# or malformed marker, an expired one, anything unexpected: it prints nothing and
# exits 0, and the tool runs.
#
#   budget-over/<hash>.gate   key=value lines written by Page Studio:
#       project=<absolute folder, or empty>   session=<session id, or empty>
#       expires=<unix seconds>                stop=<the JSON line to print>
#       member=<session id>   (any number) a session Page knows is this project's
#       spare=<session id>    (any number) a session Page knows is another project's
#       exclude=<folder>      (any number) a known project nested inside this one
#   budget-allow/<session id> exists while that session may finish one turn
#
# A marker matches when its session equals the call's session_id. A project's
# marker matches its members wherever they have cd'd, never its spares, and
# otherwise a call whose cwd is the project or inside it (/x/proj does not match
# /x/proj2) but not inside an excluded nested project: a budget on ~/projects
# never stops ~/projects/page. Typed prompts are not blocked: the turn they
# start stops at its first tool call.
#
# Installed by Page Studio > Integrations > "Install agent hooks…" (a PreToolUse
# entry, matcher "*", timeout 5). Written for macOS /bin/bash 3.2: no associative
# arrays, no ${x,,}, no set -e. Every path exits 0.
#
# Env (tests): PAGE_BUDGET_DIR is the folder that holds budget-over/ and
# budget-allow/ (default: Page Studio's support folder, as page-notify.sh finds it).

umask 077
export LC_ALL=C
PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# The folder: the same layout rules as page-notify.sh. PAGE_HOOK_OS pins the OS.
if [[ -n "${PAGE_BUDGET_DIR:-}" ]]; then
    BASE="$PAGE_BUDGET_DIR"
else
    PAGE_OS="${PAGE_HOOK_OS:-}"
    if [[ -z "$PAGE_OS" ]]; then
        case "${OSTYPE:-}" in linux*) PAGE_OS="Linux" ;; *) PAGE_OS="Darwin" ;; esac
    fi
    if [[ "$PAGE_OS" = "Linux" ]]; then
        # An XDG base directory only counts when absolute.
        case "${XDG_DATA_HOME:-}" in
            /*) BASE="$XDG_DATA_HOME/page" ;;
            *) BASE="$HOME/.local/share/page" ;;
        esac
    else
        BASE="$HOME/Library/Application Support/ClaudePowerMode"
    fi
fi
OVER="$BASE/budget-over"
ALLOW="$BASE/budget-allow"

# Fast path: nothing is over its budget (no folder, or no .gate in it). Drain the
# call and let it through.
FOUND=""
if [ -d "$OVER" ]; then
    for f in "$OVER"/*.gate; do
        if [ -f "$f" ]; then FOUND=1; break; fi
    done
fi
if [ -z "$FOUND" ]; then
    cat >/dev/null 2>&1
    exit 0
fi

# The call, flattened to one line. Only the start is read (session_id and cwd come
# first); the rest is drained so Claude Code's pipe never blocks.
INPUT="$(head -c 16384 2>/dev/null)"
cat >/dev/null 2>&1
FLAT="${INPUT//$'\n'/ }"
FLAT="${FLAT//$'\r'/ }"

# The FIRST string value of a key (never a later one, such as text inside a tool's
# input that merely looks like a key). Sets FIELD; returns 1 when there is none.
get_field() {
    FIELD=""
    local rest="$FLAT" tail
    while :; do
        tail="${rest#*\"$1\"}"
        [ "$tail" = "$rest" ] && return 1
        rest="$tail"
        tail="${rest#"${rest%%[![:space:]]*}"}"
        if [ "${tail:0:1}" = ":" ]; then
            tail="${tail:1}"
            tail="${tail#"${tail%%[![:space:]]*}"}"
            if [ "${tail:0:1}" = '"' ]; then
                tail="${tail:1}"
                FIELD="${tail%%\"*}"
                return 0
            fi
            return 1
        fi
    done
}

SID=""; CWD=""
get_field session_id && SID="$FIELD"
get_field cwd && CWD="$FIELD"

# A path with a backslash is JSON-escaped: Page can't compare it. Allow.
case "$CWD" in *\\*) exit 0 ;; esac
case "$SID" in *\\*) SID="" ;; esac

# A session Page let finish its turn.
CLEAN_SID="${SID//[^A-Za-z0-9-]/}"
if [ -n "$CLEAN_SID" ] && [ -e "$ALLOW/$CLEAN_SID" ]; then exit 0; fi

NOW="$(date +%s 2>/dev/null)"
case "$NOW" in ''|*[!0-9]*) exit 0 ;; esac

# The call's folder as `pwd -P` says it (a marker's key has its symlinks resolved).
CWD="${CWD%/}"
CWD_REAL=""
if [ -n "$CWD" ]; then CWD_REAL="$(cd "$CWD" 2>/dev/null && pwd -P 2>/dev/null)"; fi

# Inside: the folder itself, or below it at a path boundary.
inside() {
    local dir="$1" proj="${2%/}"
    [ -n "$dir" ] || return 1
    [ -z "$proj" ] && return 0   # the root folder: everything
    [ "$dir" = "$proj" ] && return 0
    [[ "$dir" == "$proj"/* ]] && return 0
    return 1
}

for gate in "$OVER"/*.gate; do
    [ -f "$gate" ] || continue
    project=""; session=""; expires=""; stop=""; member=""; spare=""; excluded=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            project=*) project="${line#project=}" ;;
            session=*) session="${line#session=}" ;;
            expires=*) expires="${line#expires=}" ;;
            stop=*) stop="${line#stop=}" ;;
            member=*) [ -n "$SID" ] && [ "${line#member=}" = "$SID" ] && member=1 ;;
            spare=*) [ -n "$SID" ] && [ "${line#spare=}" = "$SID" ] && spare=1 ;;
            exclude=/?*)
                ex="${line#exclude=}"
                if inside "$CWD" "$ex" || inside "$CWD_REAL" "$ex"; then excluded=1; fi ;;
        esac
    done 2>/dev/null < "$gate"
    [ -n "$stop" ] || continue
    case "$expires" in ''|*[!0-9]*) continue ;; esac
    [ "$expires" -lt "$NOW" ] && continue
    if [ -n "$session" ]; then
        [ -n "$SID" ] && [ "$session" = "$SID" ] || continue
    else
        [ -n "$project" ] || continue
        if [ -z "$member" ]; then
            [ -n "$spare" ] && continue
            [ -n "$excluded" ] && continue
            inside "$CWD" "$project" || inside "$CWD_REAL" "$project" || continue
        fi
    fi
    printf '%s\n' "$stop"
    exit 0
done

exit 0
