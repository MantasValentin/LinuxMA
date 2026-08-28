#!/bin/bash
# Rocky Linux 10.2 - Metrics (Prometheus + Grafana)
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FQDN=analytics.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.31
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::31
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

PROMETHEUS_VERSION=3.13.2

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages nftables openssh-server git systemd-networkd tar curl
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

configure_prometheus() {
    # Cockpit binds :9090 by default and conflicts with Prometheus
    sudo systemctl disable --now cockpit.socket 2>/dev/null || true
    sudo systemctl mask cockpit.socket 2>/dev/null || true

    sudo useradd --system --no-create-home --shell /sbin/nologin prometheus 2>/dev/null || true
    sudo mkdir -p /etc/prometheus/targets /var/lib/prometheus

    if [ ! -x /usr/local/bin/prometheus ]; then
        download_once \
            "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" \
            "/tmp/prometheus-${PROMETHEUS_VERSION}.tar.gz"
        tar -xzf "/tmp/prometheus-${PROMETHEUS_VERSION}.tar.gz" -C /tmp
        sudo cp "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" /usr/local/bin/prometheus
        sudo cp "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool" /usr/local/bin/promtool
        rm -rf "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64"
    fi

    local changed=0
    write_file_if_changed /etc/prometheus/prometheus.yml 0644 prometheus:prometheus <<EOT && changed=1
global:
    scrape_interval: 15s
    evaluation_interval: 15s

scrape_configs:
    - job_name: "prometheus"
        static_configs:
        - targets: ["127.0.0.1:9090"]

    - job_name: "node"
        file_sd_configs:
        - files:
            - /etc/prometheus/targets/node_exporters.yml
            refresh_interval: 30s
EOT

    # Seed an empty target list so Prometheus starts cleanly before Ansible
    if [ ! -f /etc/prometheus/targets/node_exporters.yml ]; then
        sudo tee /etc/prometheus/targets/node_exporters.yml > /dev/null <<EOT
- targets: []
    labels:
        job: node
EOT
    fi

    sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

    write_file_if_changed /etc/systemd/system/prometheus.service 0644 root:root <<EOT && changed=1
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \\
    --config.file=/etc/prometheus/prometheus.yml \\
    --storage.tsdb.path=/var/lib/prometheus \\
    --web.listen-address=$LAN_IP_V4:9090
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOT

    sudo semanage port -a -t http_port_t -p tcp 9090 2>/dev/null || sudo semanage port -m -t http_port_t -p tcp 9090 || true
    sudo restorecon -Rv /etc/prometheus 2>/dev/null || true

    sudo systemctl daemon-reload
    if ! sudo systemctl is-active --quiet prometheus; then
        sudo systemctl enable --now prometheus
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart prometheus
    fi
    sudo systemctl enable prometheus
}

configure_grafana() {
    if ! rpm -q grafana &>/dev/null; then
        wget -q -O /tmp/grafana-gpg.key https://rpm.grafana.com/gpg.key
        sudo rpm --import /tmp/grafana-gpg.key
        rm -f /tmp/grafana-gpg.key

        write_file_if_changed /etc/yum.repos.d/grafana.repo 0644 root:root <<EOT
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
EOT
        sudo dnf install -y grafana
    fi

    local changed=0
    if ! grep -q "^http_addr = $LAN_IP_V4\$" /etc/grafana/grafana.ini 2>/dev/null; then
        sudo tee -a /etc/grafana/grafana.ini > /dev/null <<EOT
[server]
http_addr = $LAN_IP_V4
http_port = 3000
EOT
    else
        changed=1
    fi

    sudo mkdir -p /etc/grafana/provisioning/datasources
    write_file_if_changed /etc/grafana/provisioning/datasources/prometheus.yml 0644 root:root <<EOT && changed=1
apiVersion: 1

datasources:
    - name: Prometheus
        type: prometheus
        access: proxy
        url: http://$LAN_IP_V4:9090
        isDefault: true
        editable: false
EOT

    sudo semanage port -a -t http_port_t -p tcp 3000 2>/dev/null || sudo semanage port -m -t http_port_t -p tcp 3000 || true
    sudo restorecon -Rv /etc/grafana 2>/dev/null || true

    if ! sudo systemctl is-active --quiet grafana-server; then
        sudo systemctl enable --now grafana-server
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart grafana-server
    fi
    sudo systemctl enable grafana-server
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

        # Grafana web UI from the management range 10.0.0.20-29 / fd00:10::20-29
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 3000 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 3000 accept

        # Prometheus web UI from the management range 10.0.0.20-29 / fd00:10::20-29
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 9090 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 9090 accept

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
    configure_prometheus
    configure_grafana
    configure_firewall
    configure_sshd
}

dispatch main "$@"