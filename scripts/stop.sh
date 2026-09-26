#!/usr/bin/env bash
# stop.sh — stop native control-plane processes started by start.sh
#
# Usage:
#   ./stop.sh           # stop everything (control-plane processes + zenoh)
#   ./stop.sh native    # stop every PID-managed process; leave Docker infrastructure
#   ./stop.sh zenoh     # stop zenoh router only
#   ./stop.sh <name>    # stop one named service (admin-control, cert-renewer,
#                       #   presence, supervisor)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/compose"
ENV_FILE="$SCRIPT_DIR/compose/.env"
MODE="${1:-all}"

# ── Load .env (safe — no shell re-parsing of values, same as start.sh) ────
if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        printf -v "$key" '%s' "$val"
        # shellcheck disable=SC2163  # $key holds a variable NAME (set above via printf -v),
        # not the value to export — exporting by that name is the intended idiom here.
        export "$key"
    done < "$ENV_FILE"
fi

# Must match start.sh/run.sh's in-repo default.
PID_DIR="${POD_STATE_DIR:-$SCRIPT_DIR/compose/state}/.pids"

is_bridge_pid() {
    local pid="$1" arg
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && [[ -r "/proc/$pid/cmdline" ]] || return 1
    while IFS= read -r -d '' arg; do
        [[ "$arg" == "$COMPOSE_DIR/"* || "$arg" == "$SCRIPT_DIR/scripts/"* ]] && return 0
    done < "/proc/$pid/cmdline"
    return 1
}

stop_scripts() {
    local pattern="${1:-*}"
    if [[ ! -d "$PID_DIR" ]]; then return; fi
    for pid_file in "$PID_DIR"/$pattern.pid; do
        [[ -f "$pid_file" ]] || continue
        name="$(basename "$pid_file" .pid)"
        pid="$(cat "$pid_file")"
        if is_bridge_pid "$pid"; then
            kill "$pid" 2>/dev/null && echo "  [stop] $name (pid $pid)"
        else
            echo "  [gone] $name PID file is stale or belongs to another process"
        fi
        rm -f "$pid_file"
    done
}

stop_zenoh() {
    echo "  [stop] zenoh-router (Docker)"
    docker compose -f "$SCRIPT_DIR/compose/docker-compose.yml" stop zenoh-router 2>/dev/null || true
}

case "$MODE" in
    all)
        echo "=== Stopping all ==="
        stop_scripts "*"
        stop_zenoh
        ;;
    native)
        echo "=== Stopping native control-plane processes ==="
        stop_scripts "*"
        ;;
    zenoh)
        stop_zenoh
        ;;
    admin-control|cert-renewer|presence|supervisor)
        echo "=== Stopping $MODE ==="
        stop_scripts "$MODE"
        echo "Done."
        exit 0
        ;;
    *)
        echo "Usage: $0 [all|native|zenoh|admin-control|cert-renewer|presence|supervisor]"
        exit 1
        ;;
esac

echo "Done."
