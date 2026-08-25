#!/bin/bash
set -euo pipefail

# Only invokes dnf for packages that aren't already installed.
ensure_packages() {
    local package=() pkg
    for pkg in "$@"; do
        rpm -q "$pkg" &>/dev/null || package+=("$pkg")
    done
    if [ "${#package[@]}" -gt 0 ]; then
        sudo dnf install -y "${package[@]}"
    fi
}

# Installs a repo RPM only if it isn't present yet.
ensure_repo_rpm() {
    local rpm_name=$1 rpm_url=$2
    if ! rpm -q "$rpm_name" &>/dev/null; then
        sudo dnf install -y "$rpm_url"
    fi
}

# Set hostname
ensure_hostname() {
    local hostname=$1
    if [ "$(hostnamectl --static)" != "$hostname" ]; then
        sudo hostnamectl set-hostname "$hostname"
    fi
}

# File writing with change detection
write_file_if_changed() {
    local path=$1 mode=$2 owner=$3
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    sudo install -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    return 0
}

# Disables NetworkManager and enables systemd-networkd
switch_to_systemd_networkd() {
    if systemctl is-enabled NetworkManager &>/dev/null || systemctl is-active --quiet NetworkManager; then
        sudo systemctl disable --now NetworkManager
        sudo systemctl mask NetworkManager
        sudo systemctl unmask systemd-networkd
        sudo systemctl enable --now systemd-networkd
        echo "1"
    else
        sudo systemctl unmask systemd-networkd
        sudo systemctl enable --now systemd-networkd
        echo "0"
    fi
}

# disables firewalld and enables nftables
switch_to_nftables() {
    if systemctl is-enabled firewalld &>/dev/null || systemctl is-active --quiet firewalld; then
        sudo systemctl disable --now firewalld
    fi
    sudo systemctl enable --now nftables
}

# Applies a network file for $NIC and only restarts/reconfigures if the content changed
apply_network_file() {
    local unit_path=$1 nic=$2
    if write_file_if_changed "$unit_path" 0644 root:root; then
        sudo networkctl reload
        sudo networkctl reconfigure "$nic"
    fi
}

# Writes /etc/resolv.conf only if it needs to change.
apply_resolv_conf() {
    write_file_if_changed /etc/resolv.conf 0644 root:root || true
}

# Update nftables
apply_nftables_ruleset() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"
    sudo nft -c -f "$tmp"
    if write_file_if_changed /etc/sysconfig/nftables.conf 0644 root:root < "$tmp"; then
        sudo systemctl restart nftables
    fi
    rm -f "$tmp"
}

# Downloads a URL to a destination file only if it isn't already there.
download_once() {
    local url=$1 dest=$2
    if [ ! -f "$dest" ]; then
        curl -fsSL -o "$dest" "$url"
    fi
}

# Runs the function names passed as extra script args, or `main` if none were given
dispatch() {
    local default_fn=$1
    shift
    if [ "$#" -eq 0 ]; then
        "$default_fn"
    else
        local fn
        for fn in "$@"; do
            if declare -f "$fn" >/dev/null; then
                "$fn"
            else
                echo "Unknown function: $fn" >&2
                echo "Available functions:" >&2
                declare -F | awk '{print $3}' | grep -v '^_' >&2
                exit 1
            fi
        done
    fi
}