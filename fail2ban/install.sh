#!/bin/bash
# Run as root on the deploy host from /opt/bitwarden: sudo ./fail2ban/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

dpkg -s fail2ban >/dev/null 2>&1 || { apt-get update && apt-get install -y fail2ban; }
rm -f /etc/fail2ban/jail.d/local.local   # old name used by earlier versions of this script
install -m 0644 fail2ban/jail.local /etc/fail2ban/jail.d/vaultwarden.local
install -m 0644 fail2ban/filter.d/vaultwarden.conf /etc/fail2ban/filter.d/
systemctl enable fail2ban
systemctl restart fail2ban

echo
echo "Verify -- do not assume:"
echo "  fail2ban-client status vaultwarden"
echo "  fail2ban-regex /var/lib/docker/volumes/vaultwarden_data/_data/vaultwarden.log /etc/fail2ban/filter.d/vaultwarden.conf"
echo "  fail2ban-client set vaultwarden banip 192.0.2.1 && iptables -S DOCKER-USER && fail2ban-client set vaultwarden unbanip 192.0.2.1"
