# Vaultwarden Self-Hosted

Production-grade self-hosted Bitwarden password manager.

## Quick Start

```bash
git clone https://github.com/YOUR_USERNAME/bitwarden.git
cd bitwarden
cp .env.example .env
nano .env
./setup.sh
```

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| vaultwarden | vaultwarden/server | Password vault |
| caddy | caddy:2 | HTTPS reverse proxy |
| backup | jmqm/vaultwarden_backup | Automated backups |

## Required Config

- `DOMAIN` - Your Bitwarden URL
- `EMAIL` - Email for Let's Encrypt
- `ADMIN_TOKEN` - `openssl rand -base64 48`

## Backup

Automatic daily at 3 AM, kept 30 days.

Manual: `docker exec vaultwarden_backup manual`

Restore: Extract backup tar.xz to data volume.

## Security

- Fail2ban: `fail2ban/install.sh`
- Admin panel behind `ADMIN_TOKEN`
- No signups (`SIGNUPS_ALLOWED=false`)

## Update

```bash
docker compose pull && docker compose up -d
```

## Recovery

```bash
git clone your-repo
cp .env.example .env
# Add your values
./setup.sh
# Restore from backup
```