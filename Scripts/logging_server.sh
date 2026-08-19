#!/bin/bash
set -euo pipefail

# Rocky Linux 10.2

# Interface
NIC=ens34
LAN_IP_V4=10.0.0.30
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::30
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

# Set hostname
sudo hostnamectl set-hostname "logs.lab.internal"

# Update and upgrade
sudo dnf upgrade -y

# epel-release             - a couple of deps come from EPEL
# policycoreutils-python-utils - semanage, for the SELinux port labels below
# nftables                 - firewall
# openssh-server           - remote management
# git                      - pulling config from your repo
# systemd-networkd         - networking
sudo dnf install -y epel-release
sudo dnf install -y policycoreutils-python-utils nftables openssh-server git systemd-networkd

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

# Elasticsearch requires this to be raised, or it refuses to start
sudo tee /etc/sysctl.d/99-elasticsearch.conf > /dev/null <<EOT
vm.max_map_count=262144
EOT
sudo sysctl --system

# Add the Elastic package repo (tracks the latest 8.x release)
sudo rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch
sudo tee /etc/yum.repos.d/elastic.repo > /dev/null <<EOT
[elastic-8.x]
name=Elastic repository for 8.x packages
baseurl=https://artifacts.elastic.co/packages/8.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
EOT

sudo dnf install -y elasticsearch logstash kibana

# Elasticsearch - single node, local-only. Kibana and Logstash are the only
# things that ever need to talk to it, and they run on this same box.
sudo tee -a /etc/elasticsearch/elasticsearch.yml > /dev/null <<EOT

# --- lab overrides ---
cluster.name: lab-logs
node.name: logs
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node

# Internal lab, no external exposure - keep this simple
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
EOT

sudo mkdir -p /etc/elasticsearch/jvm.options.d
sudo tee /etc/elasticsearch/jvm.options.d/heap.options > /dev/null <<EOT
-Xms2g
-Xmx2g
EOT

# Logstash - receive from Filebeat on 5044, forward to Elasticsearch
sudo tee /etc/logstash/conf.d/beats-to-es.conf > /dev/null <<EOT
input {
  beats {
    port => 5044
  }
}

filter {
}

output {
  elasticsearch {
    hosts => ["http://127.0.0.1:9200"]
    index => "logs-%{[host][name]}-%{+YYYY.MM.dd}"
  }
}
EOT

# Kibana - reachable from the LAN
sudo tee -a /etc/kibana/kibana.yml > /dev/null <<EOT

# --- lab overrides ---
server.host: "$LAN_IP_V4"
server.port: 5601
elasticsearch.hosts: ["http://127.0.0.1:9200"]
EOT

# SELinux port labels for the non-default ports Logstash/Kibana use
sudo semanage port -a -t http_port_t -p tcp 5601 2>/dev/null || sudo semanage port -m -t http_port_t -p tcp 5601 || true
sudo semanage port -a -t http_port_t -p tcp 5044 2>/dev/null || sudo semanage port -m -t http_port_t -p tcp 5044 || true

sudo restorecon -Rv /etc/elasticsearch /etc/logstash /etc/kibana /var/lib/elasticsearch 2>/dev/null || true

# Bring the stack up in dependency order. Elasticsearch has to actually be
# answering before Kibana will start cleanly.
sudo systemctl enable elasticsearch --now

echo "Waiting for Elasticsearch to become reachable..."
for i in $(seq 1 60); do
    if curl -s -o /dev/null "http://127.0.0.1:9200"; then
        break
    fi
    sleep 5
done

sudo systemctl enable logstash --now
sudo systemctl enable kibana --now

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

        # Kibana web UI from the LAN
        ip saddr 10.0.0.0/24 tcp dport 5601 accept
        ip6 saddr fd00:10::/64 tcp dport 5601 accept

        # Logstash beats input from the LAN (Filebeat on every server)
        ip saddr 10.0.0.0/24 tcp dport 5044 accept
        ip6 saddr fd00:10::/64 tcp dport 5044 accept
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