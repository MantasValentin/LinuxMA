#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

FQDN=ipa-2.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.6
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::6
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages ipa-server chrony nftables openssh-server git systemd-networkd
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

configure_chrony() {
    if write_file_if_changed /etc/chrony.conf 0644 root:root <<EOT
# Prefer the primary IPA server, fall back to public pool
server ipa-1.lab.internal iburst prefer
pool 2.rocky.pool.ntp.org iburst
pool 3.rocky.pool.ntp.org iburst

# Peer IPA server
peer ipa-1.lab.internal

# Serve time to the LAN
allow 10.0.0.0/24
allow fd00:10::/64

local stratum 10
makestep 1.0 3
driftfile /var/lib/chrony/drift
rtcsync
EOT
    then
        sudo systemctl enable chronyd --now
        sudo systemctl restart chronyd
    else
        sudo systemctl enable chronyd --now
    fi
}

# ipa-server-install fails outright if the server is already installed
configure_ipa_replica() {
    if [ ! -f /etc/ipa/default.conf ]; then
        sudo ipa-client-install \
            --domain=lab.internal \
            --realm=LAB.INTERNAL \
            --server=ipa-1.lab.internal \
            --hostname=ipa-2.lab.internal \
            --principal=admin \
            --password="$IPA_ADMIN_PASSWORD" \
            --no-ntp \
            --force-join \
            --unattended
    fi

    if ! sudo ipactl status &>/dev/null; then
        sudo ipa-replica-install \
            --setup-ca \
            --principal=admin \
            --admin-password="$IPA_ADMIN_PASSWORD" \
            --skip-mem-check \
            --unattended
    fi

    unset IPA_ADMIN_PASSWORD
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
    configure_firewall
    configure_chrony
    configure_ipa_replica
    configure_sshd
}

dispatch main "$@"