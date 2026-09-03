#!/bin/bash
# Rocky Linux 10.2
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FQDN=dns-1.lab.internal

NIC=ens34

LAN_IP_V4=10.0.0.7
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::7
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

ZONE_SERIAL=2026090201

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
    ensure_packages bind bind-utils nftables openssh-server git systemd-networkd
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

configure_tsig_key() {
    sudo mkdir -p /etc/named
    if [ ! -s /etc/named/tsig-xfer.key ]; then
        sudo tsig-keygen -a hmac-sha256 xfer-key | sudo tee /etc/named/tsig-xfer.key > /dev/null
    fi
    sudo chown root:named /etc/named/tsig-xfer.key
    sudo chmod 640 /etc/named/tsig-xfer.key
}

configure_named_options() {
    NAMED_CHANGED=0

    write_file_if_changed /etc/named.conf 0644 root:named <<EOT && NAMED_CHANGED=1
include "/etc/named/named.conf.options";
include "/etc/named/named.conf.local";
EOT

    write_file_if_changed /etc/named/named.conf.options 0644 root:named <<EOT && NAMED_CHANGED=1
options {
    directory "/var/named";
    recursion no;
    allow-query { localhost; 10.0.0.0/24; fd00:10::/64; };
    listen-on { any; };
    listen-on-v6 { any; };
    allow-transfer { none; };
    dnssec-validation auto;
    version "not disclosed";
};
EOT

    write_file_if_changed /etc/named/named.conf.local 0644 root:named <<EOT && NAMED_CHANGED=1
include "/etc/named/tsig-xfer.key";

zone "lab.internal" {
    type primary;
    file "/var/named/db.lab.internal";
    allow-update { none; };
    allow-transfer { key xfer-key; };
    notify yes;
};

zone "0.0.10.in-addr.arpa" {
    type primary;
    file "/var/named/db.10.0.0";
    allow-update { none; };
    allow-transfer { key xfer-key; };
    notify yes;
};

zone "0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa" {
    type primary;
    file "/var/named/db.fd00.10";
    allow-update { none; };
    allow-transfer { key xfer-key; };
    notify yes;
};

server 10.0.0.8 {
    keys { xfer-key; };
};

server fd00:10::8 {
    keys { xfer-key; };
};
EOT
}

