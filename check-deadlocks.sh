#!/usr/bin/env bash
# check-deadlocks.sh — alert when MySQL/MariaDB reports a NEW InnoDB deadlock.
#
# InnoDB keeps only the single most recent deadlock in SHOW ENGINE INNODB
# STATUS, so a deadlock that happened between two checks is easy to miss
# unless you compare timestamps. This script stores the last-seen deadlock
# timestamp in a state file and reports (exit 2) only when it changes.
#
# Usage:
#   check-deadlocks.sh [--state-file FILE] [--status-file FILE]
#                      [--to EMAIL] [--json] [--help]
#   --status-file reads a saved SHOW ENGINE INNODB STATUS dump instead of
#   calling mysql (useful for testing and for hosts without the client).
#   Credentials come from ~/.my.cnf ([client] user/password), never from
#   the command line. Exit codes: 0 ok, 1 warning (no deadlock section
#   found), 2 critical (new deadlock), 3 unknown (mysql error).
set -euo pipefail

STATE_FILE="/var/lib/mysql-deadlock-monitor/state"
STATUS_FILE=""
TO=""
JSON=0

usage() {
    sed -n '2,13p' "$0"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --state-file) STATE_FILE="$2"; shift 2 ;;
        --status-file) STATUS_FILE="$2"; shift 2 ;;
        --to) TO="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        --help) usage ;;
        *) echo "Unknown option: $1" >&2; exit 3 ;;
    esac
done

# --- Fetch InnoDB status -------------------------------------------------
if [ -n "$STATUS_FILE" ]; then
    [ -r "$STATUS_FILE" ] || { echo "UNKNOWN: cannot read $STATUS_FILE" >&2; exit 3; }
    STATUS=$(cat "$STATUS_FILE")
else
    command -v mysql >/dev/null 2>&1 || { echo "UNKNOWN: mysql client not found" >&2; exit 3; }
    # Credentials come from ~/.my.cnf, so nothing secret appears in argv.
    STATUS=$(mysql -N -e "SHOW ENGINE INNODB STATUS\G" 2>&1) || { echo "UNKNOWN: mysql failed: $STATUS" >&2; exit 3; }
fi

# --- Extract the latest deadlock timestamp -------------------------------
# The section looks like:
#   ------------------------
#   LATEST DETECTED DEADLOCK
#   ------------------------
#   2026-10-30 09:12:44 0x7f...
LATEST=$(printf '%s\n' "$STATUS" | awk '
    /LATEST DETECTED DEADLOCK/ { found = 1; next }
    found && /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ { print $1, $2; exit }
')

if [ -z "$LATEST" ]; then
    if [ "$JSON" -eq 1 ]; then
        printf '{"status":"warning","latest_deadlock":null,"message":"no deadlock section found"}\n'
    else
        echo "WARNING: no LATEST DETECTED DEADLOCK section in InnoDB status"
    fi
    exit 1
fi

# --- Compare with the previous run ---------------------------------------
PREVIOUS=""
[ -f "$STATE_FILE" ] && PREVIOUS=$(cat "$STATE_FILE")

mkdir -p "$(dirname "$STATE_FILE")"
printf '%s\n' "$LATEST" > "$STATE_FILE"

if [ "$LATEST" = "$PREVIOUS" ]; then
    if [ "$JSON" -eq 1 ]; then
        printf '{"status":"ok","latest_deadlock":"%s","new":false}\n' "$LATEST"
    else
        echo "OK: latest deadlock unchanged ($LATEST)"
    fi
    exit 0
fi

# New deadlock: also pull the two transactions involved for the alert.
DETAIL=$(printf '%s\n' "$STATUS" | awk '/LATEST DETECTED DEADLOCK/,/WE ROLL BACK TRANSACTION/ { print }' | head -40)

MSG="CRITICAL: new InnoDB deadlock detected at $LATEST (previous: ${PREVIOUS:-none})"
if [ "$JSON" -eq 1 ]; then
    # Escape for JSON without depending on jq.
    ESCAPED=$(printf '%s' "$DETAIL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    printf '{"status":"critical","latest_deadlock":"%s","previous":"%s","detail":%s}\n' "$LATEST" "$PREVIOUS" "$ESCAPED"
else
    echo "$MSG"
    [ -n "$DETAIL" ] && printf '%s\n' "$DETAIL"
fi
if [ -n "$TO" ]; then
    { echo "$MSG"; echo; printf '%s\n' "$DETAIL"; } | mail -s "MySQL deadlock detected ($LATEST)" "$TO" || true
fi
exit 2
