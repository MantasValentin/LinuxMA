#!/bin/bash
set -euo pipefail

# Rocky Linux 10.2

# Interface
NIC=ens34
LAN_IP_V4=10.0.0.31
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::31
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

# Versions
PROMETHEUS_VERSION=3.13.2

# Set hostname
sudo hostnamectl set-hostname "analytics.lab.internal"

# Update and upgrade
sudo dnf upgrade -y

# nftables         - firewall
# openssh-server   - remote management
# git              - pulling config from your repo
# systemd-networkd - networking
# tar/curl         - fetching the Prometheus release
sudo dnf install -y epel-release
sudo dnf install -y nftables openssh-server git systemd-networkd tar curl

# Remove the temporary networking
sudo ip addr flush dev "$NIC"
sudo ip route flush dev "$NIC"

# replace NetworkManager with systemd-networkd
sudo systemctl disable --now NetworkManager
sudo systemctl mask NetworkManager
sudo systemctl unmask systemd-networkd
sudo systemctl enable systemd-networkd --now

# replace firewalld with nftables
sudo systemctl disable --now firewalld
sudo systemctl enable nftables --now

# LAN interface
sudo tee /etc/systemd/network/10-lan.network > /dev/null <<EOT
[Match]
Name=$NIC

[Network]
Address=$LAN_IP_V4/$LAN_PREFIX_V4
Address=$LAN_IP_V6/$LAN_PREFIX_V6
Gateway=$GATEWAY_V4
Gateway=$GATEWAY_V6
IPv6AcceptRA=no
EOT

# dns resolution goes to dns-rslv
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
nameserver fd00:10::53
nameserver fd00:10::54
EOT

# Restart networking
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC"

# Prometheus
sudo useradd --system --no-create-home --shell /sbin/nologin prometheus || true
sudo mkdir -p /etc/prometheus/targets /var/lib/prometheus

curl -sL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" \
    -o /tmp/prometheus.tar.gz
tar -xzf /tmp/prometheus.tar.gz -C /tmp
sudo cp "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" /usr/local/bin/prometheus
sudo cp "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool" /usr/local/bin/promtool
sudo cp -r "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles" /etc/prometheus/
sudo cp -r "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries" /etc/prometheus/
rm -rf /tmp/prometheus.tar.gz "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64"

# Scrape config
sudo tee /etc/prometheus/prometheus.yml > /dev/null <<EOT
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

# Seed an empty target list so Prometheus starts cleanly before Ansible runs
sudo tee /etc/prometheus/targets/node_exporters.yml > /dev/null <<EOT
- targets: []
  labels:
    job: node
EOT

sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

sudo tee /etc/systemd/system/prometheus.service > /dev/null <<EOT
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \\
    --config.file=/etc/prometheus/prometheus.yml \\
    --storage.tsdb.path=/var/lib/prometheus \\
    --web.listen-address=$LAN_IP_V4:9090 \\
    --web.console.templates=/etc/prometheus/consoles \\
    --web.console.libraries=/etc/prometheus/console_libraries
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOT

sudo systemctl daemon-reload
sudo systemctl enable prometheus --now

# Grafana
wget -q -O gpg.key https://rpm.grafana.com/gpg.key
sudo rpm --import gpg.key

sudo tee /etc/yum.repos.d/grafana.repo > /dev/null <<EOT
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
EOT

sudo dnf install grafana

sudo systemctl daemon-reload
sudo systemctl enable grafana-server --now

# sudo tee -a /etc/grafana/grafana.ini > /dev/null <<EOT

# # --- lab overrides ---
# [server]
# http_addr = $LAN_IP_V4
# http_port = 3000
# EOT

# # Auto-provision Prometheus as a datasource so it's there on first login
# sudo mkdir -p /etc/grafana/provisioning/datasources
# sudo tee /etc/grafana/provisioning/datasources/prometheus.yml > /dev/null <<EOT
# apiVersion: 1

# datasources:
#   - name: Prometheus
#     type: prometheus
#     access: proxy
#     url: http://127.0.0.1:9090
#     isDefault: true
#     editable: true
# EOT

# sudo restorecon -Rv /etc/grafana /etc/prometheus 2>/dev/null || true

# sudo systemctl enable grafana-server --now

# Firewall Config
sudo tee /etc/sysconfig/nftables.conf > /dev/null <<EOT
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

        # Grafana web UI from the LAN (has its own login)
        ip saddr 10.0.0.0/24 tcp dport 3000 accept
        ip6 saddr fd00:10::/64 tcp dport 3000 accept

        # Prometheus UI has no auth of its own - management range only
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 9090 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 9090 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOT

sudo nft -f /etc/sysconfig/nftables.conf
sudo nft list ruleset
sudo systemctl restart nftables

sudo systemctl enable sshd --now
sudo systemctl daemon-reload