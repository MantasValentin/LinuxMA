#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

FQDN=dns-rslv-1.lab.internal

# TLS material issued by the IPA CA
TLS_CERT=/etc/pki/tls/certs/dns-rslv-1.pem
TLS_KEY=/etc/pki/tls/private/dns-rslv-1.key

# System CA bundle, used to validate the upstream forwarders
CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt

configure_packages() {
    ensure_packages ipa-client chrony
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
if [ -f /etc/pki/tls/certs/dns-rslv-1.pem ] && [ -f /etc/pki/tls/private/dns-rslv-1.key ]; then
    chown root:named /etc/pki/tls/certs/dns-rslv-1.pem /etc/pki/tls/private/dns-rslv-1.key
    chmod 644 /etc/pki/tls/certs/dns-rslv-1.pem
    chmod 640 /etc/pki/tls/private/dns-rslv-1.key
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

configure_named_dot() {
    local changed=0

    write_file_if_changed /etc/named/named.conf.options 0644 root:named <<EOT && changed=1
tls local-tls {
    cert-file "$TLS_CERT";
    key-file "$TLS_KEY";
    protocols { TLSv1.2; TLSv1.3; };
    ciphers "HIGH:!aNULL:!MD5:!3DES:!eNULL:!EXPORT";
    prefer-server-ciphers yes;
    session-tickets no;
};

tls cloudflare-tls {
    ca-file "$CA_BUNDLE";
    remote-hostname "cloudflare-dns.com";
    protocols { TLSv1.2; TLSv1.3; };
};

tls google-tls {
    ca-file "$CA_BUNDLE";
    remote-hostname "dns.google";
    protocols { TLSv1.2; TLSv1.3; };
};

options {
    directory "/var/named";
    recursion yes;
    allow-recursion { localhost; 10.0.0.0/24; fd00:10::/64; };
    allow-query-cache { localhost; 10.0.0.0/24; fd00:10::/64; };
    allow-query { localhost; 10.0.0.0/24; fd00:10::/64; };
    listen-on { any; };
    listen-on-v6 { any; };
    listen-on port 853 tls local-tls { any; };
    listen-on-v6 port 853 tls local-tls { any; };
    forwarders port 853 {
        1.1.1.1 tls cloudflare-tls;
        1.0.0.1 tls cloudflare-tls;
        2606:4700:4700::1111 tls cloudflare-tls;
        2606:4700:4700::1001 tls cloudflare-tls;
        8.8.8.8 tls google-tls;
        8.8.4.4 tls google-tls;
        2001:4860:4860::8888 tls google-tls;
        2001:4860:4860::8844 tls google-tls;
    };
    forward only;
    empty-zones-enable yes;
    dnssec-validation auto;
    version "not disclosed";
};
EOT

    sudo restorecon -Rv /etc/named

    if [ "$changed" -eq 1 ]; then
        sudo systemctl restart named
    fi
}

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

        # DNS-over-TLS from the LAN only
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
    configure_named_dot
    configure_firewall_dot
}

dispatch main "$@"