<div align="center">

# EFDI-Edge

**Minimal, remotely-managed Zenoh router for hardware attached directly to a sensor or sensor group.**

[![Zenoh](https://img.shields.io/badge/Zenoh-1.9.0-blue)](https://zenoh.io/)
[![Python](https://img.shields.io/badge/Python-3.10%2B-blue?logo=python&logoColor=white)](https://www.python.org/)
[![Debian](https://img.shields.io/badge/Debian-13_trixie-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![Docker](https://img.shields.io/badge/Docker%20Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue)](https://www.apache.org/licenses/LICENSE-2.0)

</div>

EFDI-Edge is a stripped-down sibling of the [parent EFDI project](https://github.com/lk-risb/EFDI):
a Zenoh router plus a small local control plane, meant to be bolted onto a
piece of sensor hardware in the field rather than run as a full fusion pod.
It carries **no protocol translators, sensor bridges, or C2 output layers**
— those live in the parent EFDI repo. It carries **no local WebUI** either —
this router is configured, updated, and restarted remotely by a central
zenoh-gateway/SCOUT instance, over the same control plane described below.

---

## Table of contents

- [What it is](#what-it-is)
- [Architecture](#architecture)
- [Remote control, precisely](#remote-control-precisely)
- [Repository layout](#repository-layout)
- [Deployment](#deployment)
- [Operations](#operations)
- [Relationship to the parent EFDI repo](#relationship-to-the-parent-efdi-repo)
- [License](#license)

---

## What it is

```
   Sensor(s)                  This box                      Central gateway

[radar / drone   ]      ┌─────────────────┐            ┌──────────────────────┐
[detector / etc. ]─???─►│  zenoh-router   │◄──mTLS────►│  zenoh-gateway/SCOUT  │
                         │  (Docker)       │            │  (WebUI + zenoh-admin)│
                         └────────┬────────┘            └──────────┬───────────┘
                                  │ loopback (7448)                 │
                         ┌────────▼────────┐            config push/restart,
                         │  admin-control   │◄───────────  enrollment, PKI
                         │  presence        │             signing, over the
                         │  supervisor      │             mesh VPN
                         │  cert-renewer    │
                         └─────────────────┘
```

This box's only job is to be a trustworthy, always-on Zenoh presence near
the sensor(s) it's attached to. Whatever actually decodes a sensor's wire
protocol into fabric tracks — ASTERIX, SAPIENT, a vendor-specific feed —
is the parent EFDI project's job, not this repo's, at least for now. See
[Relationship to the parent EFDI repo](#relationship-to-the-parent-efdi-repo).

---

## Architecture

| Service | Role |
|---|---|
| `zenoh-router` | Local pub/sub fabric — mTLS to the parent zenoh-gateway, plaintext TCP on loopback for the local control plane |
| `admin-control` | The remote control agent. The central zenoh-gateway/SCOUT WebUI talks to this over the mesh VPN — start/stop/restart, `.env` edits, log tailing, all token-gated. **This is the only thing standing in for a local WebUI.** |
| `presence` | Declares liveliness tokens so this router shows up as a node in the fabric inspector (panoscope) even when it's momentarily quiet |
| `supervisor` | Restarts a crashed control-plane process |
| `cert-renewer` | Automatic short-lived transport certificate renewal against the parent's step-ca |

All five are native Python processes (except `zenoh-router`, containerized) managed by PID files under `compose/state/.pids/`, started and stopped the same way the parent EFDI repo's `start.sh`/`stop.sh` work — because they *are* the same scripts, trimmed to this service list.

---

## Remote control, precisely

Two different things happen on two different ports of the same parent
gateway, and it matters which is which:

- **Enrollment** (one-time, at install) hits the parent's **zenoh-admin
  WebUI** (`/api/pki/enroll`) with an enrollment token. This router
  generates its own CA/transport/policy-signer keys locally — private keys
  never leave this box — and gets back signed certificates. See
  `scripts/pki/enroll-router.sh`.
- **Ongoing control** (start/stop/restart, config edits, log access) hits
  **this box's own `admin-control` agent**, called *from* the parent
  gateway's WebUI. Nothing on this router ever dials out to be controlled;
  it just listens on the mesh VPN interface for that agent's requests.

Both are gated by tokens set in `compose/.env` — `EFDI_ENROLLMENT_TOKEN`
(one-time, not persisted) and `EFDI_CONTROL_TOKEN`/`ZENOH_ADMIN_SECRET_KEY`
(persistent, protects the ongoing control agent).

---

## Repository layout

```
install.sh              Bare-metal Debian bootstrap: OS update, Docker,
                         Python, NetBird, enrollment.
start.sh / stop.sh       Interactive service launcher (parent repo's
                         convention, trimmed to infra-only services).
compose/
  docker-compose.yml     zenoh-router (+ optional local step-ca).
  .env.example           Every per-deployment value this router needs.
  control/
    admin_control.py     Remote control agent.
    presence.py          Liveliness tokens.
    supervisor.py        Crash auto-restart.
    gateway.py           Zenoh session helper (open_session, publish_dual).
    zenoh_auth.py        mTLS config helper.
    namespace_prefix.py  Topic-root resolution.
  protocols/
    gateway.py           Compat shim (`import gateway` from protocols/).
    data_stats.py        Lightweight in/out counters `gateway.py` uses.
scripts/pki/             Enrollment + certificate renewal scripts.
```

---

## Deployment

```bash
curl -fsSL https://raw.githubusercontent.com/lk-risb/EFDI-Edge/main/install.sh | bash
```

`install.sh` will:

1. Update the OS (`apt upgrade`) and install git, Python 3.10+, Docker
   Engine + the Compose plugin — from Docker's official repo, not the
   distro-bundled `docker.io`.
2. Offer to connect this box to NetBird, if it isn't already on the mesh.
3. Ask for the parent zenoh-gateway's WebUI URL, an enrollment token, and
   a namespace for this router, then run `scripts/pki/enroll-router.sh` —
   no private key ever leaves this box.
4. Generate this router's own `admin-control` token.
5. Write `compose/.env`, start `zenoh-router`, and start the local control
   plane via `start.sh --restore`.

See `docs/03-bootstrap-and-install.md` for the full walkthrough, including
what to do if a step fails partway through (every step is safe to re-run).

## Operations

```bash
./start.sh              # interactive service launcher
./start.sh --restore    # non-interactive, restores last selection
./stop.sh                # stop everything (control-plane processes + zenoh)
./stop.sh zenoh          # stop just the router
tail -f compose/state/logs/<service>.log
```

There is no local dashboard. If you need to see what's running without
SSHing in, that's what `admin-control` + the parent gateway's WebUI are for.

---

## Relationship to the parent EFDI repo

EFDI-Edge is a fork-and-trim of the parent [EFDI](https://github.com/lk-risb/EFDI)
project's own infrastructure scripts (`start.sh`, `install.sh`,
`compose/control/*.py`, `scripts/pki/*.sh`) — same conventions, same
service-launcher pattern, same PKI/enrollment mechanism, deliberately
minus every protocol translator, sensor bridge, and C2 output layer. If
this router ever needs to decode a sensor's wire protocol locally instead
of relying on the parent pod, that capability should be ported over from
the parent repo's `compose/protocols/vendors/` the same deliberate way —
not reinvented.

---

## License

Apache-2.0 — see [`LICENSE`](LICENSE).
