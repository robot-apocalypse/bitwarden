#!/bin/bash
# Installs the host-side Vaultwarden updater (replaces Watchtower).
# Run as root on the deploy host: sudo ./systemd/install.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"

install -m 0755 "$SRC/vaultwarden-update.sh" /usr/local/bin/vaultwarden-update.sh
install -m 0644 "$SRC/vaultwarden-update.service" /etc/systemd/system/
install -m 0644 "$SRC/vaultwarden-update.timer" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now vaultwarden-update.timer

echo
echo "Installed. Verify -- do not assume:"
echo "  systemctl list-timers vaultwarden-update.timer"
echo "  systemctl start vaultwarden-update.service"
echo "  journalctl -u vaultwarden-update.service -n 50"
