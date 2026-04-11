# Vaultwarden Infrastructure Modernization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modernize self-hosted Bitwarden from 8 containers to 3, GitHub-ready for disaster recovery, production-grade security and backups.

**Architecture:** Simplified stack with vaultwarden + caddy + backup container. All config in GitHub for reproducibility. Fail2ban moved to host level for simplicity.

**Tech Stack:** Docker, Docker Compose, Vaultwarden, Caddy, jmqm/vaultwarden_backup

---

## Deliverables

### File Structure

```
bitwarden/
├── docker-compose.yml           # Main compose (3 services)
├── .env.example           # Environment template (no secrets)
├── caddy/
│   └── Caddyfile        # Reverse proxy config
├── backup/
│   └── config.env       # Backup config (optional)
├── backup.sh            # Fallback backup script
├── fail2ban/
│   └── jail.local      # Fail2ban config (host level)
└── README.md              # Deployment + recovery docs
```

---

## Task 1: Create docker-compose.yml

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Write docker-compose.yml**

```yaml
version: '3.8'

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    volumes:
      - vw-data:/data
    environment:
      - DOMAIN=${DOMAIN}
      - ADMIN_TOKEN=${ADMIN_TOKEN}
      - SIGNUPS_ALLOWED=false
      - SHOW_PASSWORD_HINT=false
      - SMTP_HOST=${SMTP_HOST}
      - SMTP_FROM=${SMTP_FROM}
      - SMTP_FROM_NAME=Bitwarden\ \(${DOMAIN}\)
      - SMTP_PORT=${SMTP_PORT}
      - SMTP_SECURITY=${SMTP_SECURITY}
      - SMTP_USERNAME=${SMTP_USERNAME}
      - SMTP_PASSWORD=${SMTP_PASSWORD}
      - SMTP_AUTH_METHOD=Login
      - YUBICO_CLIENT_ID=${YUBICO_CLIENT_ID}
      - YUBICO_SECRET_KEY=${YUBICO_SECRET_KEY}
      - YUBICO_SERVER=${YUBICO_SERVER:-https://api.yubico.com}
      - PUSH_ENABLED=${PUSH_ENABLED:-true}
      - IP_HEADER=X-Real-IP
      - ROCKET_ADDRESS=0.0.0.0
      - ROCKET_PORT=80
      - LOG_FILE=/data/vaultwarden.log
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - EXTENDED_LOGGING=true
    networks:
      - proxy

  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-certs:/root/.caddy
    environment:
      - ACME_AGREE=true
      - DOMAIN=${DOMAIN}
      - EMAIL=${EMAIL}
    networks:
      - proxy
    depends_on:
      - vaultwarden

  backup:
    image: jmqm/vaultwarden_backup:latest
    container_name: vaultwarden_backup
    restart: unless-stopped
    volumes:
      - vw-data:/data:ro
      - ./backups:/backups
    environment:
      - DELETE_AFTER=30
      - CRON_TIME=0\ 3\ *\ *\ *
      - TZ=America/Denver
      - BACKUP_ADD_ATTACHMENTS=true
      - BACKUP_ADD_SENDS=true
      - BACKUP_ADD_CONFIG=true
      - BACKUP_ADD_RSA_KEY=true
    network_mode: none

networks:
  proxy:
    driver: bridge

volumes:
  vw-data:
    name: vaultwarden_data
  caddy-data:
    name: caddy_data
  caddy-certs:
    name: caddy_certs
```

- [ ] **Step 2: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker-compose with vaultwarden, caddy, backup"
```

---

## Task 2: Create Environment Template

**Files:**
- Create: `.env.example`

- [ ] **Step 1: Write .env.example**

```bash
# ===========================================
# REQUIRED - Replace with your values
# ===========================================

# Domain (your Bitwarden URL, e.g., https://bitwarden.peakscale.solutions)
DOMAIN=

# Email for Let's Encrypt notifications
EMAIL=

# Admin token (generate with: openssl rand -base64 48)
ADMIN_TOKEN=

