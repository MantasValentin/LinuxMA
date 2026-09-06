#!/bin/bash
# Health check for db-proxy-1.lab.internal
# Run as: sudo ./healthcheck_db_proxy_1.sh
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/healthcheck_common.sh"

FQDN=db-proxy-1.lab.internal
SELF_V4=10.0.0.41
PEER_V4=10.0.0.42
PEER_FQDN=db-proxy-2.lab.internal
DB1_V4=10.0.0.43
DB1_FQDN=db-1.lab.internal
DB2_V4=10.0.0.44
DB2_FQDN=db-2.lab.internal
VIP_V4=10.0.0.40
NIC=ens34

TLS_CERT=/etc/pki/tls/certs/db-node.pem
TLS_KEY=/etc/pki/tls/private/db-node.key
TLS_COMBINED=/etc/pki/tls/certs/db-node-combined.pem
TLS_CA=/etc/ipa/ca.crt

hc_init "db-proxy-1"

hc_section "Hostname / identity"
if [ "$(hostnamectl --static)" = "$FQDN" ]; then
    hc_pass "hostname is $FQDN"
else
    hc_fail "hostname is $(hostnamectl --static), expected $FQDN" "sudo hostnamectl set-hostname $FQDN"
fi

hc_section "IPA / time sync"
hc_ipa_join
hc_chrony

hc_section "DNS resolution"
hc_dns "$FQDN" "$SELF_V4"
hc_dns "$PEER_FQDN" "$PEER_V4"
hc_dns "$DB1_FQDN" "$DB1_V4"
hc_dns "$DB2_FQDN" "$DB2_V4"

hc_section "Network reachability"
hc_ping "$PEER_V4" "$PEER_FQDN"
hc_ping "$DB1_V4" "$DB1_FQDN"
hc_ping "$DB2_V4" "$DB2_FQDN"

hc_section "TLS certificate"
hc_cert_tracking "$TLS_CERT"
hc_cert_expiry "$TLS_CERT" 14
if [ -f "$TLS_COMBINED" ]; then
    hc_pass "combined haproxy PEM ($TLS_COMBINED) exists"
else
    hc_fail "combined haproxy PEM missing: $TLS_COMBINED" "re-run configure_tls_cert() from db_proxy_primary.sh"
fi

hc_section "etcd"
hc_service etcd
hc_tcp_port 127.0.0.1 2379 "etcd client (local)"
hc_tcp_port 127.0.0.1 2380 "etcd peer port (local)"
hc_tcp_port "$PEER_V4" 2380 "etcd peer port ($PEER_FQDN)"
hc_tcp_port "$DB1_V4" 2380 "etcd peer port ($DB1_FQDN)"
hc_tcp_port "$DB2_V4" 2380 "etcd peer port ($DB2_FQDN)"

if command -v etcdctl &>/dev/null; then
    if ETCDCTL_API=3 sudo etcdctl \
        --cacert="$TLS_CA" --cert="$TLS_CERT" --key="$TLS_KEY" \
        --endpoints="https://127.0.0.1:2379" endpoint health &>/tmp/etcd_health.$$; then
        hc_pass "etcdctl endpoint health: healthy"
    else
        hc_fail "etcdctl endpoint health failed" "cat /tmp/etcd_health.$$; sudo journalctl -u etcd -n 50 --no-pager"
    fi
    cat /tmp/etcd_health.$$ 2>/dev/null
    rm -f /tmp/etcd_health.$$

    member_count=$(ETCDCTL_API=3 sudo etcdctl \
        --cacert="$TLS_CA" --cert="$TLS_CERT" --key="$TLS_KEY" \
        --endpoints="https://127.0.0.1:2379" member list 2>/dev/null | wc -l)
    if [ "$member_count" -eq 4 ]; then
        hc_pass "etcd member list has 4 members (etcd1-4: proxy-1, proxy-2, db-1, db-2)"
    else
        hc_fail "etcd member list has $member_count members, expected 4" "ETCDCTL_API=3 sudo etcdctl --cacert=$TLS_CA --cert=$TLS_CERT --key=$TLS_KEY --endpoints=https://127.0.0.1:2379 member list"
    fi
