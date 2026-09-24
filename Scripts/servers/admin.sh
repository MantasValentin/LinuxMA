#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

FQDN=admin-1.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.20
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::20
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server ansible-core git nftables systemd-networkd systemd-resolved
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

# Bootstrap only: plain DNS to the resolvers so configure_dot_trust below
# can resolve ipa-1/2.lab.internal at all. This box gets a static IP (no
# DHCP-supplied resolv.conf), so without this there's no name resolution
# yet to even fetch the CA cert. configure_resolver() overwrites this
# with the DoT-enabled setup once the CA is trusted.
configure_resolver_bootstrap() {
    apply_resolv_conf <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
nameserver fd00:10::53
nameserver fd00:10::54
EOT
}

# CA cert used to validate the resolvers' DoT certificates. This is
# fetched from IPA's unauthenticated bootstrap endpoint, so this box can
# trust the CA WITHOUT joining the IPA realm (no ipa-client-install here).
DOT_CA_ANCHOR=/etc/pki/ca-trust/source/anchors/lab-internal-ca.pem

# Pulls the IPA CA cert so DNSOverTLS=yes (strict) can actually validate
# dns-rslv-1/2's certs, instead of either failing DNS entirely or
# silently skipping validation (see configure_resolver below for that
# opportunistic tradeoff, kept here in a comment for reference).
configure_dot_trust() {
    local tmp
    tmp=$(mktemp)
    if ! curl -fsS -o "$tmp" http://ipa-1.lab.internal/ipa/config/ca.crt; then
        curl -fsS -o "$tmp" http://ipa-2.lab.internal/ipa/config/ca.crt
    fi

    if write_file_if_changed "$DOT_CA_ANCHOR" 0644 root:root < "$tmp"; then
        sudo update-ca-trust extract
    fi
    rm -f "$tmp"
}

# DNS-over-TLS to the local resolvers via systemd-resolved. Plain
# /etc/resolv.conf (glibc's stub resolver) has no TLS support at all, so
# this box needs a local resolving daemon in front of it -- resolved is
# the natural pick since systemd-networkd is already in use here.
#
# DNSOverTLS=yes is the STRICT profile (RFC 7858): the cert from
# dns-rslv-1/2 must validate against configure_dot_trust's CA import
# above, or lookups through that server fail outright. That's what's
# configured below.
#
# Alternative: DNSOverTLS=opportunistic -- tries TLS, falls back to
# plaintext if it's unavailable, and even when TLS succeeds it does NOT
# authenticate the server at all (no hostname/chain check). Stops passive
# eavesdropping, doesn't stop an active on-path attacker (e.g. a rogue
# DHCP/ARP-spoofed box on this LAN segment pretending to be the
# resolver). If you want that instead, swap DNSOverTLS below to
# "opportunistic" and configure_dot_trust becomes unnecessary.
configure_resolver() {
    sudo systemctl unmask systemd-resolved
    sudo systemctl enable systemd-resolved --now

    if write_file_if_changed /etc/systemd/resolved.conf 0644 root:root <<EOT
[Resolve]
DNS=10.0.0.53#dns-rslv-1.lab.internal 10.0.0.54#dns-rslv-2.lab.internal
DNSOverTLS=yes
EOT
    then
        sudo systemctl restart systemd-resolved
    fi

    sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
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
    configure_resolver_bootstrap
    configure_dot_trust
    configure_resolver
    configure_firewall
    configure_sshd
}

dispatch main "$@"