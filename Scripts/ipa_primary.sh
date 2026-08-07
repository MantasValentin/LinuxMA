#!/bin/bash
set -euo pipefail

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <IPA_ADMIN_PASSWORD> <IPA_DM_PASSWORD>"
    echo "Example: bash ipa_primary.sh password1 password2"
    exit 1
fi

# Input Database Manager password and Admin password
IPA_ADMIN_PASSWORD=$1
IPA_DM_PASSWORD=$2

# Interface
NIC=ens34
LAN_IP_V4=10.0.0.5
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10:0:0::5
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10:0:0::1

# FreeIPA must have a real FQDN hostname
sudo hostnamectl set-hostname "ipa1.lab.local"

# Update and upgrade
sudo dnf upgrade -y

# epel-release     - Extra Packages
sudo dnf install -y epel-release
# ipa-server       - the IPA stack (this is the RHEL/Rocky package name;
#                    upstream FreeIPA calls it freeipa-server on Debian/Ubuntu)
# chrony           - accurate time is mandatory for Kerberos
# nftables         - firewall
# openssh-server   - remote management
# git              - pulling config from your repo
# systemd-networkd - Networking
sudo dnf install -y ipa-server chrony nftables openssh-server git systemd-networkd

# Rocky uses NetworkManager (not systemd-resolved) to own DNS/interfaces by
# default - disable and mask it, systemd-networkd takes over below, same
# role netplan removal plays on the Ubuntu box.
sudo systemctl disable --now NetworkManager
sudo systemctl mask NetworkManager
sudo systemctl enable systemd-networkd --now
sudo systemctl enable nftables --now

# ssh service unit is named "sshd" on RHEL/Rocky, not "ssh"
sudo systemctl enable sshd --now

# Rocky ships firewalld active out of the box - we're standardizing on
# nftables instead, so it needs to go
sudo systemctl disable --now firewalld

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

# Restart networking (systemd-networkd ships as part of the base systemd
# package on Rocky too, just disabled by default - same units as Ubuntu)
sudo systemctl unmask systemd-networkd
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC"

# NTP configuration
# Note: Rocky's chrony config lives at /etc/chrony.conf, not /etc/chrony/chrony.conf
sudo tee /etc/chrony.conf > /dev/null <<EOT
# Upstream time sources
pool 2.rocky.pool.ntp.org iburst

# Serve time to the LAN
allow 10.0.0.0/24
allow fd00:10::/64

# Act as a fallback stratum source if upstream is unreachable
# (keeps LAN clients roughly in sync with each other even if internet drops)
local stratum 10

# Step the clock on large offsets instead of just slewing, but only at startup
makestep 1.0 3

# Record drift for faster resync after reboot
driftfile /var/lib/chrony/drift
EOT

# chrony's service unit is "chronyd" on RHEL/Rocky, not "chrony"
sudo systemctl enable chronyd --now
sudo systemctl restart chronyd

# IPA server install (ipa-server-install itself is identical across distros -
# only the package name that ships the binary differs
sudo ipa-server-install \
    --realm=LAB.LOCAL \
    --domain=lab.local \
    --hostname=ipa1.lab.local \
    --ip-address="$LAN_IP_V4" \
    --ip-address="$LAN_IP_V6" \
    --ds-password="$IPA_DM_PASSWORD" \
    --admin-password="$IPA_ADMIN_PASSWORD" \
    --no-host-dns \
    --no-ntp \
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