else
    hc_fail "etcdctl not found" "confirm /usr/local/bin/etcdctl symlink exists (set up by configure_etcd)"
fi

hc_section "HAProxy"
hc_service haproxy
hc_tcp_port 127.0.0.1 5000 "haproxy pg_write (local)"
hc_tcp_port 127.0.0.1 5001 "haproxy pg_read (local)"
hc_tcp_port 127.0.0.1 7000 "haproxy stats (local)"
up_backends=$(curl -sk --cacert "$TLS_CA" "https://127.0.0.1:7000/;csv" 2>/dev/null | awk -F',' '$1=="pg_write" && $18=="UP" {c++} END{print c+0}')
if [ "${up_backends:-0}" -ge 1 ]; then
    hc_pass "haproxy pg_write backend has $up_backends server(s) UP"
else
    hc_fail "haproxy pg_write backend has no UP servers" "curl -sk --cacert $TLS_CA https://127.0.0.1:7000/;csv"
fi
read_up=$(curl -sk --cacert "$TLS_CA" "https://127.0.0.1:7000/;csv" 2>/dev/null | awk -F',' '$1=="pg_read" && $18=="UP" {c++} END{print c+0}')
if [ "${read_up:-0}" -ge 1 ]; then
    hc_pass "haproxy pg_read backend has $read_up server(s) UP"
else
    hc_warn "haproxy pg_read backend has no UP servers" "curl -sk --cacert $TLS_CA https://127.0.0.1:7000/;csv"
fi

hc_section "keepalived / VIP"
hc_service keepalived
if ip addr show dev "$NIC" | grep -q "$VIP_V4"; then
    hc_pass "VIP $VIP_V4 is present on this node"
else
    hc_pass "VIP $VIP_V4 is NOT on this node (expected unless this node is currently MASTER)"
fi

hc_section "conntrackd (VIP failover connection sync)"
hc_service conntrackd
if sudo conntrackd -C /etc/conntrackd/conntrackd.conf -s &>/tmp/conntrackd_stats.$$; then
    hc_pass "conntrackd stats query succeeded"
else
    hc_fail "conntrackd stats query failed" "sudo systemctl status conntrackd --no-pager; sudo journalctl -u conntrackd -n 50 --no-pager"
fi
cat /tmp/conntrackd_stats.$$ 2>/dev/null
rm -f /tmp/conntrackd_stats.$$
if lsmod | grep -q '^nf_conntrack '; then
    hc_pass "nf_conntrack kernel module loaded"
else
    hc_warn "nf_conntrack kernel module not loaded" "sudo modprobe nf_conntrack"
fi
if [ -f /etc/keepalived/notify.sh ] && [ -x /etc/keepalived/notify.sh ]; then
    hc_pass "keepalived notify.sh hook present and executable"
else
    hc_fail "keepalived notify.sh hook missing or not executable" "re-run configure_conntrackd() from db_proxy_primary.sh; sudo chmod 755 /etc/keepalived/notify.sh"
fi

hc_section "Firewall"
hc_service nftables
hc_nft_rule 'meta l4proto vrrp' "VRRP allowed for keepalived"
hc_nft_rule 'tcp dport \{ ?2379, ?2380 ?\}' "etcd client/peer ports open"
hc_nft_rule 'tcp dport \{ ?5000, ?5001 ?\}' "haproxy read/write ports open to LAN"
hc_nft_rule 'tcp dport 7000' "haproxy stats restricted to mgmt range"
hc_nft_rule 'tcp dport 22' "ssh restricted to mgmt range"

hc_section "SSH"
hc_service sshd

hc_summary