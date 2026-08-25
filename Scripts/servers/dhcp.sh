#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FQDN=dhcp.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.4
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::4
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1
LAN_PREFIX_NET_V6=fd00:10

# Temporary bootstrap networking before pulling this script to run it:
#   sudo ip link set "$NIC" up
#   sudo ip addr add 10.0.0.250/24 dev "$NIC"
#   sudo ip route add default via 10.0.0.1
#   echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server git nftables dnsmasq systemd-networkd
}

configure_network() {
    local is_using_networkmanager
    is_using_networkmanager=$(switch_to_systemd_networkd)
    switch_to_nftables

    if [ "$is_using_networkmanager" = "1" ]; then
        sudo ip addr flush dev "$NIC" 2>/dev/null || true
        sudo ip route flush dev "$NIC" 2>/dev/null || true
    fi

    apply_network_file /etc/systemd/network/10-lan.network "$NIC" <<EOT
[Match]
Name=$NIC

[Network]
Address=$LAN_IP_V4/$LAN_PREFIX_V4
Address=$LAN_IP_V6/$LAN_PREFIX_V6
Gateway=$GATEWAY_V4
Gateway=$GATEWAY_V6
IPv6AcceptRA=no
IPForward=no
EOT
}

configure_resolver() {
    apply_resolv_conf <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
nameserver fd00:10::53
nameserver fd00:10::54
EOT
}

configure_dnsmasq() {
    if write_file_if_changed /etc/dnsmasq.conf 0644 root:root <<EOT
# Bind to the LAN interface
interface=$NIC

# IPv4
# DHCP range
dhcp-range=10.0.0.100,10.0.0.200,255.255.255.0,24h

# DNS server handed to clients is dns-rslv
dhcp-option=6,10.0.0.53,10.0.0.54

# Default gateway handed to clients is the firewall
dhcp-option=3,$GATEWAY_V4

# IPv6
# DHCP range
dhcp-range=${LAN_PREFIX_NET_V6}::100,${LAN_PREFIX_NET_V6}::200,$LAN_PREFIX_V6,24h

# DNS server handed to clients is dns-rslv
dhcp-option=option6:23,fd00:10::53,fd00:10::54

# Disable dnsmasq's own DNS listener
port=0

# Logging
log-facility=-
EOT
    then
        sudo systemctl enable dnsmasq --now
        sudo systemctl restart dnsmasq
    else
        sudo systemctl enable dnsmasq --now
    fi
}

configure_firewall() {
    apply_nftables_ruleset <<EOT
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

        # DHCPv4 requests from the LAN
        udp dport 67 accept

        # DHCPv6 requests from the LAN
        udp dport 547 accept

        # For node exporter from analytics server 10.0.0.31 / fd00:10::31
        ip saddr 10.0.0.31/24 tcp dport 9100 accept
        ip6 saddr fd00:10::31/64 tcp dport 9100 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOT
}

configure_sshd() {
    sudo systemctl enable sshd --now
}

main() {
    configure_hostname
    configure_packages
    configure_network
    configure_resolver
    configure_dnsmasq
    configure_firewall
    configure_sshd
}

dispatch main "$@"
