#!/usr/bin/env bash
# install.sh — EFDI-Edge router installer
# Configures compose/.env, Python venv, enrolls this router with a parent
# zenoh-gateway/SCOUT, and starts the Zenoh router + local control plane.
# Run as the deployment user (not root) on bare-metal Debian.

set -euo pipefail

# $USER isn't always exported (minimal containers, some non-login shells) —
# with `set -u` that turns every usage below into a hard crash.
USER="${USER:-$(whoami)}"

# TODO: point this at the real EFDI-Edge repository once one exists — this
# is a placeholder following the parent EFDI repo's own naming convention,
# not a URL that has been verified to resolve.
REPO_URL="https://github.com/lk-risb/EFDI-Edge.git"
INSTALL_DIR="${INSTALL_DIR:-$HOME/efdi-edge}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "$PWD")"
ENV_FILE="$SCRIPT_DIR/compose/.env"
COMPOSE_FILE="$SCRIPT_DIR/compose/docker-compose.yml"
VENV="$SCRIPT_DIR/compose/venv"

# ── OS package manager detection (Debian apt is the primary target; dnf kept
# for parity with the parent EFDI repo's own installer) — used throughout
# this script so a bare host with none of git/Python/Docker pre-installed
# can still complete `./install.sh` unattended. ─────────────────────────────
PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
fi

# Docker publishes separate apt repos per distro (different signing metadata,
# different codename lists) — "apt" alone doesn't distinguish Debian from
# Ubuntu, so read the real distro ID for the one step that needs it.
DISTRO_ID=""
[ -f /etc/os-release ] && DISTRO_ID="$(. /etc/os-release && echo "$ID")"

# pkg_install <apt-package-list> <dnf-package-list> — either list may be empty
# when a package only exists under one distro family.
pkg_install() {
    local apt_pkgs="$1" dnf_pkgs="$2"
    case "$PKG_MGR" in
        apt) [ -n "$apt_pkgs" ] && sudo apt-get update -qq && sudo apt-get install -y -qq $apt_pkgs ;;
        dnf) [ -n "$dnf_pkgs" ] && sudo dnf install -y -q $dnf_pkgs ;;
        *) return 1 ;;
    esac
}

# Match the parent EFDI repo's curl-pipe bootstrap behavior: install into a
# normal git checkout, then re-exec the checked-in installer.
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Bootstrapping — cloning repo to $INSTALL_DIR ..."
    if ! command -v git >/dev/null 2>&1; then
        pkg_install git git
    fi
    command -v git >/dev/null 2>&1 || {
        echo "git is required to install EFDI-Edge and could not be auto-installed (no apt or dnf found)." >&2
        exit 1
    }
    if [ -d "$INSTALL_DIR/.git" ]; then
        git -C "$INSTALL_DIR" pull --ff-only
    else
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    exec bash "$INSTALL_DIR/install.sh" </dev/tty
fi

