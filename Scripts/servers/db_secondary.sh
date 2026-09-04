#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

read -r -s -p $'Postgres superuser password:\n' PG_SUPERUSER_PASSWORD
read -r -s -p $'Postgres replication password:\n' PG_REPL_PASSWORD
read -r -s -p $'DB backup encryption password:\n' DB_BACKUP_PASSWORD
read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

FQDN=db-2.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.44
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1
PEER_IP_V4=10.0.0.43

LAN_IP_V6=fd00:10::44
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1
PEER_IP_V6=fd00:10::43

DB_PROXY_1_IP_V4=10.0.0.41
DB_PROXY_1_IP_V6=fd00:10::41
DB_PROXY_2_IP_V4=10.0.0.42
DB_PROXY_2_IP_V6=fd00:10::42

# Patroni/etcd identity
NODE_NAME=db-2
ETCD_NAME=etcd4
ETCD_VERSION=v3.7.0
ETCD_CLUSTER="etcd1=https://10.0.0.41:2380,etcd2=https://10.0.0.42:2380,etcd3=https://10.0.0.43:2380,etcd4=https://10.0.0.44:2380"

# PostgreSQL version
PG_VERSION=18

# TLS material issued by the IPA CA
TLS_CERT=/etc/pki/tls/certs/db-node.pem
TLS_KEY=/etc/pki/tls/private/db-node.key
TLS_COMBINED=/etc/pki/tls/certs/db-node-combined.pem
TLS_CA=/etc/ipa/ca.crt

# pgBackRest backup is written to two independent repos for redundancy.
BACKUP_REPO_1_FQDN=db-backup-1.lab.internal
BACKUP_REPO_2_FQDN=db-backup-2.lab.internal

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server git nftables systemd-networkd python3-pip ipa-client chrony

    sudo dnf -qy module disable postgresql || true
    ensure_repo_rpm pgdg-redhat-repo "https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    ensure_packages "postgresql${PG_VERSION}-server" pgbackrest
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
    ipa service-add "db/$FQDN" --force || true
    kdestroy

    unset IPA_ADMIN_PASSWORD
}

configure_tls_cert() {
    sudo mkdir -p /etc/pki/tls/private /etc/pki/tls/certs
    sudo groupadd -f pgcerts

    write_file_if_changed /usr/local/bin/db-tls-renew-hook.sh 0755 root:root <<'EOT' || true
#!/bin/bash
set -uo pipefail
if [ -f /etc/pki/tls/certs/db-node.pem ] && [ -f /etc/pki/tls/private/db-node.key ]; then
    cat /etc/pki/tls/certs/db-node.pem /etc/pki/tls/private/db-node.key > /etc/pki/tls/certs/db-node-haproxy.pem
    chown root:pgcerts /etc/pki/tls/certs/db-node-haproxy.pem
    chmod 640 /etc/pki/tls/certs/db-node-haproxy.pem
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
            -K "db/$FQDN" \
            -U id-kp-serverAuth \
            -U id-kp-clientAuth \
            -g 4096 \
            -C "/usr/local/bin/db-tls-renew-hook.sh" \
            -w
    fi

    sudo chown root:pgcerts "$TLS_CERT" "$TLS_KEY"
    sudo chmod 644 "$TLS_CERT"
    sudo chmod 640 "$TLS_KEY"

    if [ ! -f "$TLS_COMBINED" ] || [ "$TLS_KEY" -nt "$TLS_COMBINED" ]; then
        sudo bash -c "cat '$TLS_CERT' '$TLS_KEY' > '$TLS_COMBINED'"
        sudo chown root:pgcerts "$TLS_COMBINED"
        sudo chmod 640 "$TLS_COMBINED"
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
    sudo usermod -aG pgcerts postgres
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
    certfile: $TLS_CERT
    keyfile: $TLS_KEY
    cafile: $TLS_CA

etcd3:
    hosts: 10.0.0.41:2379,10.0.0.42:2379,10.0.0.43:2379,10.0.0.44:2379
    protocol: https
    cacert: $TLS_CA
    cert: $TLS_CERT
    key: $TLS_KEY

bootstrap:
    dcs:
        synchronous_mode: true
        synchronous_mode_strict: false
        synchronous_node_count: 1
        maximum_lag_on_syncnode: 1048576 
        maximum_lag_on_failover: 1048576
        ttl: 30
        loop_wait: 10
        retry_timeout: 10
        postgresql:
            use_pg_rewind: true
            parameters:
                wal_level: replica
                hot_standby: "on"
                max_wal_senders: 10
                max_replication_slots: 10
                wal_keep_size: 512MB
                ssl: "on"
                ssl_cert_file: $TLS_CERT
                ssl_key_file: $TLS_KEY
                ssl_ca_file: $TLS_CA
                ssl_min_protocol_version: TLSv1.2

    initdb:
        - encoding: UTF8
        - data-checksums

    pg_hba:
        - hostssl replication replicator 10.0.0.41/32 scram-sha-256
        - hostssl replication replicator 10.0.0.42/32 scram-sha-256
        - hostssl replication replicator fd00:10::41/128 scram-sha-256
        - hostssl replication replicator fd00:10::42/128 scram-sha-256
        - hostssl all all 10.0.0.0/24 scram-sha-256
        - hostssl all all fd00:10::/64 scram-sha-256
        - hostnossl all all 0.0.0.0/0 reject
        - hostnossl all all ::/0 reject

postgresql:
    listen: 0.0.0.0:5432
    connect_address: $LAN_IP_V4:5432
    data_dir: /var/lib/pgsql/${PG_VERSION}/data
    bin_dir: /usr/pgsql-${PG_VERSION}/bin
    authentication:
        replication:
            username: replicator
            password: "$PG_REPL_PASSWORD"
            sslmode: verify-ca
            sslrootcert: $TLS_CA
        superuser:
            username: postgres
            password: "$PG_SUPERUSER_PASSWORD"
            sslmode: verify-ca
            sslrootcert: $TLS_CA
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
Description=Patroni
After=etcd.service network-online.target
Wants=network-online.target

[Service]
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
        sudo systemctl restart patroni
    fi
    sudo systemctl enable patroni
}

