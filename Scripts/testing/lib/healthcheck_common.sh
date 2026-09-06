#!/bin/bash
# Shared helpers for the healthcheck_*.sh scripts.
# Not meant to be run directly - sourced by the per-host scripts.
set -uo pipefail

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
LOG_FILE=""

# Sets up logging to /var/log/healthcheck/<name>-<timestamp>.log AND stdout.
hc_init() {
    local name=$1
    sudo mkdir -p /var/log/healthcheck
    LOG_FILE="/var/log/healthcheck/${name}-$(date +%Y%m%d-%H%M%S).log"
    sudo touch "$LOG_FILE"
    sudo chmod 640 "$LOG_FILE"
    # Duplicate all stdout/stderr to the log file from here on.
    exec > >(sudo tee -a "$LOG_FILE") 2>&1
    echo "===================================================="
    echo " Health check: $name"
    echo " Host:         $(hostname -f 2>/dev/null || hostname)"
    echo " Started:      $(date -Is)"
    echo " Log file:     $LOG_FILE"
    echo "===================================================="
}

hc_section() { echo; echo "----- $* -----"; }

hc_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "[ OK   ] $*"
}

hc_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo "[ WARN ] $1"
    [ -n "${2:-}" ] && echo "         fix: $2"
}

hc_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[ FAIL ] $1"
    [ -n "${2:-}" ] && echo "         fix: $2"
}

# Checks that a systemd unit exists, is active, and is enabled at boot.
hc_service() {
    local svc=$1
    if ! systemctl list-unit-files "${svc}.service" &>/dev/null; then
        hc_fail "service '$svc' has no unit file (not installed?)" "check the relevant ensure_packages/write_file_if_changed step in the provisioning script"
        return
    fi
    if systemctl is-active --quiet "$svc"; then
        hc_pass "service '$svc' is active"
    else
        hc_fail "service '$svc' is NOT active" "sudo systemctl status $svc --no-pager; sudo journalctl -u $svc -n 50 --no-pager; sudo systemctl restart $svc"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        hc_pass "service '$svc' is enabled at boot"
    else
        hc_warn "service '$svc' is not enabled at boot" "sudo systemctl enable $svc"
    fi
}

# TCP reachability, no TLS.
hc_tcp_port() {
    local host=$1 port=$2 desc=${3:-"$host:$port"}
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        hc_pass "TCP reachable: $desc"
    else
        hc_fail "TCP NOT reachable: $desc" "check nftables ruleset on both ends and that the service is actually listening (ss -tlnp)"
    fi
}

hc_ping() {
    local ip=$1 desc=${2:-$ip}
    if ping -c1 -W2 "$ip" &>/dev/null; then
        hc_pass "ping reachable: $desc"
    else
        hc_warn "ping failed (non-fatal, icmp may be filtered): $desc" "verify routing/nftables 'ip protocol icmp accept' rule"
    fi
}

hc_dns() {
    local fqdn=$1 expect=$2
    local got
    got=$(getent hosts "$fqdn" 2>/dev/null | awk '{print $1}' | head -1)
    if [ "$got" = "$expect" ]; then
        hc_pass "DNS $fqdn -> $expect"
    else
        hc_fail "DNS $fqdn resolved to '${got:-<none>}', expected '$expect'" "check dns_primary.sh zone file and /etc/resolv.conf on this host"
    fi
}

# certmonger tracking status for a request nickname (the -f cert path works as the nickname).
hc_cert_tracking() {
    local certfile=$1
    local status
    status=$(sudo getcert list -f "$certfile" 2>/dev/null | awk -F': ' '/status:/{print $2; exit}')
    if [ "$status" = "MONITORING" ]; then
        hc_pass "certmonger tracking '$certfile': MONITORING"
    else
        hc_fail "certmonger tracking '$certfile' status='${status:-not tracked}'" "sudo getcert list; sudo getcert resubmit -f $certfile"
    fi
}

hc_cert_expiry() {
    local certfile=$1 days=${2:-14}
    if [ ! -f "$certfile" ]; then
        hc_fail "cert file missing: $certfile" "re-run the provisioning script's configure_tls_cert step"
        return
    fi
    if sudo openssl x509 -in "$certfile" -checkend $((days * 86400)) -noout &>/dev/null; then
        hc_pass "cert $certfile valid for more than $days days"
    else
        hc_warn "cert $certfile expires within $days days" "certmonger should auto-renew via ipa-getcert; verify with: sudo getcert list"
    fi
}

hc_nft_rule() {
    local pattern=$1 desc=$2
    if sudo nft list ruleset 2>/dev/null | grep -qE "$pattern"; then
        hc_pass "nftables rule present: $desc"
    else
        hc_warn "nftables rule missing/changed: $desc" "re-run configure_firewall() in the provisioning script"
    fi
}

hc_chrony() {
    if command -v chronyc &>/dev/null && sudo chronyc tracking &>/dev/null; then
        local leap
        leap=$(sudo chronyc tracking | awk -F': ' '/Leap status/{print $2}')
        if [ "$leap" = "Normal" ]; then
            hc_pass "chrony leap status: Normal"
        else
            hc_warn "chrony leap status: ${leap:-unknown}" "sudo chronyc sources -v; sudo systemctl restart chronyd"
        fi
    else
        hc_fail "chronyc tracking failed / chronyd not responding" "sudo systemctl status chronyd"
    fi
}

hc_ipa_join() {
    if [ -f /etc/ipa/default.conf ]; then
        hc_pass "IPA client is enrolled (/etc/ipa/default.conf present)"
    else
        hc_fail "IPA client is NOT enrolled" "re-run configure_ipa_join() from the provisioning script"
    fi
    if systemctl is-active --quiet sssd; then
        hc_pass "sssd is active"
    else
        hc_warn "sssd is not active" "sudo systemctl restart sssd"
    fi
}

hc_summary() {
    hc_section "Summary"
    echo "PASS=$PASS_COUNT  WARN=$WARN_COUNT  FAIL=$FAIL_COUNT"
    echo "Full log: $LOG_FILE"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo "RESULT: FAIL"
        exit 1
    elif [ "$WARN_COUNT" -gt 0 ]; then
        echo "RESULT: WARN"
        exit 2
    else
        echo "RESULT: PASS"
        exit 0
    fi
}