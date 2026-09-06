#!/usr/bin/env bash
# start.sh — interactive EFDI-Edge service launcher
# Usage: ./start.sh [--restore]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/compose"
ENV_FILE="$SCRIPT_DIR/compose/.env"
VENV="$COMPOSE_DIR/venv"

# ── Load .env (safe — no shell re-parsing of values) ──────────────────────
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

if [[ -z "${EFDI_CONTROL_TOKEN:-}" && -n "${ZENOH_ADMIN_SECRET_KEY:-}" ]]; then
    EFDI_CONTROL_TOKEN="$(printf 'efdi-control-v1:%s' "$ZENOH_ADMIN_SECRET_KEY" | sha256sum | awk '{print $1}')"
    export EFDI_CONTROL_TOKEN
fi

export ZENOH_LOCAL_ENDPOINT="${ZENOH_LOCAL_ENDPOINT:-tcp/127.0.0.1:7448}"
# Exported (not just used to derive EFDI_CERT_DIR) so native Python bridges and
# the containerized admin can share the same certificate location. Defaults
# inside the repo, under compose/certs/ — gitignored, admins drop the router's
# certificates here rather than scattering them somewhere in $HOME.
export BUNDLE_DIR="${BUNDLE_DIR:-$SCRIPT_DIR/compose/certs}"
export EFDI_CERT_DIR="${EFDI_CERT_DIR:-$BUNDLE_DIR/efdi}"

# Runtime state (logs, PID files, Zenoh's own config/certs under
# ${POD_STATE_DIR}/zenoh/...) defaults inside the repo, under compose/state/ —
# gitignored, keeps every path a dev needs to find in one place instead of
# scattered across $HOME. Exported (not just a local default) because
# `docker compose` (invoked later for zenoh-router) needs it in the real
# environment to interpolate ${POD_STATE_DIR} in volume paths — it has no
# access to this script's own defaulting logic.
export POD_STATE_DIR="${POD_STATE_DIR:-$SCRIPT_DIR/compose/state}"
# Host-launched bridges read the same prefix state file the admin writes.
export NAMESPACE_PREFIX_FILE="${POD_STATE_DIR}/namespace-prefix"
export DATA_NAMESPACE_PREFIX_FILE="${POD_STATE_DIR}/data-topic-prefix"
export PYTHONPATH="$COMPOSE_DIR:$COMPOSE_DIR/control${PYTHONPATH:+:$PYTHONPATH}"
LOG_DIR="$POD_STATE_DIR/logs"
PID_DIR="$POD_STATE_DIR/.pids"
LAUNCHER_STATE_FILE="$POD_STATE_DIR/launcher-state.env"
mkdir -p "$LOG_DIR" "$PID_DIR"

# ── Ensure venv ────────────────────────────────────────────────────────────
if [[ ! -x "$VENV/bin/python3" ]]; then
    echo "Creating venv at $VENV…"
    python3 -m venv "$VENV"
    "$VENV/bin/python3" -m pip install --quiet -r "$COMPOSE_DIR/requirements.txt"
    echo "Venv ready."
fi
PYTHON="$VENV/bin/python3"
if ! "$PYTHON" -c 'import zenoh' 2>/dev/null; then
    "$PYTHON" -m pip install --quiet -r "$COMPOSE_DIR/requirements.txt"
fi

# ── ANSI colors (only when stdout is a terminal) ───────────────────────────
if [[ -t 1 ]]; then
    R='\033[0m' BOLD='\033[1m' DIM='\033[2m'
    GREEN='\033[32m' YELLOW='\033[33m' CYAN='\033[36m'
else
    R='' BOLD='' DIM='' GREEN='' YELLOW='' CYAN=''
fi

# ── Service registry ───────────────────────────────────────────────────────
# EFDI-Edge is infra-only by design — no protocol translators, bridges, or
# output layers here (see README.md). Those are the parent EFDI pod's job;
# this box is just a Zenoh router plus the control plane that lets the
# central zenoh-gateway/SCOUT configure and restart it remotely.
SERVICES=(
    zenoh
    admin-control
    cert-renewer supervisor presence
)