configure_pgbackrest() {
    sudo mkdir -p /var/log/pgbackrest
    sudo chown postgres:postgres /var/log/pgbackrest

    write_file_if_changed /etc/pgbackrest/pgbackrest.conf 0640 postgres:postgres <<EOT
[global]
repo1-host=$BACKUP_REPO_1_FQDN
repo1-host-type=tls
repo1-host-ca-file=$TLS_CA
repo1-host-cert-file=$TLS_CERT
repo1-host-key-file=$TLS_KEY
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=$DB_BACKUP_PASSWORD

repo2-host=$BACKUP_REPO_2_FQDN
repo2-host-type=tls
repo2-host-ca-file=$TLS_CA
repo2-host-cert-file=$TLS_CERT
repo2-host-key-file=$TLS_KEY
repo2-cipher-type=aes-256-cbc
repo2-cipher-pass=$DB_BACKUP_PASSWORD

log-path=/var/log/pgbackrest
process-max=2
compress-type=zst

[pg-cluster]
pg1-path=/var/lib/pgsql/${PG_VERSION}/data
pg1-port=5432
EOT

    # Patroni invokes archive_command when it is the primary.
    if sudo systemctl is-active --quiet patroni; then
        sudo -u postgres /opt/patroni/venv/bin/patronictl -c /etc/patroni/patroni.yml \
            edit-config --pg archive_mode=on \
            --pg archive_command='pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf archive-push %p' \
            --pg restore_command='pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf archive-get %f "%p"' \
            -y || true
    fi

    write_file_if_changed /usr/local/bin/pg_backup_if_primary.sh 0755 root:root <<EOT
#!/bin/bash
# Runs a pgBackRest backup only if node is currently the Patroni leader
set -euo pipefail
TYPE=\$1   # full or diff

if ! curl -fs --cacert $TLS_CA --resolve "$FQDN:8008:127.0.0.1" "https://$FQDN:8008/primary" > /dev/null 2>&1; then
    logger "pg_backup: not primary, skipping \${TYPE} backup"
    exit 0
fi

logger "pg_backup: starting \${TYPE} backup"
sudo -u postgres pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf \
    --type="\${TYPE}" backup
logger "pg_backup: \${TYPE} backup complete"
EOT

    write_file_if_changed /etc/cron.d/pgbackrest 0644 root:root <<EOT
0 1 * * 0 root /usr/local/bin/pg_backup_if_primary.sh full   >> /var/log/pgbackrest/cron.log 2>&1
0 1 * * 1-6 root /usr/local/bin/pg_backup_if_primary.sh diff >> /var/log/pgbackrest/cron.log 2>&1
EOT

    if sudo systemctl is-active --quiet patroni && \
        curl -fs --cacert "$TLS_CA" --resolve "$FQDN:8008:127.0.0.1" "https://$FQDN:8008/primary" >/dev/null 2>&1; then
        sudo -u postgres pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf \
            stanza-create 2>/dev/null || true
    fi

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

        # Postgres the peer and proxy
        ip saddr { $LAN_IP_V4, $PEER_IP_V4, $DB_PROXY_1_IP_V4, $DB_PROXY_2_IP_V4 } tcp dport 5432 accept
        ip6 saddr { $LAN_IP_V6, $PEER_IP_V6, $DB_PROXY_1_IP_V6, $DB_PROXY_2_IP_V6 } tcp dport 5432 accept

        # Patroni REST API
        ip saddr { $LAN_IP_V4, $PEER_IP_V4 } tcp dport 8008 accept
        ip6 saddr { $LAN_IP_V6, $PEER_IP_V6 } tcp dport 8008 accept

        # etcd peers
        ip saddr { $LAN_IP_V4, $PEER_IP_V4, $DB_PROXY_1_IP_V4, $DB_PROXY_2_IP_V4 } tcp dport { 2379, 2380 } accept
        ip6 saddr { $LAN_IP_V6, $PEER_IP_V6, $DB_PROXY_1_IP_V6, $DB_PROXY_2_IP_V6 } tcp dport { 2379, 2380 } accept

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
    configure_etcd
    configure_patroni
    configure_pgbackrest
    configure_firewall
    configure_sshd
}

dispatch main "$@"