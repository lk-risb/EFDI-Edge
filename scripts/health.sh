#!/usr/bin/env bash
# Self-heal this router's deployment, then run every repository check that
# makes sense here. No frontend, no WebUI, no pytest suite — see the parent
# EFDI repo's own health.sh for that fuller version; this is the trimmed
# infra-only equivalent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/compose/.env"
COMPOSE_FILE="$ROOT/compose/docker-compose.yml"
PYTHON="$ROOT/compose/venv/bin/python3"

# shellcheck source=scripts/_spinner.sh
. "$ROOT/scripts/_spinner.sh"

[ -f "$ENV_FILE" ] || fail "compose/.env not found — run ./install.sh first"
[ -x "$PYTHON" ] || PYTHON="$(command -v python3)"
cd "$ROOT"

banner "Health Check"

_HEALTH_FAILED=0

info "Python compile checks"
mapfile -t python_files < <(
    find "$ROOT/compose/control" "$ROOT/compose/protocols" -type f -name '*.py' -print | sort
)
if "$PYTHON" -m py_compile "${python_files[@]}"; then
    ok "Python modules compile"
else
    warn "Python compile check failed (see above)"
    _HEALTH_FAILED=1
fi

info "Shell syntax and ShellCheck"
mapfile -d '' -t shell_files < <(
    git ls-files -co --exclude-standard -z -- '*.sh' 2>/dev/null \
    || find "$ROOT" -maxdepth 3 -type f -name '*.sh' -print0
)
for index in "${!shell_files[@]}"; do
    case "${shell_files[$index]}" in /*) ;; *) shell_files[index]="$ROOT/${shell_files[index]}" ;; esac
    bash -n "${shell_files[index]}" || { warn "${shell_files[$index]} has a syntax error"; _HEALTH_FAILED=1; }
done
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "${shell_files[@]}"; then
        ok "Shell checks passed"
    else
        warn "ShellCheck found issues (see above)"
        _HEALTH_FAILED=1
    fi
else
    warn "shellcheck is not installed; shell syntax passed but linting was skipped"
fi

info "Compose rendering"
if docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config -q; then
    ok "Compose file renders"
else
    warn "Compose file failed to render (see above)"
    _HEALTH_FAILED=1
fi

info "Router state files"
POD_STATE_DIR="$(grep '^POD_STATE_DIR=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
_STATE_MISSING=0
for f in "${POD_STATE_DIR}/zenoh/config.json5" "${POD_STATE_DIR}/zenoh/tls/router-cert.pem" \
         "${POD_STATE_DIR}/zenoh/tls/router-key.pem" "${POD_STATE_DIR}/zenoh/tls/ca-root.pem"; do
    if [ -d "$f" ]; then
        warn "$f is a directory, not a file (Docker's stray bind-mount placeholder) — removing empty directory"
        rmdir "$f" 2>/dev/null || warn "  could not remove — not empty, needs manual attention"
        _STATE_MISSING=1
    elif [ ! -f "$f" ]; then
        warn "$f is missing — re-run ./install.sh's enrollment step"
        _STATE_MISSING=1
    fi
done
[ "$_STATE_MISSING" -eq 0 ] && ok "Router state files present"
[ "$_STATE_MISSING" -eq 1 ] && _HEALTH_FAILED=1

info "Zenoh router container"
if docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps zenoh-router \
        --format "{{.Status}}" 2>/dev/null | grep -q "healthy\|Up"; then
    ok "zenoh-router is up"
else
    warn "zenoh-router is not running or not healthy"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --no-color --tail=50 zenoh-router 2>&1 || true
    _HEALTH_FAILED=1
fi

info "Control-plane processes"
PID_DIR="${POD_STATE_DIR}/.pids"
for svc in admin-control presence supervisor; do
    pid_file="$PID_DIR/$svc.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        ok "$svc running (pid $(cat "$pid_file"))"
    else
        warn "$svc is not running — start it with ./start.sh"
        _HEALTH_FAILED=1
    fi
done
# cert-renewer only runs once EFDI_STEP_CA_URL is configured — absence alone
# isn't a failure the way the three above are.
_CR_PID_FILE="$PID_DIR/cert-renewer.pid"
if [ -f "$_CR_PID_FILE" ] && kill -0 "$(cat "$_CR_PID_FILE")" 2>/dev/null; then
    ok "cert-renewer running (pid $(cat "$_CR_PID_FILE"))"
else
    dim "cert-renewer not running (fine if EFDI_STEP_CA_URL isn't configured yet)"
fi

info "NetBird mesh"
if command -v netbird >/dev/null 2>&1; then
    if netbird status 2>/dev/null | grep -qi "connected"; then
        ok "NetBird connected"
    else
        warn "NetBird is installed but not connected — this router cannot reach the parent gateway"
        _HEALTH_FAILED=1
    fi
else
    warn "NetBird is not installed — this router cannot reach the parent gateway over the mesh"
fi

info "Whitespace and optional secret scan"
git diff --check || { warn "Whitespace check found issues (see above)"; _HEALTH_FAILED=1; }
if command -v gitleaks >/dev/null 2>&1; then
    gitleaks detect --source "$ROOT" --no-banner --redact \
        || { warn "gitleaks found something (see above)"; _HEALTH_FAILED=1; }
else
    warn "gitleaks is not installed; tracked-file secret scan was skipped"
fi

info "Container status"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps \
    --format 'table {{.Name}}\t{{.Status}}'

printf '\n'
if [ "$_HEALTH_FAILED" -eq 0 ]; then
    printf '  %b┌────────────────────────────────────────────────┐%b\n' "$G" "$NC"
    printf '  %b│%b  %bHealth check passed%b                          %b│%b\n' \
        "$G" "$NC" "$W" "$NC" "$G" "$NC"
    printf '  %b└────────────────────────────────────────────────┘%b\n\n' "$G" "$NC"
else
    printf '  %b┌────────────────────────────────────────────────┐%b\n' "$R" "$NC"
    printf '  %b│%b  %bHealth check found issues — see above%b          %b│%b\n' \
        "$R" "$NC" "$W" "$NC" "$R" "$NC"
    printf '  %b└────────────────────────────────────────────────┘%b\n\n' "$R" "$NC"
fi

# Interactive troubleshooting menu — only when actually run by hand at a real
# terminal. update.sh/reinstall.sh call this script unattended as a self-test
# (see their own EFDI_NONINTERACTIVE=1 before invoking it); without both
# checks, one of those automated runs would hang forever on `read`.
if [ -t 0 ] && [ -z "${EFDI_NONINTERACTIVE:-}" ]; then
    section "Troubleshooting"
    echo "  [1] Restart the router container"
    echo "  [2] Restart a control-plane process"
    echo "  [Q] Done"
    read -rp "  Action [1/2/Q]: " _TS_ACTION
    case "${_TS_ACTION:-Q}" in
        1)
            if docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" restart zenoh-router; then
                ok "Restarted zenoh-router"
            else
                warn "Could not restart zenoh-router — see output above"
            fi
            ;;
        2)
            echo "  Services: admin-control, presence, supervisor, cert-renewer"
            read -rp "  Service name to restart: " _TS_SERVICE
            "$ROOT/scripts/stop.sh" "$_TS_SERVICE" 2>/dev/null || true
            if EFDI_NONINTERACTIVE=1 "$ROOT/scripts/start.sh" --service "$_TS_SERVICE"; then
                ok "Restarted $_TS_SERVICE"
            else
                warn "Could not restart '$_TS_SERVICE' — check the name matches exactly"
            fi
            ;;
        *) ;;
    esac
fi

exit "$_HEALTH_FAILED"
