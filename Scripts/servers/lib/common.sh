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

# Blocks until the local etcd endpoint reports itself healthy
wait_for_etcd_health() {
    local endpoint=$1 cert=$2 key=$3 ca=$4
    local max_attempts=60 i
    for ((i = 1; i <= max_attempts; i++)); do
        if sudo ETCDCTL_API=3 /usr/local/bin/etcdctl \
            --endpoints="https://${endpoint}:2379" \
            --cacert="$ca" --cert="$cert" --key="$key" \
            --dial-timeout=2s \
            endpoint health &>/dev/null; then
            return 0
        fi
        sleep 2
    done

    echo "etcd at $endpoint did not report healthy after $((max_attempts * 2))s" >&2
    return 1
}

# Runs an etcdctl command against $seed_endpoints, retrying for a while if it fails
etcdctl_retry() {
    local seed_endpoints=$1 cert=$2 key=$3 ca=$4
    shift 4
    local max_attempts=30 i out rc=0
    for ((i = 1; i <= max_attempts; i++)); do
        if out=$(sudo /usr/local/bin/etcdctl \
            --cacert="$ca" --cert="$cert" --key="$key" --endpoints="$seed_endpoints" \
            --dial-timeout=5s --command-timeout=10s \
            "$@" 2>&1); then
            printf '%s\n' "$out"
            return 0
        fi
        rc=$?
        echo "etcdctl $* failed (attempt $i/$max_attempts): $out" >&2
        sleep 5
    done
    return "$rc"
}

# Registers this node as a member of an etcd cluster and returns the initial_cluster
etcd_join_existing_cluster() {
    local name=$1 peer_url=$2 seed_endpoints=$3 cert=$4 key=$5 ca=$6

    local member_list old_id cluster

    member_list=$(etcdctl_retry "$seed_endpoints" "$cert" "$key" "$ca" member list) || {
        echo "Could not reach any etcd seed endpoint ($seed_endpoints) to join the cluster as $name" >&2
        return 1
    }

    old_id=$(printf '%s' "$member_list" | awk -F', ' -v n="$name" '$3 == n {print $1}')

    if [ -n "$old_id" ]; then
        etcdctl_retry "$seed_endpoints" "$cert" "$key" "$ca" member remove "$old_id" || true
    fi

    etcdctl_retry "$seed_endpoints" "$cert" "$key" "$ca" member add "$name" --peer-urls="$peer_url" || {
        echo "Failed to add $name ($peer_url) to the etcd cluster" >&2
        return 1
    }

    cluster=$(printf '%s' "$member_list" | awk -F', ' '{print $3"="$4}' | paste -sd,)
    cluster="${cluster},${name}=${peer_url}"

    echo "$cluster"
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