# Restore only non-secret launcher choices. Explicit compose/.env values win;
# remembered addresses are fallbacks for values that were left blank there.
# The file is parsed as data, never sourced, so punctuation in a URL cannot be
# evaluated as shell syntax.
REMEMBERED_SERVICES=""
load_launcher_state() {
    [[ -f "$LAUNCHER_STATE_FILE" ]] || return
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            SELECTED_SERVICES)
                REMEMBERED_SERVICES="$val"
                ;;
        esac
    done < "$LAUNCHER_STATE_FILE"
}

save_launcher_state() {
    local tmp="${LAUNCHER_STATE_FILE}.tmp.$$" selected="" svc key
    for svc in "${SERVICES[@]}"; do
        [[ "${sel[$svc]:-0}" == "1" ]] || continue
        selected+="${selected:+,}$svc"
    done

    umask 077
    {
        printf '# EFDI-Edge launcher memory: service selections only.\n'
        printf 'SELECTED_SERVICES=%s\n' "$selected"
    } > "$tmp"
    mv -f "$tmp" "$LAUNCHER_STATE_FILE"
}

load_launcher_state
RESTORE_ONLY=0
if [[ "${1:-}" == "--restore" ]]; then
    RESTORE_ONLY=1
    export EFDI_NONINTERACTIVE=1
fi

declare -A SVC_CAT=(
    [zenoh]="Infrastructure"
    [admin-control]="Infrastructure"
    [cert-renewer]="Infrastructure"
    [supervisor]="Infrastructure"
    [presence]="Infrastructure"
)

declare -A SVC_DESC=(
    [zenoh]="Zenoh message router (Docker)"
    [admin-control]="Remote control agent — the central zenoh-gateway/SCOUT WebUI talks to this, not a local UI"
    [cert-renewer]="Automatic short-lived transport certificate renewal"
    [supervisor]="Auto-restarts a crashed control-plane process"
    [presence]="Liveliness presence tokens (fabric node visibility in panoscope)"
)

# ── Ready check — 0=can start, 1=missing config ───────────────────────────
svc_ready() {
    case "$1" in
        zenoh) return 0 ;;
        admin-control) [[ -n "${ZENOH_ADMIN_SECRET_KEY:-}" || -n "${EFDI_CONTROL_TOKEN:-}" ]] ;;
        cert-renewer)
            [[ -n "${EFDI_STEP_CA_URL:-}" &&
               "${EFDI_STEP_CA_URL}" == https://* &&
               -f "${EFDI_STEP_RENEW_CERT_PATH:-${EFDI_CERT_DIR}/${PARTNER_NAMESPACE}-cert.pem}" &&
               -f "${EFDI_STEP_RENEW_KEY_PATH:-${EFDI_CERT_DIR}/${PARTNER_NAMESPACE}-key.pem}" ]]
            ;;
        presence) [[ -n "${PARTNER_NAMESPACE:-}" ]] ;;
        *)        return 0 ;;
    esac
}

# Short config note shown in status column when not ready
svc_hint() {
    case "$1" in
        *) echo "" ;;
    esac
}

is_bridge_pid() {
    local pid="$1" expected_script="${2:-}" arg
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && [[ -r "/proc/$pid/cmdline" ]] || return 1
    local efdi_process=1
    while IFS= read -r -d '' arg; do
        if [[ -n "$expected_script" ]]; then
            [[ "$arg" == "$COMPOSE_DIR/$expected_script" || "$arg" == "$SCRIPT_DIR/$expected_script" ]] && return 0
        elif [[ "$arg" == "$COMPOSE_DIR/"* ]]; then
            return 0
        fi
        [[ "$arg" == "$COMPOSE_DIR/"* ]] && efdi_process=0
    done < "/proc/$pid/cmdline"
    # A service's implementation may change during an upgrade (for example, a
    # service's script moving between layers/ and bridges/). Treat
    # the PID-file's still-live EFDI process as running until an explicit stop
    # or restart removes it; otherwise a normal launcher run can duplicate the
    # same Zenoh subscriber.
    [[ "$efdi_process" == "0" ]]
}

