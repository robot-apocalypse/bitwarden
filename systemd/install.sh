#!/bin/bash
# Installs the host-side Vaultwarden updater (replaces Watchtower) and the
# daily backup (replaces jmqm/vaultwarden_backup).
# Run as root on the deploy host: sudo ./systemd/install.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"

# The snap auto-refreshes, so the CLI cannot rot against the AWS API the way
# Watchtower rotted against Docker's.
[ -x /snap/bin/aws ] || snap install aws-cli --classic

for n in update backup; do
  install -m 0755 "$SRC/vaultwarden-$n.sh" /usr/local/bin/
  install -m 0644 "$SRC/vaultwarden-$n.service" "$SRC/vaultwarden-$n.timer" /etc/systemd/system/
done

systemctl daemon-reload
systemctl enable --now vaultwarden-update.timer vaultwarden-backup.timer

echo
echo "Installed. Verify -- do not assume:"
echo "  systemctl list-timers 'vaultwarden-*'"
echo "  systemctl start vaultwarden-backup.service"
echo "  journalctl -u vaultwarden-backup.service -n 20"
echo "  systemctl start vaultwarden-update.service"
echo "  journalctl -u vaultwarden-update.service -n 50"
