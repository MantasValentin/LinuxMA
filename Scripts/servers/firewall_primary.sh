#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FQDN=firewall1.lab.internal

# External (WAN) and internal (LAN) interfaces
NIC_E=ens33
NIC_I=ens34

WAN_IP_V4=192.168.0.3
WAN_VIP_V4=192.168.0.2
WAN_GATEWAY_V4=192.168.0.1
WAN_PREFIX_V4=24
PEER_WAN_IP_V4=192.168.0.4

WAN_IP_V6=fd00:192:168::3
WAN_VIP_V6=fd00:192:168::2
WAN_GATEWAY_V6=fd00:192:168::1
WAN_PREFIX_V6=64
PEER_WAN_IP_V6=fd00:192:168::4

LAN_IP_V4=10.0.0.2
LAN_VIP_V4=10.0.0.1
LAN_PREFIX_V4=24
PEER_LAN_IP_V4=10.0.0.3

LAN_IP_V6=fd00:10::2
LAN_VIP_V6=fd00:10::1
LAN_PREFIX_V6=64
LAN_PREFIX_NET_V6=fd00:10
PEER_LAN_IP_V6=fd00:10::3

# Shared secret for keepalived VRRP auth
# identical between firewall_primary.sh and firewall_secondary.sh
VRRP_AUTH_PASS="VRRP_Secret"

configure_hostname() {
    ensure_hostname $FQDN
}

configure_packages() {
    sudo dnf upgrade -y
    ensure_packages epel-release
    ensure_packages openssh-server git nftables keepalived conntrack-tools radvd systemd-networkd
}

configure_sysctl() {
    write_file_if_changed /etc/sysctl.d/99-firewall.conf 0644 root:root <<EOT
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# Mitigates ip spoofing by checking if the source ip comes from the correct NIC
# Prevents WAN connections from pretending to be coming from LAN admin servers
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

# Don't answer/accept ICMP redirects
# Prevents external changes to the firewall's routing table
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
    sudo sysctl --system > /dev/null
}

configure_network() {
    local is_using_networkmanager
    is_using_networkmanager=$(switch_to_systemd_networkd)
    switch_to_nftables

    # radvd is started by keepalived's notify script
    sudo systemctl disable --now radvd 2>/dev/null || true

    if [ "$is_using_networkmanager" = "1" ]; then
        sudo ip addr flush dev "$NIC_E" 2>/dev/null || true
        sudo ip addr flush dev "$NIC_I" 2>/dev/null || true
        sudo ip route flush dev "$NIC_E" 2>/dev/null || true
        sudo ip route flush dev "$NIC_I" 2>/dev/null || true
    fi

    local wan_changed=0 lan_changed=0
    write_file_if_changed /etc/systemd/network/10-lan.network 0644 root:root <<EOT && lan_changed=0
[Match]
Name=$NIC_I

[Network]
Address=$LAN_IP_V4/$LAN_PREFIX_V4
Address=$LAN_IP_V6/$LAN_PREFIX_V6
IPv6AcceptRA=no
EOT

    write_file_if_changed /etc/systemd/network/20-wan.network 0644 root:root <<EOT && wan_changed=0
[Match]
Name=$NIC_E

[Network]
Address=$WAN_IP_V4/$WAN_PREFIX_V4
Address=$WAN_IP_V6/$WAN_PREFIX_V6
Gateway=$WAN_GATEWAY_V4
Gateway=$WAN_GATEWAY_V6
IPv6AcceptRA=no
EOT

    if [ "$wan_changed" -eq 1 ] || [ "$lan_changed" -eq 1 ]; then
        sudo networkctl reload
        sudo networkctl reconfigure "$NIC_E" "$NIC_I"
    fi
}

configure_resolver() {
    apply_resolv_conf <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
nameserver fd00:10::53
nameserver fd00:10::54
EOT
}

