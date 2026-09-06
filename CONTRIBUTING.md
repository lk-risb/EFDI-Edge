# Contributing to EFDI-Edge

EFDI-Edge is the minimal, remotely-managed Zenoh router meant to run on
hardware attached directly to a sensor or sensor group. It has no local
WebUI — it is configured, updated, and restarted by a central
zenoh-gateway/SCOUT instance.

## The one hard rule: no secrets or internal infra details land here

Do **not** commit anything that belongs to a specific real deployment:

- Internal hostnames, mesh IPs, real `PARTNER_NAMESPACE` values, or
  operator-provisioning details for a specific site.
- Secrets of any kind — enrollment tokens, certs, private keys,
  `EFDI_CONTROL_TOKEN`/`ZENOH_ADMIN_SECRET_KEY` values. Certs are never
  committed (see `scripts/pki/enroll-router.sh`); `compose/.env` and
  `compose/certs/` are gitignored — do not defeat it.
- Stack-specific values hardcoded into scripts or compose files (see
  "No over-specification" below).

## No over-specification

This router runs at many different sites, each with its own namespace and
parent gateway. Nothing here hardcodes one deployment's assumption. Every
environment value — the parent gateway's admin URL, the router's own
namespace, the Zenoh endpoint — arrives at runtime from `compose/.env`
(populated by `install.sh`, driven by `compose/.env.example` as the source
of truth for what varies per deployment).

When you add something, ask: *does this bake one specific site's assumption
into the router?* If so, it belongs in an env var, not a literal.

## Scope: infrastructure only, deliberately

This repo intentionally carries no protocol translators, sensor bridges, or
C2 output layers — see the parent EFDI project for those. EFDI-Edge is
Zenoh router + control plane (`admin-control`, `presence`, `supervisor`,
`cert-renewer`) only. If a change adds a translator or bridge, it likely
belongs in the parent EFDI repo instead, mirrored here only if this box's
role changes.

## How we work

- **Branch + PR.** Open a PR against `main`; keep changes scoped and
  reviewable.
- **Keep it runnable.** `bash -n` every touched shell script; `python3 -m
  py_compile` every touched Python file.
- **License.** Contributions are under Apache-2.0 (see [`LICENSE`](LICENSE)).

## Where things live

- `install.sh` — bare-metal Debian bootstrap: OS update, Docker, Python,
  NetBird, enrollment with a parent zenoh-gateway.
- `start.sh`/`stop.sh` — the same interactive service launcher convention
  as the parent EFDI repo, trimmed to infrastructure services only.
- `compose/control/` — `admin_control.py` (the remote control agent),
  `presence.py`, `supervisor.py`, `gateway.py`/`zenoh_auth.py`/
  `namespace_prefix.py` (Zenoh session helpers).
- `scripts/pki/` — enrollment and certificate-renewal scripts.
- `compose/.env.example` — the per-deployment config.
