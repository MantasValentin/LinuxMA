#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

read -r -s -p $'Postgres superuser password:\n' PG_SUPERUSER_PASSWORD
read -r -s -p $'Postgres replication password:\n' PG_REPL_PASSWORD

FQDN=db2.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.42
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1
PEER_IP_V4=10.0.0.41
WITNESS_IP_V4=10.0.0.43

LAN_IP_V6=fd00:10::42
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1
PEER_IP_V6=fd00:10::41
WITNESS_IP_V6=fd00:10::43

PG_VIP_V4=10.0.0.40
PG_VIP_PREFIX_V4=24
PG_VIP_V6=fd00:10::40
PG_VIP_PREFIX_V6=64

# Shared secret for keepalived VRRP auth
# identical between db_primary.sh and db_secondary.sh
VRRP_AUTH_PASS="PGVRRP_Secret"

# Patroni/etcd identity
NODE_NAME=db2
ETCD_NAME=etcd2
ETCD_VERSION=v3.7.0
ETCD_CLUSTER="etcd1=http://10.0.0.41:2380,etcd2=http://10.0.0.42:2380,etcd3=http://10.0.0.43:2380"

# PostgreSQL version
PG_VERSION=18

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server git nftables keepalived haproxy systemd-networkd python3-pip

    sudo dnf -qy module disable postgresql || true
    ensure_repo_rpm pgdg-redhat-repo "https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    ensure_packages "postgresql${PG_VERSION}-server"
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

