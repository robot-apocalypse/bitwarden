# Vaultwarden upgrade runbook

Host: AWS EC2 (`vaultwarden`), deploy dir `/opt/bitwarden`.

## Why (2026-08-17)

Server was stuck on **1.35.4** (container created 2026-04-17) because the
Watchtower service could not talk to the Docker daemon:

```
Error response from daemon: client version 1.25 is too old.
Minimum supported API version is 1.44
```

`containrrr/watchtower` is unmaintained, so nothing had updated in four months.

Meanwhile clients auto-updated. The desktop client calls
`POST /identity/accounts/prelogin/password`, an endpoint **added in 1.36.0**
(PR #7156, released 2026-05-03). On 1.35.4 it 404s, and the client reports
"an unexpected error occurred".

1.36.0 also carries security fixes, including **SSRF via the icon endpoint**
(GHSA-72vh-x5jq-m82g), which this deployment exercises heavily.

## Pre-flight

```bash
cd /opt/bitwarden

# 1. Confirm volume identity. Expect exactly one: vaultwarden_data.
#    Two volumes (e.g. bitwarden_vw-data) means a past deploy switched
#    volumes and regenerated rsa_key.pem -- stop and identify the live one.
docker volume ls | grep -iE 'vw|vault|bitwarden'

# 2. Trigger an on-demand backup. Verify the TIMESTAMP is from just now --
#    the presence of old files proves nothing.
docker exec vaultwarden_backup manual
ls -lh --time-style=full-iso ./backups | tail -5
date

# 3. Independent copy of the data volume.
#    Vaultwarden MUST be stopped: SQLite runs in WAL mode (db.sqlite3-wal /
#    -shm), and copying it live yields a tarball that restores to a stale or
#    corrupt database -- worse than no backup, because you would trust it.
docker compose stop vaultwarden
docker run --rm -v vaultwarden_data:/data -v "$PWD:/out" alpine \
  tar czf /out/vw-data-$(date +%F).tar.gz -C /data .
ls -lh vw-data-*.tar.gz
```

Vaultwarden stays stopped from here into the upgrade below. Confirm the
working tree matches what is deployed (expect HEAD `e042a83`, clean):

```bash
git status
git log --oneline -1
```

`rsa_key.pem` lives in the data volume. Losing it invalidates every client
session. Confirm it is inside the tarball before continuing:

```bash
tar tzf vw-data-$(date +%F).tar.gz | grep rsa_key
```

### Alternative: AMI snapshot

An AMI of the whole instance is a valid substitute for the tarball, and is a
better rollback (launch a fresh instance from it). Taken with containers
running it is crash-consistent, not application-consistent; SQLite recovers
from that by replaying the WAL on first start. Stopping vaultwarden before
the snapshot still gives a cleaner image if you have the option.

## Upgrade

`docker compose up -d` on its own does **not** update anything: the `latest`
tag is already present locally, so compose reuses it. The `pull` is what
fetches the new image.

`vw-data` is a **named** volume (`name: vaultwarden_data`), so a normal
pull/up preserves the database and signing key. Clients are NOT logged out
by this step.

```bash
cd /opt/bitwarden
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=50 vaultwarden
```

## Verify

```bash
curl -s https://bitwarden.peakscale.solutions/api/version          # expect 1.37.x
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' -d '{"email":"x@example.com"}' \
  https://bitwarden.peakscale.solutions/identity/accounts/prelogin/password
# expect anything but 404
```

Then log in from desktop and mobile.

## Rollback

Restore into a **new** volume and repoint compose at it. Never `rm -rf` the
live volume first -- a bad tarball would leave you with nothing to go back to.

```bash
cd /opt/bitwarden
docker compose down

# Restore into a fresh volume, leaving vaultwarden_data untouched.
docker volume create vaultwarden_data_restored
docker run --rm -v vaultwarden_data_restored:/data -v "$PWD:/in" alpine \
  tar xzf /in/vw-data-<DATE>.tar.gz -C /data
docker run --rm -v vaultwarden_data_restored:/data alpine ls -l /data/rsa_key.pem

# In docker-compose.yml: set the volume name to vaultwarden_data_restored
# and pin the previous image (vaultwarden/server:1.35.4), then:
docker compose up -d
```

Only delete `vaultwarden_data` once the restored volume is confirmed good.

## Backups were silently broken (found 2026-08-17)

`./backups` was **empty since 2026-04-11** -- this deployment had never
produced a single backup. The container logged:

```
tar: can't open '/backups/2026-08-14_03-00-00.tar.xz': Permission denied
[2026-08-14 03:00:00 AM] New backup created, no archives older than 30 days to delete.
```

It reports success on the line after the write fails, which is why four
months passed unnoticed.

Cause: `jmqm/vaultwarden_backup` requires `UID`/`GID` env vars and the
compose file set neither, so the cron job could not write to the root-owned
`./backups` bind mount. Fixed by adding `UID=0` / `GID=0` (matches the
root-owned mount, and can read the root-owned `/data`).

Verify after deploying the change -- do not assume:

```bash
docker compose up -d backup
docker exec vaultwarden_backup manual
ls -lh --time-style=full-iso ./backups     # a real file, timestamped NOW
tar tJf ./backups/<newest>.tar.xz | head   # it must actually open
```

The last step matters: a file existing is not proof it is a valid archive.
Confirm `rsa_key.pem` and `db.sqlite3` are inside.

The image is unmaintained (last pushed 2024-10-06), and its script is **not
WAL-safe**: it tars `db.sqlite3` without `db.sqlite3-wal`, so a restore can
silently lose everything committed since the last checkpoint. Treat its
archives as a secondary copy. The primary snapshots come from the updater
below, which uses SQLite's online backup API.

## Automated updates (installed 2026-08-17)

Watchtower was **replaced**, not removed. The requirement is real -- clients
auto-update, so a server that never updates will break again. But the fix
is host-side, because Watchtower's failure mode was a third-party image
rotting against the Docker API, which a host-side updater cannot suffer:
it uses the same `docker` CLI that apt keeps in step with the daemon.

- `/usr/local/bin/vaultwarden-update.sh`
- `/etc/systemd/system/vaultwarden-update.{service,timer}` -- Sun 03:30,
  `Persistent=true`, 30m jitter

Each run: takes a WAL-safe snapshot via SQLite's online backup API,
**verifies it with `PRAGMA integrity_check` and aborts if it fails**, keeps
the last 14, pulls, brings the stack up, then waits for vaultwarden's own
container HEALTHCHECK and **exits non-zero if it never becomes healthy**.

```bash
systemctl list-timers vaultwarden-update.timer   # when it next runs
systemctl start vaultwarden-update.service       # run now
journalctl -u vaultwarden-update.service -n 50   # what happened
```

Note on the health check: the first version shelled out to `wget` inside the
vaultwarden container. The 1.37.1 image is Debian-based and has neither
`wget` nor `curl`, so the check errored, the string comparison did not match,
and the service exited 0 -- a check that could not fail. Caught only by
running it. If you edit this script, **run it and read the journal**; the
recurring lesson in this incident is that nothing here reports its own
failure.

- **Pin the image tag** (`vaultwarden/server:1.37.1`) instead of `latest`, so
  updates are intentional and the running version is visible in git. Note this
  trades away automatic patching -- with the timer in place, staying on
  `latest` is defensible; pinning means updating the tag deliberately.

## Follow-ups

- **The AMI from 2026-08-17 is a PRE-fix snapshot.** It predates the 1.37.1
  upgrade, the backup permission fix, the removal of Watchtower, and the
  updater. Restoring it silently reverts all of them. Take a fresh AMI now
  that the host is in its intended state, and treat the old one as
  incident-rollback only.
- **Log rotation**: `LOG_FILE=/data/vaultwarden.log` with `EXTENDED_LOGGING`
  and no rotation -- 35 MB as of 2026-08-17 on a root filesystem at 67%
  (2.3 GB free). Not urgent at that rate, but unbounded. `icon_cache` grows
  too. Add rotation before it matters.
- **No alerting path**: SMTP is unconfigured, so nothing here can tell you
  when it breaks -- which is how four months passed. Configuring SMTP would
  let the updater's `OnFailure=` actually reach you.
- **Client IPs**: compose sets `IP_HEADER=X-Real-IP` but `caddy/Caddyfile`
  uses a bare `reverse_proxy vaultwarden:80`. Caddy sends `X-Forwarded-For`,
  not `X-Real-IP`, so every log line shows the proxy container IP
  (172.18.0.3). Add `header_up X-Real-IP {remote_host}`. Latent until
  fail2ban is installed, which would then ban the proxy.
- **Push**: `PUSH_ENABLED=false` with populated `PUSH_INSTALLATION_ID`/`KEY`
  looks like leftover from commit 18ec5c6. Re-enable if mobile should
  update on its own.
- **Signups are closed** -- verified, no action needed. `/api/config` reports
  `disableUserRegistration: false`, but that field is `is_signup_disabled()`,
  a UI hint for clients. It stays false here because SMTP is unconfigured
  (`mail_enabled()` false) and `invitations_allowed` defaults true; hiding
  registration in that state would leave invited users unable to sign up.
  Enforcement is `is_signup_allowed(email)` -> `signups_allowed()` = false.
