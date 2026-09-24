#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

DOT_MODE=yes

DOT_CA_ANCHOR=/etc/pki/ca-trust/source/anchors/lab-internal-ca.pem

configure_packages() {
    ensure_packages systemd-resolved
}

configure_dot_trust() {
    [ "$DOT_MODE" = "yes" ] || return 0

    local tmp
    tmp=$(mktemp)
    if ! curl -fsS -o "$tmp" http://ipa-1.lab.internal/ipa/config/ca.crt; then
        curl -fsS -o "$tmp" http://ipa-2.lab.internal/ipa/config/ca.crt
    fi

    if write_file_if_changed "$DOT_CA_ANCHOR" 0644 root:root < "$tmp"; then
        sudo update-ca-trust extract
    fi
    rm -f "$tmp"
}

configure_resolver() {
    sudo systemctl unmask systemd-resolved
    sudo systemctl enable systemd-resolved --now

    if write_file_if_changed /etc/systemd/resolved.conf 0644 root:root <<EOT
[Resolve]
DNS=10.0.0.53#dns-rslv-1.lab.internal 10.0.0.54#dns-rslv-2.lab.internal
DNSOverTLS=$DOT_MODE
EOT
    then
        sudo systemctl restart systemd-resolved
    fi

    sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
}

main() {
    configure_packages
    configure_dot_trust
    configure_resolver
}

dispatch main "$@"