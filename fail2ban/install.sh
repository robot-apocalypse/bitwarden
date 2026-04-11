#!/bin/bash
sudo apt update && sudo apt install fail2ban -y
sudo cp fail2ban/jail.local /etc/fail2ban/jail.d/local.local
sudo cp fail2ban/filter.d/vaultwarden.conf /etc/fail2ban/filter.d/
sudo systemctl restart fail2ban
sudo fail2ban-client status vaultwarden || echo "Fail2ban installed. Check config."