configure_zones() {
    ZONE_DATA_CHANGED=0

    write_file_if_changed /var/named/db.lab.internal 0644 root:named <<EOT && ZONE_DATA_CHANGED=1
\$TTL    3600
@       IN      SOA     ns-1.lab.internal. dns-admin.lab.internal. (
                             $ZONE_SERIAL  ; Serial YYYYMMDDnn
                                   3600    ; Refresh (1 hour)
                                    900    ; Retry (15 min)
                                 604800    ; Expire (1 week)
                                   3600 )  ; Negative cache TTL (1 hour)

; Server records
@       IN      NS      ns-1.lab.internal.
@       IN      NS      ns-2.lab.internal.

; 10.0.0.1 / fd00:10::1 is reserved for the firewall virtual IP

; Firewall, firewall VIP is 1
firewall     IN      A       10.0.0.1
firewall     IN      AAAA    fd00:10::1
firewall-1    IN      A       10.0.0.2
firewall-1    IN      AAAA    fd00:10::2
firewall-2    IN      A       10.0.0.3
firewall-2    IN      AAAA    fd00:10::3

; DHCP
dhcp      IN      A       10.0.0.4
dhcp      IN      AAAA    fd00:10::4

; IPA
ipa-1        IN      A       10.0.0.5
ipa-1        IN      AAAA    fd00:10::5
ipa-2        IN      A       10.0.0.6
ipa-2        IN      AAAA    fd00:10::6
ipa-ca      IN      A       10.0.0.5
ipa-ca      IN      A       10.0.0.6
ipa-ca      IN      AAAA    fd00:10::5
ipa-ca      IN      AAAA    fd00:10::6

; Kerberos/LDAP service discovery
_kerberos-master._tcp.lab.internal. IN SRV 0 100 88  ipa-1.lab.internal.
_kerberos-master._udp.lab.internal. IN SRV 0 100 88  ipa-1.lab.internal.
_kerberos._tcp.lab.internal.        IN SRV 0 100 88  ipa-1.lab.internal.
_kerberos._tcp.lab.internal.        IN SRV 0 100 88  ipa-2.lab.internal.
_kerberos._udp.lab.internal.        IN SRV 0 100 88  ipa-1.lab.internal.
_kerberos._udp.lab.internal.        IN SRV 0 100 88  ipa-2.lab.internal.
_kpasswd._tcp.lab.internal.         IN SRV 0 100 464 ipa-1.lab.internal.
_kpasswd._tcp.lab.internal.         IN SRV 0 100 464 ipa-2.lab.internal.
_kpasswd._udp.lab.internal.         IN SRV 0 100 464 ipa-1.lab.internal.
_kpasswd._udp.lab.internal.         IN SRV 0 100 464 ipa-2.lab.internal.
_ldap._tcp.lab.internal.            IN SRV 0 100 389 ipa-1.lab.internal.
_ldap._tcp.lab.internal.            IN SRV 0 100 389 ipa-2.lab.internal.
_kerberos.lab.internal.             IN TXT "LAB.INTERNAL"

; Authoritative DNS
dns-1        IN      A       10.0.0.7
dns-1        IN      AAAA    fd00:10::7
ns-1         IN      A       10.0.0.7
ns-1         IN      AAAA    fd00:10::7
dns-2        IN      A       10.0.0.8
dns-2        IN      AAAA    fd00:10::8
ns-2         IN      A       10.0.0.8
ns-2         IN      AAAA    fd00:10::8

; HashiCorp Vault, vault VIP is 9
vault       IN      A       10.0.0.9
vault       IN      AAAA    fd00:10::9
vault-1      IN      A       10.0.0.10
vault-1      IN      AAAA    fd00:10::10
vault-2      IN      A       10.0.0.11
vault-2      IN      AAAA    fd00:10::11

; Management
admin-1       IN      A       10.0.0.20
admin-1       IN      AAAA    fd00:10::20

; Logs, analytics
logs        IN      A       10.0.0.30
logs        IN      AAAA    fd00:10::30
analytics   IN      A       10.0.0.31
analytics   IN      AAAA    fd00:10::31

; Database, db VIP is 40
db           IN      A       10.0.0.40
db           IN      AAAA    fd00:10::40
db-proxy-1    IN      A       10.0.0.41
db-proxy-1    IN      AAAA    fd00:10::41
db-proxy-2    IN      A       10.0.0.42
db-proxy-2    IN      AAAA    fd00:10::42
db-1          IN      A       10.0.0.43
db-1          IN      AAAA    fd00:10::43
db-2          IN      A       10.0.0.44
db-2          IN      AAAA    fd00:10::44
db-backup-1   IN      A       10.0.0.45
db-backup-1   IN      AAAA    fd00:10::45
db-backup-2   IN      A       10.0.0.46
db-backup-2   IN      AAAA    fd00:10::46

; Recursive DNS resolver
dns-rslv-1    IN      A       10.0.0.53
dns-rslv-1    IN      AAAA    fd00:10::53
dns-rslv-2    IN      A       10.0.0.54
dns-rslv-2    IN      AAAA    fd00:10::54

; Reverse Proxy
proxy       IN      A       10.0.0.60
proxy       IN      AAAA    fd00:10::60

; Apps
app-1         IN      A       10.0.0.70
app-1         IN      AAAA    fd00:10::70
EOT

    write_file_if_changed /var/named/db.10.0.0 0644 root:named <<EOT && ZONE_DATA_CHANGED=1
\$TTL    3600
@       IN      SOA     ns-1.lab.internal. dns-admin.lab.internal. (
                             $ZONE_SERIAL  ; Serial YYYYMMDDnn
                                   3600    ; Refresh (1 hour)
                                    900    ; Retry (15 min)
                                 604800    ; Expire (1 week)
                                   3600 )  ; Negative cache TTL (1 hour)

; Server records
@       IN      NS      ns-1.lab.internal.
@       IN      NS      ns-2.lab.internal.

; Firewall, firewall VIP is 1
1       IN      PTR     firewall.lab.internal.
2       IN      PTR     firewall-1.lab.internal.
3       IN      PTR     firewall-2.lab.internal.

; DHCP
4       IN      PTR     dhcp.lab.internal.

; IPA
5       IN      PTR     ipa-1.lab.internal.
6       IN      PTR     ipa-2.lab.internal.

; Authoritative DNS
7      IN      PTR     dns-1.lab.internal.
7      IN      PTR     ns-1.lab.internal.
8      IN      PTR     dns-2.lab.internal.
8      IN      PTR     ns-2.lab.internal.

; HashiCorp Vault, vault VIP is 9
9       IN      PTR     vault.lab.internal.
10      IN      PTR     vault-1.lab.internal.
11      IN      PTR     vault-2.lab.internal.

; Management
20      IN      PTR     admin-1.lab.internal.

; Logs, analytics
30      IN      PTR     logs.lab.internal.
31      IN      PTR     analytics.lab.internal.

; Database, db VIP is 40
40      IN      PTR     db.lab.internal.
41      IN      PTR     db-proxy-1.lab.internal.
42      IN      PTR     db-proxy-2.lab.internal.
43      IN      PTR     db-1.lab.internal.
44      IN      PTR     db-2.lab.internal.
45      IN      PTR     db-backup-1.lab.internal.
46      IN      PTR     db-backup-2.lab.internal.

; Recursive DNS resolver
53      IN      PTR     dns-rslv-1.lab.internal.
54      IN      PTR     dns-rslv-2.lab.internal.

; Reverse Proxy
60      IN      PTR     proxy.lab.internal.

; Apps
70      IN      PTR     app-1.lab.internal.
EOT

    write_file_if_changed /var/named/db.fd00.10 0644 root:named <<EOT && ZONE_DATA_CHANGED=1
\$TTL    3600
@       IN      SOA     ns-1.lab.internal. dns-admin.lab.internal. (
                             $ZONE_SERIAL    ; Serial YYYYMMDDnn
                                   3600    ; Refresh (1 hour)
                                    900    ; Retry (15 min)
                                 604800    ; Expire (1 week)
                                   3600 )  ; Negative cache TTL (1 hour)

@       IN      NS      ns-1.lab.internal.
@       IN      NS      ns-2.lab.internal.

; Firewall, firewall VIP is 1
1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR firewall.lab.internal.
2.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR firewall-1.lab.internal.
3.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR firewall-2.lab.internal.

; DHCP
4.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dhcp.lab.internal.

; IPA
5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR ipa-1.lab.internal.
6.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR ipa-2.lab.internal.

; Authoritative DNS
7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dns-1.lab.internal.
7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR ns-1.lab.internal.
8.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dns-2.lab.internal.
8.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR ns-2.lab.internal.

; HashiCorp Vault, vault VIP is 9
9.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR vault.lab.internal.
0.1.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR vault-1.lab.internal.
1.1.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR vault-2.lab.internal.

; Management
0.2.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR admin-1.lab.internal.

; Logs, analytics
0.3.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR logs.lab.internal.
1.3.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR analytics.lab.internal.

; Database, db VIP is 40
0.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR db.lab.internal.
1.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR db-proxy-1.lab.internal.
2.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR db-proxy-2.lab.internal.
3.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR db-1.lab.internal.
4.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR db-2.lab.internal.
5.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR db-backup-1.lab.internal.
6.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR db-backup-2.lab.internal.

; Recursive DNS resolver
3.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dns-rslv-1.lab.internal.
4.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dns-rslv-2.lab.internal.

; Reverse Proxy
0.6.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR proxy.lab.internal.

; Apps
0.7.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR app-1.lab.internal.
EOT

    sudo restorecon -Rv /etc/named /var/named

    sudo named-checkconf
    sudo named-checkzone lab.internal /var/named/db.lab.internal
    sudo named-checkzone 0.0.10.in-addr.arpa /var/named/db.10.0.0
    sudo named-checkzone 0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa /var/named/db.fd00.10
}

configure_named_service() {
    configure_named_options
    configure_zones

    if ! sudo systemctl is-active --quiet named; then
        sudo systemctl enable named --now
    elif [ "${NAMED_CHANGED:-0}" -eq 1 ]; then
        sudo systemctl restart named
    elif [ "${ZONE_DATA_CHANGED:-0}" -eq 1 ]; then
        sudo rndc reload
    fi
    sudo systemctl enable named
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

        # DNS queries from the LAN only
        ip saddr 10.0.0.0/24 udp dport 53 accept
        ip saddr 10.0.0.0/24 tcp dport 53 accept
        ip6 saddr fd00:10::/64 udp dport 53 accept
        ip6 saddr fd00:10::/64 tcp dport 53 accept

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
    configure_tsig_key
    configure_named_service
    configure_firewall
    configure_sshd
}

dispatch main "$@"