# ===========================================
# SMTP Configuration (for email notifications)
# ===========================================
SMTP_HOST=
SMTP_FROM=
SMTP_PORT=
SMTP_SECURITY=starttls
SMTP_USERNAME=
SMTP_PASSWORD=

# ===========================================
# Optional: YubiKey 2FA
# ===========================================
# YUBICO_CLIENT_ID=
# YUBICO_SECRET_KEY=

# ===========================================
# Optional: Bitwarden Push Notifications
# ===========================================
# PUSH_ENABLED=true
# PUSH_INSTALLATION_ID=
# PUSH_INSTALLATION_KEY=

# ===========================================
# Logging
# ===========================================
LOG_LEVEL=info
```

- [ ] **Step 2: Create setup script**

Create: `setup.sh`

```bash
#!/bin/bash
set -euo pipefail

echo "=== Vaultwarden Setup ==="

# Create .env from example if it doesn't exist
if [ ! -f .env ]; then
    echo "Creating .env from template..."
    cp .env.example .env
    echo "Edit .env with your values before running docker compose up -d"
    exit 0
fi

echo "Loading environment..."
set -a
source .env
set +a

# Validate required vars
if [ -z "${DOMAIN:-}" ]; then
    echo "ERROR: DOMAIN is required"
    exit 1
fi

if [ -z "${ADMIN_TOKEN:-}" ]; then
    echo "Generating ADMIN_TOKEN..."
    export ADMIN_TOKEN=$(openssl rand -base64 48)
    echo "ADMIN_TOKEN=$ADMIN_TOKEN" >> .env
fi

echo "Starting services..."
docker compose up -d