configure_firewall() {
    apply_nftables_ruleset <<EOT
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
        meta l4proto vrrp iifname "$NIC_I" ip saddr $PEER_LAN_IP_V4 accept
        meta l4proto vrrp iifname "$NIC_I" ip6 saddr $PEER_LAN_IP_V6 accept
        meta l4proto vrrp iifname "$NIC_E" ip saddr $PEER_WAN_IP_V4 accept
        meta l4proto vrrp iifname "$NIC_E" ip6 saddr $PEER_WAN_IP_V6 accept

        # For conntrackd to sync both firewalls
        iifname "$NIC_I" tcp dport 3780 accept
        iifname "$NIC_I" udp dport 3780 accept

        # SSH only from the management range and LAN NIC
        iifname "$NIC_I" ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 ct state new accept
        iifname "$NIC_I" ip6 saddr fd00:10::20-fd00:10::29 tcp dport 22 ct state new accept

        # For node exporter from analytics server 10.0.0.31 / fd00:10::31
        ip saddr 10.0.0.31/24 tcp dport 9100 accept
        ip6 saddr fd00:10::31/64 tcp dport 9100 accept
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
}

configure_keepalived() {
    if write_file_if_changed /etc/keepalived/keepalived.conf 0644 root:root <<EOT
global_defs {
    router_id FIREWALL_1
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
    state MASTER
    interface $NIC_E
    virtual_router_id 200
    priority 150
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
    state MASTER
    interface $NIC_I
    virtual_router_id 101
    priority 150
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
    state MASTER
    interface $NIC_E
    virtual_router_id 201
    priority 150
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
    then
        sudo systemctl restart keepalived
    else
        if ! sudo systemctl is-active --quiet keepalived; then
            sudo systemctl enable --now keepalived
        fi
    fi
    sudo systemctl enable keepalived
}

configure_conntrackd() {
    sudo modprobe nf_conntrack
    sudo modprobe nf_conntrack_netlink
    write_file_if_changed /etc/modules-load.d/conntrack.conf 0644 root:root <<EOT
nf_conntrack
nf_conntrack_netlink
EOT

    sudo sysctl -w net.netfilter.nf_conntrack_max=1048576 > /dev/null
    write_file_if_changed /etc/sysctl.d/99-conntrack.conf 0644 root:root <<EOT
net.netfilter.nf_conntrack_max = 1048576
EOT
    sudo sysctl -p /etc/sysctl.d/99-conntrack.conf > /dev/null

    local changed=0
    write_file_if_changed /etc/conntrackd/conntrackd.conf 0644 root:root <<EOT && changed=0
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
        IPv4_Destination_Address $PEER_LAN_IP_V4
        SndSocketBuffer 1249280
        RcvSocketBuffer 1249280
        Checksum on
    }

    UDP {
        Port 3780
        Interface $NIC_I
        IPv6_address $LAN_IP_V6
        IPv6_Destination_Address $PEER_LAN_IP_V6
        SndSocketBuffer 1249280
        RcvSocketBuffer 1249280
        Checksum on
    }
}
EOT

    write_file_if_changed /etc/keepalived/notify.sh 0755 root:root <<'EOT'
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
    sudo restorecon -v /etc/keepalived/notify.sh > /dev/null

    sudo mkdir -p /etc/systemd/system/keepalived.service.d
    write_file_if_changed /etc/systemd/system/keepalived.service.d/override.conf 0644 root:root <<EOT || true
[Unit]
After=conntrackd.service
Wants=conntrackd.service
EOT

    sudo mkdir -p /etc/systemd/system/conntrackd.service.d
    write_file_if_changed /etc/systemd/system/conntrackd.service.d/priority.conf 0644 root:root <<EOT || true
[Service]
Nice=-10
EOT

    sudo systemctl daemon-reload

    if ! sudo systemctl is-active --quiet conntrackd; then
        sudo systemctl enable --now conntrackd
    elif [ "$changed" -eq 1 ]; then
        sudo systemctl restart conntrackd
    fi
    sudo systemctl enable conntrackd
}

configure_radvd() {
    # keepalived's notify.sh starts/stops radvd on MASTER/BACKUP transitions
    write_file_if_changed /etc/radvd.conf 0644 root:root <<EOT
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
    sudo systemctl disable --now radvd 2>/dev/null || true
}

configure_sshd() {
    sudo systemctl enable sshd --now
}

main() {
    configure_hostname
    configure_packages
    configure_sysctl
    configure_network
    configure_resolver
    configure_firewall
    configure_conntrackd
    configure_radvd
    configure_keepalived
    configure_sshd
}

dispatch main "$@"