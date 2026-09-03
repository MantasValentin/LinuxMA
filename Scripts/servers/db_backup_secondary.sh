#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

read -r -s -p $'DB backup encryption password:\n' DB_BACKUP_PASSWORD
read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

FQDN=db-backup-2.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.46
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::46
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

DB_1_IP_V4=10.0.0.43
DB_1_IP_V6=fd00:10::43
DB_2_IP_V4=10.0.0.44
DB_2_IP_V6=fd00:10::44
DB_1_FQDN=db-1.lab.internal
DB_2_FQDN=db-2.lab.internal

# TLS material issued by the IPA CA for this repo host
TLS_CERT=/etc/pki/tls/certs/db-backup-node.pem
TLS_KEY=/etc/pki/tls/private/db-backup-node.key
TLS_CA=/etc/ipa/ca.crt

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server git nftables systemd-networkd ipa-client chrony

    ensure_repo_rpm pgdg-redhat-repo "https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    ensure_packages pgbackrest
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

    kinit admin <<< "$IPA_ADMIN_PASSWORD"
    ipa service-add "pgbackrest/$FQDN" --force || true
    kdestroy

    unset IPA_ADMIN_PASSWORD
}

configure_tls_cert() {
    sudo mkdir -p /etc/pki/tls/private /etc/pki/tls/certs

    write_file_if_changed /usr/local/bin/pgbackrest-tls-renew-hook.sh 0755 root:root <<'EOT' || true
#!/bin/bash
# certmonger post-renewal hook: bounce pgbackrest so it picks up the
# renewed server certificate.
systemctl try-restart pgbackrest.service 2>/dev/null || true
EOT

    if ! sudo getcert list -f "$TLS_CERT" &>/dev/null; then
        sudo ipa-getcert request \
            -f "$TLS_CERT" \
            -k "$TLS_KEY" \
            -N "CN=$FQDN" \
            -D "$FQDN" \
            -K "pgbackrest/$FQDN" \
            -U id-kp-serverAuth \
            -T id-kp-serverAuth \
            -g 4096 \
            -C "/usr/local/bin/pgbackrest-tls-renew-hook.sh" \
            -w
    fi

    sudo useradd --system --shell /sbin/nologin postgres 2>/dev/null || true
    sudo chown root:postgres "$TLS_CERT" "$TLS_KEY"
    sudo chmod 644 "$TLS_CERT"
    sudo chmod 640 "$TLS_KEY"
}

configure_pgbackrest_repo() {
    sudo mkdir -p /var/lib/pgbackrest /var/log/pgbackrest
    sudo chown postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest
    sudo chmod 750 /var/lib/pgbackrest

    local changed=0
    write_file_if_changed /etc/pgbackrest/pgbackrest.conf 0640 postgres:postgres <<EOT && changed=1
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-retention-full-type=count
repo1-retention-diff=7
log-path=/var/log/pgbackrest
process-max=2
compress-type=zst

repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=$DB_BACKUP_PASSWORD

tls-server-address=*
tls-server-cert-file=$TLS_CERT
tls-server-key-file=$TLS_KEY
tls-server-ca-file=$TLS_CA
tls-server-auth=$DB_1_FQDN=pg-cluster
tls-server-auth=$DB_2_FQDN=pg-cluster
EOT

    write_file_if_changed /etc/systemd/system/pgbackrest.service 0644 root:root <<EOT && changed=1
[Unit]
Description=pgBackRest TLS repository server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=postgres
ExecStart=/usr/bin/pgbackrest server --daemon --config=/etc/pgbackrest/pgbackrest.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOT

    sudo systemctl daemon-reload
    if ! sudo systemctl is-active --quiet pgbackrest; then
        sudo systemctl enable --now pgbackrest
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart pgbackrest
    fi
    sudo systemctl enable pgbackrest

    unset DB_BACKUP_PASSWORD
}

configure_firewall() {
    apply_nftables_ruleset <<EOT
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        iifname "lo" accept
        ip protocol icmp accept
        meta l4proto ipv6-icmp accept

        # SSH only from the management range
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 22 accept

        # pgBackRest TLS repo access
        ip saddr { $DB_1_IP_V4, $DB_2_IP_V4 } tcp dport 8432 accept
        ip6 saddr { $DB_1_IP_V6, $DB_2_IP_V6 } tcp dport 8432 accept

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
    configure_chrony
    configure_ipa_join
    configure_tls_cert
    configure_pgbackrest_repo
    configure_firewall
    configure_sshd
}

dispatch main "$@"