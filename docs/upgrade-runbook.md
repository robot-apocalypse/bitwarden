# Vaultwarden operations runbook

Production: `https://bitwarden.peakscale.solutions`, one EC2 instance
(`i-0c20d9e1feb8aa8f8`, us-west-2, Elastic IP `35.85.12.15`), deploy dir
`/opt/bitwarden`, data in the Docker volume `vaultwarden_data`.

**Access is via SSM, not SSH** (port 22 is closed and no keys are installed):

```bash
aws ssm start-session --target i-0c20d9e1feb8aa8f8 --profile peakscale --region us-west-2
```

Infrastructure is Terraform in `terraform/`, with state in
`s3://peakscale-terraform-state-prod/prod/bitwarden/terraform.tfstate`.

> **Ground rule.** Three mechanisms on this host -- Watchtower, the old backup
> container, and unattended-upgrades -- ran for months while doing nothing,
> and each logged success. "Container is up" or "timer is enabled" is not
> "job is working". After changing anything, run it and read its output.

## What runs automatically

| What | When | Mechanism | Output |
|---|---|---|---|
| Backup | daily 03:00 America/Denver | `vaultwarden-backup.timer` -> `/usr/local/bin/vaultwarden-backup.sh daily` | `backups/daily-*.tar.gz` (keep 30) + S3 |
| Container update | Sun 03:30 UTC (+0-30 min) | `vaultwarden-update.timer` -> `/usr/local/bin/vaultwarden-update.sh` | `backups/preupdate-*.tar.gz` (keep 14) + S3 |
| OS security updates | daily | `unattended-upgrades` (stock `50-` + `52unattended-upgrades-local`) | reboots at 10:30 UTC when required |
| Disk snapshots | daily 11:00 UTC | DLM policy (Terraform `backups.tf`) | EBS snapshots, keep 7 |
| Log rotation | weekly or at 20 MB | `/etc/logrotate.d/vaultwarden` | `vaultwarden.log-YYYYMMDD.gz`, keep 12 |
| Alerting | continuous | CloudWatch alarms (Terraform `alerts.tf`) | email to ian@peakscale.solutions |

Everything under `systemd/` and `logrotate/` is installed by
`sudo ./systemd/install.sh`, which is safe to re-run.

### Backups

`vaultwarden-backup.sh` snapshots the database with SQLite's online backup
API, which includes the WAL. A plain file copy of `db.sqlite3` does not: the
main file is only checkpointed when the container restarts, so before
2026-10-02 every "daily" archive was the database as of the last update. The
script then:

1. runs `PRAGMA integrity_check` on the snapshot, and aborts if it fails;
2. tars the snapshot with `rsa_key.pem`, plus `attachments/`, `sends/` and
   `config.json` if present;
3. uploads the archive to `s3://peakscale-vaultwarden-backups/vaultwarden/`.
   The bucket is versioned, expires objects after 90 days, and the instance
   role may only `PutObject` -- it cannot list, read, or delete;
4. publishes the CloudWatch heartbeat (see Alerts).

Not in the archives: `.env` (DOMAIN, EMAIL, the hashed ADMIN_TOKEN) and the
Caddy certificates. Both are in the EBS snapshots, and both are recreatable.

For an on-demand backup before risky work, use any label:

```bash
sudo /usr/local/bin/vaultwarden-backup.sh manual
```

### Container updates

`vaultwarden-update.sh`:

1. takes a `preupdate` backup, and **aborts the update if it fails**;
2. `docker compose pull`, then `docker compose up -d` (`up` alone updates
   nothing -- the tags float, so `pull` is what fetches new images);
3. requires vaultwarden's HEALTHCHECK to report healthy, caddy to be running,
   and `/alive` to answer through caddy, or exits non-zero;
4. records `ok <epoch>` in `/var/lib/vaultwarden-ops/update-status`. Any
   other exit records `failed`.

Images float (`vaultwarden/server:latest`, `caddy:2`) on purpose. The August
2026 outage was the server freezing at 1.35.4 while clients auto-updated
past it, which broke desktop and mobile login: `/identity/accounts/prelogin/password`
returned 404 because that endpoint arrived in 1.36.0. Staying current is the
requirement; the pre-update backup and health checks are the safety net.

## Alerts

Both alarms fire on the **absence** of a success signal, and are evaluated
in CloudWatch, not on the host.

- **`vaultwarden-backup-missing`** -- no `BackupSuccess` (Label=daily)
  datapoint for 26 hours. The causes are a failed backup, a stopped timer, or
  a dead host or SSM agent. Start with:

  ```bash
  systemctl list-timers 'vaultwarden-*'
  journalctl -u vaultwarden-backup.service -n 40
  ```

- **`vaultwarden-update-failed`** -- the daily backup reported `UpdateOK=0`:
  the last update run failed, is still marked `running`, or last succeeded
  over 8 days ago. Start with:

  ```bash
  cat /var/lib/vaultwarden-ops/update-status
  journalctl -u vaultwarden-update.service -n 60
  ```

Each alarm also emails when it returns to OK.

## Checking health by hand

