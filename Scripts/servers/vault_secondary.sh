#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

FQDN=vault-2.lab.internal
PEER_FQDN=vault-1.lab.internal
VIP_FQDN=vault.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.11
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1
PEER_IP_V4=10.0.0.10

LAN_IP_V6=fd00:10::11
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1
PEER_IP_V6=fd00:10::10

VAULT_VIP_V4=10.0.0.9
VAULT_VIP_PREFIX_V4=24
VAULT_VIP_V6=fd00:10::9
VAULT_VIP_PREFIX_V6=64

# Shared secret for keepalived VRRP auth
# identical between vault_primary.sh and vault_secondary.sh
VRRP_AUTH_PASS="VaultVRRP_Secret"

NODE_ID="vault-2"

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages chrony nftables keepalived haproxy openssh-server git systemd-networkd dnf-plugins-core
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
server ipa1.lab.internal iburst prefer
server ipa2.lab.internal iburst

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

# ipa-client-install fails outright if already joined, so guard it.
configure_ipa_join() {
    if [ ! -f /etc/ipa/default.conf ]; then
        sudo ipa-client-install \
            --domain=lab.internal \
            --realm=LAB.INTERNAL \
            --server=ipa1.lab.internal \
            --server=ipa2.lab.internal \
            --hostname="$FQDN" \
            --principal=admin \
            --password="$IPA_ADMIN_PASSWORD" \
            --mkhomedir \
            --force-join \
            --unattended
    fi

    kinit admin <<< "$IPA_ADMIN_PASSWORD"
    ipa service-add "vault/$FQDN" --force || true

    kdestroy
    unset IPA_ADMIN_PASSWORD
}

configure_vault_package() {
    sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
    ensure_packages vault
}

configure_tls_cert() {
    sudo mkdir -p /etc/vault.d/tls
    sudo mkdir -p /opt/vault/data
    sudo chown -R vault:vault /opt/vault
    sudo chmod 750 /opt/vault/data

    if ! sudo getcert list -f /etc/vault.d/tls/vault.crt &>/dev/null; then
        sudo ipa-getcert request \
            -f /etc/vault.d/tls/vault.crt \
            -k /etc/vault.d/tls/vault.key \
            -N "CN=$FQDN" \
            -D "$FQDN" \
            -K "vault/$FQDN" \
            -U id-kp-serverAuth \
            -T id-kp-serverAuth \
            -g 4096 \
            -C "/usr/bin/systemctl kill -s HUP vault" \
            -w
    fi

    sudo chown vault:vault /etc/vault.d/tls/vault.crt /etc/vault.d/tls/vault.key
    sudo chmod 644 /etc/vault.d/tls/vault.crt
    sudo chmod 600 /etc/vault.d/tls/vault.key
}

configure_vault_service() {
    local changed=0
    write_file_if_changed /etc/vault.d/vault.hcl 0640 vault:vault <<EOT && changed=1
ui           = true
disable_mlock = false
api_addr     = "https://$FQDN:8200"
cluster_addr = "https://$FQDN:8201"

storage "raft" {
    path    = "/opt/vault/data"
    node_id = "$NODE_ID"

    retry_join {
        leader_api_addr = "https://$FQDN:8200"
    }
    retry_join {
        leader_api_addr = "https://$PEER_FQDN:8200"
    }
}

listener "tcp" {
    address         = "0.0.0.0:8200"
    cluster_address = "0.0.0.0:8201"
    tls_cert_file   = "/etc/vault.d/tls/vault.crt"
    tls_key_file    = "/etc/vault.d/tls/vault.key"
}
EOT

    sudo restorecon -Rv /etc/vault.d /opt/vault
    sudo systemctl daemon-reload

    if ! sudo systemctl is-active --quiet vault; then
        sudo systemctl enable --now vault
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart vault
    fi
    sudo systemctl enable vault

    write_file_if_changed /etc/profile.d/vault-env.sh 0644 root:root <<EOT
export VAULT_ADDR="https://$FQDN:8200"
export VAULT_CACERT="/etc/ipa/ca.crt"
EOT
}

configure_ha_proxy() {
    local changed=0
    write_file_if_changed /etc/haproxy/haproxy.cfg 0644 root:root <<EOT && changed=1
global
    maxconn 500
    log 127.0.0.1 local0

defaults
    log global
    retries 2
    timeout client 5m
    timeout connect 4s
    timeout server 5m
    timeout check 5s

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /
    stats refresh 5s

# Vault API/UI - only the active, unsealed leader passes this check
listen vault_api
    mode tcp
    bind *:8200
    bind :::8200
    option httpchk GET /v1/sys/health
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions check-ssl verify none port 8200
    server vault1 10.0.0.10:8200 check
    server vault2 10.0.0.11:8200 check
EOT

    sudo setsebool -P haproxy_connect_any=1 || true
    if ! sudo systemctl is-active --quiet haproxy; then
        sudo systemctl enable --now haproxy
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart haproxy
    fi
    sudo systemctl enable haproxy
}

configure_keepalived() {
    local changed=0
    write_file_if_changed /etc/keepalived/keepalived.conf 0644 root:root <<EOT && changed=1
global_defs {
    router_id VAULT_2
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

vrrp_sync_group VG_VAULT {
    group {
        VI_VAULT_V4
        VI_VAULT_V6
    }
}

vrrp_instance VI_VAULT_V4 {
    state MASTER
    interface $NIC
    virtual_router_id 120
    priority 100
    advert_int 1
    preempt_delay 3

    authentication {
        auth_type PASS
        auth_pass $VRRP_AUTH_PASS
    }

    virtual_ipaddress {
        $VAULT_VIP_V4/$VAULT_VIP_PREFIX_V4
    }

    track_interface {
        $NIC
    }

    track_script {
        chk_haproxy
    }
}

vrrp_instance VI_VAULT_V6 {
    state MASTER
    interface $NIC
    virtual_router_id 121
    priority 100
    advert_int 1
    preempt_delay 3

    virtual_ipaddress {
        $VAULT_VIP_V6/$VAULT_VIP_PREFIX_V6
    }

    track_interface {
        $NIC
    }

    track_script {
        chk_haproxy
    }
}
EOT

    if ! sudo systemctl is-active --quiet keepalived; then
        sudo systemctl enable --now keepalived
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart keepalived
    fi
    sudo systemctl enable keepalived
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

        # Vault API/UI - reachable from the whole LAN
        ip saddr 10.0.0.0/24 tcp dport 8200 accept
        ip6 saddr fd00:10::/64 tcp dport 8200 accept

        # Vault raft replication only from the two vault nodes
        ip saddr { 10.0.0.10, 10.0.0.11 } tcp dport 8201 accept
        ip6 saddr { fd00:10::10, fd00:10::11 } tcp dport 8201 accept

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
    configure_vault_package
    configure_tls_cert
    configure_vault_service
    configure_ha_proxy
    configure_keepalived
    configure_firewall
    configure_sshd
}

dispatch main "$@"