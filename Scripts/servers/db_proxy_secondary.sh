#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

FQDN=db-proxy-2.lab.internal
VIP_FQDN=db.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.42
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1
PEER_IP_V4=10.0.0.41

LAN_IP_V6=fd00:10::42
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1
PEER_IP_V6=fd00:10::41

VIP_V4=10.0.0.40
VIP_PREFIX_V4=24
VIP_V6=fd00:10::40
VIP_PREFIX_V6=64

DB_1_IP_V4=10.0.0.43
DB_1_IP_V6=fd00:10::43
DB_2_IP_V4=10.0.0.44
DB_2_IP_V6=fd00:10::44

# Shared secret for keepalived VRRP auth
VRRP_AUTH_PASS="PGVRRP_Secret"

# etcd identity
ETCD_NAME=etcd2
ETCD_VERSION=v3.7.0
ETCD_CLUSTER="etcd1=https://10.0.0.41:2380,etcd2=https://10.0.0.42:2380,etcd3=https://10.0.0.43:2380,etcd4=https://10.0.0.44:2380"

# TLS material issued by the IPA CA
TLS_CERT=/etc/pki/tls/certs/db-node.pem
TLS_KEY=/etc/pki/tls/private/db-node.key
TLS_COMBINED=/etc/pki/tls/certs/db-node-combined.pem
TLS_CA=/etc/ipa/ca.crt

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server git nftables keepalived haproxy systemd-networkd ipa-client chrony conntrack-tools
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
    ipa host-add $VIP_FQDN --force || true
    ipa service-add "db/$FQDN" --force || true
    ipa service-add "db/$VIP_FQDN" --force || true
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
systemctl try-restart haproxy.service 2>/dev/null || true
EOT

    if ! sudo getcert list -f "$TLS_CERT" &>/dev/null; then
        sudo ipa-getcert request \
            -f "$TLS_CERT" \
            -k "$TLS_KEY" \
            -N "CN=$FQDN" \
            -D "$FQDN" \
            -D "$VIP_FQDN" \
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

configure_haproxy() {
    sudo usermod -aG pgcerts haproxy 2>/dev/null || true

    if write_file_if_changed /etc/haproxy/haproxy.cfg 0644 root:root <<EOT
global
    maxconn 500
    log 127.0.0.1 local0

defaults
    mode tcp
    log global
    retries 2
    timeout client 30m
    timeout connect 5s
    timeout server 30m
    timeout check 5s

listen stats
    mode http
    bind *:7000 ssl crt $TLS_COMBINED
    stats enable
    stats uri /
    stats refresh 5s

# Writes to only the current Patroni leader
listen pg_write
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions check-ssl verify required ca-file $TLS_CA
    server db-1 $DB_1_IP_V4:5432 maxconn 100 check port 8008
    server db-2 $DB_2_IP_V4:5432 maxconn 100 check port 8008

# Reads to any node that is up, so both share the load
listen pg_read
    bind *:5001
    balance roundrobin
    option httpchk GET /health
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 check-ssl verify required ca-file $TLS_CA
    server db-1 $DB_1_IP_V4:5432 maxconn 100 check port 8008
    server db-2 $DB_2_IP_V4:5432 maxconn 100 check port 8008
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

configure_conntrackd() {
    sudo modprobe nf_conntrack
    sudo modprobe nf_conntrack_netlink
    write_file_if_changed /etc/modules-load.d/conntrack.conf 0644 root:root <<EOT
nf_conntrack
nf_conntrack_netlink
EOT

    sudo sysctl -w net.netfilter.nf_conntrack_max=1048576 > /dev/null
    write_file_if_changed /etc/sysctl.d/99-conntrack.conf 0644 root:root <<EOT
net.netfilter.nf_conntrack_max = 1048576
EOT
    sudo sysctl -p /etc/sysctl.d/99-conntrack.conf > /dev/null

    local changed=0
    write_file_if_changed /etc/conntrackd/conntrackd.conf 0644 root:root <<EOT && changed=0
General {
    HashSize 131072
    HashLimit 1048576
    LogFile on
    Syslog on
    LockFile /var/lock/conntrackd.lock
    UNIX {
        Path /var/run/conntrackd.ctl
    }
    NetlinkBufferSize 2097152
    NetlinkBufferSizeMaxGrowth 8388608
    NetlinkOverrunResync on
    NetlinkEventsReliable off
    Filter From Userspace {
        Protocol Accept {
            UDP
            TCP
        }
        Address Ignore {
            IPv4_address 127.0.0.1
            IPv6_address ::1
        }
    }
}

Sync {
    Mode FTFW {
        DisableExternalCache off
        CommitTimeout 180
        PurgeTimeout 60
    }

    UDP Default {
        Port 3780
        Interface $NIC
        IPv4_address $LAN_IP_V4
        IPv4_Destination_Address $PEER_IP_V4
        SndSocketBuffer 1249280
        RcvSocketBuffer 1249280
        Checksum on
    }

    UDP {
        Port 3780
        Interface $NIC
        IPv6_address $LAN_IP_V6
        IPv6_Destination_Address $PEER_IP_V6
        SndSocketBuffer 1249280
        RcvSocketBuffer 1249280
        Checksum on
    }
}
EOT

    write_file_if_changed /etc/keepalived/notify.sh 0755 root:root <<'EOT'
#!/bin/sh
CONNTRACKD_BIN=/usr/sbin/conntrackd
CONNTRACKD_CONFIG=/etc/conntrackd/conntrackd.conf

case "$1" in
    master)
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -c
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -B
        logger "keepalived: entering MASTER, committed conntrack cache"
        ;;
    backup)
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -f
        logger "keepalived: entering BACKUP, flushed conntrack cache"
        ;;
    fault)
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -f
        logger "keepalived: entering FAULT, flushed conntrack cache"
        ;;