```bash
systemctl list-timers 'vaultwarden-*'
journalctl -u vaultwarden-backup.service -n 20
journalctl -u vaultwarden-update.service -n 30
cat /var/lib/vaultwarden-ops/update-status
docker ps --format '{{.Names}} {{.Image}} {{.Status}}'
docker exec vaultwarden /vaultwarden --version
ls -lt /opt/bitwarden/backups | head
fail2ban-client status vaultwarden
apt list --upgradable 2>/dev/null | grep -c security     # expect 0 or close
```

Verify a backup by restoring it, not by its existence (see Restore).

## Manual update

Run the automated job, which takes the backup and does the health checks:

```bash
sudo systemctl start vaultwarden-update.service
journalctl -u vaultwarden-update.service -n 30
```

The run is good only if the journal ends with `vaultwarden healthy, caddy
running, end-to-end probe ok` and `=== done`.

## Rollback

Vaultwarden upgrades can migrate the database schema, and an older binary
will not start on a newer schema. A rollback is therefore a restore, not
just an image change.

1. Find the version before the update, from the journal's
   `updated: <old> -> <new>` line, or from the vaultwarden release notes.
2. Pin it in `docker-compose.yml`, e.g. `image: vaultwarden/server:1.37.2`.
3. Restore that run's `preupdate-*.tar.gz` (see Restore), then
   `docker compose up -d`.
4. While pinned, the weekly updater keeps you on that version (it pulls the
   pinned tag, so nothing changes). Unpin back to `latest` once upstream has
   fixed the problem, or the server falls behind the clients again -- which
   is exactly what caused the August 2026 outage.

## Restore

Tested 2026-10-03: the newest S3 archive was restored into a throwaway
container running the production image. It started cleanly, kept the
existing `rsa_key.pem`, passed `integrity_check`, and had all ciphers.

1. Get the archive. Local copies are in `/opt/bitwarden/backups/`. For S3,
   from a workstation with SSO credentials (the instance cannot read the
   bucket):

   ```bash
   aws s3 ls s3://peakscale-vaultwarden-backups/vaultwarden/ --profile peakscale
   # The host has no SSH/scp, so hand it a short-lived download link:
   aws s3 presign s3://peakscale-vaultwarden-backups/vaultwarden/<file>.tar.gz --expires-in 600 --profile peakscale
   # then on the host:
   sudo curl -fsS -o /opt/bitwarden/backups/<file>.tar.gz '<presigned-url>'
   ```

2. Take a backup of the current state first, even a broken one:
   `sudo /usr/local/bin/vaultwarden-backup.sh prerestore`.

3. Stop vaultwarden and restore into the volume. **Delete `db.sqlite3-wal`
   and `db.sqlite3-shm`** -- otherwise SQLite replays the old WAL on top of
   the restored database:

   ```bash
   cd /opt/bitwarden
   docker compose stop vaultwarden
   docker run --rm -v vaultwarden_data:/data -v "$PWD/backups:/in:ro" alpine sh -c \
     'rm -f /data/db.sqlite3-wal /data/db.sqlite3-shm && tar -xzf /in/<file>.tar.gz -C /data'
   docker compose start vaultwarden
   ```

4. Verify: `docker ps` shows vaultwarden healthy, the web vault logs in, and
   the item count looks right. `rsa_key.pem` came from the same archive, so
   existing client sessions keep working.

To rehearse without touching production, restore into a new volume and run
`vaultwarden/server` against it on a local port, as the 2026-10-03 test did.

**Whole-host loss:** launch from the latest DLM snapshot (it includes `.env`
and the Caddy certificates), or rebuild with Terraform and restore the newest
S3 archive into a fresh deploy. Then point the Elastic IP at the new
instance.

## OS updates and reboots

`unattended-upgrades` installs the security pocket daily and reboots at
10:30 UTC when required. That includes Docker and containerd security
releases, which restart the engine; the containers come back because they
are `restart: unless-stopped`. Ordinary `noble-updates` are not applied
automatically -- run `sudo apt full-upgrade` occasionally.

The config is Ubuntu's stock `/etc/apt/apt.conf.d/50unattended-upgrades` plus
`52unattended-upgrades-local`. Do not overwrite `50-`: the key is
`Unattended-Upgrade::` (singular). The original user_data wrote
`Unattended-Upgrades::`, which apt silently ignores, so from April to
October 2026 nothing was installed while the daily run logged success. To
verify, run:

```bash
sudo unattended-upgrade --dry-run -d 2>&1 | grep 'Allowed origins are'   # must not be empty
```

## History

- **2026-08-17** -- Watchtower had been crash-looping for four months
  (`client version 1.25 is too old`), freezing the server at 1.35.4 and
  breaking desktop and mobile clients. Replaced with the host-side updater.
  The `jmqm/vaultwarden_backup` container was found never to have written a
  file (missing `UID`/`GID`) while logging "New backup created".
- **2026-10-02** -- Drift check. The backup container's archives turned out to
  be frozen copies, missing the WAL, so it was replaced by
  `vaultwarden-backup.sh` with S3 and DLM. The lost Terraform state was
  re-imported, an Elastic IP was added, and fail2ban was made to work: caddy
  now sends `X-Real-IP`, the filter was rewritten, and bans go in DOCKER-USER.
- **2026-10-03** -- Security review. unattended-upgrades was found
  never to have run; it was fixed and 146 security updates were installed.
  Other changes: the admin token was hashed, HSTS and a CAA record were added,
  log rotation was set up, the restore was tested, and these alerts were
  added.