configure_postgresql() {
    if [ ! -f /var/lib/pgsql/18/data/postgresql.conf ]; then
        sudo /usr/pgsql-18/bin/postgresql-18-setup initdb
        sudo systemctl enable --now postgresql-18
    else
        if ! sudo systemctl is-active --quiet postgresql-18; then
            sudo systemctl enable --now postgresql-18
        fi
    fi
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
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=pg-etcd-cluster
EOT

    write_file_if_changed /etc/systemd/system/etcd.service 0644 root:root <<EOT && changed=1
[Unit]
Description=etcd (Patroni DCS)
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

configure_patroni() {
    if [ ! -x /opt/patroni/venv/bin/patroni ]; then
        sudo python3 -m venv /opt/patroni/venv
        sudo /opt/patroni/venv/bin/pip install --upgrade pip
        sudo /opt/patroni/venv/bin/pip install "patroni[etcd3]" psycopg2-binary
    fi

    sudo useradd --system --shell /sbin/nologin postgres 2>/dev/null || true
    sudo mkdir -p "/var/lib/pgsql/${PG_VERSION}/data" /var/log/patroni
    sudo chown -R postgres:postgres /var/lib/pgsql /var/log/patroni

    sudo mkdir -p /etc/patroni
    local changed=0
    write_file_if_changed /etc/patroni/patroni.yml 0640 postgres:postgres <<EOT && changed=1
scope: pg-cluster
namespace: /db/
name: $NODE_NAME

restapi:
    listen: 0.0.0.0:8008
    connect_address: $LAN_IP_V4:8008

etcd3:
    hosts: 10.0.0.41:2379,10.0.0.42:2379,10.0.0.43:2379

bootstrap:
    dcs:
        ttl: 30
        loop_wait: 10
        retry_timeout: 10
        maximum_lag_on_failover: 1048576
        postgresql:
            use_pg_rewind: true
            parameters:
                wal_level: replica
                hot_standby: "on"
                max_wal_senders: 10
                max_replication_slots: 10
                wal_keep_size: 512MB

    initdb:
        - encoding: UTF8
        - data-checksums

    pg_hba:
        - host replication replicator 10.0.0.41/32 md5
        - host replication replicator 10.0.0.42/32 md5
        - host replication replicator fd00:10::41/128 md5
        - host replication replicator fd00:10::42/128 md5
        - host all all 10.0.0.0/24 md5
        - host all all fd00:10::/64 md5

postgresql:
    listen: 0.0.0.0:5432
    connect_address: $LAN_IP_V4:5432
    data_dir: /var/lib/pgsql/${PG_VERSION}/data
    bin_dir: /usr/pgsql-${PG_VERSION}/bin
    authentication:
        replication:
            username: replicator
            password: "$PG_REPL_PASSWORD"
        superuser:
            username: postgres
            password: "$PG_SUPERUSER_PASSWORD"
    parameters:
        unix_socket_directories: '/var/run/postgresql'

tags:
    nofailover: false
    noloadbalance: false
    clonefrom: false
    nosync: false
EOT

    write_file_if_changed /etc/systemd/system/patroni.service 0644 root:root <<EOT && changed=1
[Unit]
Description=Patroni (PostgreSQL HA)
After=etcd.service network-online.target
Wants=network-online.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/opt/patroni/venv/bin/patroni /etc/patroni/patroni.yml
KillMode=process
TimeoutSec=30
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOT

    sudo systemctl daemon-reload
    if ! sudo systemctl is-active --quiet patroni; then
        sudo systemctl enable --now patroni
    elif [ "$changed" -eq 1 ]; then
        # Passwords/topology changes need a real restart; Patroni also
        # supports `patronictl reload` for a subset of dynamic settings if
        # you want a lighter touch for those cases.
        sudo systemctl restart patroni
    fi
    sudo systemctl enable patroni
}

configure_haproxy() {
    if write_file_if_changed /etc/haproxy/haproxy.cfg 0644 root:root <<EOT
global
    maxconn 500
    log 127.0.0.1 local0

defaults
    mode tcp
    log global
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /
    stats refresh 5s

# Writes: only the current Patroni leader passes this check
listen pg_write
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server db1 10.0.0.41:5432 maxconn 100 check port 8008
    server db2 10.0.0.42:5432 maxconn 100 check port 8008

# Reads: any node that is up passes this check, so both share the load
listen pg_read
    bind *:5001
    balance roundrobin
    option httpchk GET /health
    http-check expect status 200
    default-server inter 3s fall 3 rise 2
    server db1 10.0.0.41:5432 maxconn 100 check port 8008
    server db2 10.0.0.42:5432 maxconn 100 check port 8008
EOT
    then
        sudo setsebool -P haproxy_connect_any=1 || true
        if sudo systemctl is-active --quiet haproxy; then
            sudo systemctl restart haproxy
        else
            sudo systemctl enable --now haproxy
        fi
    else
        sudo setsebool -P haproxy_connect_any=1 || true
        sudo systemctl enable --now haproxy
    fi
}

configure_keepalived() {
    if write_file_if_changed /etc/keepalived/keepalived.conf 0644 root:root <<EOT
global_defs {
    router_id DB_2
    script_user root
    enable_script_security
}

vrrp_script chk_haproxy {
    script "/usr/bin/pgrep haproxy"
    interval 2
    weight -60
    fall 2
    rise 2
}

vrrp_sync_group VG_DB {
    group {
        VI_DB_V4
        VI_DB_V6
    }
}

vrrp_instance VI_DB_V4 {
    state BACKUP
    interface $NIC
    virtual_router_id 110
    priority 100
    advert_int 1
    preempt_delay 3

    authentication {
        auth_type PASS
        auth_pass $VRRP_AUTH_PASS
    }

    virtual_ipaddress {
        $PG_VIP_V4/$PG_VIP_PREFIX_V4
    }

    track_script {
        chk_haproxy
    }
}

vrrp_instance VI_DB_V6 {
    state BACKUP
    interface $NIC
    virtual_router_id 111
    priority 100
    advert_int 1
    preempt_delay 3

    virtual_ipaddress {
        $PG_VIP_V6/$PG_VIP_PREFIX_V6
    }

    track_script {
        chk_haproxy
    }
}
EOT
    then
        if sudo systemctl is-active --quiet keepalived; then
            sudo systemctl restart keepalived
        else
            sudo systemctl enable --now keepalived
        fi
    else
        sudo systemctl enable --now keepalived
    fi
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

        # VRRP for the proxy VIP
        meta l4proto vrrp accept

        # SSH only from the management range
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 22 accept

        # Postgres - only the peer DB node talks directly on 5432 (replication + local haproxy)
        ip saddr { $LAN_IP_V4, $PEER_IP_V4 } tcp dport 5432 accept
        ip6 saddr { $LAN_IP_V6, $PEER_IP_V6 } tcp dport 5432 accept

        # Patroni REST API - peer node health checks
        ip saddr { $LAN_IP_V4, $PEER_IP_V4 } tcp dport 8008 accept
        ip6 saddr { $LAN_IP_V6, $PEER_IP_V6 } tcp dport 8008 accept

        # etcd peer + client traffic between the three etcd members
        ip saddr { $LAN_IP_V4, $PEER_IP_V4, $WITNESS_IP_V4 } tcp dport { 2379, 2380 } accept
        ip6 saddr { $LAN_IP_V6, $PEER_IP_V6, $WITNESS_IP_V6 } tcp dport { 2379, 2380 } accept

        # HAProxy read/write ports - open to the LAN (this is what apps connect to)
        ip saddr 10.0.0.0/24 tcp dport { 5000, 5001 } accept
        ip6 saddr fd00:10::/64 tcp dport { 5000, 5001 } accept

        # HAProxy stats - mgmt range only
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 7000 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 7000 accept

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
    configure_postgresql
    configure_etcd
    configure_patroni
    configure_haproxy
    configure_keepalived
    configure_firewall
    configure_sshd
}

dispatch main "$@"