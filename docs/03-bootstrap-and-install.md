# 03 — Bootstrap and Install

## Prerequisites

### Bare host bootstrap

`./install.sh` updates the OS (`apt upgrade`) and auto-installs git, Python
3.10+, and Docker Engine + the Compose plugin (from Docker's official repo,
not the distro-bundled `docker.io`) if any are missing — a bare Debian
install with nothing on it works. Debian is this project's actual target;
RHEL/Rocky/Alma (`dnf`) is supported on a best-effort basis, matching the
parent EFDI repo's own installer.

If you'd rather do it by hand first (or the auto-install fails on your
distro), the manual steps are:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl ca-certificates
sudo apt install -y python3 python3-venv python3-pip

# Docker Engine + Compose plugin (official repo, not docker.io)
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # log out and back in afterward
```

Verify: `python3 --version` (3.10+), `docker --version`, `docker compose version`.

### Networking

This router needs to reach its parent zenoh-gateway over NetBird — the only
mesh VPN this project uses. `install.sh` offers to install and connect it
if it isn't already up. If you'd rather connect manually first:

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sh
sudo netbird up --setup-key=<key>
```

### Enrollment token

Before running `install.sh`, get from whoever manages the central
zenoh-gateway/SCOUT instance:

- The gateway's WebUI base URL (e.g. `https://zenoh-gateway.example`).
- A one-time enrollment token, minted on the gateway side for this router.
- A namespace to enroll under (a short identifier for this router — e.g.
  `site-alpha-radar`).

## Running the installer

```bash
curl -fsSL https://raw.githubusercontent.com/lk-risb/EFDI-Edge/main/install.sh | bash
```

The first run clones the repo to `~/efdi-edge` (override with
`INSTALL_DIR=/path ./install.sh`) and re-execs the checked-out
`install.sh`. Every subsequent run — including a re-run after a failure —
operates on that checkout directly.

Walkthrough:

1. **OS update.** If a reboot is required (kernel/library update), the
   installer stops and asks you to reboot and re-run — safe, nothing is
   lost.
2. **Prerequisites.** Python, Docker, Compose, openssl. If Docker was just
   installed, the installer stops and asks for a fresh login session
   (group membership for `docker` doesn't apply to the current one) —
   re-run `./install.sh` after logging back in.
3. **Networking.** Connect to NetBird, or skip for a fully local test setup
   (this router won't reach a real parent gateway until connected).
4. **Router state directory.** Where Zenoh's config, TLS material, and
   logs live (`POD_STATE_DIR`, defaults to `~/efdi-edge-state`).
5. **Enrollment.** Prompts for the parent gateway's WebUI URL, this
   router's namespace, the Zenoh fabric endpoint to dial (e.g.
   `tls/zenoh-gateway.example:7447` — the actual mesh Zenoh port, distinct
   from the WebUI URL above), and the enrollment token. Runs
   `scripts/pki/enroll-router.sh`, which generates this router's CA,
   transport, and policy-signer keys **locally** and sends only CSRs to
   the parent — no private key ever leaves this box.
6. **Render the Zenoh router config.** Copies the enrolled identity into
   `${POD_STATE_DIR}/zenoh/tls/` (the path the container actually mounts)
   and renders `${POD_STATE_DIR}/zenoh/config.json5` from
   `examples/zenoh-router.json5.tmpl` — full mTLS, `connect.endpoints` set
   to what you entered, and the same federation ACL model as the parent
   EFDI project. **One value in this template is a documented guess, not a
   verified default:** `INBOUND_NAMESPACE` (the bilateral prefix the
   fabric is allowed to push data to) defaults to this router's own data
   root rather than a real inbound-namespace convention, since no live
   example was available to check it against for a leaf/edge router.
   Confirm with whoever manages the parent fabric's federation setup
   whether this router should receive any inbound bilateral data at all.
7. **Local control agent.** Generates `EFDI_CONTROL_TOKEN` — the token the
   parent gateway's WebUI will use to control this router remotely
   (start/stop/restart, config edits, logs). Give this token to whoever
   manages the gateway.
8. **Write `compose/.env`, start the router and control plane.**

Every step re-run is safe: `.env` is only ever fully rewritten at the end,
after all prompts succeed, and existing values are used as defaults on a
second pass.

## After install

```
./start.sh              # interactive service launcher
./start.sh --restore    # non-interactive; restores what was last selected
```

This router has no local WebUI. To confirm it's actually reachable and
controllable, ask whoever manages the parent zenoh-gateway to check that
it appears in their fabric inspector (panoscope) and that a restart
command reaches it.

## Troubleshooting

- **Enrollment fails with an HTTP error.** Double-check the WebUI URL
  (it's the gateway's zenoh-admin base URL, e.g. `https://gateway.example`
  — not the `admin-control` port `18896`, which is a different service on
  the same box used for ongoing control, not enrollment) and that the
  token hasn't already been used or expired.
- **`admin-control` isn't reachable from the parent gateway.** Check
  `EFDI_CONTROL_BIND` in `compose/.env` — it must be the mesh VPN
  interface's IP (or `0.0.0.0` if you accept the exposure), not
  `127.0.0.1`, once the parent needs to reach it over the network.
- **Zenoh router won't come up healthy.** `docker compose -f
  compose/docker-compose.yml logs zenoh-router` — most often a missing or
  malformed `compose/state/zenoh/config.json5` (should have been rendered
  by the enrollment step).
