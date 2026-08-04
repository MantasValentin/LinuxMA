#!/bin/bash
set -euo pipefail

# Interface
NIC=ens34
LAN_IP=10.0.0.4
LAN_SUBNET_MASK=24
GATEWAY=10.0.0.1

# Temporary bootstrap networking before pulling this script to run it
# sudo ip link set "$NIC" up
# sudo ip addr add 10.0.0.250/24 dev "$NIC"
# sudo ip route add default via 10.0.0.1
# echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null

# Set hostname
sudo hostnamectl set-hostname "dhcp"

# Update and upgrade
sudo apt update && sudo apt upgrade -y

# Install the neccecasy packages
# openssh-server  - remote management
# git             - pulling config from your repo
# nftables        - firewall
# dnsmasq         - DHCP server only
sudo apt install -y openssh-server git nftables dnsmasq

# Remove the temporary networking
sudo ip addr flush dev "$NIC"
sudo ip route flush dev "$NIC"

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

# Configure dnsmasq with DHCP only, DNS listener disabled (port=0)
sudo rm -f /etc/dnsmasq.conf
sudo tee /etc/dnsmasq.conf > /dev/null <<EOT
# Bind to the LAN interface
interface=$NIC

# DHCP range
dhcp-range=10.0.0.100,10.0.0.200,255.255.255.0,24h

# Default gateway handed to clients is the firewall
dhcp-option=3,$GATEWAY

# DNS server handed to clients is dns-rslv
dhcp-option=6,10.0.0.53,10.0.0.54

# Disable dnsmasq's own DNS listener - this box does DHCP only
port=0

# Logging
log-facility=-
EOT

sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

# Firewall input filtering only
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

        # DHCP requests from the LAN
        udp dport 67 accept
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