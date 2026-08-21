#!/bin/bash
set -euo pipefail

# Rocky Linux 10.2

# External (WAN) and internal (LAN) interfaces
NIC_E=ens33
NIC_I=ens34

WAN_IP_V4=192.168.0.4
WAN_VIP_V4=192.168.0.2
WAN_GATEWAY_V4=192.168.0.1
WAN_PREFIX_V4=24
MASTER_FIREWALL_WAN_IP_V4=192.168.0.3

LAN_IP_V4=10.0.0.3
LAN_VIP_V4=10.0.0.1
LAN_PREFIX_V4=24
MASTER_FIREWALL_LAN_IP_V4=10.0.0.2

WAN_IP_V6=fd00:192:168::4
WAN_VIP_V6=fd00:192:168::2
WAN_GATEWAY_V6=fd00:192:168::1
WAN_PREFIX_V6=64
MASTER_FIREWALL_WAN_IP_V6=fd00:192:168::3

LAN_IP_V6=fd00:10::3
LAN_VIP_V6=fd00:10::1
LAN_PREFIX_V6=64
LAN_PREFIX_NET_V6=fd00:10
MASTER_FIREWALL_LAN_IP_V6=fd00:10::2

# Shared secret
# identical between firewall_primary.sh and firewall_secondary.sh
VRRP_AUTH_PASS="VRRP_Secret"

# Set hostname
sudo hostnamectl set-hostname "firewall2.lab.internal"

# Update and upgrade
sudo dnf upgrade -y

# epel-release      - conntrackd and radvd ship from EPEL on Rocky
# openssh-server    - remote management
# git               - pulling config from your repo
# nftables          - firewall, NAT, DNAT
# keepalived        - for configuring a virtual IP
# conntrack-tools   - syncs the connection-tracking table for both firewalls
# radvd             - ipv6 RA
# systemd-networkd  - networking
sudo dnf install -y epel-release
sudo dnf install -y openssh-server git nftables keepalived conntrack-tools radvd systemd-networkd

# Enable IP forwarding
sudo tee /etc/sysctl.d/99-firewall.conf > /dev/null <<EOT
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# Mitigates ip spoofing by checking if the source ip comes from the correct NIC
# Prevents WAN connections from pretending to be comming from LAN admin servers 
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

# Don't answer/accept ICMP redirects
# Prevents externall changes to the firewalls routing table
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
# Prevents the firewall from revealing the LAN topology
net.ipv4.conf.all.send_redirects=0
# Prevents the firewall from accepting a hostile routing path
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0

# Ignore RA, use static addresses
net.ipv6.conf.all.accept_ra=0
EOT
sudo sysctl --system

# replace NetworkManager with systemd-networkd
sudo systemctl disable --now NetworkManager
sudo systemctl mask NetworkManager
sudo systemctl unmask systemd-networkd
sudo systemctl enable systemd-networkd --now

# replace firewalld with nftables
sudo systemctl disable --now firewalld
sudo systemctl enable nftables --now

# radvd is started by keepalived's notify script on transition to MASTER, not at boot
sudo systemctl disable --now radvd

# WAN interface
sudo tee /etc/systemd/network/10-wan.network > /dev/null <<EOT
[Match]
Name=$NIC_E

[Network]
Address=$WAN_IP_V4/$WAN_PREFIX_V4
Address=$WAN_IP_V6/$WAN_PREFIX_V6
Gateway=$WAN_GATEWAY_V4
Gateway=$WAN_GATEWAY_V6
IPv6AcceptRA=no
EOT

# LAN interface
sudo tee /etc/systemd/network/20-lan.network > /dev/null <<EOT
[Match]
Name=$NIC_I

[Network]
Address=$LAN_IP_V4/$LAN_PREFIX_V4
Address=$LAN_IP_V6/$LAN_PREFIX_V6
IPv6AcceptRA=no
EOT

# Restart networking
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC_E" "$NIC_I"

