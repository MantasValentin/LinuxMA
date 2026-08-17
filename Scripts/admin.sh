#!/bin/bash
set -euo pipefail

# Interface
NIC=ens34
LAN_IP_V4=10.0.0.20
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10:0:0::20
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10:0:0::1

# Admin FQDN hostname
sudo hostnamectl set-hostname "admin.lab.internal"

# First update package lists and upgrade the machine
sudo apt update && sudo apt upgrade -y

# ansible          - automation utility
# nftables         - firewall
# openssh-server   - remote management
# git              - pulling config from your repo
sudo apt install -y openssh-server ansible git nftables

sudo systemctl disable --now NetworkManager
sudo systemctl mask NetworkManager
sudo systemctl enable systemd-networkd --now
sudo systemctl enable nftables --now
sudo systemctl enable ssh --now

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

sudo systemctl unmask systemd-networkd
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC"

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