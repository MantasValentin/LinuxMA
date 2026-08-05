#!/bin/bash
set -euo pipefail

# Check if the correct number of arguments is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <IPA_ADMIN_PASSWORD>"
    echo "Example: bash ipa_secondary.sh password1"
    exit 1
fi

# Input Admin password
IPA_ADMIN_PASSWORD=$1

# Interface
NIC=ens34
LAN_IP=10.0.0.6
LAN_SUBNET_MASK=24
GATEWAY=10.0.0.1

# FreeIPA must have a real FQDN hostname
sudo hostnamectl set-hostname "ipa2.lab.local"

# Update and upgrade
sudo apt update && sudo apt upgrade -y

# freeipa-server   - the IPA stack
# chrony           - accurate time is mandatory for Kerberos
# nftables         - firewall
# openssh-server   - remote management
# git              - pulling config from your repo
sudo apt install -y freeipa-server chrony nftables openssh-server git

# Disable automatic dns resolution
sudo systemctl disable --now systemd-resolved

sudo systemctl enable nftables --now
sudo systemctl enable ssh --now

# LAN interface
sudo tee /etc/systemd/network/10-lan.network > /dev/null <<EOT
[Match]
Name=$NIC

[Network]
Address=$LAN_IP/$LAN_SUBNET_MASK
Gateway=$GATEWAY
EOT

# dns resolution goes to dns-rslv
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
EOT

# Get rid of netplan configuration files
sudo rm -fr /etc/netplan/

# Restart networking
sudo systemctl unmask systemd-networkd systemd-networkd-wait-online
sudo systemctl enable systemd-networkd systemd-networkd-wait-online
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC"

# NTP configuration
sudo tee /etc/chrony/chrony.conf > /dev/null <<EOT
# Prefer the primary IPA server, fall back to public pool
server 10.0.0.5 iburst prefer
pool ntp.ubuntu.com iburst

# Serve time to the LAN
allow 10.0.0.0/24

local stratum 10
makestep 1.0 3
driftfile /var/lib/chrony/chrony.drift
EOT

sudo systemctl enable chrony --now
sudo systemctl restart chrony

# Join as a client first
sudo ipa-client-install \
    --domain=lab.local \
    --realm=LAB.LOCAL \
    --server=ipa1.lab.local \
    --hostname=ipa2.lab.local \
    --principal=admin \
    --password="$IPA_ADMIN_PASSWORD" \
    --no-ntp \
    --unattended

# Promote to a full replica
sudo ipa-replica-install \
    --setup-ca \
    --principal=admin \
    --admin-password="$IPA_ADMIN_PASSWORD" \
    --unattended

sudo tee /etc/nftables.conf > /dev/null <<EOT
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Established/related connections
        ct state established,related accept

        # Loopback
        iifname "lo" accept

        # ICMP
        ip protocol icmp accept

        # SSH only from the management range 10.0.0.20-29
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 accept

        # Kerberos + kpasswd, from the LAN
        ip saddr 10.0.0.0/24 tcp dport { 88, 464 } accept
        ip saddr 10.0.0.0/24 udp dport { 88, 464 } accept

        # LDAP/LDAPS, from the LAN
        ip saddr 10.0.0.0/24 tcp dport { 389, 636 } accept

        # Web UI / cert enrollment, from the LAN
        ip saddr 10.0.0.0/24 tcp dport { 80, 443 } accept

        # NTP (chrony) from the LAN
        ip saddr 10.0.0.0/24 udp dport 123 accept

        # Replica install / custodia secret transfer, IPA peer only
        ip saddr 10.0.0.5 tcp dport 8888 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOT

sudo nft -f /etc/nftables.conf
sudo nft list ruleset
sudo systemctl restart nftables