# True when some OTHER service's pidfile already claims this PID. Kept from
# the parent EFDI repo's start.sh: there, several services run the SAME
# script with different arguments (e.g. one ASTERIX category translator per
# --category), so a bare script match isn't enough to decide ownership. No
# service here currently shares a script, but a future protocol addition
# might, so this stays rather than being cut only to be re-added later.
pid_claimed_by_other() {
    local candidate="$1" own_file="$2" other other_pid
    for other in "$PID_DIR"/*.pid; do
        [[ -f "$other" && "$other" != "$own_file" ]] || continue
        IFS= read -r other_pid < "$other" || continue
        [[ "$other_pid" == "$candidate" ]] && return 0
    done
    return 1
}

pid_has_args() {
    local pid="$1"
    shift
    local expected arg found
    local -a actual=()
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    while IFS= read -r -d '' arg; do
        actual+=("$arg")
    done < "/proc/$pid/cmdline"
    for expected in "$@"; do
        [[ -n "$expected" ]] || continue
        found=1
        for arg in "${actual[@]}"; do
            if [[ "$arg" == "$expected" ]]; then
                found=0
                break
            fi
        done
        (( found == 0 )) || return 1
    done
}

is_running() {
    local f="$PID_DIR/$1.pid" pid cmd live_pid
    if [[ -f "$f" ]]; then
        IFS= read -r pid < "$f"
        # A PID another service already owns is not this service's process; the
        # pidfile is stale from a previous mis-adoption. Fall through to the
        # scan below rather than reporting a sibling's process as ours.
        if ! pid_claimed_by_other "$pid" "$f" &&
           is_bridge_pid "$pid" "${2:-}" &&
           pid_has_args "$pid" "${@:3}"; then
            return 0
        fi
    fi
    cmd="${2:-}"
    [[ -n "$cmd" ]] || return 1
    while IFS= read -r live_pid; do
        # Never adopt a process another service started. Without this, the
        # second service sharing a script is reported "already running" and is
        # silently never launched.
        pid_claimed_by_other "$live_pid" "$f" && continue
        if is_bridge_pid "$live_pid" "$cmd" &&
           pid_has_args "$live_pid" "${@:3}"; then
            printf '%s\n' "$live_pid" > "$f"
            return 0
        fi
    done < <(pgrep -f "$cmd" 2>/dev/null || true)
    return 1
}

# Prompt for a single server address (blank to skip). One flat network routed
# entirely over the VPN mesh here, so there's no separate LAN-vs-NetBird
# address to ask for.
#   _prompt_address <label> <addr_var>
_prompt_address() {
    local label="$1" addr_var="$2"
    if [[ "${EFDI_NONINTERACTIVE:-}" == "1" ]]; then
        printf -v "$addr_var" '%s' ""
        return
    fi
    local addr_in
    read -rp "$(printf "  ${BOLD}${label} IP/URL${R} (blank to skip): ")" addr_in
    printf -v "$addr_var" '%s' "$addr_in"
}

# Prompt for a username and password (password input hidden via read -s).
#   _prompt_credentials <label> <user_var> <pass_var>
_prompt_credentials() {
    local label="$1" user_var="$2" pass_var="$3"
    if [[ "${EFDI_NONINTERACTIVE:-}" == "1" ]]; then
        printf -v "$user_var" '%s' ""
        printf -v "$pass_var" '%s' ""
        return
    fi
    local user_in pass_in
    read -rp "$(printf "  ${BOLD}${label} username${R}: ")" user_in
    read -rsp "$(printf "  ${BOLD}${label} password${R}: ")" pass_in
    echo
    printf -v "$user_var" '%s' "$user_in"
    printf -v "$pass_var" '%s' "$pass_in"
}

_prompt_secret() {
    local label="$1" value_var="$2" value
    if [[ "${EFDI_NONINTERACTIVE:-}" == "1" ]]; then
        printf -v "$value_var" '%s' ""
        return
    fi
    read -rsp "$(printf "  ${BOLD}%s${R} (blank to skip): " "$label")" value
    echo
    printf -v "$value_var" '%s' "$value"
}

# ── Launch helpers ─────────────────────────────────────────────────────────
_start() {   # _start <name> <rel-script-path> [args…]
    local name="$1"; shift
    local script="$1"; shift
    local pid_file="$PID_DIR/$name.pid"
    if is_running "$name" "$script" "$@"; then
        printf "  ${DIM}[skip]${R}  %-16s already running (pid %s)\n" "$name" "$(cat "$pid_file")"
        return
    fi
    rm -f "$pid_file"
    ( exec setsid "$PYTHON" "$COMPOSE_DIR/$script" "$@" >> "$LOG_DIR/$name.log" 2>&1 ) &
    echo $! > "$pid_file"
    printf "  ${GREEN}[start]${R} %-16s pid %s\n" "$name" "$!"
}

# Same as _start but execs a native binary directly — no Python interpreter.
# is_bridge_pid() only checks that "$COMPOSE_DIR/$script" appears literally in
# the process's argv, so this is a drop-in for any registered service whose
# implementation isn't a Python script.
_start_bin() {   # _start_bin <name> <rel-binary-path> [args…]
    local name="$1"; shift
    local script="$1"; shift
    local pid_file="$PID_DIR/$name.pid"
    if is_running "$name" "$script" "$@"; then
        printf "  ${DIM}[skip]${R}  %-16s already running (pid %s)\n" "$name" "$(cat "$pid_file")"
        return
    fi
    rm -f "$pid_file"
    ( cd "$(dirname "$COMPOSE_DIR/$script")" && exec setsid "$COMPOSE_DIR/$script" "$@" >> "$LOG_DIR/$name.log" 2>&1 ) &
    echo $! > "$pid_file"
    printf "  ${GREEN}[start]${R} %-16s pid %s\n" "$name" "$!"
}

launch() {
    local name="$1"
    case "$name" in

        zenoh)
            if [[ -f "${POD_STATE_DIR}/pki/step-ca/config/ca.json" ]]; then
                mesh_ip=$(netbird status 2>/dev/null | sed -n 's/.*NetBird IP:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1 || true)
                if [[ "$mesh_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    "$SCRIPT_DIR/scripts/pki/configure-step-ca-names.sh" \
                        "${POD_STATE_DIR}/pki/step-ca" "$mesh_ip" >/dev/null
                fi
                docker compose -f "$SCRIPT_DIR/compose/docker-compose.yml" --profile managed-ca up -d step-ca
            fi
            if docker compose -f "$SCRIPT_DIR/compose/docker-compose.yml" ps zenoh-router \
                    --format "{{.Status}}" 2>/dev/null | grep -q "healthy\|Up"; then
                printf "  ${DIM}[skip]${R}  zenoh-router already running\n"
            else
                printf "  ${GREEN}[start]${R} zenoh-router (Docker)\n"
                docker compose -f "$SCRIPT_DIR/compose/docker-compose.yml" up -d zenoh-router
                printf "  Waiting for zenoh-router"
                for _ in $(seq 1 20); do
                    sleep 1
                    if docker compose -f "$SCRIPT_DIR/compose/docker-compose.yml" ps zenoh-router \
                            --format "{{.Status}}" 2>/dev/null | grep -q "healthy"; then
                        echo " OK"; return
                    fi
                    printf "."
                done
                echo " (timeout — continuing)"
            fi
            ;;

        admin-control)
            if [[ -z "${ZENOH_ADMIN_SECRET_KEY:-}" && -z "${EFDI_CONTROL_TOKEN:-}" ]]; then
                printf "  ${YELLOW}[skip]${R}  admin-control requires ZENOH_ADMIN_SECRET_KEY or EFDI_CONTROL_TOKEN\n"
                return 1
            fi
            if is_running "admin-control" "control/admin_control.py"; then
                printf "  ${DIM}[skip]${R}  %-16s already running (pid %s)\n" "admin-control" "$(cat "$PID_DIR/admin-control.pid")"
                return
            fi
            rm -f "$PID_DIR/admin-control.pid"
            ( exec setsid "$PYTHON" "$COMPOSE_DIR/control/admin_control.py" \
                >> "$LOG_DIR/admin-control.log" 2>&1 ) &
            echo $! > "$PID_DIR/admin-control.pid"
            printf "  ${GREEN}[start]${R} %-16s pid %s\n" "admin-control" "$!"
            ;;

        supervisor)
            if is_running "supervisor" "control/supervisor.py"; then
                printf "  ${DIM}[skip]${R}  %-16s already running (pid %s)\n" "supervisor" "$(cat "$PID_DIR/supervisor.pid")"
                return
            fi
            rm -f "$PID_DIR/supervisor.pid"
            ( exec setsid "$PYTHON" "$COMPOSE_DIR/control/supervisor.py" \
                >> "$LOG_DIR/supervisor.log" 2>&1 ) &
            echo $! > "$PID_DIR/supervisor.pid"
            printf "  ${GREEN}[start]${R} %-16s pid %s\n" "supervisor" "$!"
            ;;

        presence)
            _start presence control/presence.py
            ;;

        cert-renewer)
            local renew_cert renew_key renew_root renew_url
            renew_cert="${EFDI_STEP_RENEW_CERT_PATH:-${EFDI_CERT_DIR}/${PARTNER_NAMESPACE}-cert.pem}"
            renew_key="${EFDI_STEP_RENEW_KEY_PATH:-${EFDI_CERT_DIR}/${PARTNER_NAMESPACE}-key.pem}"
            renew_root="${EFDI_STEP_RENEW_ROOT_PATH:-${POD_STATE_DIR}/pki/step-ca/certs/root_ca.crt}"
            renew_url="$EFDI_STEP_CA_URL"
            if [[ -z "$renew_url" || "$renew_url" != https://* ]]; then
                printf "  ${YELLOW}[skip]${R}  cert-renewer requires an https:// EFDI_STEP_CA_URL\n"
                return 1
            fi
            export EFDI_STEP_RENEW_RUNTIME_CERT_PATH="${EFDI_STEP_RENEW_RUNTIME_CERT_PATH:-${POD_STATE_DIR}/zenoh/tls/pod-cert.pem}"
            if is_running "cert-renewer" "scripts/pki/renew-step-identities.sh"; then
                printf "  ${DIM}[skip]${R}  %-16s already running (pid %s)\n" "cert-renewer" "$(cat "$PID_DIR/cert-renewer.pid")"
                return
            fi
            ( exec setsid "$SCRIPT_DIR/scripts/pki/renew-step-identities.sh" --daemon \
                "$renew_url" "$renew_root" "$renew_cert:$renew_key" \
                >> "$LOG_DIR/cert-renewer.log" 2>&1 ) &
            echo $! > "$PID_DIR/cert-renewer.pid"
            printf "  ${GREEN}[start]${R} %-16s pid %s\n" "cert-renewer" "$!"
            ;;


    esac
}

# Prerequisite report for the admin-control agent, one line per service:
#
#   <name><TAB>ready|blocked<TAB><hint>
#
# The web UI needs to know that a service cannot start BEFORE offering a Start
# button, otherwise an unconfigured service spawns, exits immediately and shows
# up as CRASHED with no reason. That answer lives in svc_ready/svc_hint, and
# re-implementing those tables in Python would leave two copies to drift apart,
# so the agent asks this script instead. Reporting only — starts nothing.
if [[ "${1:-}" == "--check-all" ]]; then
    for svc in "${SERVICES[@]}"; do
        if svc_ready "$svc"; then
            printf '%s\tready\t%s\n' "$svc" "$(svc_hint "$svc")"
        else
            printf '%s\tblocked\t%s\n' "$svc" "$(svc_hint "$svc")"
        fi
    done
    exit 0
fi

# Non-interactive entrypoint used by the localhost admin-control agent.  It
# reuses the exact same launch table as the human menu, including environment
# validation and PID handling, without opening a terminal prompt.
if [[ "${1:-}" == "--service" ]]; then
    requested="${2:-}"
    for svc in "${SERVICES[@]}"; do
        if [[ "$svc" == "$requested" ]]; then
            launch "$requested"
            exit $?
        fi
    done
    echo "Unknown service: $requested" >&2
    exit 2
fi

# ── Interactive menu ───────────────────────────────────────────────────────
declare -A sel

select_service() {
    local service="$1"
    sel[$service]=1
}

# Restore the last valid selection. On first use, default to every infra
# service — there's nothing optional left to opt out of on this box.
for svc in "${SERVICES[@]}"; do sel[$svc]=0; done
restored=0
if [[ -n "$REMEMBERED_SERVICES" ]]; then
    IFS=',' read -r -a remembered_services <<< "$REMEMBERED_SERVICES"
    for remembered in "${remembered_services[@]}"; do
        for svc in "${SERVICES[@]}"; do
            if [[ "$remembered" == "$svc" ]]; then
                sel[$svc]=1
                restored=1
                break
            fi
        done
    done
fi
# A previous `run.sh all` or manual native-process start may have launched
# services that are not yet present in launcher memory. Show those processes as
# selected too, then persist the merged set after this run. This keeps the menu
# faithful to the actual PID-managed runtime instead of merely labeling an
# unchecked item as RUNNING.
for svc in "${SERVICES[@]}"; do
    if is_running "$svc"; then
        sel[$svc]=1
        restored=1
    fi
done
if (( restored == 0 )); then
    for svc in "${SERVICES[@]}"; do
        sel[$svc]=1
    done
fi
# The web UI's native-process control plane is always kept selected so an old
# launcher-state file cannot leave Runtime Control disconnected after upgrade.
sel[admin-control]=1
sel[supervisor]=1
svc_ready cert-renewer && sel[cert-renewer]=1 || true

draw_menu() {
    clear
    printf "${BOLD}╔══════════════════════════════════════════════════════════════════╗${R}\n"
    printf "${BOLD}║        EFDI-Edge Launcher  —  select services to start           ║${R}\n"
    printf "${BOLD}╚══════════════════════════════════════════════════════════════════╝${R}\n"

    local prev_cat="" idx=0
    for svc in "${SERVICES[@]}"; do
        (( idx++ ))
        local cat="${SVC_CAT[$svc]}"

        if [[ "$cat" != "$prev_cat" ]]; then
            printf "\n  ${CYAN}${BOLD}%s${R}\n" "$cat"
            printf "  ${DIM}──────────────────────────────────────────────────────────${R}\n"
            prev_cat="$cat"
        fi

        # Status
        local stat scol
        if is_running "$svc"; then
            stat="RUNNING" scol="$GREEN"
        elif svc_ready "$svc"; then
            stat="ready" scol="$DIM"
        else
            stat="$(svc_hint "$svc")" scol="$YELLOW"
        fi

        # Checkbox
        local chk ccol
        if [[ "${sel[$svc]}" == "1" ]]; then chk="✓" ccol="$GREEN"
        else chk=" " ccol="$DIM"; fi

        printf "  ${DIM}[%2d]${R} ${ccol}[%s]${R} %-16s ${DIM}%-42s${R}  ${scol}%s${R}\n" \
            "$idx" "$chk" "$svc" "${SVC_DESC[$svc]}" "$stat"
    done

    printf "\n  ${DIM}──────────────────────────────────────────────────────────────${R}\n"
    printf "  ${DIM}Toggle: type number(s)   a=select all   n=clear all   q=quit${R}\n"
    printf "  ${DIM}Press Enter with no input to start the selected services.${R}\n\n"
}

change_selection=1
if (( RESTORE_ONLY == 1 )); then
    change_selection=0
fi
if (( restored == 1 )) && [[ -t 0 ]]; then
    draw_menu
    printf "  ${GREEN}Saved selection restored.${R} Auto-starting in 5 seconds.\n"
    printf "  Press ${BOLD}c${R} to change settings, ${BOLD}q${R} to quit, or Enter to start now: "
    saved_action=""
    if read -r -t 5 saved_action; then
        case "$saved_action" in
            c|C) change_selection=1 ;;
            q|Q) exit 0 ;;
            *)   change_selection=0 ;;
        esac
    else
        echo
        change_selection=0
    fi
fi

while (( change_selection == 1 )); do
    draw_menu
    printf "${BOLD}> ${R}"
    read -r input || { echo; exit 0; }

    case "$input" in
        q|Q)
            exit 0
            ;;
        a|A)
            for svc in "${SERVICES[@]}"; do
                svc_ready "$svc" && select_service "$svc" || true
            done
            ;;
        n|N)
            for svc in "${SERVICES[@]}"; do sel[$svc]=0; done
            ;;
        "")
            # Confirm at least one selected
            any=0
            for svc in "${SERVICES[@]}"; do [[ "${sel[$svc]}" == "1" ]] && { any=1; break; }; done
            if (( any == 0 )); then
                printf "\n  ${YELLOW}Nothing selected — pick at least one service.${R}\n"
                sleep 1
                continue
            fi
            break
            ;;
        *)
            # Toggle by number (space-separated)
            for tok in $input; do
                if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#SERVICES[@]} )); then
                    svc="${SERVICES[$((tok-1))]}"
                    [[ "${sel[$svc]}" == "1" ]] && sel[$svc]=0 || select_service "$svc"
                fi
            done
            ;;
    esac
done

# ── Start ──────────────────────────────────────────────────────────────────
printf "\n${BOLD}Starting selected services…${R}\n\n"

for svc in "${SERVICES[@]}"; do
    [[ "${sel[$svc]}" == "1" ]] || continue
    launch "$svc"
done

save_launcher_state

printf "\n${BOLD}Done.${R}  Logs → ${LOG_DIR}/   Stop → ./stop.sh\n"
