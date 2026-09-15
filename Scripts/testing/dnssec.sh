#!/bin/bash
# dnssec_test.sh
#
# Verifies that DNSSEC signing on dns-1/dns-2 and DNSSEC validation on
# dns-rslv-1/dns-rslv-2 are actually working, end to end.
#
# Run this from any host on the lab LAN (10.0.0.0/24) that has `dig`
# installed (bind-utils), e.g. admin-1 (10.0.0.20). It does not need to be
# run as root and it makes no changes to any server.
#
# Usage:
#   ./dnssec_test.sh
#
# Exit code is 0 if every check passed, 1 otherwise.

set -uo pipefail

# ---- Lab topology (override with env vars if your addressing differs) ----
DNS_PRIMARY="${DNS_PRIMARY:-10.0.0.7}"
DNS_SECONDARY="${DNS_SECONDARY:-10.0.0.8}"
RESOLVER_PRIMARY="${RESOLVER_PRIMARY:-10.0.0.53}"
RESOLVER_SECONDARY="${RESOLVER_SECONDARY:-10.0.0.54}"

FORWARD_ZONE="${FORWARD_ZONE:-lab.internal}"
REVERSE_ZONE_V4="${REVERSE_ZONE_V4:-0.0.10.in-addr.arpa}"
REVERSE_ZONE_V6="${REVERSE_ZONE_V6:-0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa}"

TEST_A_NAME="${TEST_A_NAME:-firewall.lab.internal}"
TEST_PTR_NAME="${TEST_PTR_NAME:-1.0.0.10.in-addr.arpa}"

# A domain that is deliberately, permanently DNSSEC-broken on the public
# internet. Used to prove a resolver actually enforces validation instead of
# just having dnssec-validation turned on without effect.
KNOWN_BAD_DOMAIN="${KNOWN_BAD_DOMAIN:-dnssec-failed.org}"

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

section() {
    echo ""
    echo "== $1 =="
}

require_dig() {
    if ! command -v dig >/dev/null 2>&1; then
        echo "ERROR: 'dig' not found. Install bind-utils first (dnf install bind-utils)." >&2
        exit 2
    fi
}

# --- Test: an authoritative server has a DNSKEY and a self-signing RRSIG ---
test_zone_is_signed() {
    local server="$1" zone="$2" label="$3"
    local dnskey rrsig

    dnskey=$(dig +time=3 +tries=1 @"$server" "$zone" DNSKEY +short 2>/dev/null)
    rrsig=$(dig +time=3 +tries=1 @"$server" "$zone" SOA +dnssec +short 2>/dev/null | grep -c '^RRSIG')

    if [ -n "$dnskey" ]; then
        pass "$label: DNSKEY published for $zone"
    else
        fail "$label: no DNSKEY returned for $zone"
    fi

    if [ "$rrsig" -ge 1 ] 2>/dev/null; then
        pass "$label: SOA for $zone carries an RRSIG"
    else
        fail "$label: SOA for $zone has no RRSIG (zone not signed / not yet reloaded?)"
    fi
}

# --- Test: a recursive resolver sets the AD bit for a signed internal name ---
test_resolver_validates() {
    local server="$1" name="$2" type="$3" label="$4"
    local flags

    flags=$(dig +time=3 +tries=1 @"$server" "$name" "$type" +dnssec 2>/dev/null | awk '/^;; flags:/{print; exit}')

    if [ -z "$flags" ]; then
        fail "$label: no response from $server for $name/$type"
        return
    fi

    if echo "$flags" | grep -q ' ad'; then
        pass "$label: $name/$type validated (ad flag set) via $server"
    else
        fail "$label: $name/$type NOT validated via $server (flags: $flags)"
    fi
}

# --- Test: a resolver rejects a deliberately broken DNSSEC domain ---
test_resolver_rejects_bad() {
    local server="$1" label="$2" status

    status=$(dig +time=3 +tries=1 @"$server" "$KNOWN_BAD_DOMAIN" A 2>/dev/null | awk '/^;; ->>HEADER<<-/{print $6}' | tr -d ',')

    if [ "$status" = "SERVFAIL" ]; then
        pass "$label: correctly returned SERVFAIL for known-bad domain $KNOWN_BAD_DOMAIN"
    else
        fail "$label: expected SERVFAIL for $KNOWN_BAD_DOMAIN, got '${status:-no response}' (validation may not be enforced)"
    fi
}

require_dig

echo "DNSSEC verification for lab.internal"
echo "Authoritative: $DNS_PRIMARY (dns-1), $DNS_SECONDARY (dns-2)"
echo "Resolvers:     $RESOLVER_PRIMARY (dns-rslv-1), $RESOLVER_SECONDARY (dns-rslv-2)"

section "1. Zones are signed on the authoritative servers"
test_zone_is_signed "$DNS_PRIMARY" "$FORWARD_ZONE" "dns-1"
test_zone_is_signed "$DNS_PRIMARY" "$REVERSE_ZONE_V4" "dns-1"
test_zone_is_signed "$DNS_PRIMARY" "$REVERSE_ZONE_V6" "dns-1"
test_zone_is_signed "$DNS_SECONDARY" "$FORWARD_ZONE" "dns-2 (post zone-transfer)"
test_zone_is_signed "$DNS_SECONDARY" "$REVERSE_ZONE_V4" "dns-2 (post zone-transfer)"
test_zone_is_signed "$DNS_SECONDARY" "$REVERSE_ZONE_V6" "dns-2 (post zone-transfer)"

section "2. Resolvers validate signed internal names (AD bit set)"
test_resolver_validates "$RESOLVER_PRIMARY" "$TEST_A_NAME" "A" "dns-rslv-1"
test_resolver_validates "$RESOLVER_SECONDARY" "$TEST_A_NAME" "A" "dns-rslv-2"
test_resolver_validates "$RESOLVER_PRIMARY" "$TEST_PTR_NAME" "PTR" "dns-rslv-1"
test_resolver_validates "$RESOLVER_SECONDARY" "$TEST_PTR_NAME" "PTR" "dns-rslv-2"

section "3. Resolvers actively enforce validation (reject a broken domain)"
test_resolver_rejects_bad "$RESOLVER_PRIMARY" "dns-rslv-1"
test_resolver_rejects_bad "$RESOLVER_SECONDARY" "dns-rslv-2"

echo ""
echo "===================================="
echo "Passed: $PASS   Failed: $FAIL"
echo "===================================="

if [ "$FAIL" -eq 0 ]; then
    echo "All DNSSEC checks passed."
    exit 0
else
    echo "One or more DNSSEC checks failed. See DNSSEC_GUIDE.md 'Troubleshooting' section."
    exit 1
fi