# DNS resolution goes to internal resolvers
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
nameserver fd00:10::53
nameserver fd00:10::54
EOT

# Firewall Config
sudo tee /etc/sysconfig/nftables.conf > /dev/null <<EOT
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$NIC_E" masquerade
    }

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "$NIC_E" ip daddr $WAN_VIP_V4 tcp dport { 80, 443 } dnat to 10.0.0.60
    }
}

table ip6 nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$NIC_E" masquerade
    }

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "$NIC_E" ip6 daddr $WAN_VIP_V6 tcp dport { 80, 443 } dnat to fd00:10::60
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

        # ICMPv4
        ip protocol icmp accept

        # ICMPv6
        meta l4proto ipv6-icmp accept

        # VRRP is used by keepalived
        meta l4proto vrrp iifname "$NIC_I" accept
        meta l4proto vrrp iifname "$NIC_E" ip saddr $MASTER_FIREWALL_WAN_IP_V4 accept
        meta l4proto vrrp iifname "$NIC_E" ip6 saddr $MASTER_FIREWALL_WAN_IP_V6 accept

        # For conntrackd to sync both firewalls
        iifname "$NIC_I" tcp dport 3780 accept
        iifname "$NIC_I" udp dport 3780 accept

        # SSH only from the management range and LAN NIC
        iifname "$NIC_I" ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 ct state new accept
        iifname "$NIC_I" ip6 saddr fd00:10::20-fd00:10::29 tcp dport 22 ct state new accept

        # For node exporter
        ip saddr 10.0.0.0/24 tcp dport 9100 accept
        ip6 saddr fd00:10::/64 tcp dport 9100 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # Established/related connections
        ct state established,related accept

        # Drop invalid packets
        ct state invalid drop

        # ICMPv4
        ip protocol icmp accept
        
        # ICMPv6
        meta l4proto ipv6-icmp accept

        iifname "$NIC_E" oifname "$NIC_I" ip daddr 10.0.0.60 tcp dport { 80, 443 } accept
        iifname "$NIC_E" oifname "$NIC_I" ip6 daddr fd00:10::60 tcp dport { 80, 443 } accept

        iifname "$NIC_I" oifname "$NIC_E" tcp dport { 80, 443 } ct state new accept

        iifname "$NIC_I" oifname "$NIC_E" udp dport 53 accept
        iifname "$NIC_I" oifname "$NIC_E" tcp dport 53 accept

        iifname "$NIC_I" oifname "$NIC_E" ip saddr { 10.0.0.5, 10.0.0.6 } udp dport 123 accept
        iifname "$NIC_I" oifname "$NIC_E" ip6 saddr { fd00:10::5, fd00:10::6 } udp dport 123 accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOT

sudo nft -f /etc/sysconfig/nftables.conf
sudo nft list ruleset
sudo systemctl restart nftables

# Attach the firewall to a virtual IP
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<EOT
global_defs {
    router_id FIREWALL_2
    script_user root
    enable_script_security
}

vrrp_script chk_wan_ipv4 {
    script "/usr/bin/ping -c1 -W1 8.8.8.8"
    interval 2
    weight -60
    fall 2
    rise 2
}

vrrp_script chk_wan_ipv6 {
    script "/usr/bin/ping -c1 -W1 2001:4860:4860::8888"
    interval 2
    weight -60
    fall 2
    rise 2
}

vrrp_sync_group VG_FIREWALL {
    group {
        VI_1
        VI_2
        VI_3
        VI_4
    }

    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault  "/etc/keepalived/notify.sh fault"
}

# IPv4 LAN VIP
vrrp_instance VI_1 {
    state BACKUP
    interface $NIC_I
    virtual_router_id 100
    priority 100
    advert_int 1
    preempt_delay 3

    authentication {
        auth_type PASS
        auth_pass $VRRP_AUTH_PASS
    }

    virtual_ipaddress {
        $LAN_VIP_V4/$LAN_PREFIX_V4
    }

    track_interface {
        $NIC_E
        $NIC_I
    }

    track_script {
        chk_wan_ipv4
    }
}

