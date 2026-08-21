#!/bin/bash
set -euo pipefail

# Rocky Linux 10.2

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
LAN_IP_V4=10.0.0.6
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::6
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

# FreeIPA must have a real FQDN hostname
sudo hostnamectl set-hostname "ipa2.lab.internal"

# Update and upgrade
sudo dnf upgrade -y

# epel-release     - Extra Packages
# ipa-server       - the IPA stack
# chrony           - accurate time is mandatory for Kerberos
# nftables         - firewall
# openssh-server   - remote management
# git              - pulling config from your repo
# systemd-networkd - Networking
sudo dnf install -y epel-release
sudo dnf install -y ipa-server chrony nftables openssh-server git systemd-networkd

# replace NetworkManager with systemd-networkd
sudo systemctl disable --now NetworkManager
sudo systemctl mask NetworkManager
sudo systemctl unmask systemd-networkd
sudo systemctl enable systemd-networkd --now

# replace firewalld with nftables
sudo systemctl disable --now firewalld
sudo systemctl enable nftables --now

# LAN interface
sudo tee /etc/systemd/network/10-lan.network > /dev/null <<EOT
[Match]
Name=$NIC

[Network]
Address=$LAN_IP_V4/$LAN_PREFIX_V4
Address=$LAN_IP_V6/$LAN_PREFIX_V6
Gateway=$GATEWAY_V4
Gateway=$GATEWAY_V6
IPv6AcceptRA=no
EOT

# dns resolution goes to dns-rslv
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
nameserver fd00:10::53
nameserver fd00:10::54
EOT

# Restart networking
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC"

# NTP configuration
sudo tee /etc/chrony.conf > /dev/null <<EOT
# Prefer the primary IPA server, fall back to public pool
server ipa1.lab.internal iburst prefer
pool 2.rocky.pool.ntp.org iburst
pool 3.rocky.pool.ntp.org iburst

# Peer IPA server
peer ipa1.lab.internal

# Serve time to the LAN
allow 10.0.0.0/24
allow fd00:10::/64

local stratum 10
makestep 1.0 3
driftfile /var/lib/chrony/drift
rtcsync
EOT

sudo systemctl enable chronyd --now
sudo systemctl restart chronyd

# Join as a client first
sudo ipa-client-install \
    --domain=lab.internal \
    --realm=LAB.INTERNAL \
    --server=ipa1.lab.internal \
    --hostname=ipa2.lab.internal \
    --principal=admin \
    --password="$IPA_ADMIN_PASSWORD" \
    --no-ntp \
    --force-join \
    --unattended

# Promote to a full replica
sudo ipa-replica-install \
    --setup-ca \
    --principal=admin \
    --admin-password="$IPA_ADMIN_PASSWORD" \
    --unattended

# Firewall Config
sudo tee /etc/sysconfig/nftables.conf > /dev/null <<EOT
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Established/related connections
        ct state established,related accept

        # Loopback
        iifname "lo" accept

        # ICMPv4
        ip protocol icmp accept

        # ICMPv6
        meta l4proto ipv6-icmp accept

        # SSH only from the management range 10.0.0.20-29 / fd00:10::20-29
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 22 accept

        # Kerberos + kpasswd
        ip saddr 10.0.0.0/24 tcp dport { 88, 464 } accept
        ip saddr 10.0.0.0/24 udp dport { 88, 464 } accept
        ip6 saddr fd00:10::/64 tcp dport { 88, 464 } accept
        ip6 saddr fd00:10::/64 udp dport { 88, 464 } accept

        # LDAP/LDAPS
        ip saddr 10.0.0.0/24 tcp dport { 389, 636 } accept
        ip6 saddr fd00:10::/64 tcp dport { 389, 636 } accept

        # Web UI
        ip saddr 10.0.0.0/24 tcp dport { 80, 443 } accept
        ip6 saddr fd00:10::/64 tcp dport { 80, 443 } accept

        # NTP
        ip saddr 10.0.0.0/24 udp dport 123 accept
        ip6 saddr fd00:10::/64 udp dport 123 accept

        # Connection between IPA servers
        ip saddr 10.0.0.0/24 tcp dport 8888 accept
        ip6 saddr fd00:10::/64 tcp dport 8888 accept

        # For node exporter
        ip saddr 10.0.0.0/24 tcp dport 9100 accept
        ip6 saddr fd00:10::/64 tcp dport 9100 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOT

sudo nft -f /etc/sysconfig/nftables.conf
sudo nft list ruleset
sudo systemctl restart nftables

sudo systemctl enable sshd --now
sudo systemctl daemon-reload