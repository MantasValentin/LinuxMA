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

sudo systemctl enable chrony --now

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
    --unattended