#!/usr/bin/env bash
# TAK-style reinstall: remove local containers, keep certs and state.
# There is no local image to rebuild — zenoh-router is an already-published,
# digest-pinned upstream image, unlike the parent EFDI repo's own
# locally-built zenoh-admin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/compose/.env"
COMPOSE_FILE="$ROOT/compose/docker-compose.yml"

# shellcheck source=scripts/_spinner.sh
. "$ROOT/scripts/_spinner.sh"

[ -f "$ENV_FILE" ] || fail "compose/.env not found — run ./install.sh first"
cd "$ROOT"
banner "Reinstall"

# reinstall.sh only removes containers — it assumes a prior successful
# install.sh run already wrote the Zenoh router config. If that never
# happened (an earlier install attempt was interrupted before reaching it),
# `docker compose up` doesn't error on the missing bind-mount source — Docker
# silently creates an empty DIRECTORY there instead, and zenohd then crashes
# with a confusing "Failed to load config file: Is a directory" instead of
# the real problem. Catch it here with an actionable message.
POD_STATE_DIR="$(grep '^POD_STATE_DIR=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
ZENOH_CONFIG="${POD_STATE_DIR}/zenoh/config.json5"
if [ -d "$ZENOH_CONFIG" ]; then
    rmdir "$ZENOH_CONFIG" 2>/dev/null || true
fi
[ -f "$ZENOH_CONFIG" ] || fail "Zenoh config not found at $ZENOH_CONFIG — this router was never fully installed. Run ./install.sh first."

info "Stopping native control-plane processes..."
"$ROOT/scripts/stop.sh" native
ok "Native runtime stopped"

run_spin "Removing router container" "Router container removed" \
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down --remove-orphans \
    || fail "Could not remove the existing router container"

run_spin "Starting Zenoh router" "Zenoh router started" \
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d zenoh-router \
    || { dump_service_logs "$COMPOSE_FILE" "$ENV_FILE"; fail "Router startup failed"; }

EFDI_NONINTERACTIVE=1 "$ROOT/scripts/start.sh" --restore
ok "Native runtime restored"

bash "$ROOT/scripts/health.sh"
