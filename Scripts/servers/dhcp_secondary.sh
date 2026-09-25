#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

FQDN=dhcp-2.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.13
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::13
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

PEER_IP_V4=10.0.0.12
PEER_IP_V6=fd00:10::12

SERVER_NAME=dhcp-2
PEER_NAME=dhcp-1

HA_AUTH_USER="ha_dhcp"
HA_AUTH_PASS="HA_Secret"

# Temporary bootstrap networking before pulling this script to run it:
#   sudo ip link set "$NIC" up
#   sudo ip addr add 10.0.0.250/24 dev "$NIC"
#   sudo ip route add default via 10.0.0.1
#   echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server git nftables systemd-networkd kea
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
IPForward=no
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

_ha_peers_json() {
    cat <<EOT
              "peers": [
                {
                  "name": "dhcp-1",
                  "url": "http://10.0.0.12:8000/",
                  "role": "primary",
                  "auto-failover": true,
                  "basic-auth-user": "$HA_AUTH_USER",
                  "basic-auth-password": "$HA_AUTH_PASS"
                },
                {
                  "name": "dhcp-2",
                  "url": "http://10.0.0.13:8000/",
                  "role": "standby",
                  "auto-failover": true,
                  "basic-auth-user": "$HA_AUTH_USER",
                  "basic-auth-password": "$HA_AUTH_PASS"
                }
              ]
EOT
}

configure_kea() {
    sudo mkdir -p /etc/kea /var/lib/kea /run/kea
    sudo install -d -o kea -g kea -m 0750 /var/lib/kea /run/kea

    local dhcp4_changed=0 dhcp6_changed=0 ca_changed=0

    write_file_if_changed /etc/kea/kea-dhcp4.conf 0640 root:kea <<EOT && dhcp4_changed=1
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "$NIC" ]
    },
    "control-socket": {
      "socket-type": "unix",
      "socket-name": "/run/kea/kea4-ctrl-socket"
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv",
      "lfc-interval": 3600
    },
    "valid-lifetime": 86400,
    "renew-timer": 43200,
    "rebind-timer": 75600,
    "option-data": [
      { "name": "routers", "data": "$GATEWAY_V4" },
      { "name": "domain-name-servers", "data": "10.0.0.53,10.0.0.54" },
      { "name": "domain-name", "data": "lab.internal" }
    ],
    "subnet4": [
      {
        "id": 1,
        "subnet": "10.0.0.0/$LAN_PREFIX_V4",
        "pools": [ { "pool": "10.0.0.100 - 10.0.0.200" } ]
      }
    ],
    "hooks-libraries": [
      {
        "library": "/usr/lib64/kea/hooks/libdhcp_lease_cmds.so"
      },
      {
        "library": "/usr/lib64/kea/hooks/libdhcp_ha.so",
        "parameters": {
          "high-availability": [
            {
              "this-server-name": "$SERVER_NAME",
              "mode": "hot-standby",
              "heartbeat-delay": 10000,
              "max-response-delay": 30000,
              "max-ack-delay": 5000,
              "max-unacked-clients": 0,
$(_ha_peers_json)
            }
          ]
        }
      }
    ]
  }
}
EOT

    write_file_if_changed /etc/kea/kea-dhcp6.conf 0640 root:kea <<EOT && dhcp6_changed=1
{
  "Dhcp6": {
    "interfaces-config": {
      "interfaces": [ "$NIC" ]
    },
    "control-socket": {
      "socket-type": "unix",
      "socket-name": "/run/kea/kea6-ctrl-socket"
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases6.csv",
      "lfc-interval": 3600
    },
    "valid-lifetime": 86400,
    "renew-timer": 43200,
    "rebind-timer": 75600,
    "option-data": [
      { "name": "dns-servers", "data": "fd00:10::53, fd00:10::54" }
    ],
    "subnet6": [
      {
        "id": 1,
        "subnet": "fd00:10::/$LAN_PREFIX_V6",
        "pools": [ { "pool": "fd00:10::100 - fd00:10::200" } ]
      }
    ],
    "hooks-libraries": [
      {
        "library": "/usr/lib64/kea/hooks/libdhcp_lease_cmds.so"
      },
      {
        "library": "/usr/lib64/kea/hooks/libdhcp_ha.so",
        "parameters": {
          "high-availability": [
            {
              "this-server-name": "$SERVER_NAME",
              "mode": "hot-standby",
              "heartbeat-delay": 10000,
              "max-response-delay": 30000,
              "max-ack-delay": 5000,
              "max-unacked-clients": 0,
$(_ha_peers_json)
            }
          ]
        }
      }
    ]
  }
}
EOT

    write_file_if_changed /etc/kea/kea-ctrl-agent.conf 0640 root:kea <<EOT && ca_changed=1
{
  "Control-agent": {
    "http-host": "$LAN_IP_V4",
    "http-port": 8000,
    "authentication": {
      "type": "basic",
      "clients": [
        { "user": "$HA_AUTH_USER", "password": "$HA_AUTH_PASS" }
      ]
    },
    "control-sockets": {
      "dhcp4": {
        "socket-type": "unix",
        "socket-name": "/run/kea/kea4-ctrl-socket"
      },
      "dhcp6": {
        "socket-type": "unix",
        "socket-name": "/run/kea/kea6-ctrl-socket"
      }
    }
  }
}
EOT

    sudo restorecon -Rv /etc/kea /var/lib/kea /run/kea 2>/dev/null || true

    sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
    sudo kea-dhcp6 -t /etc/kea/kea-dhcp6.conf
    sudo kea-ctrl-agent -t /etc/kea/kea-ctrl-agent.conf

    sudo mkdir -p /etc/systemd/system/kea-ctrl-agent.service.d
    write_file_if_changed /etc/systemd/system/kea-ctrl-agent.service.d/override.conf 0644 root:root <<EOT || true
