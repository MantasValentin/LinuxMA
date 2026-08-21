#!/usr/bin/env bash
set -euo pipefail

# Rocky Linux 10.2

read -r -s -p "IPA admin password: " IPA_ADMIN_PASSWORD

HOSTNAME_SHORT=$(hostname -s)
FQDN="${HOSTNAME_SHORT}.lab.internal"

sudo dnf upgrade -y

# epel-release - a couple of ipa-client's deps ship from EPEL, same as ipa-server
# ipa-client   - the RHEL/Rocky package name for the FreeIPA client (freeipa-client on Debian/Ubuntu)
# chrony       - accurate time is mandatory for Kerberos
sudo dnf install -y epel-release
sudo dnf install -y ipa-client chrony

# chrony config
sudo tee /etc/chrony.conf > /dev/null <<EOT
# Upstream time sources
server ipa1.lab.internal iburst prefer
server ipa2.lab.internal iburst

# Step the clock on large offsets instead of just slewing, but only at startup
makestep 1.0 3

# Record drift for faster resync after reboot
driftfile /var/lib/chrony/drift

rtcsync
EOT

sudo systemctl enable chronyd --now
sudo systemctl restart chronyd

getent hosts "$FQDN" || { echo "DNS lookup failed for $FQDN"; exit 1; }

sudo ipa-client-install \
    --domain=lab.internal \
    --realm=LAB.INTERNAL \
    --server=ipa1.lab.internal \
    --server=ipa2.lab.internal \
    --hostname="$FQDN" \
    --principal=admin \
    --password="$IPA_ADMIN_PASSWORD" \
    --mkhomedir \
    --force-join \
    --unattended

unset IPA_ADMIN_PASSWORD