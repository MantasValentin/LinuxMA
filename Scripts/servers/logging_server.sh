#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FQDN=logs.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.30
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::30
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages policycoreutils-python-utils nftables openssh-server git systemd-networkd
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

configure_elastic_stack() {
    # Elasticsearch requires this to be raised, or it refuses to start
    write_file_if_changed /etc/sysctl.d/99-elasticsearch.conf 0644 root:root <<EOT
vm.max_map_count=262144
EOT
    sudo sysctl --system > /dev/null

    sudo rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch

    write_file_if_changed /etc/yum.repos.d/elasticsearch.repo 0644 root:root <<EOT
[elasticsearch]
name=Elasticsearch repository for 9.x packages
baseurl=https://artifacts.elastic.co/packages/9.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
EOT
    write_file_if_changed /etc/yum.repos.d/logstash.repo 0644 root:root <<EOT
[logstash-9.x]
name=Logstash repository for 9.x packages
baseurl=https://artifacts.elastic.co/packages/9.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
EOT
    write_file_if_changed /etc/yum.repos.d/kibana.repo 0644 root:root <<EOT
[kibana-9.x]
name=Kibana repository for 9.x packages
baseurl=https://artifacts.elastic.co/packages/9.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
EOT

    ensure_packages elasticsearch logstash kibana

    local es_changed=0
    write_file_if_changed /etc/elasticsearch/elasticsearch.yml 0660 root:elasticsearch <<EOT && es_changed=1
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
cluster.name: lab-logs
node.name: logs
network.host: 127.0.0.1
discovery.type: single-node

xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl:
    enabled: false
xpack.security.transport.ssl:
    enabled: false
EOT

    sudo mkdir -p /etc/elasticsearch/jvm.options.d
    write_file_if_changed /etc/elasticsearch/jvm.options.d/heap.options 0644 root:elasticsearch <<EOT && es_changed=1
-Xms2g
-Xmx2g
EOT

    local ls_changed=0
    write_file_if_changed /etc/logstash/conf.d/beats-to-es.conf 0644 root:root <<EOT && ls_changed=1
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

        data_stream => true
        data_stream_type => "logs"
        data_stream_dataset => "lab"
        data_stream_namespace => "default"
    }
}
EOT

    local kb_changed=0
    if ! grep -q "^server.host: \"$LAN_IP_V4\"" /etc/kibana/kibana.yml 2>/dev/null; then
        sudo tee -a /etc/kibana/kibana.yml > /dev/null <<EOT
server.host: "$LAN_IP_V4"
server.port: 5601
elasticsearch.hosts: ["http://127.0.0.1:9200"]
EOT
    else
        kb_changed=1
    fi

    # SELinux port labels for the non-default ports Logstash/Kibana use
    sudo semanage port -a -t http_port_t -p tcp 5601 2>/dev/null || sudo semanage port -m -t http_port_t -p tcp 5601 || true
    sudo semanage port -a -t http_port_t -p tcp 5044 2>/dev/null || sudo semanage port -m -t http_port_t -p tcp 5044 || true

    sudo restorecon -Rv /etc/elasticsearch /etc/logstash /etc/kibana /var/lib/elasticsearch 2>/dev/null || true

    # Bring the stack up in dependency order
    if ! sudo systemctl is-active --quiet elasticsearch; then
        sudo systemctl enable --now elasticsearch
        for _ in $(seq 1 60); do
            curl -s -o /dev/null "http://127.0.0.1:9200" && break
            sleep 5
        done
    elif [ "$es_changed" -eq 1 ]; then
        sudo systemctl restart elasticsearch
    fi
    sudo systemctl enable elasticsearch

    if ! sudo systemctl is-active --quiet logstash; then
        sudo systemctl enable --now logstash
    elif [ "$ls_changed" -eq 1 ]; then
        sudo systemctl restart logstash
    fi
    sudo systemctl enable logstash

    if ! sudo systemctl is-active --quiet kibana; then
        sudo systemctl enable --now kibana
    elif [ "$kb_changed" -eq 1 ]; then
        sudo systemctl restart kibana
    fi
    sudo systemctl enable kibana
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

        # Kibana web UI only from the management range 10.0.0.20-29 / fd00:10::20-29
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 5601 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 5601 accept

        # Logstash beats input from the LAN
        ip saddr 10.0.0.0/24 tcp dport 5044 accept
        ip6 saddr fd00:10::/64 tcp dport 5044 accept

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
    configure_elastic_stack
    configure_firewall
    configure_sshd
}

dispatch main "$@"