# Safe here (never earlier): bash is now reading this script from a real file,
# not from the pipe `curl | bash` hands it — the branch above already re-execs
# with `</dev/tty` for that case. Reassigning stdin before this point would
# yank the script's own source out from under bash mid-read, breaking curl's
# write with an EPIPE (`curl: (23) Failure writing output to destination`).
[ -t 0 ] || exec < /dev/tty 2>/dev/null || true

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "${GREEN}[✓]${NC} $*"; }
info()    { echo -e "${CYAN}[*]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
err()     { echo -e "${RED}[✗]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}── $* ──────────────────────────────────────────────────────${NC}"; }

dump_service_logs() {
    echo -e "\n${CYAN}[*]${NC} Service logs (diagnosing the failure above):\n"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps -a 2>&1 || true
    echo ""
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --no-log-prefix --tail=80 2>&1 || true
}

# shellcheck source=scripts/_ask.sh
. "$SCRIPT_DIR/scripts/_ask.sh"

# ── Banner (ported from the INTCORE installer's ASCII splash) ──────────────
echo -e "${CYAN}"
cat <<'BANNER'
=================================================
 _____ _____ ____ ___   _____ ____   ____ _____
| ____|  ___|  _ \_ _| | ____|  _ \ / ___| ____|
|  _| | |_  | | | | |  |  _| | | | | |  _|  _|
| |___|  _| | |_| | |  | |___| |_| | |_| | |___
|_____|_|   |____/___| |_____|____/ \____|_____|
=================================================
BANNER
echo -e "${NC}"
echo "  Zenoh router + remote control plane. No local WebUI — configured"
echo "  and restarted remotely by a parent zenoh-gateway/SCOUT instance."
echo ""

# Numbered, framed step banners (ported from the INTCORE installer's
# "====\n[N/TOTAL] Title...\n====" style), overriding the plain underlined
# section() defined above for the rest of this script.
TOTAL_STEPS=10
STEP=0
SECTION_TITLE=""
_SECTION_RULE="$(printf '=%.0s' $(seq 1 70))"
section() {
    STEP=$((STEP + 1))
    SECTION_TITLE="$*"
    echo -e "\n${CYAN}${_SECTION_RULE}${NC}"
    echo -e "${CYAN}[$STEP/$TOTAL_STEPS] ${SECTION_TITLE}...${NC}"
    echo -e "${CYAN}${_SECTION_RULE}${NC}\n"
}
section_done() { ok "[$STEP/$TOTAL_STEPS] ${SECTION_TITLE} COMPLETED."; }

# ── Existing installation ────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    echo -e "\n${CYAN}── Existing installation ──────────────────────────────────────${NC}"
    echo "  [C] Reconfigure (re-run this installer)"
    echo "  [Q] Cancel"
    read -rp "  Action [C/q]: " _EXISTING_ACTION
    case "${_EXISTING_ACTION:-C}" in
        [Cc]*) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# ── OS update ─────────────────────────────────────────────────────────────────
section "OS update"
case "$PKG_MGR" in
    apt) sudo apt-get update -qq && sudo apt-get upgrade -y -qq ;;
    dnf) sudo dnf upgrade -y -q ;;
    *) warn "No supported package manager (apt/dnf) found — skipping OS update." ;;
esac

REBOOT_NEEDED=0
[ -f /var/run/reboot-required ] && REBOOT_NEEDED=1
if [ "$PKG_MGR" = "dnf" ] && command -v needs-restarting &>/dev/null; then
    sudo needs-restarting -r &>/dev/null || REBOOT_NEEDED=1
fi
if (( REBOOT_NEEDED )); then
    ok "System updated."
    warn "A reboot is required (kernel or core library update) — reboot, then re-run ./install.sh to continue."
    exit 0
fi
ok "System up to date."
section_done

# ── Prerequisites ─────────────────────────────────────────────────────────────
section "Prerequisites"

