#!/bin/bash
set -euo pipefail

# Set hostname
sudo hostnamectl set-hostname "firewall1"

# External (WAN) and internal (LAN) interfaces
NIC_E=ens33
NIC_I=ens34

LAN_IP=10.0.0.2
SECONDARY_FIREWALL_LAN_IP=10.0.0.3

# Shared secrets
# identical between firewall_primary.sh and firewall_secondary.sh
VRRP_AUTH_PASS="VRRP_Secret"

# Update and upgrade
sudo apt update && sudo apt upgrade -y

# openssh-server  - remote management
# git             - pulling config from your repo
# nftables        - firewall, NAT, DNAT
# keepalived      - for configuring a virtual IP
# conntrackd      - syncs the connection-tracking table for both firewalls
sudo apt install -y openssh-server git nftables keepalived conntrackd

# Enable IP forwarding
sudo tee /etc/sysctl.d/99-firewall.conf > /dev/null <<EOT
net.ipv4.ip_forward=1

# Mitigates ip spoofing by checking if the source ip comes from the correct NIC
# Prevents WAN connections from pretending to be comming from LAN admin servers 
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

# Don't answer/accept ICMP redirects
# Prevents externall changes to the firewalls routing table
net.ipv4.conf.all.accept_redirects=0
# Prevents the firewall from revealing the LAN topology
net.ipv4.conf.all.send_redirects=0
# Prevents the firewall from accepting a hostile routing path
net.ipv4.conf.all.accept_source_route=0
EOT
sudo sysctl --system

# Disable automatic dns resolution
sudo systemctl disable --now systemd-resolved

sudo systemctl enable nftables --now
sudo systemctl enable ssh --now

# WAN interface
sudo tee /etc/systemd/network/10-wan.network > /dev/null <<EOT
[Match]
Name=$NIC_E

[Network]
DHCP=yes

[DHCPv4]
UseDNS=no
EOT

# LAN interface
sudo tee /etc/systemd/network/20-lan.network > /dev/null <<EOT
[Match]
Name=$NIC_I

[Network]
Address=$LAN_IP/24
EOT

# Get rid of netplan configuration files
sudo rm -fr /etc/netplan/

# Restart networking
sudo systemctl unmask systemd-networkd systemd-networkd-wait-online
sudo systemctl enable systemd-networkd systemd-networkd-wait-online
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC_E" "$NIC_I"

# DNS resolution goes to internal resolvers
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
EOT

# NAT and filtering
sudo tee /etc/nftables.conf > /dev/null <<EOT
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Masquerade all LAN-sourced traffic heading out to the internet
        oifname "$NIC_E" masquerade
    }

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # Inbound WAN traffic on 80/443 is DNAT'd to the reverse proxy only
        iifname "$NIC_E" tcp dport 80 dnat to 10.0.0.60
        iifname "$NIC_E" tcp dport 443 dnat to 10.0.0.60
    }
}

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Established/related connections
        ct state established,related accept

        # Drop invalid packets
        ct state invalid drop

        # Loopback
        iifname "lo" accept

        # ICMP rate-limited to prevent ping-flood
        ip protocol icmp icmp type echo-request limit rate 10/second accept
        ip protocol icmp icmp type { destination-unreachable, time-exceeded, echo-reply } accept

        # VRRP is used by keepalived
        ip protocol vrrp iifname "$NIC_I" accept

        # For conntrackd to sync both firewalls
        iifname "$NIC_I" tcp dport 3780 accept
        iifname "$NIC_I" udp dport 3780 accept

        # SSH only from the management range and LAN NIC
        iifname "$NIC_I" ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 ct state new accept

        # Allow DHCP on the WAN network
        iifname "$NIC_E" udp dport 68 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # Established/related connections
        ct state established,related accept

        # Drop invalid packets
        ct state invalid drop

        # LAN out to the internet
        iifname "$NIC_I" oifname "$NIC_E" accept

        # WAN in, but only to the reverse proxy on 80/443
        iifname "$NIC_E" oifname "$NIC_I" ip daddr 10.0.0.60 tcp dport { 80, 443 } accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOT

