#!/bin/bash
# Consistent Vaultwarden backup, kept locally and copied off-host to S3.
# Usage: vaultwarden-backup.sh [label]   (label: daily | preupdate | ...)
#
# Replaces jmqm/vaultwarden_backup, whose daily archives were byte-identical
# for weeks: it tarred db.sqlite3 without db.sqlite3-wal, and the main file
# is only checkpointed when the container restarts, so every archive was the
# database as of the last update. This uses SQLite's online backup API, which
# includes the WAL.
set -euo pipefail

LABEL=${1:-daily}
DIR=/opt/bitwarden
BK=$DIR/backups
BUCKET=peakscale-vaultwarden-backups
TS=$(date +%F-%H%M%S)
NAME=$LABEL-$TS.tar.gz
AWS=/snap/bin/aws
STATUS=/var/lib/vaultwarden-ops/update-status
case "$LABEL" in preupdate) KEEP=14 ;; *) KEEP=30 ;; esac

echo "=== vaultwarden-backup $NAME ==="

# Snapshot, verify, and archive in one throwaway container. /data is mounted
# read-write because reading a WAL-mode database needs to write db.sqlite3-shm. The db snapshot
# must pass integrity_check before anything is written to $BK.
docker run --rm -v vaultwarden_data:/data -v "$BK:/out" alpine sh -euc "
  apk add --no-cache sqlite >/dev/null 2>&1
  S=\$(mktemp -d)
  sqlite3 /data/db.sqlite3 \".backup \$S/db.sqlite3\"
  R=\$(sqlite3 \$S/db.sqlite3 'PRAGMA integrity_check;')
  [ \"\$R\" = ok ] || { echo \"integrity_check failed: \$R\" >&2; exit 1; }
  echo \"ciphers: \$(sqlite3 \$S/db.sqlite3 'select count(*) from ciphers;')\"
  cp /data/rsa_key.pem \$S/
  for f in config.json attachments sends; do
    if [ -e /data/\$f ]; then cp -a /data/\$f \$S/; fi
  done
  tar -czf /out/$NAME.tmp -C \$S .
  mv /out/$NAME.tmp /out/$NAME
"
echo "local ok: $BK/$NAME ($(stat -c %s "$BK/$NAME") bytes)"

# Off-host copy. The instance role may only PutObject, so confirm the upload
# -- `aws s3 cp` exits non-zero on any failed upload.
"$AWS" s3 cp --only-show-errors "$BK/$NAME" "s3://$BUCKET/vaultwarden/$NAME"
echo "s3 ok: s3://$BUCKET/vaultwarden/$NAME"

ls -t "$BK"/"$LABEL"-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

# Heartbeat for the CloudWatch dead-man's-switch alarm. This is only reached
# when everything above succeeded, so a missing datapoint means a failure, a
# timer that stopped running, or a dead host -- alerted on by AWS, not by
# anything on this box.
put_metric() {
  "$AWS" cloudwatch put-metric-data --region us-west-2 --namespace Vaultwarden \
    --metric-name "$1" --value "$2" ${3:+--dimensions "$3"}
}
put_metric BackupSuccess 1 "Label=$LABEL"

# The daily run also reports on the weekly updater (see vaultwarden-update.sh):
# 1 only if its last run succeeded and was under 8 days ago.
if [ "$LABEL" = daily ]; then
  read -r STATE WHEN 2>/dev/null < "$STATUS" || { STATE=missing; WHEN=0; }
  if [ "$STATE" = ok ] && [ $(( $(date +%s) - WHEN )) -lt $(( 8 * 86400 )) ]; then OK=1; else OK=0; fi
  echo "updater: last state=$STATE at $(date -d @"$WHEN" +%F-%H%M%S) -> UpdateOK=$OK"
  put_metric UpdateOK "$OK"
fi
echo "=== done ==="