# Sets PYTHON/PY_VER if a 3.10+ interpreter is found; returns 1 otherwise.
detect_python() {
    for py in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$py" &>/dev/null; then
            PY_VER=$("$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null) || continue
            PY_MAJ=${PY_VER%%.*}; PY_MIN=${PY_VER#*.}
            if (( PY_MAJ > 3 || (PY_MAJ == 3 && PY_MIN >= 10) )); then
                PYTHON="$py"; return 0
            fi
        fi
    done
    return 1
}

if ! detect_python; then
    info "Python 3.10+ not found — installing…"
    pkg_install "python3 python3-venv python3-pip" "python3.11 python3.11-pip" \
        || err "Python 3.10+ required and no supported package manager (apt/dnf) found — install it manually and re-run."
    detect_python || err "Python 3.10+ still not found after installing — install it manually and re-run."
fi
ok "Python ${PY_VER} ($PYTHON)"

# Debian split venv+pip support out of the base python3 package — ensure both
# unconditionally, idempotent, a no-op if already present (see the parent
# EFDI repo's own install.sh for the exact failure this avoids).
if ! "$PYTHON" -m ensurepip --version &>/dev/null; then
    info "Installing venv/pip support for ${PYTHON}…"
    pkg_install "python3-venv python3-pip" "python3-pip" \
        || warn "Could not install python3-venv/python3-pip automatically — venv creation below may fail."
fi

DOCKER_JUST_INSTALLED=0
if ! command -v docker &>/dev/null; then
    info "Docker not found — installing from the official Docker repository (not distro-bundled docker.io)…"
    case "$PKG_MGR" in
        apt)
            # Docker publishes a separate apt repo per distro (Ubuntu vs
            # Debian) — default to the Debian repo, since Debian is this
            # project's actual target; only Ubuntu itself gets its own repo.
            _docker_apt_distro="debian"
            [ "$DISTRO_ID" = "ubuntu" ] && _docker_apt_distro="ubuntu"
            sudo install -m 0755 -d /etc/apt/keyrings
            sudo curl -fsSL "https://download.docker.com/linux/${_docker_apt_distro}/gpg" -o /etc/apt/keyrings/docker.asc
            sudo chmod a+r /etc/apt/keyrings/docker.asc
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${_docker_apt_distro} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
                | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update -qq
            sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        dnf)
            sudo dnf -y -q install dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
            sudo dnf install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo systemctl enable --now docker
            ;;
        *) err "Docker not found and no supported package manager (apt/dnf) found — install it manually and re-run." ;;
    esac
    command -v docker &>/dev/null || err "Docker installation failed — install it manually and re-run."
    sudo groupadd docker 2>/dev/null || true
    sudo usermod -aG docker "$USER"
    DOCKER_JUST_INSTALLED=1
fi
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "")
if [ -z "$COMPOSE_VER" ]; then
    info "Docker Compose v2 plugin not found — installing…"
    pkg_install "docker-compose-plugin" "docker-compose-plugin" \
        || err "Docker Compose v2 plugin not found and no supported package manager (apt/dnf) found — install it manually and re-run."
    COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "")
fi
[ -n "$COMPOSE_VER" ] || err "Docker Compose v2 plugin still not found after install attempt."
ok "Docker Compose $COMPOSE_VER"

if ! command -v openssl &>/dev/null; then
    info "openssl not found — installing…"
    pkg_install "openssl" "openssl" \
        || err "openssl is required for router enrollment and could not be auto-installed — install it manually and re-run."
fi
ok "openssl $(openssl version | awk '{print $2}')"

if ! command -v envsubst &>/dev/null; then
    info "envsubst not found — installing (gettext)…"
    pkg_install "gettext-base" "gettext" \
        || err "envsubst is required to render the Zenoh router config and could not be auto-installed — install gettext manually and re-run."
fi

# The user was just added to the docker group — that membership only applies
# to new login sessions, not this one, so any docker command below would fail
# with a permission error. Rather than fight that with newgrp/sg tricks in a
# non-interactive script, stop here and ask for a fresh session.
if (( DOCKER_JUST_INSTALLED )); then
    echo ""
    ok "Docker installed — added $USER to the docker group."
    warn "Log out and back in (or reboot), then re-run ./install.sh to continue."
    exit 0
fi
section_done

# ── Networking (NetBird mesh) ──────────────────────────────────────────────────
# This router reaches its parent zenoh-gateway over the same mesh VPN every
# other EFDI pod uses.
section "Networking"
_NB_IP=$(ip addr show wt0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1) || true

if [ -n "$_NB_IP" ]; then
    ok "NetBird connected ($_NB_IP)"
