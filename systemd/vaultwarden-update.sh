#!/bin/bash
# Automated Vaultwarden update with a consistent pre-update backup.
# Replaces containrrr/watchtower, which is unmaintained and broke against
# the Docker API (client 1.25 vs required 1.44), silently freezing the
# server at 1.35.4 while clients auto-updated past it.
set -euo pipefail

DIR=/opt/bitwarden
BK=$DIR/backups
TS=$(date +%F-%H%M%S)
cd "$DIR"

echo "=== vaultwarden-update $TS ==="

# 1. Consistent snapshot via SQLite's online backup API (WAL-safe, no downtime).
#    The bundled backup container tars db.sqlite3 without db.sqlite3-wal,
#    so it can miss recent commits. This does not.
echo "--- pre-update backup"
docker run --rm -v vaultwarden_data:/data -v "$BK:/out" alpine sh -c \
  "apk add --no-cache sqlite >/dev/null 2>&1 && \
   sqlite3 /data/db.sqlite3 '.backup /out/preupdate-$TS.sqlite3' && \
   cp /data/rsa_key.pem /out/preupdate-$TS-rsa_key.pem"

# Verify the snapshot before trusting it. A file is not a backup.
INTEG=$(docker run --rm -v "$BK:/b" alpine sh -c \
  "apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 /b/preupdate-$TS.sqlite3 'PRAGMA integrity_check;'")
if [ "$INTEG" != "ok" ]; then
  echo "ABORT: pre-update backup failed integrity check: $INTEG" >&2
  exit 1
fi
echo "pre-update backup ok: preupdate-$TS.sqlite3"

# Retain 14 pre-update snapshots.
ls -t "$BK"/preupdate-*.sqlite3 2>/dev/null | tail -n +15 | xargs -r rm -f
ls -t "$BK"/preupdate-*-rsa_key.pem 2>/dev/null | tail -n +15 | xargs -r rm -f

BEFORE=$(docker inspect vaultwarden --format '{{.Config.Image}}@{{.Image}}')

echo "--- pull"
docker compose pull

echo "--- up"
docker compose up -d

AFTER=$(docker inspect vaultwarden --format '{{.Config.Image}}@{{.Image}}')
if [ "$BEFORE" = "$AFTER" ]; then
  echo "no image change"
else
  echo "updated: $BEFORE -> $AFTER"
fi

# Confirm the server is actually healthy after the update, and fail loudly.
# Uses the container's own HEALTHCHECK: no dependency on wget/curl existing
# inside the image (1.37.1 is Debian-based and has neither).
HEALTHY=no
for i in $(seq 1 30); do
  ST=$(docker inspect vaultwarden --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)
  if [ "$ST" = "healthy" ]; then HEALTHY=yes; break; fi
  sleep 5
done
if [ "$HEALTHY" != "yes" ]; then
  echo "ABORT: vaultwarden did not become healthy after update (last status: $ST)" >&2
  exit 1
fi
# Caddy has no HEALTHCHECK, so a broken caddy update would otherwise pass
# silently while the site is unreachable. Assert it is running AND that the
# vault answers end-to-end through the proxy.
CST=$(docker inspect caddy --format '{{.State.Status}}' 2>/dev/null || echo missing)
if [ "$CST" != "running" ]; then
  echo "ABORT: caddy not running after update (status: $CST)" >&2
  exit 1
fi

PROBE=no
for i in $(seq 1 12); do
  if docker run --rm --network container:caddy curlimages/curl:latest \
       -fsS --max-time 10 http://localhost:80/alive >/dev/null 2>&1; then
    PROBE=yes; break
  fi
  sleep 5
done
if [ "$PROBE" != "yes" ]; then
  echo "ABORT: vault did not answer through caddy after update" >&2
  exit 1
fi

echo "vaultwarden healthy, caddy running, end-to-end probe ok"

docker image prune -f >/dev/null 2>&1 || true
echo "=== done $(date +%F-%H%M%S) ==="