sudo nft -f /etc/nftables.conf
sudo nft list ruleset
sudo systemctl restart nftables

# Attach the firewall to a virtual IP
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<EOT
global_defs {
    router_id FIREWALL_1
    script_user root
    enable_script_security
}

vrrp_script chk_wan {
    script "/usr/bin/ping -c1 -W1 8.8.8.8"
    interval 2
    weight -60
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface $NIC_I
    virtual_router_id 100
    priority 150
    advert_int 1
    preempt_delay 3

    authentication {
        auth_type PASS
        auth_pass $VRRP_AUTH_PASS
    }

    virtual_ipaddress {
        10.0.0.1/24
    }

    track_interface {
        $NIC_E
        $NIC_I
    }

    track_script {
        chk_wan
    }

    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault "/etc/keepalived/notify.sh fault"
}
EOT

# Configure conntrackd to sync the connection-tracking table for both firewalls
sudo modprobe nf_conntrack
sudo modprobe nf_conntrack_netlink
echo "nf_conntrack"         | sudo tee -a /etc/modules-load.d/conntrack.conf > /dev/null
echo "nf_conntrack_netlink" | sudo tee -a /etc/modules-load.d/conntrack.conf > /dev/null

sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
echo "net.netfilter.nf_conntrack_max = 1048576" | sudo tee -a /etc/sysctl.d/99-conntrack.conf > /dev/null
sudo sysctl -p /etc/sysctl.d/99-conntrack.conf

sudo tee /etc/conntrackd/conntrackd.conf > /dev/null <<EOT
General {
    HashSize 131072
    HashLimit 1048576
    LogFile on
    Syslog on
    LockFile /var/lock/conntrackd.lock
    UNIX {
        Path /var/run/conntrackd.ctl
    }
    NetlinkBufferSize 2097152
    NetlinkBufferSizeMaxGrowth 8388608
    NetlinkOverrunResync on
    NetlinkEventsReliable off
    Filter From Userspace {
        Protocol Accept {
            UDP
        }
        Address Ignore {
            IPv4_address 127.0.0.1
        }
    }
}

Sync {
    Mode FTFW {
        DisableExternalCache off
        CommitTimeout 180
        PurgeTimeout 60
    }
    UDP Default {
        IPv4_address $LAN_IP
        Port 3780
        Interface $NIC_I
        IPv4_Destination_Address $SECONDARY_FIREWALL_LAN_IP
        SndSocketBuffer 1249280
        RcvSocketBuffer 1249280
        Checksum on
    }
}
EOT

sudo tee /etc/keepalived/notify.sh > /dev/null <<'EOT'
#!/bin/sh
CONNTRACKD_BIN=/usr/sbin/conntrackd
CONNTRACKD_CONFIG=/etc/conntrackd/conntrackd.conf

case "$1" in
    master)
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -c
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -B
        logger "keepalived: entering MASTER, committed conntrack cache"
        ;;
    backup)
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -f
        logger "keepalived: entering BACKUP, flushed conntrack cache"
        ;;
    fault)
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -f
        logger "keepalived: entering FAULT, flushed conntrack cache"
        ;;
    *)
        logger "keepalived: notify.sh called with unrecognized state: $1"
        ;;
esac
EOT

sudo chmod +x /etc/keepalived/notify.sh
sudo chown root:root /etc/keepalived/notify.sh

# Make sure conntrackd is up before keepalived
sudo mkdir -p /etc/systemd/system/keepalived.service.d
sudo tee /etc/systemd/system/keepalived.service.d/override.conf > /dev/null <<EOT
[Unit]
After=conntrackd.service
Wants=conntrackd.service
EOT

# Configure conntrackd service priority
sudo mkdir -p /etc/systemd/system/conntrackd.service.d
sudo tee /etc/systemd/system/conntrackd.service.d/priority.conf > /dev/null <<'EOF'
[Service]
Nice=-10
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now conntrackd
sudo systemctl enable --now keepalived