echo "Done! Access ${DOMAIN}/admin for admin panel"
```

- [ ] **Step 3: Commit**

```bash
git add .env.example setup.sh
git commit -m "feat: add environment template and setup script"
```

---

## Task 3: Configure Caddy Reverse Proxy

**Files:**
- Create: `caddy/Caddyfile`

- [ ] **Step 1: Write Caddyfile**

```
{#DOMAIN} {
    log {
        level INFO
        output file /data/access.log {
            roll_size 10MB
            roll_keep 10
        }
    }

    # Enable websockets for real-time sync
    @websockets {
        header Connection *Upgrade*
        header Upgrade websocket
    }

    # Proxy to vaultwarden
    reverse_proxy /ws* vaultwarden:80 {
        # WebSocket support
        transport http {
            enable_websockets
        }
    }

    reverse_proxy vaultwarden:80

    # Optional: Security headers
    header {
        # X-Frame-Options "SAMEORIGIN"
        # X-Content-Type-Options "nosniff"
        # Referrer-Policy "strict-origin-when-cross-origin"
        # Content-Security-Policy "frame-ancestors 'self'"
        
        # Remove sensitive headers
        -Server
        -X-Powered-By
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add caddy/Caddyfile
git commit -m "feat: add caddy reverse proxy config"
```

---

## Task 4: Fail2ban Configuration (Host Level)

**Files:**
- Create: `fail2ban/jail.local`

- [ ] **Step 1: Write fail2ban config**

```ini
[DEFAULT]
bantime = 86400
findtime = 3600
maxretry = 5
banaction = iptables-allports
protocol = tcp

[vaultwarden]
enabled = true
filter = vaultwarden
action = iptables-allports[name=vaultwarden]
logpath = /var/lib/docker/volumes/vaultwarden_data/_data/vaultwarden.log
```

Create: `fail2ban/filter.d/vaultwarden.conf`

```ini
[Definition]
failregex = ^.*Username or password is incorrect.*client_ip: <HOST>
failregex = ^.*Too many requests.*client_ip: <HOST>
```

- [ ] **Step 2: Create installation script**

Create: `fail2ban/install.sh`

```bash
#!/bin/bash
# Run on host to install fail2ban for vaultwarden

# Install fail2ban
sudo apt update && sudo apt install fail2ban -y

# Copy config
sudo cp fail2ban/jail.local /etc/fail2ban/jail.d/local.local
sudo cp fail2ban/filter.d/vaultwarden.conf /etc/fail2ban/filter.d/

# Restart
sudo systemctl restart fail2ban

# Check status
sudo fail2ban-client status vaultwarden
```

- [ ] **Step 3: Commit**

```bash
git add fail2ban/jail.local fail2ban/filter.d/vaultwarden.conf fail2ban/install.sh
git commit -m "feat: add fail2ban config for brute-force protection"
```

---

## Task 5: Create README with Deployment and Recovery

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README**

```markdown
# Vaultwarden Self-Hosted

Production-grade self-hosted Bitwarden password manager.

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/YOUR_USERNAME/bitwarden.git
cd bitwarden

# 2. Setup environment
cp .env.example .env
nano .env  # Fill in required values

# 3. Start services
./setup.sh
```

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| vaultwarden | vaultwarden/server | Password vault |
| caddy | caddy:2 | HTTPS reverse proxy |
| backup | jmqm/vaultwarden_backup | Automated backups |

## Configuration

### Required Variables

- `DOMAIN` - Your Bitwarden URL (e.g., https://bitwarden.peakscale.solutions)
- `EMAIL` - Email for Let's Encrypt
- `ADMIN_TOKEN` - Admin panel access (generate with `openssl rand -base64 48`)

### Optional Variables

- SMTP settings for email notifications
- YubiKey for 2FA
- Push notifications

See `.env.example` for all options.

## Backup

Automatic backups run daily at 3 AM and are kept for 30 days.

Manual backup:
```bash
docker exec vaultwarden_backup manual
```

Restore:
```bash
# Stop vaultwarden
docker compose stop vaultwarden

# Extract backup
cd backups
tar -xJf vaultwarden-YYYYMMDD-HHMMSS.tar.xz -C /tmp

# Restore files to data volume
docker run --rm -v vaultwarden_data:/data -v /tmp/restore:/backup alpine \
  cp -r /backup/* /data/
```

## Security

- Fail2ban configured at host level (see `fail2ban/install.sh`)
- All traffic via HTTPS (Caddy with Let's Encrypt)
- Admin panel behind `ADMIN_TOKEN`
- No new user signups (`SIGNUPS_ALLOWED=false`)

## Updates

```bash
docker compose pull
docker compose up -d
docker image prune -f
```

## Recovery (from new server)

```bash
# 1. Clone repository
git clone https://github.com/YOUR_USERNAME/bitwarden.git

# 2. Setup environment
cp .env.example .env
# Edit .env with same values as before

# 3. Restore data from backup
# (see Backup section above)

# 4. Start services
./setup.sh
```

## Client Setup

| Device | Recommended Auth |
|--------|-----------------|
| Mac Desktop | Touch ID / Face ID |
| Firefox (Mac) | PIN unlock |
| Android | System autofill (fingerprint) |
| Android Firefox | Autofill or PIN |

## Ports

- 80, 443 - HTTP/HTTPS (Caddy)

## License

GPL-3.0
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with deployment and recovery steps"
```

---

## Task 6: GitHub Setup

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Write .gitignore**

```
# Environment
.env
.env.local

# Backups
backups/

# Logs
*.log

# Docker
.docker/

# OS
.DS_Store
Thumbs.db
```

- [ ] **Step 2: Create GitHub repo instructions**

Add to README or create separate `DEPLOY.md`:

```markdown
## GitHub Setup

1. Create repository on GitHub
2. Push local code:
   ```bash
   git remote add origin https://github.com/YOUR_USER/bitwarden.git
   git push -u origin main
   ```
3. Repository is ready for recovery deployment
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: add gitignore for secrets and backups"
```

---

## Execution Options

**Plan complete.**

**1. Subagent-Driven (recommended)** - Dispatch tasks to fresh subagents with review checkpoints.

**2. Inline Execution** - Execute tasks in this session.

**Which approach?**