else
    echo "  This router reaches the zenoh-gateway and other EFDI nodes over NetBird —"
    echo "  the only mesh VPN this project uses. NetBird is not connected on this host yet."
    echo ""
    while true; do
        read -rp "$(echo -e "  ${BOLD}Connect now?${NC} [Y]es / [N]o (manual/offline): ")" _VPN_ACTION
        case "${_VPN_ACTION:-Y}" in
            [Yy]*)
                ask_key NETBIRD_SETUP_KEY "NetBird setup key (app.netbird.io → Keys)"
                ask_key NETBIRD_MGMT_URL "Self-hosted management URL (leave blank for NetBird Cloud)"
                if command -v netbird >/dev/null 2>&1 || dpkg -l netbird 2>/dev/null | grep -q '^ii' || rpm -q netbird >/dev/null 2>&1; then
                    info "Removing stale NetBird install…"
                    sudo netbird down 2>/dev/null
                    case "$PKG_MGR" in
                        apt) sudo apt-get purge -y -qq netbird 2>/dev/null ;;
                        dnf) sudo dnf remove -y -q netbird 2>/dev/null ;;
                    esac
                    sudo rm -rf /etc/netbird /var/lib/netbird
                fi
                info "Installing NetBird…"
                curl -fsSL https://pkgs.netbird.io/install.sh | sh
                info "Connecting to NetBird…"
                _NB_UP_ARGS=(up --setup-key="$NETBIRD_SETUP_KEY")
                [ -n "$NETBIRD_MGMT_URL" ] && _NB_UP_ARGS+=(--management-url="$NETBIRD_MGMT_URL")
                sudo netbird "${_NB_UP_ARGS[@]}" \
                    || err "NetBird connection failed — check your setup key${NETBIRD_MGMT_URL:+ and management URL} and re-run."
                sleep 3
                _NB_IP=$(ip addr show wt0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1) || true
                [ -n "$_NB_IP" ] && ok "NetBird connected ($_NB_IP)" \
                    || warn "Could not read wt0's IP after connecting — check 'netbird status'."
                break
                ;;
            [Nn]*)
                warn "Skipping — this router will only reach a local Zenoh router until connected manually."
                break
                ;;
            *) echo "    Enter Y or N" ;;
        esac
    done
fi
section_done

# ── Pod state directory ───────────────────────────────────────────────────────
section "Router state directory"
echo "  Zenoh router config, TLS material, and logs live here."
EXISTING_POD_STATE=""
if [ -f "$ENV_FILE" ]; then
    EXISTING_POD_STATE=$(grep '^POD_STATE_DIR=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')
fi
ask POD_STATE_DIR "POD_STATE_DIR" "${EXISTING_POD_STATE:-$HOME/efdi-edge-state}"
BUNDLE_DIR="${POD_STATE_DIR}/certs"
ZENOH_LOCAL_ENDPOINT="tcp/127.0.0.1:7448"
section_done

# ── Enrollment — this is what makes the central zenoh-gateway able to see
# ── and control this router ───────────────────────────────────────────────
# No private key ever leaves this box: scripts/pki/enroll-router.sh generates
# its CA/transport/policy-signer keys locally, sends only CSRs to the
# parent's zenoh-admin WebUI (its /api/pki/enroll route — NOT the
# admin-control agent's own port; that's a separate service on the same
# central gateway, used for start/stop/restart/config-push instead), and
# receives back signed certificates.
section "Enrollment with the parent zenoh-gateway"
echo "  This router needs a one-time enrollment token from whoever manages"
echo "  the central zenoh-gateway/SCOUT instance's WebUI."
echo ""
ask GATEWAY_WEBUI_URL "Parent zenoh-gateway WebUI base URL (e.g. https://zenoh-gateway.example)"
ask PARTNER_NAMESPACE "This router's namespace (short identifier, e.g. site-alpha-radar)"
ask ZENOH_FABRIC_ENDPOINT "Parent Zenoh fabric endpoint to dial (e.g. tls/zenoh-gateway.example:7447)"
NAMESPACE_PREFIX="EFDI"
mkdir -p "$BUNDLE_DIR/efdi" "${POD_STATE_DIR}/pki"
info "Enrolling — this box's private keys are generated locally and never leave it."
ask_secret EFDI_ENROLLMENT_TOKEN "Enrollment token"
EFDI_ENROLLMENT_TOKEN="$EFDI_ENROLLMENT_TOKEN" \
    "$SCRIPT_DIR/scripts/pki/enroll-router.sh" \
        "$GATEWAY_WEBUI_URL" "$PARTNER_NAMESPACE" "$BUNDLE_DIR/efdi" "${POD_STATE_DIR}/pki" "${POD_STATE_DIR}/zenoh" \
    || err "Enrollment failed — check the WebUI URL and token, then re-run."
