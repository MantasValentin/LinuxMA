#!/bin/bash
# Health check for db-1.lab.internal
# Run as: sudo ./healthcheck_db_1.sh
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/healthcheck_common.sh"

FQDN=db-1.lab.internal
SELF_V4=10.0.0.43
PEER_V4=10.0.0.44
PEER_FQDN=db-2.lab.internal
PROXY1_V4=10.0.0.41
PROXY1_FQDN=db-proxy-1.lab.internal
PROXY2_V4=10.0.0.42
PROXY2_FQDN=db-proxy-2.lab.internal
BACKUP1_V4=10.0.0.45
BACKUP1_FQDN=db-backup-1.lab.internal
BACKUP2_V4=10.0.0.46
BACKUP2_FQDN=db-backup-2.lab.internal
PG_VERSION=18

TLS_CERT=/etc/pki/tls/certs/db-node.pem
TLS_KEY=/etc/pki/tls/private/db-node.key
TLS_CA=/etc/ipa/ca.crt
PGBACKREST_CONF=/etc/pgbackrest/pgbackrest.conf

hc_init "db-1"

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
hc_dns "$PROXY1_FQDN" "$PROXY1_V4"
hc_dns "$PROXY2_FQDN" "$PROXY2_V4"
hc_dns "$BACKUP1_FQDN" "$BACKUP1_V4"
hc_dns "$BACKUP2_FQDN" "$BACKUP2_V4"

hc_section "Network reachability"
hc_ping "$PEER_V4" "$PEER_FQDN"
hc_ping "$PROXY1_V4" "$PROXY1_FQDN"
hc_ping "$PROXY2_V4" "$PROXY2_FQDN"
hc_ping "$BACKUP1_V4" "$BACKUP1_FQDN"
hc_ping "$BACKUP2_V4" "$BACKUP2_FQDN"

hc_section "TLS certificate"
hc_cert_tracking "$TLS_CERT"
hc_cert_expiry "$TLS_CERT" 14

hc_section "etcd"
hc_service etcd
hc_tcp_port 127.0.0.1 2379 "etcd client (local)"
hc_tcp_port "$PEER_V4" 2379 "etcd client ($PEER_FQDN)"
hc_tcp_port "$PROXY1_V4" 2379 "etcd client ($PROXY1_FQDN)"
hc_tcp_port "$PROXY2_V4" 2379 "etcd client ($PROXY2_FQDN)"
if command -v etcdctl &>/dev/null; then
    if ETCDCTL_API=3 sudo etcdctl --cacert="$TLS_CA" --cert="$TLS_CERT" --key="$TLS_KEY" \
        --endpoints="https://127.0.0.1:2379" endpoint health &>/dev/null; then
        hc_pass "etcdctl endpoint health: healthy"
    else
        hc_fail "etcdctl endpoint health failed" "sudo journalctl -u etcd -n 50 --no-pager"
    fi
    member_count=$(ETCDCTL_API=3 sudo etcdctl --cacert="$TLS_CA" --cert="$TLS_CERT" --key="$TLS_KEY" \
        --endpoints="https://127.0.0.1:2379" member list 2>/dev/null | wc -l)
    if [ "$member_count" -eq 4 ]; then
        hc_pass "etcd member list has 4 members (etcd1-4: proxy-1, proxy-2, db-1, db-2)"
    else
        hc_fail "etcd member list has $member_count members, expected 4" "ETCDCTL_API=3 sudo etcdctl --cacert=$TLS_CA --cert=$TLS_CERT --key=$TLS_KEY --endpoints=https://127.0.0.1:2379 member list"
    fi
fi

hc_section "Patroni"
hc_service patroni
if curl -fsk --cacert "$TLS_CA" "https://127.0.0.1:8008/liveness" &>/dev/null; then
    hc_pass "patroni REST API /liveness OK (localhost)"
else
    hc_fail "patroni REST API /liveness failed" "curl -vk --cacert $TLS_CA https://127.0.0.1:8008/liveness; sudo journalctl -u patroni -n 80 --no-pager"
fi
if curl -fsk --cacert "$TLS_CA" "https://$PEER_V4:8008/liveness" &>/dev/null; then
    hc_pass "patroni REST API reachable on peer ($PEER_FQDN)"
else
    hc_warn "patroni REST API not reachable on peer ($PEER_FQDN)" "confirm peer's patroni.service is active and firewall allows 8008 from $SELF_V4"
fi

role="unknown"
if curl -fsk --cacert "$TLS_CA" "https://127.0.0.1:8008/primary" &>/dev/null; then
    role="primary"
elif curl -fsk --cacert "$TLS_CA" "https://127.0.0.1:8008/replica" &>/dev/null; then
    role="replica"
fi
hc_pass "this node's current Patroni role: $role"

if [ -x /opt/patroni/venv/bin/patronictl ]; then
    PATRONICTL=/opt/patroni/venv/bin/patronictl
    echo
    sudo -u postgres "$PATRONICTL" -c /etc/patroni/patroni.yml list 2>&1 || hc_warn "patronictl list failed" "sudo -u postgres $PATRONICTL -c /etc/patroni/patroni.yml list"
    bad_members=$(sudo -u postgres "$PATRONICTL" -c /etc/patroni/patroni.yml list 2>/dev/null | grep -Ei 'start failed|stopped|creating replica' | wc -l)
    if [ "${bad_members:-0}" -eq 0 ]; then
        hc_pass "no cluster members in a failed/stopped state"
    else
        hc_fail "$bad_members cluster member(s) in a failed/stopped/creating state" "sudo -u postgres $PATRONICTL -c /etc/patroni/patroni.yml list; check journalctl -u patroni on the affected node"
    fi
