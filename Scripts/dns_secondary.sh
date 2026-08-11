#!/bin/bash
set -euo pipefail

# Interface
NIC=ens34
LAN_IP_V4=10.0.0.8
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::8
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

if [ ! -f /etc/bind/tsig-xfer.key ]; then
    echo "ERROR: /etc/bind/tsig-xfer.key not found."
    echo "Copy it from dns1 first, e.g.:"
    echo "  scp /etc/bind/tsig-xfer.key sysadmin@10.0.0.123:/home/sysadmin/tsig-xfer.key"
    echo "  sudo mkdir /etc/bind/"
    echo "  sudo mv /home/sysadmin/tsig-xfer.key /etc/bind/tsig-xfer.key"
    exit 1
fi

# Set hostname
sudo hostnamectl set-hostname "dns2"

# Update and upgrade
sudo apt update && sudo apt upgrade -y

# bind9           - the DNS server itself
# bind9utils      - named-checkconf / named-checkzone / rndc tools
# bind9-doc       - documentation
# dnsutils        - dig / nslookup for testing
# nftables        - firewall
# openssh-server  - remote management
# git             - pulling config from your repo
sudo apt install -y bind9 bind9utils bind9-doc dnsutils nftables openssh-server git

sudo systemctl enable nftables --now
sudo systemctl enable ssh --now

# Disable automatic dns resolution
sudo systemctl disable --now systemd-resolved

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

# Get rid of netplan configuration files
sudo rm -fr /etc/netplan/

# Restart networking
sudo systemctl unmask systemd-networkd systemd-networkd-wait-online
sudo systemctl enable systemd-networkd systemd-networkd-wait-online
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC"

# Need to make sure that TSIG key is copied to the secondary
# Lock access to the key
sudo chown root:bind /etc/bind/tsig-xfer.key
sudo chmod 640 /etc/bind/tsig-xfer.key

# Deploy the config
sudo tee /etc/bind/named.conf.options > /dev/null <<EOT
options {
    directory "/var/cache/bind";
    recursion no;
    allow-query { localhost; 10.0.0.0/24; fd00:10::/64; };
    listen-on { any; };
    listen-on-v6 { any; };
    allow-transfer { none; };
    dnssec-validation auto;
    version "not disclosed";
};
EOT

sudo tee /etc/bind/named.conf.local > /dev/null <<EOT
include "/etc/bind/tsig-xfer.key";

zone "lab.internal" {
    type secondary;
    primaries { 10.0.0.7 key xfer-key; fd00:10::7 key xfer-key; };
    file "/var/cache/bind/db.lab.internal";
};

zone "0.0.10.in-addr.arpa" {
    type secondary;
    primaries { 10.0.0.7 key xfer-key; fd00:10::7 key xfer-key; };
    file "/var/cache/bind/db.10.0.0";
};

zone "0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa" {
    type secondary;
    primaries { 10.0.0.7 key xfer-key; fd00:10::7 key xfer-key; };
    file "/var/cache/bind/db.fd00.10.0.0";
};

server 10.0.0.7 {
    keys { xfer-key; };
};

server fd00:10::7 {
    keys { xfer-key; };
};
EOT

# Validate syntax before restarting
sudo named-checkconf

sudo systemctl enable named
sudo systemctl restart named

# Firewall Config
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

        # DNS queries from the LAN only
        ip saddr 10.0.0.0/24 udp dport 53 accept
        ip saddr 10.0.0.0/24 tcp dport 53 accept
        ip6 saddr fd00:10::/64 udp dport 53 accept
        ip6 saddr fd00:10::/64 tcp dport 53 accept
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
sudo systemctl daemon-reload