# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Ian's self-hosted Bitwarden (Vaultwarden) at `https://bitwarden.peakscale.solutions`. **It does not run on zeno.** Production is a single AWS EC2 instance (t3.micro, us-west-2, Elastic IP, Ubuntu) with the repo checked out at `/opt/bitwarden`. This directory on zeno is the git working copy (remote `github.com:robot-apocalypse/bitwarden`, branch `master`) and the place Terraform is run from. Stack: `vaultwarden/server:latest` + `caddy:2` (Let's Encrypt, ports 80/443) via docker compose; host-side systemd timers do backups and updates.

**Read `docs/upgrade-runbook.md` first** — it is the current, authoritative ops doc (access, timers, alerts, restore, rollback, history). `README.md` is stale (still lists the removed backup container).

## Access and deploy

- No SSH (port 22 closed, no keys). Shell via SSM: `aws ssm start-session --target <instance_id> --profile peakscale --region us-west-2` (instance id is in the runbook / `terraform output instance_id`).
- Repo changes reach prod by pulling on the host in `/opt/bitwarden` and re-running the relevant installer (unverified: assumed git pull over SSM; there is no CI).
- `sudo ./systemd/install.sh` — installs backup/update scripts to `/usr/local/bin`, units to `/etc/systemd/system`, logrotate config. Idempotent.
- `sudo ./fail2ban/install.sh` — host fail2ban jail reading the vaultwarden log in the Docker volume; bans go in `DOCKER-USER`.
- `setup.sh` is the original first-time bootstrap (create `.env`, `docker compose up -d`). Not needed on the existing host.
- Manual update: `sudo systemctl start vaultwarden-update.service` (takes a verified backup first, health-checks after). Do not just `docker compose up -d` — tags float, only `pull` fetches.

## Terraform (`terraform/`)

AWS provider, region us-west-2, `profile = "peakscale"`. Remote state: `s3://peakscale-terraform-state-prod/prod/bitwarden/terraform.tfstate` (bucket in us-east-1, S3 lockfile).
- `simple.tf` — default VPC, security group (80/443), SSM instance role, EC2 instance (user_data + ami in `ignore_changes`; edits only affect rebuilds), Elastic IP, Route53 A + CAA records.
- `backups.tf` — S3 backup bucket `peakscale-vaultwarden-backups` (versioned, 90-day expiry, instance may only PutObject), DLM daily EBS snapshots (keep 7).
- `alerts.tf` — SNS email + CloudWatch dead-man's-switch alarms (`vaultwarden-backup-missing`, `vaultwarden-update-failed`) fed by heartbeat metrics from the backup script.

Only `plan` without being asked; `apply` changes production.

## Layout

```
docker-compose.yml        prod stack (vaultwarden + caddy); volumes vaultwarden_data, caddy_data, caddy_certs
docker-compose.local.yml  local throwaway test instance (http://localhost:8888, dummy admin token)
caddy/Caddyfile           {$DOMAIN} reverse proxy, sets X-Real-IP, HSTS
systemd/                  vaultwarden-backup.{sh,service,timer} (daily 03:00 America/Denver), vaultwarden-update.* (Sun 03:30 UTC), install.sh
fail2ban/, logrotate/     host config + installers
docs/upgrade-runbook.md   ops runbook (authoritative)
docs/superpowers/plans/   2025-04 modernization plan (historical; describes the since-removed backup container)
```

`.env` vars (names only): `DOMAIN EMAIL ADMIN_TOKEN SMTP_* LOG_LEVEL`. ADMIN_TOKEN is stored hashed. `.env` exists only on the EC2 host (in EBS snapshots, not in backup archives).

## Gotchas

- "Running" is not "working": Watchtower, the old jmqm backup container and unattended-upgrades all silently did nothing for months while logging success. After any change, run the job and read its output.
- Backups must use SQLite's online `.backup` (WAL-safe); a plain copy of `db.sqlite3` is stale. On restore, delete `db.sqlite3-wal`/`-shm`.
- Keep images floating on `latest`: the Aug 2026 outage was the server frozen at 1.35.4 while clients auto-updated. Rollback = pin + restore preupdate backup (schema migrations).
- Vaultwarden must see real client IPs (`IP_HEADER=X-Real-IP` + Caddy `header_up`), or rate limiting and fail2ban are useless.
- Terraform state was once lost (local-only on a lost laptop) and re-imported 2026-10-02. The `simple.tf` comment referring to `imports.tf` is stale — that file was removed.

## Related

Same AWS account / `peakscale` profile / state bucket as `~/apps/invoice`. Alerts go to email via SNS, not the zeno ntfy server.
