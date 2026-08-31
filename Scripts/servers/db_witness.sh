#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

FQDN=db-witness.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.43
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::43
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

ETCD_NAME=etcd3
ETCD_VERSION=v3.7.0
ETCD_CLUSTER="etcd1=https://10.0.0.41:2380,etcd2=https://10.0.0.42:2380,etcd3=https://10.0.0.43:2380"

# TLS material issued by the IPA CA
TLS_CERT=/etc/pki/tls/certs/db-node.pem
TLS_KEY=/etc/pki/tls/private/db-node.key
TLS_CA=/etc/ipa/ca.crt

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server git nftables systemd-networkd ipa-client chrony
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
    ipa service-add "etcd/$FQDN" --force || true
    kdestroy

    unset IPA_ADMIN_PASSWORD
}

configure_tls_cert() {
    sudo mkdir -p /etc/pki/tls/private /etc/pki/tls/certs
    sudo groupadd -f pgcerts

    write_file_if_changed /usr/local/bin/db-tls-renew-hook.sh 0755 root:root <<'EOT' || true
#!/bin/bash
# certmonger post-renewal hook. Rebuilds the HAProxy combined PEM (if
# HAProxy is installed on this node) and restarts every service that
# holds the cert/key open. Services that don't exist here are silently
# skipped.
set -uo pipefail
if [ -f /etc/pki/tls/certs/db-node.pem ] && [ -f /etc/pki/tls/private/db-node.key ]; then
    cat /etc/pki/tls/certs/db-node.pem /etc/pki/tls/private/db-node.key > /etc/pki/tls/certs/db-node-haproxy.pem 2>/dev/null || true
    chown root:pgcerts /etc/pki/tls/certs/db-node-haproxy.pem 2>/dev/null || true
    chmod 640 /etc/pki/tls/certs/db-node-haproxy.pem 2>/dev/null || true
fi
systemctl try-restart etcd.service 2>/dev/null || true
systemctl try-restart patroni.service 2>/dev/null || true
systemctl try-restart haproxy.service 2>/dev/null || true
EOT

    if ! sudo getcert list -f "$TLS_CERT" &>/dev/null; then
        sudo ipa-getcert request \
            -f "$TLS_CERT" \
            -k "$TLS_KEY" \
            -N "CN=$FQDN" \
            -D "$FQDN" \
            -K "etcd/$FQDN" \
            -U id-kp-serverAuth \
            -U id-kp-clientAuth \
            -T id-kp-serverAuth \
            -T id-kp-clientAuth \
            -g 4096 \
            -C "/usr/local/bin/db-tls-renew-hook.sh" \
            -w
    fi

    sudo chown root:pgcerts "$TLS_CERT" "$TLS_KEY"
    sudo chmod 644 "$TLS_CERT"
    sudo chmod 640 "$TLS_KEY"
}

configure_etcd() {
    if [ ! -x /opt/etcd/etcd ]; then
        download_once \
            "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" \
            "/tmp/etcd-${ETCD_VERSION}.tar.gz"
        sudo mkdir -p /opt/etcd
        sudo tar -xzf "/tmp/etcd-${ETCD_VERSION}.tar.gz" -C /opt/etcd --strip-components=1
        sudo ln -sf /opt/etcd/etcd /usr/local/bin/etcd
        sudo ln -sf /opt/etcd/etcdctl /usr/local/bin/etcdctl
    fi

    sudo useradd --system --no-create-home --shell /sbin/nologin etcd 2>/dev/null || true
    sudo usermod -aG pgcerts etcd
    sudo mkdir -p /var/lib/etcd
    sudo chown etcd:etcd /var/lib/etcd

    sudo mkdir -p /etc/etcd
    local changed=0
    write_file_if_changed /etc/etcd/etcd.conf 0640 root:etcd <<EOT && changed=1
ETCD_NAME=$ETCD_NAME
ETCD_DATA_DIR=/var/lib/etcd
ETCD_LISTEN_PEER_URLS=https://$LAN_IP_V4:2380
ETCD_LISTEN_CLIENT_URLS=https://$LAN_IP_V4:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://$LAN_IP_V4:2380
ETCD_ADVERTISE_CLIENT_URLS=https://$LAN_IP_V4:2379
ETCD_INITIAL_CLUSTER=$ETCD_CLUSTER
ETCD_INITIAL_CLUSTER_STATE=existing
ETCD_INITIAL_CLUSTER_TOKEN=pg-etcd-cluster

ETCD_CERT_FILE=$TLS_CERT
ETCD_KEY_FILE=$TLS_KEY
ETCD_TRUSTED_CA_FILE=$TLS_CA
ETCD_CLIENT_CERT_AUTH=true

ETCD_PEER_CERT_FILE=$TLS_CERT
ETCD_PEER_KEY_FILE=$TLS_KEY
ETCD_PEER_TRUSTED_CA_FILE=$TLS_CA
ETCD_PEER_CLIENT_CERT_AUTH=true
EOT

    write_file_if_changed /etc/systemd/system/etcd.service 0644 root:root <<EOT && changed=1
[Unit]
Description=etcd
After=network-online.target
Wants=network-online.target

[Service]
User=etcd
Type=notify
EnvironmentFile=/etc/etcd/etcd.conf
ExecStart=/usr/local/bin/etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOT

    sudo systemctl daemon-reload
    if ! sudo systemctl is-active --quiet etcd; then
        sudo systemctl enable --now etcd
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart etcd
    fi
    sudo systemctl enable etcd
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

        # etcd peer + client traffic from db1/db2 only
        ip saddr { 10.0.0.41, 10.0.0.42 } tcp dport { 2379, 2380 } accept

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
    configure_chrony
    configure_ipa_join
    configure_tls_cert
    configure_etcd
    configure_firewall
    configure_sshd
}

dispatch main "$@"