#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FQDN=dns-rslv1.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.53
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::53
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

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
    ensure_packages bind bind-utils nftables openssh-server git systemd-networkd
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
EOT
}

# This box is the resolver, so it resolves through itself.
configure_resolver() {
    apply_resolv_conf <<EOT
nameserver 127.0.0.1
nameserver ::1
EOT
}

configure_named_service() {
    local changed=0

    write_file_if_changed /etc/named.conf 0644 root:named <<EOT && changed=1
include "/etc/named/named.conf.options";
include "/etc/named/named.conf.local";
EOT

    sudo mkdir -p /etc/named
    write_file_if_changed /etc/named/named.conf.options 0644 root:named <<EOT && changed=1
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

    write_file_if_changed /etc/named/named.conf.local 0644 root:named <<EOT && changed=1
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

    sudo restorecon -Rv /etc/named
    sudo named-checkconf

    if ! sudo systemctl is-active --quiet named; then
        sudo systemctl enable named --now
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart named
    fi
    sudo systemctl enable named
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

        # DNS queries from the LAN only
        ip saddr 10.0.0.0/24 udp dport 53 accept
        ip saddr 10.0.0.0/24 tcp dport 53 accept
        ip6 saddr fd00:10::/64 udp dport 53 accept
        ip6 saddr fd00:10::/64 tcp dport 53 accept

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
    configure_named_service
    configure_firewall
    configure_sshd
}

dispatch main "$@"
