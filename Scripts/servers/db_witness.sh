#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

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
ETCD_CLUSTER="etcd1=http://10.0.0.41:2380,etcd2=http://10.0.0.42:2380,etcd3=http://10.0.0.43:2380"

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server git nftables systemd-networkd
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
    sudo mkdir -p /var/lib/etcd
    sudo chown etcd:etcd /var/lib/etcd

    sudo mkdir -p /etc/etcd
    local changed=0
    write_file_if_changed /etc/etcd/etcd.conf 0640 root:etcd <<EOT && changed=1
ETCD_NAME=$ETCD_NAME
ETCD_DATA_DIR=/var/lib/etcd
ETCD_LISTEN_PEER_URLS=http://$LAN_IP_V4:2380
ETCD_LISTEN_CLIENT_URLS=http://$LAN_IP_V4:2379,http://127.0.0.1:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=http://$LAN_IP_V4:2380
ETCD_ADVERTISE_CLIENT_URLS=http://$LAN_IP_V4:2379
ETCD_INITIAL_CLUSTER=$ETCD_CLUSTER
ETCD_INITIAL_CLUSTER_STATE=existing
ETCD_INITIAL_CLUSTER_TOKEN=pg-etcd-cluster
EOT

    write_file_if_changed /etc/systemd/system/etcd.service 0644 root:root <<EOT && changed=1
[Unit]
Description=etcd (Patroni DCS witness)
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
    configure_etcd
    configure_firewall
    configure_sshd
}

dispatch main "$@"
