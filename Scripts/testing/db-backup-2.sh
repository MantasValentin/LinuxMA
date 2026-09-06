#!/bin/bash
# Health check for db-backup-2.lab.internal
# Run as: sudo ./healthcheck_db_backup_2.sh
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/healthcheck_common.sh"

FQDN=db-backup-2.lab.internal
SELF_V4=10.0.0.46
DB1_V4=10.0.0.43
DB1_FQDN=db-1.lab.internal
DB2_V4=10.0.0.44
DB2_FQDN=db-2.lab.internal

TLS_CERT=/etc/pki/tls/certs/db-backup-node.pem
TLS_KEY=/etc/pki/tls/private/db-backup-node.key
TLS_CA=/etc/ipa/ca.crt
PGBACKREST_CONF=/etc/pgbackrest/pgbackrest.conf
REPO_PATH=/var/lib/pgbackrest

hc_init "db-backup-2"

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
hc_dns "$DB1_FQDN" "$DB1_V4"
hc_dns "$DB2_FQDN" "$DB2_V4"

hc_section "Network reachability"
hc_ping "$DB1_V4" "$DB1_FQDN"
hc_ping "$DB2_V4" "$DB2_FQDN"

hc_section "TLS certificate"
hc_cert_tracking "$TLS_CERT"
hc_cert_expiry "$TLS_CERT" 14
if [ -f "$TLS_CERT" ]; then
    owner=$(stat -c '%U:%G' "$TLS_KEY" 2>/dev/null || echo "?")
    if [ "$owner" = "root:postgres" ]; then
        hc_pass "key ownership on $TLS_KEY is root:postgres"
    else
        hc_warn "key ownership on $TLS_KEY is '$owner', expected root:postgres" "sudo chown root:postgres $TLS_KEY && sudo chmod 640 $TLS_KEY"
    fi
fi

hc_section "pgBackRest TLS repo server"
hc_service pgbackrest
hc_tcp_port 127.0.0.1 8432 "pgbackrest TLS server (local)"
if echo | timeout 5 openssl s_client -connect 127.0.0.1:8432 -cert "$TLS_CERT" -key "$TLS_KEY" -CAfile "$TLS_CA" 2>/dev/null | grep -q "Verify return code: 0"; then
    hc_pass "TLS handshake to pgbackrest server succeeds and chains to IPA CA"
else
    hc_fail "TLS handshake to pgbackrest server failed or did not validate" "openssl s_client -connect 127.0.0.1:8432 -cert $TLS_CERT -key $TLS_KEY -CAfile $TLS_CA"
fi

hc_section "Repo client restriction"
echo "Note: pgBackRest client access is validated end-to-end from db-1/db-2 via 'pgbackrest info'."
if grep -q "tls-server-auth=${DB1_FQDN}=pg-cluster" "$PGBACKREST_CONF" 2>/dev/null && \
   grep -q "tls-server-auth=${DB2_FQDN}=pg-cluster" "$PGBACKREST_CONF" 2>/dev/null; then
    hc_pass "tls-server-auth restricts clients to $DB1_FQDN and $DB2_FQDN"
else
    hc_fail "tls-server-auth entries for db-1/db-2 missing or changed" "check [global] section of $PGBACKREST_CONF"
fi

hc_section "Backup repository / encryption"
if grep -q '^repo1-cipher-type=' "$PGBACKREST_CONF" 2>/dev/null; then
    hc_pass "repo1 encryption (repo1-cipher-type) is configured on this repo host"
else
    hc_fail "repo1 has NO encryption configured on this repo host" "add repo1-cipher-type=aes-256-cbc and repo1-cipher-pass=<the DB backup encryption password> to $PGBACKREST_CONF; the same password must be set on db-1 and db-2 as both repo1-cipher-pass and repo2-cipher-pass"
fi

if sudo -u postgres pgbackrest --stanza=pg-cluster --config="$PGBACKREST_CONF" info &>/tmp/pgbr_info.$$; then
    hc_pass "pgbackrest info (local) succeeded"
    if grep -qi "cipher: aes-256-cbc" /tmp/pgbr_info.$$; then
        hc_pass "pgbackrest reports repo is encrypted (aes-256-cbc)"
    else
        hc_warn "pgbackrest info did not report encryption for this repo" "confirm repo1-cipher-pass is set and matches the client-side config, then re-run stanza-create if needed"
    fi
    latest_backup=$(grep -oE '[0-9]{8}-[0-9]{6}[FDI]' /tmp/pgbr_info.$$ | tail -1)
    if [ -n "$latest_backup" ]; then
        hc_pass "latest backup found: $latest_backup"
    else
        hc_warn "no backups found in repo yet" "this is expected before the first scheduled backup runs (see /etc/cron.d/pgbackrest on db-1/db-2)"
    fi
else
    hc_fail "pgbackrest info (local) failed" "cat /tmp/pgbr_info.$$"
fi
cat /tmp/pgbr_info.$$ 2>/dev/null
rm -f /tmp/pgbr_info.$$

hc_section "Disk space"
avail_pct=$(df --output=pcent "$REPO_PATH" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$avail_pct" ] && [ "$avail_pct" -lt 85 ]; then
    hc_pass "disk usage under $REPO_PATH is ${avail_pct}% (< 85%)"
else
    hc_warn "disk usage under $REPO_PATH is ${avail_pct:-unknown}% (>= 85% or unknown)" "df -h $REPO_PATH; consider pruning retention or expanding storage"
fi

hc_section "Firewall"
hc_service nftables
hc_nft_rule 'tcp dport 8432' "pgBackRest TLS port open to db-1/db-2 only"
hc_nft_rule 'tcp dport 22' "ssh restricted to mgmt range"

hc_section "SSH"
hc_service sshd

hc_summary