# IPv4 WAN VIP
vrrp_instance VI_2 {
    state BACKUP
    interface $NIC_E
    virtual_router_id 200
    priority 100
    advert_int 1
    preempt_delay 3

    authentication {
        auth_type PASS
        auth_pass $VRRP_AUTH_PASS
    }

    virtual_ipaddress {
        $WAN_VIP_V4/$WAN_PREFIX_V4
    }

    track_interface {
        $NIC_E
        $NIC_I
    }

    track_script {
        chk_wan_ipv4
    }
}

# IPv6 LAN VIP
vrrp_instance VI_3 {
    state BACKUP
    interface $NIC_I
    virtual_router_id 101
    priority 100
    advert_int 1
    preempt_delay 3

    virtual_ipaddress {
        $LAN_VIP_V6/$LAN_PREFIX_V6
    }

    track_interface {
        $NIC_E
        $NIC_I
    }

    track_script {
        chk_wan_ipv6
    }
}

# IPv6 WAN VIP
vrrp_instance VI_4 {
    state BACKUP
    interface $NIC_E
    virtual_router_id 201
    priority 100
    advert_int 1
    preempt_delay 3

    virtual_ipaddress {
        $WAN_VIP_V6/$WAN_PREFIX_V6
    }

    track_interface {
        $NIC_E
        $NIC_I
    }

    track_script {
        chk_wan_ipv6
    }
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
            TCP
        }
        Address Ignore {
            IPv4_address 127.0.0.1
            IPv6_address ::1
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
        Port 3780
        Interface $NIC_I
        IPv4_address $LAN_IP_V4
        IPv4_Destination_Address $MASTER_FIREWALL_LAN_IP_V4
        SndSocketBuffer 1249280
        RcvSocketBuffer 1249280
        Checksum on
    }

    UDP {
        Port 3780
        Interface $NIC_I
        IPv6_address $LAN_IP_V6
        IPv6_Destination_Address $MASTER_FIREWALL_LAN_IP_V6
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
        systemctl start radvd
        logger "keepalived: entering MASTER, committed conntrack cache, started radvd"
        ;;
    backup)
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -f
        systemctl stop radvd
        logger "keepalived: entering BACKUP, flushed conntrack cache, stopped radvd"
        ;;
    fault)
        $CONNTRACKD_BIN -C $CONNTRACKD_CONFIG -f
        systemctl stop radvd
        logger "keepalived: entering FAULT, flushed conntrack cache, stopped radvd"
        ;;
esac
EOT

sudo chmod +x /etc/keepalived/notify.sh
sudo chown root:root /etc/keepalived/notify.sh
sudo restorecon -v /etc/keepalived/notify.sh

# Make sure conntrackd is up before keepalived
sudo mkdir -p /etc/systemd/system/keepalived.service.d
sudo tee /etc/systemd/system/keepalived.service.d/override.conf > /dev/null <<EOT
[Unit]
After=conntrackd.service
Wants=conntrackd.service
EOT

# Configure conntrackd service priority
sudo mkdir -p /etc/systemd/system/conntrackd.service.d
sudo tee /etc/systemd/system/conntrackd.service.d/priority.conf > /dev/null <<EOF
[Service]
Nice=-10
EOF

# Setup RA for IPv6
sudo tee /etc/radvd.conf > /dev/null <<EOT
interface $NIC_I {
    AdvSendAdvert on;
    AdvManagedFlag on;
    AdvOtherConfigFlag on;
    MinRtrAdvInterval 5;
    MaxRtrAdvInterval 20;

    prefix $LAN_PREFIX_NET_V6::/$LAN_PREFIX_V6 {
        AdvOnLink on;
        AdvAutonomous off;
    };
};
EOT

sudo systemctl enable sshd --now
sudo systemctl daemon-reload
sudo systemctl enable --now conntrackd
sudo systemctl enable --now keepalived