#!/usr/bin/env bash
set -euo pipefail

# Check if the correct number of arguments is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <IPA_ADMIN_PASSWORD>"
    echo "Example: bash ipa_client_setup.sh password1"
    exit 1
fi

# Input Database Manager password and Admin password
IPA_ADMIN_PASSWORD=$1

# Derives the FQDN from this host's existing short hostname (dns1, dhcp, firewall, etc.)
HOSTNAME_SHORT=$(hostname -s)
FQDN="${HOSTNAME_SHORT}.lab.local"

sudo apt update
sudo apt install -y freeipa-client chrony

sudo tee /etc/chrony/chrony.conf > /dev/null <<EOT
# Upstream time sources
server 10.0.0.5 iburst prefer
server 10.0.0.6 iburst

# Step the clock on large offsets instead of just slewing, but only at startup
makestep 1.0 3

# Record drift for faster resync after reboot
driftfile /var/lib/chrony/drift
EOT

# chrony's service unit is "chronyd" on RHEL/Rocky, not "chrony"
sudo systemctl enable chrony --now
sudo systemctl restart chrony

getent hosts "$FQDN" || { echo "DNS lookup failed for $FQDN"; exit 1; }

sudo ipa-client-install \
    --domain=lab.local \
    --realm=LAB.LOCAL \
    --server=ipa1.lab.local \
    --server=ipa2.lab.local \
    --hostname="$FQDN" \
    --principal=admin \
    --password="$IPA_ADMIN_PASSWORD" \
    --mkhomedir \
    --force-join \
    --unattended