fi

hc_section "PostgreSQL"
if sudo -u postgres /usr/pgsql-${PG_VERSION}/bin/pg_isready -h /var/run/postgresql -p 5432 &>/dev/null; then
    hc_pass "pg_isready: accepting connections"
else
    hc_fail "pg_isready failed" "sudo systemctl status patroni; sudo -u postgres /usr/pgsql-${PG_VERSION}/bin/pg_ctl status -D /var/lib/pgsql/${PG_VERSION}/data"
fi

if [ "$role" = "primary" ]; then
    repl_count=$(sudo -u postgres psql -h /var/run/postgresql -p 5432 -Atc "select count(*) from pg_stat_replication;" 2>/dev/null || echo "err")
    if [ "$repl_count" = "1" ]; then
        hc_pass "pg_stat_replication shows 1 connected standby (expected: $PEER_FQDN)"
    else
        hc_fail "pg_stat_replication shows '$repl_count' connected standbys, expected 1" "sudo -u postgres psql -h /var/run/postgresql -c 'select application_name, state, sync_state from pg_stat_replication;'"
    fi
fi

hba_bad=$(sudo grep -E '^\s*host(no)?ssl' /var/lib/pgsql/${PG_VERSION}/data/pg_hba.conf 2>/dev/null | grep -Ev 'scram-sha-256|reject' | wc -l)
if [ "${hba_bad:-0}" -eq 0 ]; then
    hc_pass "pg_hba.conf: all host entries require scram-sha-256 password auth or reject (no trust/peer for remote)"
else
    hc_fail "pg_hba.conf has entries that are not scram-sha-256/reject" "sudo cat /var/lib/pgsql/${PG_VERSION}/data/pg_hba.conf"
fi
nossl_ok=$(sudo grep -Ec '^\s*hostnossl\s+all\s+all\s+.*reject' /var/lib/pgsql/${PG_VERSION}/data/pg_hba.conf 2>/dev/null)
if [ "${nossl_ok:-0}" -ge 2 ]; then
    hc_pass "non-TLS connections are rejected (hostnossl ... reject present for v4 and v6)"
else
    hc_warn "could not confirm hostnossl reject rules for both v4/v6" "check patroni bootstrap.dcs.pg_hba in patroni.yml (only applies pre-bootstrap; edit live config via patronictl edit-config)"
fi

hc_section "pgBackRest (client side)"
if grep -q '^repo1-cipher-type=' "$PGBACKREST_CONF" 2>/dev/null; then
    hc_pass "pgBackRest repo1 encryption (repo1-cipher-type) is configured"
else
    hc_fail "pgBackRest repo1 has NO encryption configured" "add repo1-cipher-type=aes-256-cbc and repo1-cipher-pass=<passphrase> to $PGBACKREST_CONF"
fi
if grep -q '^repo2-cipher-type=' "$PGBACKREST_CONF" 2>/dev/null; then
    hc_pass "pgBackRest repo2 encryption (repo2-cipher-type) is configured"
else
    hc_fail "pgBackRest repo2 has NO encryption configured" "add repo2-cipher-type=aes-256-cbc and repo2-cipher-pass=<passphrase> to $PGBACKREST_CONF"
fi
pass1=$(sudo grep '^repo1-cipher-pass=' "$PGBACKREST_CONF" 2>/dev/null | cut -d= -f2-)
pass2=$(sudo grep '^repo2-cipher-pass=' "$PGBACKREST_CONF" 2>/dev/null | cut -d= -f2-)
if [ -n "$pass1" ] && [ "$pass1" = "$pass2" ]; then
    hc_pass "repo1-cipher-pass and repo2-cipher-pass match (same DB backup encryption password used for both repos, as expected)"
elif [ -n "$pass1" ] && [ -n "$pass2" ]; then
    hc_fail "repo1-cipher-pass and repo2-cipher-pass differ" "these must be the same DB backup encryption password on both repos for this design; check $PGBACKREST_CONF"
fi

if sudo -u postgres pgbackrest --stanza=pg-cluster --config="$PGBACKREST_CONF" info &>/tmp/pgbr_info.$$; then
    hc_pass "pgbackrest info succeeded (both repos reachable)"
else
    hc_fail "pgbackrest info failed" "cat /tmp/pgbr_info.$$"
fi
cat /tmp/pgbr_info.$$ 2>/dev/null
rm -f /tmp/pgbr_info.$$

hc_tcp_port "$BACKUP1_V4" 8432 "$BACKUP1_FQDN pgBackRest TLS repo"
hc_tcp_port "$BACKUP2_V4" 8432 "$BACKUP2_FQDN pgBackRest TLS repo"

hc_section "Firewall"
hc_service nftables
hc_nft_rule 'tcp dport 5432' "postgres port open to peer + both proxies"
hc_nft_rule 'tcp dport 8008' "patroni REST API open to peer"
hc_nft_rule 'tcp dport \{ ?2379, ?2380 ?\}' "etcd client/peer ports open to peer + both proxies"

hc_section "SSH"
hc_service sshd

hc_summary