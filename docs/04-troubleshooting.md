# 04 — Troubleshooting

Symptom-first fixes for problems hit while installing or operating an
EFDI-Edge router — including plain "which value goes where" confusion, not
just crashes. Read this before re-investigating something that looks
familiar; if you hit something new, add it here so the next person doesn't
have to re-earn the same diagnosis.

### Zenoh connection failure

**Symptom:** `zenoh.ZError: Unable to connect to any of [tls/zenoh...]`

```bash
# 1. Verify the router is healthy
docker compose -f compose/docker-compose.yml ps zenoh-router

# 2. Verify the endpoint variable is set
echo $ZENOH_LOCAL_ENDPOINT   # expected: tcp/127.0.0.1:7448

# 3. Verify certificate files exist
ls $EFDI_CERT_DIR/*.pem
```

If `compose/.env` was loaded with a bare `source compose/.env`, variables
are not exported to child processes. Use `./start.sh` (which handles
this), or:

```bash
set -a && source compose/.env && set +a
```

### A TLS/mTLS identity profile must match the endpoint it dials

**Symptom:** A fabric connection attempt to the parent gateway produces no
error and no link — looks identical to a DNS or firewall issue.

**Cause:** the parent gateway and any other fabric this router might ever
dial are each signed by a **different CA**. Pointing the right endpoint at
the wrong certificate identity fails the mTLS handshake silently rather
than with a clear rejection.

**Fix:** the Zenoh fabric endpoint entered during enrollment and this
router's own enrolled identity (from `scripts/pki/enroll-router.sh`) are
one atomic pair — never mix an endpoint from one enrollment with
certificates from a different one.

### NetBird split-DNS is invisible inside containers

**Symptom:** `compose/.env` points the Zenoh endpoint at a mesh hostname
(e.g. `zenoh-gateway.example`); the `zenoh-router` container never even
attempts a connection — no socket, no TLS error, just silence.

**Cause:** `network_mode: host` shares the network *namespace*, not
`/etc/resolv.conf`. NetBird's split-DNS resolver for the mesh domain runs
on the **host** only; the container gets Docker's own generated resolver,
which has never heard of the mesh domain. The hostname resolves fine on
the host (`getent hosts` works there) and silently fails inside the
container.

**Fix:** add an explicit `extra_hosts` entry mapping the mesh hostname to
its current NetBird IP in `zenoh-router`'s compose service definition.
Re-add/update it if NetBird ever reassigns the IP.

### Identically-named duplicate function definitions silently shadow

**Symptom:** Code you're reading in `compose/control/` or
`compose/protocols/` looks obviously wrong (wrong logic, a bug that should
be very visible) — but the running system's actual behavior looks fine.

**Cause:** Python allows redefining a function at module scope with no
warning. If a file has the same function name defined twice, the
**second** definition silently wins — the first becomes dead code that
still looks live.

**Fix:** before trusting that a function you're reading is the one that
actually runs, confirm at runtime:
`python3 -c "import inspect; from module import the_func; print(inspect.getsourcelines(the_func))"`
tells you which definition's line number is actually bound.

### `pip install` fails with "externally-managed-environment"

**Symptom:** Running `pip install -r requirements.txt` directly against
the system `python3` (rather than through `install.sh`/`start.sh`) fails
with `error: externally-managed-environment` (PEP 668, common on modern
Debian/Ubuntu).

**Cause:** the system Python is intentionally locked down against
unmanaged `pip install`s. `install.sh`/`start.sh` don't fight this — they
create and use their own virtualenv at `compose/venv`.

**Fix:** use that venv directly:

```bash
compose/venv/bin/pip install -r compose/requirements.txt
compose/venv/bin/python3 control/some_script.py
```

Never pass `--break-system-packages` to the system `pip`.

### Duplicate process instances

**Symptom:** Two copies of the same service running, usually from calling
`./start.sh` twice without stopping first.

**Fix:**

```bash
./stop.sh
rm -f compose/state/.pids/*.pid
./start.sh
```

