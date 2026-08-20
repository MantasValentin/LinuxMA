#!/bin/bash
set -euo pipefail

# Rocky Linux 10.2

# Interface
NIC=ens34
LAN_IP_V4=10.0.0.54
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::54
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

# Temporary bootstrap networking before pulling this script to run it
# sudo ip link set "$NIC" up
# sudo ip addr add 10.0.0.250/24 dev "$NIC"
# sudo ip route add default via 10.0.0.1
# echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null

# Set hostname
sudo hostnamectl set-hostname "dns-rslv2.lab.internal"

# Update and upgrade
sudo dnf upgrade -y

# bind             - used here purely as a caching/forwarding resolver
# bind-utils       - dig / nslookup / named-checkconf
# nftables         - firewall
# openssh-server   - remote management
# git              - pulling config from your repo
# systemd-networkd - networking
sudo dnf install -y epel-release
sudo dnf install -y bind bind-utils nftables openssh-server git systemd-networkd

# Remove the temporary networking
sudo ip addr flush dev "$NIC"
sudo ip route flush dev "$NIC"

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

# Restart networking
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC"

# This box is the resolver, so it resolves through itself
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 127.0.0.1
nameserver ::1
EOT

# Top-level config just pulls in the split files below
sudo tee /etc/named.conf > /dev/null <<EOT
include "/etc/named/named.conf.options";
include "/etc/named/named.conf.local";
EOT

# Recurse and cache for the LAN, forward everything else to public resolvers
sudo mkdir -p /etc/named
sudo tee /etc/named/named.conf.options > /dev/null <<EOT
options {
    directory "/var/named";
    recursion yes;
    allow-recursion { localhost; 10.0.0.0/24; fd00:10::/64; };
    allow-query { localhost; 10.0.0.0/24; fd00:10::/64; };
    listen-on { any; };
    listen-on-v6 { any; };
    forwarders {
        8.8.8.8;
        1.1.1.1;
        2001:4860:4860::8888;
        2606:4700:4700::1111;
    };
    forward first;
    dnssec-validation auto;
    validate-except {
        lab.internal;
        0.0.10.in-addr.arpa;
        0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa;
    };
    version "not disclosed";
};
EOT

# lab.internal gets forwarded to the authoritative pair
sudo tee /etc/named/named.conf.local > /dev/null <<EOT
zone "lab.internal" {
    type forward;
    forward only;
    forwarders { 10.0.0.7; 10.0.0.8; fd00:10::7; fd00:10::8; };
};

zone "0.0.10.in-addr.arpa" {
    type forward;
    forward only;
    forwarders { 10.0.0.7; 10.0.0.8; fd00:10::7; fd00:10::8; };
};

zone "0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa" {
    type forward;
    forward only;
    forwarders { 10.0.0.7; 10.0.0.8; fd00:10::7; fd00:10::8; };
};
EOT

# Reset SELinux labels
sudo restorecon -Rv /etc/named

# Validate syntax before restarting
sudo named-checkconf
sudo systemctl enable named
sudo systemctl restart named

# Firewall config
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

        # DNS queries from the LAN only
        ip saddr 10.0.0.0/24 udp dport 53 accept
        ip saddr 10.0.0.0/24 tcp dport 53 accept
        ip6 saddr fd00:10::/64 udp dport 53 accept
        ip6 saddr fd00:10::/64 tcp dport 53 accept

        # For node exporter
        ip saddr 10.0.0.31 tcp dport 9100 accept
        ip6 saddr fd00::31 tcp dport 9100 accept
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