[Unit]
After=kea-dhcp4.service kea-dhcp6.service
Wants=kea-dhcp4.service kea-dhcp6.service
EOT
    sudo systemctl daemon-reload

    if ! sudo systemctl is-active --quiet kea-dhcp4; then
        sudo systemctl enable kea-dhcp4 --now
    elif [ "$dhcp4_changed" -eq 1 ]; then
        sudo systemctl restart kea-dhcp4
    fi
    sudo systemctl enable kea-dhcp4

    if ! sudo systemctl is-active --quiet kea-dhcp6; then
        sudo systemctl enable kea-dhcp6 --now
    elif [ "$dhcp6_changed" -eq 1 ]; then
        sudo systemctl restart kea-dhcp6
    fi
    sudo systemctl enable kea-dhcp6

    if ! sudo systemctl is-active --quiet kea-ctrl-agent; then
        sudo systemctl enable kea-ctrl-agent --now
    elif [ "$ca_changed" -eq 1 ]; then
        sudo systemctl restart kea-ctrl-agent
    fi
    sudo systemctl enable kea-ctrl-agent
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

        # DHCPv4 requests from the LAN
        udp dport 67 accept

        # DHCPv6 requests from the LAN
        udp dport 547 accept

        # Kea Control Agent
        # plus admin API access from the management range
        ip saddr $PEER_IP_V4/32 tcp dport 8000 accept
        ip6 saddr $PEER_IP_V6/128 tcp dport 8000 accept
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 8000 accept
        ip6 saddr fd00:10::20-fd00:10::29 tcp dport 8000 accept

        # For node exporter from analytics server 10.0.0.31 / fd00:10::31
        ip saddr 10.0.0.31/32 tcp dport 9100 accept
        ip6 saddr fd00:10::31/128 tcp dport 9100 accept
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
    configure_kea
    configure_firewall
    configure_sshd
}

dispatch main "$@"