### A code fix isn't live until the running process restarts

**Symptom:** You fix a bug in `admin_control.py`, `supervisor.py`, or
anything under `compose/protocols/`, confirm the file changed on disk, and
the running system's behavior doesn't change.

**Cause:** editing a `.py` file has zero effect on an already-running
interpreter holding the old bytecode in memory.

**Fix:** restart the specific process that imports the changed file (not
just the one that crashed, if it's a shared module like
`compose/protocols/gateway.py`) before concluding a fix didn't work.

### A `TypeError` names a parameter that doesn't exist anywhere in the current source

**Symptom:** A long-running process throws a `TypeError` naming some
parameter — but `grep`-ing the entire repo for that parameter name finds
nothing; the function's actual, on-disk signature has never had a
parameter by that name.

**Cause:** a stale `__pycache__/*.pyc`, compiled from an older version of
a shared module (e.g. `compose/protocols/gateway.py`), is shadowing the
current source.

**Fix:**

```bash
find compose -name '__pycache__' -exec rm -rf {} +
# then restart every process that imports the affected module
```

### Enrollment fails with an HTTP error

**Symptom:** `scripts/pki/enroll-router.sh` (run by `install.sh`) fails
with an HTTP error when contacting the parent zenoh-gateway.

**Cause:** almost always the wrong URL or a spent/expired token. The
enrollment URL is the parent gateway's **zenoh-admin WebUI base URL**
(e.g. `https://gateway.example`) — it is easy to instead type the
`admin-control` port (`18896`), which is a *different* service on the same
box used for ongoing remote control after enrollment, not for enrolling in
the first place. An enrollment token is also single-use and time-limited;
reusing one that already succeeded (or waiting too long after it was
issued) fails the same way.

**Fix:** double-check the URL is the WebUI base URL, not `:18896`, and
get a fresh token from the parent gateway if the old one might have
already been used or has expired.

### `admin-control` isn't reachable from the parent gateway

**Symptom:** Enrollment succeeds and the router starts, but the parent
gateway's fabric inspector (panoscope) never shows it as controllable, or
a restart command from the parent never reaches it.

**Cause:** `EFDI_CONTROL_BIND` in `compose/.env` is still `127.0.0.1`
(loopback-only) — correct for a router that only ever controls itself, but
the parent gateway is a *different* machine and can't reach a
loopback-bound service over the network.

**Fix:** Set `EFDI_CONTROL_BIND` to the mesh VPN interface's own IP (the
NetBird address, typically), or `0.0.0.0` if binding on every interface is
acceptable for this deployment, then restart `admin-control`.

### Zenoh router won't come up healthy

**Symptom:** `docker compose -f compose/docker-compose.yml ps` shows
`zenoh-router` unhealthy or restarting.

**Cause:** most often a missing or malformed
`compose/state/zenoh/config.json5` — this file is generated by the
enrollment step, not hand-written; if enrollment failed partway through
(see the HTTP-error entry above) or was interrupted, it can be absent or
half-written.

**Fix:**

```bash
docker compose -f compose/docker-compose.yml logs zenoh-router
```

If the log points at a missing/invalid `config.json5`, re-run
`scripts/pki/enroll-router.sh` (safe to re-run — see
[03-bootstrap-and-install.md](03-bootstrap-and-install.md)) rather than
editing the generated file by hand.

### "There's no dashboard, is it even doing anything?"

**Symptom:** After a clean install, there's nothing to look at locally —
no WebUI, no obvious confirmation the router is doing its job.

**Cause:** this is by design, not a missing feature. EFDI-Edge is a
headless router with a remote control plane; it has no local dashboard on
purpose (see the parent README's "Relationship to the parent EFDI repo").

**Fix:** confirm liveness from the *parent* gateway's side instead of
looking for a local UI — ask whoever manages it to check the router
appears in their fabric inspector (panoscope) and that a restart command
issued from there actually reaches it. Locally, `tail -f
compose/state/logs/<service>.log` is the only "dashboard" this router has.