ok "Enrolled as ${PARTNER_NAMESPACE} — certs written to $BUNDLE_DIR/efdi"
section_done

# ── Stage certs where the zenoh-router CONTAINER can see them, and render
# ── its config ────────────────────────────────────────────────────────────
# docker-compose.yml bind-mounts ${POD_STATE_DIR}/zenoh/tls into the
# container at /etc/zenoh/tls — NOT compose/certs/efdi (that's for
# host-side Python processes and admin-control, via EFDI_CERT_DIR). The
# enrolled identity is copied here so the router config below can
# reference container-internal paths.
section "Rendering Zenoh router config"
mkdir -p "${POD_STATE_DIR}/zenoh/tls" "${POD_STATE_DIR}/zenoh/rocksdb"
install -m 644 "$BUNDLE_DIR/efdi/${PARTNER_NAMESPACE}-cert.pem" "${POD_STATE_DIR}/zenoh/tls/router-cert.pem"
install -m 600 "$BUNDLE_DIR/efdi/${PARTNER_NAMESPACE}-key.pem" "${POD_STATE_DIR}/zenoh/tls/router-key.pem"
install -m 644 "$BUNDLE_DIR/efdi/efdi-ca-root.pem" "${POD_STATE_DIR}/zenoh/tls/ca-root.pem"

NAMESPACE_ROOT="${NAMESPACE_PREFIX%%/*}"
DATA_TOPIC_ROOT="${NAMESPACE_PREFIX}/${PARTNER_NAMESPACE}"
# The inbound namespace is authorized by the parent's signed delegation
# grant (${POD_STATE_DIR}/pki/delegation.json, written by
# scripts/pki/enroll-router.sh) — its `subscribe` scope is the exact
# key-expression prefix the parent's cert/CSR exchange bound this router
# to receive. Cert-issued, not guessed.
DELEGATION_FILE="${POD_STATE_DIR}/pki/delegation.json"
INBOUND_NAMESPACE=""
if [ -f "$DELEGATION_FILE" ]; then
    INBOUND_NAMESPACE=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    envelope = json.load(f)
subscribe = envelope.get("payload", {}).get("subscribe", [])
if len(subscribe) == 1:
    print(subscribe[0].removesuffix("/**"))
' "$DELEGATION_FILE" 2>/dev/null) || true
fi
if [ -n "$INBOUND_NAMESPACE" ]; then
    ok "Inbound namespace granted by delegation: ${INBOUND_NAMESPACE}"
else
    warn "Delegation grant has no single inbound 'subscribe' scope — defaulting INBOUND_NAMESPACE to this router's own data root (${DATA_TOPIC_ROOT}). Confirm with the parent fabric admin if bidirectional push is expected."
    INBOUND_NAMESPACE="${DATA_TOPIC_ROOT}"
fi
ZENOH_CONNECT_ENDPOINTS="[\"${ZENOH_FABRIC_ENDPOINT}\"]"
ZENOH_VERIFY_NAME_ON_CONNECT="false"
ZENOH_PLUGINS_LOADING_ENABLED="true"
export ZENOH_LISTEN_PORT="${ZENOH_LISTEN_PORT:-7447}"
export ZENOH_LOCAL_TCP_PORT="${ZENOH_LOCAL_TCP_PORT:-7448}"
export ZENOH_CONNECT_ENDPOINTS PARTNER_NAMESPACE INBOUND_NAMESPACE NAMESPACE_PREFIX NAMESPACE_ROOT DATA_TOPIC_ROOT
export ZENOH_VERIFY_NAME_ON_CONNECT ZENOH_PLUGINS_LOADING_ENABLED
export LISTEN_CERT_PEM="/etc/zenoh/tls/router-cert.pem"
export LISTEN_KEY_PEM="/etc/zenoh/tls/router-key.pem"
export CONNECT_CERT_PEM="/etc/zenoh/tls/router-cert.pem"
export CONNECT_KEY_PEM="/etc/zenoh/tls/router-key.pem"
export CA_ROOTS_PEM="/etc/zenoh/tls/ca-root.pem"
if [ -d "${POD_STATE_DIR}/zenoh/config.json5" ]; then
    rmdir "${POD_STATE_DIR}/zenoh/config.json5" 2>/dev/null || true