esac
EOT
    sudo restorecon -v /etc/keepalived/notify.sh > /dev/null

    sudo mkdir -p /etc/systemd/system/keepalived.service.d
    write_file_if_changed /etc/systemd/system/keepalived.service.d/override.conf 0644 root:root <<EOT || true
[Unit]
After=conntrackd.service
Wants=conntrackd.service
EOT

    sudo mkdir -p /etc/systemd/system/conntrackd.service.d
    write_file_if_changed /etc/systemd/system/conntrackd.service.d/priority.conf 0644 root:root <<EOT || true
[Service]
Nice=-10
EOT

    sudo systemctl daemon-reload

    if ! sudo systemctl is-active --quiet conntrackd; then
        sudo systemctl enable --now conntrackd
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart conntrackd
    fi
    sudo systemctl enable conntrackd
}

configure_keepalived() {
    if write_file_if_changed /etc/keepalived/keepalived.conf 0644 root:root <<EOT
global_defs {
    router_id DB_PROXY_2
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
        VIP_DB_V4
        VIP_DB_V6
    }

    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault  "/etc/keepalived/notify.sh fault"
}

vrrp_instance VIP_DB_V4 {
    state MASTER
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
        $VIP_V4/$VIP_PREFIX_V4
    }

    track_script {
        chk_haproxy
    }
}

vrrp_instance VIP_DB_V6 {
    state MASTER
    interface $NIC
    virtual_router_id 111
    priority 100
    advert_int 1
    preempt_delay 3

    virtual_ipaddress {
        $VIP_V6/$VIP_PREFIX_V6
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

        # etcd peers
        ip saddr { $LAN_IP_V4, $PEER_IP_V4, $DB_1_IP_V4, $DB_2_IP_V4 } tcp dport { 2379, 2380 } accept
        ip6 saddr { $LAN_IP_V6, $PEER_IP_V6, $DB_1_IP_V6, $DB_2_IP_V6 } tcp dport { 2379, 2380 } accept

        # HAProxy read/write ports
        ip saddr 10.0.0.0/24 tcp dport { 5000, 5001 } accept
        ip6 saddr fd00:10::/64 tcp dport { 5000, 5001 } accept

        # HAProxy stats only from the management range
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 7000 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 7000 accept

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
    configure_haproxy
    configure_conntrackd
    configure_keepalived
    configure_firewall
    configure_sshd
}

dispatch main "$@"