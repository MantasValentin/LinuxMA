#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

FQDN=dns-rslv-2.lab.internal

# TLS material issued by the IPA CA
TLS_CERT=/etc/pki/tls/certs/dns-rslv-2.pem
TLS_KEY=/etc/pki/tls/private/dns-rslv-2.key

# Local loopback-only DoT-forwarding proxy (Unbound), fronting BIND's
# forwarders so the resolver->upstream leg is encrypted too.
UNBOUND_PORT=5335

configure_packages() {
    ensure_packages ipa-client chrony unbound policycoreutils-python-utils
}

configure_chrony() {
    if write_file_if_changed /etc/chrony.conf 0644 root:root <<EOT
server ipa-1.lab.internal iburst prefer
server ipa-2.lab.internal iburst

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

# ipa-client-install fails outright if already joined
configure_ipa_join() {
    if [ ! -f /etc/ipa/default.conf ]; then
        sudo ipa-client-install \
            --domain=lab.internal \
            --realm=LAB.INTERNAL \
            --server=ipa-1.lab.internal \
            --server=ipa-2.lab.internal \
            --hostname="$FQDN" \
            --principal=admin \
            --password="$IPA_ADMIN_PASSWORD" \
            --mkhomedir \
            --force-join \
            --unattended
    fi

    unset IPA_ADMIN_PASSWORD
}

configure_dot_cert() {
    sudo mkdir -p /etc/pki/tls/private /etc/pki/tls/certs

    write_file_if_changed /usr/local/bin/dns-tls-renew-hook.sh 0755 root:root <<'EOT' || true
#!/bin/bash
set -uo pipefail
if [ -f /etc/pki/tls/certs/dns-rslv-2.pem ] && [ -f /etc/pki/tls/private/dns-rslv-2.key ]; then
    chown root:named /etc/pki/tls/certs/dns-rslv-2.pem /etc/pki/tls/private/dns-rslv-2.key
    chmod 644 /etc/pki/tls/certs/dns-rslv-2.pem
    chmod 640 /etc/pki/tls/private/dns-rslv-2.key
fi
systemctl try-restart named.service 2>/dev/null || true
EOT

    if ! sudo getcert list -f "$TLS_CERT" &>/dev/null; then
        sudo ipa-getcert request \
            -f "$TLS_CERT" \
            -k "$TLS_KEY" \
            -N "CN=$FQDN" \
            -D "$FQDN" \
            -K "host/$FQDN" \
            -U id-kp-serverAuth \
            -g 2048 \
            -C "/usr/local/bin/dns-tls-renew-hook.sh" \
            -w
    fi

    sudo chown root:named "$TLS_CERT" "$TLS_KEY"
    sudo chmod 644 "$TLS_CERT"
    sudo chmod 640 "$TLS_KEY"
    sudo restorecon -Rv /etc/pki/tls/private /etc/pki/tls/certs
}

# Local, loopback-only DoT client proxy. named forwards to it in plaintext
# over loopback; it re-issues those queries as DNS-over-TLS to Cloudflare
# and Google, validating each provider's own certificate hostname.
configure_dot_forwarder() {
    if ! sudo semanage port -l 2>/dev/null | grep -qE "^dns_port_t\b.*\b${UNBOUND_PORT}\b"; then
        sudo semanage port -a -t dns_port_t -p tcp "$UNBOUND_PORT" 2>/dev/null || \
            sudo semanage port -m -t dns_port_t -p tcp "$UNBOUND_PORT" 2>/dev/null || true
        sudo semanage port -a -t dns_port_t -p udp "$UNBOUND_PORT" 2>/dev/null || \
            sudo semanage port -m -t dns_port_t -p udp "$UNBOUND_PORT" 2>/dev/null || true
    fi

    local changed=0
    write_file_if_changed /etc/unbound/unbound.conf 0644 root:root <<EOT && changed=1
server:
    interface: 127.0.0.1@$UNBOUND_PORT
    interface: ::1@$UNBOUND_PORT
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    access-control: 127.0.0.1/32 allow
    access-control: ::1/128 allow
    access-control: 0.0.0.0/0 refuse
    access-control: ::0/0 refuse

    # Pure forwarding relay only -- no local DNSSEC validation here.
    # named is the single validation point for this lab.
    module-config: "iterator"

    tls-cert-bundle: /etc/pki/tls/certs/ca-bundle.crt

    hide-identity: yes
    hide-version: yes
    num-threads: 1
    so-reuseport: yes

forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com
    forward-addr: 8.8.8.8@853#dns.google
    forward-addr: 8.8.4.4@853#dns.google
    forward-addr: 2001:4860:4860::8888@853#dns.google
    forward-addr: 2001:4860:4860::8844@853#dns.google
EOT

    if ! sudo systemctl is-active --quiet unbound; then
        sudo systemctl enable unbound --now
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart unbound
    fi
    sudo systemctl enable unbound
}

# Adds the port-853 client-facing listener and repoints named's forwarders
# at the local Unbound DoT proxy instead of talking to 8.8.8.8/1.1.1.1
# directly in plaintext.
configure_named_dot() {
    local changed=0

    write_file_if_changed /etc/named/named.conf.options 0644 root:named <<EOT && changed=1
tls dot-tls {
    cert-file "$TLS_CERT";
    key-file "$TLS_KEY";
    protocols { TLSv1.2; TLSv1.3; };
    ciphers "HIGH:!aNULL:!MD5:!3DES:!eNULL:!EXPORT";
    prefer-server-ciphers yes;
    session-tickets no;
};

options {
    directory "/var/named";
    recursion yes;
    allow-recursion { localhost; 10.0.0.0/24; fd00:10::/64; };
    allow-query-cache { localhost; 10.0.0.0/24; fd00:10::/64; };
    allow-query { localhost; 10.0.0.0/24; fd00:10::/64; };
    listen-on { any; };
    listen-on-v6 { any; };
    listen-on port 853 tls dot-tls { any; };
    listen-on-v6 port 853 tls dot-tls { any; };
    forwarders {
        127.0.0.1 port $UNBOUND_PORT;
        ::1 port $UNBOUND_PORT;
    };
    forward only;
    empty-zones-enable yes;
    dnssec-validation auto;
    version "not disclosed";
};
EOT

    sudo restorecon -Rv /etc/named
    sudo named-checkconf

    if [ "$changed" -eq 1 ]; then
        sudo systemctl restart named
    fi
}

# Adds the port-853 LAN rule to the existing ruleset. apply_nftables_ruleset
# replaces the whole ruleset, so this reproduces the same base rules as
# dns_resolver_secondary.sh plus the new DoT rule.
configure_firewall_dot() {
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

        # DNS-over-TLS (encrypted DNS) from the LAN only
        ip saddr 10.0.0.0/24 tcp dport 853 accept
        ip6 saddr fd00:10::/64 tcp dport 853 accept

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

main() {
    configure_packages
    configure_chrony
    configure_ipa_join
    configure_dot_cert
    configure_dot_forwarder
    configure_named_dot
    configure_firewall_dot
}

dispatch main "$@"