fi
envsubst < "$SCRIPT_DIR/examples/zenoh-router.json5.tmpl" > "${POD_STATE_DIR}/zenoh/config.json5"
ok "Zenoh config written: ${POD_STATE_DIR}/zenoh/config.json5 (mTLS, connects to ${ZENOH_FABRIC_ENDPOINT})"
section_done

# ── Local control agent secret ────────────────────────────────────────────────
section "Local control agent"
EFDI_CONTROL_TOKEN="$(env_value EFDI_CONTROL_TOKEN)"
EFDI_CONTROL_TOKEN="${EFDI_CONTROL_TOKEN:-$(openssl rand -hex 32)}"
ZENOH_ADMIN_SECRET_KEY="$(env_value ZENOH_ADMIN_SECRET_KEY)"
ZENOH_ADMIN_SECRET_KEY="${ZENOH_ADMIN_SECRET_KEY:-$(openssl rand -hex 32)}"
ok "Generated admin-control token — the parent zenoh-gateway needs this to control this router remotely."
section_done

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Summary ──────────────────────────────────────────────────────────${NC}"
echo "  PARTNER_NAMESPACE : $PARTNER_NAMESPACE"
echo "  POD_STATE_DIR     : $POD_STATE_DIR"
echo "  ZENOH_ENDPOINT    : $ZENOH_LOCAL_ENDPOINT"
echo "  Fabric endpoint   : $ZENOH_FABRIC_ENDPOINT"
echo "  Parent gateway    : $GATEWAY_WEBUI_URL"
echo ""
read -rp "$(echo -e "  ${BOLD}Proceed?${NC} [Y/n]: ")" _CONFIRM
[[ "${_CONFIRM:-Y}" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

mkdir -p "$POD_STATE_DIR"
printf '%s\n' "${NAMESPACE_PREFIX}" > "${POD_STATE_DIR}/namespace-prefix"
printf '%s\n' "${NAMESPACE_PREFIX}" > "${POD_STATE_DIR}/data-topic-prefix"

# ── Write compose/.env ─────────────────────────────────────────────────────────
section "Writing compose/.env"

EXTRA_LINES=""
if [ -f "$ENV_FILE" ]; then
    MANAGED_KEYS="POD_STATE_DIR|PARTNER_NAMESPACE|NAMESPACE_PREFIX|DATA_NAMESPACE_PREFIX|POD_ID"
    MANAGED_KEYS+="|BUNDLE_DIR|EFDI_CERT_DIR"
    MANAGED_KEYS+="|ZENOH_LOCAL_ENDPOINT|ZENOH_LISTEN_PORT|ZENOH_LOCAL_TCP_PORT|ZENOH_LOG|ZENOH_FABRIC_ENDPOINT"
    MANAGED_KEYS+="|EFDI_CONTROL_BIND|EFDI_CONTROL_PORT|EFDI_CONTROL_URL|EFDI_CONTROL_TOKEN"
    MANAGED_KEYS+="|EFDI_SHELL_CONTROL_HOST|EFDI_SHELL_CONTROL_PORT|ZENOH_ADMIN_SECRET_KEY"
    EXTRA_LINES=$(grep -Ev "^(#|[[:space:]]*$)" "$ENV_FILE" 2>/dev/null \
                  | grep -Ev "^(${MANAGED_KEYS})=" || true)
fi

{
    echo "# EFDI-Edge compose/.env — written by install.sh on $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "# DO NOT commit to version control."
    echo ""
    echo "# ── Router identity ───────────────────────────────────────────────────"
    echo "POD_STATE_DIR=${POD_STATE_DIR}"
    echo "PARTNER_NAMESPACE=${PARTNER_NAMESPACE}"
    echo "NAMESPACE_PREFIX=${NAMESPACE_PREFIX}"
    echo "DATA_NAMESPACE_PREFIX=${NAMESPACE_PREFIX}"
    echo "POD_ID=efdi-edge"
    echo ""
    echo "# ── Certificates ──────────────────────────────────────────────────────"
    echo "BUNDLE_DIR=${BUNDLE_DIR}"
    echo "EFDI_CERT_DIR=${BUNDLE_DIR}/efdi"
    echo ""
    echo "# ── Zenoh ─────────────────────────────────────────────────────────────"
    echo "ZENOH_LOCAL_ENDPOINT=${ZENOH_LOCAL_ENDPOINT}"
    echo "ZENOH_FABRIC_ENDPOINT=${ZENOH_FABRIC_ENDPOINT}"
    echo "ZENOH_LISTEN_PORT=7447"
    echo "ZENOH_LOCAL_TCP_PORT=7448"
    echo "ZENOH_LOG=info"
    echo ""
    echo "# ── Local control agent (the parent gateway talks to this) ─────────────"
    echo "EFDI_CONTROL_BIND=127.0.0.1"
    echo "EFDI_CONTROL_PORT=18896"
    echo "EFDI_CONTROL_URL=http://127.0.0.1:18896"
    echo "EFDI_CONTROL_TOKEN=${EFDI_CONTROL_TOKEN}"
    echo "EFDI_SHELL_CONTROL_HOST=127.0.0.1"
    echo "EFDI_SHELL_CONTROL_PORT=18897"
    echo "ZENOH_ADMIN_SECRET_KEY=${ZENOH_ADMIN_SECRET_KEY}"
    if [ -n "$EXTRA_LINES" ]; then
        echo ""
        echo "# ── Preserved from prior .env ────────────────────────────────────────"
        echo "$EXTRA_LINES"
    fi
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok "compose/.env written (mode 600)"
section_done

# ── Python venv ────────────────────────────────────────────────────────────────
section "Python virtual environment"
if [ ! -x "$VENV/bin/pip" ]; then
    info "Creating venv at $VENV…"
    "$PYTHON" -m venv "$VENV"
fi
info "Synchronizing Python runtime dependencies…"
"$VENV/bin/pip" install --quiet --disable-pip-version-check \
    -r "$SCRIPT_DIR/compose/requirements.txt"
ok "Venv ready from compose/requirements.txt"
section_done

# ── Infrastructure ────────────────────────────────────────────────────────────
section "EFDI-Edge infrastructure"
info "Starting Zenoh router…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d zenoh-router || {
    dump_service_logs
    err "Zenoh router startup failed — see logs above."
}

EFDI_NONINTERACTIVE=1 "$SCRIPT_DIR/start.sh" --restore
ok "Router and control-plane processes started"
section_done

# ── Done ──────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}${_SECTION_RULE}${NC}"
echo -e "${GREEN}${BOLD}  EFDI-EDGE ROUTER INSTALLATION COMPLETED SUCCESSFULLY${NC}"
echo -e "${GREEN}${_SECTION_RULE}${NC}"
echo ""
echo "  Start   : ./start.sh"
echo "  Stop    : ./stop.sh"
echo "  Logs    : tail -f ${POD_STATE_DIR}/logs/<service>.log"
echo "  Config  : $ENV_FILE"
echo ""
echo "  This router has no local WebUI. Manage it from the parent"
echo "  zenoh-gateway/SCOUT instance, using the admin-control token above."
echo ""
