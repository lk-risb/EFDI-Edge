# Security Policy

## Supported Versions

This repo doesn't tag releases — `main` is the only supported branch.
Security fixes land there; there is nothing older to backport to.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Use GitHub Security Advisories on this repository to report privately —
this keeps the report confidential until a fix ships.

Include, where possible:
- Affected component (the Zenoh router config, `admin-control`, an
  enrollment/PKI script, `start.sh`/deployment scripts)
- Steps to reproduce
- Impact (what an attacker could actually do — e.g. cross-namespace
  publish, credential exposure, remote-control auth bypass)

You should receive an acknowledgement within a few days. There's no fixed
SLA — this is a small, partner-operated project — but reports are taken
seriously and fixes are prioritized by severity.

## Scope

This repo covers the Zenoh router deployment (`compose/docker-compose.yml`),
the local control plane (`compose/control/`), the PKI enrollment/renewal
scripts (`scripts/pki/`), and the `start.sh`/`stop.sh`/`install.sh`
scripts. It does not cover vulnerabilities in upstream dependencies (Zenoh
itself, Docker, the parent zenoh-gateway/SCOUT's own WebUI) — report those
to their respective maintainers or the parent EFDI project.

## Notes for Reviewers

- Transport is mutual TLS between this router and the fabric; this router
  is ACL-scoped to write only within its assigned namespace
  (`<PARTNER_NAMESPACE>/**`) — publishes outside it are silently denied
  by the router.
- Certificates are never committed (`compose/certs/`, `compose/.env` are
  gitignored) and are mounted read-only into the container that needs them.
- Private keys never leave this box during enrollment
  (`scripts/pki/enroll-router.sh` generates them locally and sends only
  CSRs to the parent).
- `admin-control` is the only network-reachable control surface on this
  box — bind it to the mesh VPN interface, not `0.0.0.0`, and always set
  `EFDI_CONTROL_TOKEN`.
