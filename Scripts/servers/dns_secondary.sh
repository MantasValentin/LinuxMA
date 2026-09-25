#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

FQDN=dns-2.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.8
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::8
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

# Temporary bootstrap networking before pulling this script to run it:
#   sudo ip link set "$NIC" up
#   sudo ip addr add 10.0.0.250/24 dev "$NIC"
#   sudo ip route add default via 10.0.0.1
#   echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null

check_tsig_key_present() {
    if [ ! -f /etc/named/tsig-xfer.key ]; then
        echo "ERROR: /etc/named/tsig-xfer.key not found."
        echo "Copy it from dns1 first, e.g.:"
        echo "scp /etc/named/tsig-xfer.key sysadmin@10.0.0.123:/home/sysadmin/tsig-xfer.key"
        echo "sudo mkdir -p /etc/named/"
        echo "sudo mv /home/sysadmin/tsig-xfer.key /etc/named/tsig-xfer.key"
        exit 1
    fi
}

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    sudo dnf copr enable -y isc/bind
    sudo dnf install -y isc-bind
    ensure_packages nftables openssh-server git systemd-networkd
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

configure_resolver() {
    apply_resolv_conf <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
nameserver fd00:10::53
nameserver fd00:10::54
EOT
}

configure_named_service() {
    sudo mkdir -p /etc/named /var/named
    chown -R root:named /etc/named /var/named
    chmod -R 770 /etc/named /var/named
    check_tsig_key_present
    sudo chown root:named /etc/named/tsig-xfer.key
    sudo chmod 0770 /etc/named/tsig-xfer.key

    local changed=0

    write_file_if_changed /etc/opt/isc/scls/isc-bind/named.conf 0770 root:named <<EOT && changed=1
include "/etc/named/named.conf.options";
include "/etc/named/named.conf.local";
EOT

    write_file_if_changed /etc/named/named.conf.options 0770 root:named <<EOT && changed=1
options {
    directory "/var/named";
    recursion no;
    allow-query { localhost; 10.0.0.0/24; fd00:10::/64; };
    allow-query-cache { none; };
    listen-on { any; };
    listen-on-v6 { any; };
    allow-transfer { none; };
    dnssec-validation auto;
    version "not disclosed";
};
EOT

    write_file_if_changed /etc/named/named.conf.local 0770 root:named <<EOT && changed=1
include "/etc/named/tsig-xfer.key";

zone "lab.internal" {
    type secondary;
    primaries { 10.0.0.7 key xfer-key; fd00:10::7 key xfer-key; };
    file "/var/named/db.lab.internal";
};

zone "0.0.10.in-addr.arpa" {
    type secondary;
    primaries { 10.0.0.7 key xfer-key; fd00:10::7 key xfer-key; };
    file "/var/named/db.10.0.0";
};

zone "0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa" {
    type secondary;
    primaries { 10.0.0.7 key xfer-key; fd00:10::7 key xfer-key; };
    file "/var/named/db.fd00.10";
};

server 10.0.0.7 {
    keys { xfer-key; };
};

server fd00:10::7 {
    keys { xfer-key; };
};
EOT

    sudo restorecon -Rv /etc/named /var/named

    if ! sudo systemctl is-active --quiet isc-bind-named; then
        sudo systemctl enable --now isc-bind-named
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart isc-bind-named
    fi
    sudo systemctl enable isc-bind-named
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
        ip saddr 10.0.0.31/32 tcp dport 9100 accept
        ip6 saddr fd00:10::31/128 tcp dport 9100 accept
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