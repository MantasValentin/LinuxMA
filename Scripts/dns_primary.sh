#!/bin/bash
set -euo pipefail

# Rocky Linux 10.2

# Interface
NIC=ens34
LAN_IP_V4=10.0.0.7
LAN_PREFIX_V4=24
GATEWAY_V4=10.0.0.1

LAN_IP_V6=fd00:10::7
LAN_PREFIX_V6=64
GATEWAY_V6=fd00:10::1

# Temporary bootstrap networking before pulling this script to run it
# sudo ip link set "$NIC" up
# sudo ip addr add 10.0.0.250/24 dev "$NIC"
# sudo ip route add default via 10.0.0.1
# echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null

# Set hostname
sudo hostnamectl set-hostname "dns1.lab.internal"

# Update and upgrade
sudo dnf upgrade -y

# bind             - the DNS server itself
# bind-utils       - dig / nslookup / named-checkconf / named-checkzone / tsig-keygen
# nftables         - firewall
# openssh-server   - remote management
# git              - pulling config from your repo
# systemd-networkd - networking
sudo dnf install -y epel-release
sudo dnf install -y bind bind-utils nftables openssh-server git systemd-networkd

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

# Use to generate a TSIG key for DNS authentication between primary and secondary dns servers
sudo mkdir -p /etc/named
sudo tsig-keygen -a hmac-sha256 xfer-key | sudo tee /etc/named/tsig-xfer.key

# Lock access to the key
sudo chown root:named /etc/named/tsig-xfer.key
sudo chmod 640 /etc/named/tsig-xfer.key

# Top-level config just pulls in the split files below
sudo tee /etc/named.conf > /dev/null <<EOT
include "/etc/named/named.conf.options";
include "/etc/named/named.conf.local";
EOT

# Deploy the config
sudo tee /etc/named/named.conf.options > /dev/null <<EOT
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

sudo tee /etc/named/named.conf.local > /dev/null <<EOT
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

sudo tee /var/named/db.lab.internal > /dev/null <<'EOT'
$TTL    3600
@       IN      SOA     ns1.lab.internal. dns-admin.lab.internal. (
                             2026080601    ; Serial YYYYMMDDnn
                                   3600    ; Refresh (1 hour)
                                    900    ; Retry (15 min)
                                 604800    ; Expire (1 week)
                                   3600 )  ; Negative cache TTL (1 hour)

; Server records
@       IN      NS      ns1.lab.internal.
@       IN      NS      ns2.lab.internal.

; 10.0.0.1 / fd00:10::1 is reserved for a virtual IP

; Firewall
firewall1    IN      A       10.0.0.2
firewall1    IN      AAAA    fd00:10::2
firewall2    IN      A       10.0.0.3
firewall2    IN      AAAA    fd00:10::3

; DHCP
dhcp      IN      A       10.0.0.4
dhcp      IN      AAAA    fd00:10::4

; IPA
ipa1        IN      A       10.0.0.5
ipa1        IN      AAAA    fd00:10::5
ipa2        IN      A       10.0.0.6
ipa2        IN      AAAA    fd00:10::6
ipa-ca      IN      A       10.0.0.5
ipa-ca      IN      A       10.0.0.6
ipa-ca      IN      AAAA    fd00:10::5
ipa-ca      IN      AAAA    fd00:10::6

; Kerberos/LDAP service discovery
_kerberos-master._tcp.lab.internal. IN SRV 0 100 88  ipa1.lab.internal.
_kerberos-master._udp.lab.internal. IN SRV 0 100 88  ipa1.lab.internal.
_kerberos._tcp.lab.internal.        IN SRV 0 100 88  ipa1.lab.internal.
_kerberos._tcp.lab.internal.        IN SRV 0 100 88  ipa2.lab.internal.
_kerberos._udp.lab.internal.        IN SRV 0 100 88  ipa1.lab.internal.
_kerberos._udp.lab.internal.        IN SRV 0 100 88  ipa2.lab.internal.
_kpasswd._tcp.lab.internal.         IN SRV 0 100 464 ipa1.lab.internal.
_kpasswd._tcp.lab.internal.         IN SRV 0 100 464 ipa2.lab.internal.
_kpasswd._udp.lab.internal.         IN SRV 0 100 464 ipa1.lab.internal.
_kpasswd._udp.lab.internal.         IN SRV 0 100 464 ipa2.lab.internal.
_ldap._tcp.lab.internal.            IN SRV 0 100 389 ipa1.lab.internal.
_ldap._tcp.lab.internal.            IN SRV 0 100 389 ipa2.lab.internal.
_kerberos.lab.internal.             IN TXT "LAB.INTERNAL"

; Authoritative DNS
dns1        IN      A       10.0.0.7
dns1        IN      AAAA    fd00:10::7
ns1         IN      A       10.0.0.7
ns1         IN      AAAA    fd00:10::7
dns2        IN      A       10.0.0.8
dns2        IN      AAAA    fd00:10::8
ns2         IN      A       10.0.0.8
ns2         IN      AAAA    fd00:10::8

; Management
admin       IN      A       10.0.0.20
admin       IN      AAAA    fd00:10::20

; Logs, analytics
logs        IN      A       10.0.0.30
logs        IN      AAAA    fd00:10::30
analytics   IN      A       10.0.0.31
analytics   IN      AAAA    fd00:10::31

; Database
db1          IN      A       10.0.0.40
db1          IN      AAAA    fd00:10::40
db2          IN      A       10.0.0.41
db2          IN      AAAA    fd00:10::41

; Recursive DNS resolver
dns-rslv1    IN      A       10.0.0.53
dns-rslv1    IN      AAAA    fd00:10::53
dns-rslv2    IN      A       10.0.0.54
dns-rslv2    IN      AAAA    fd00:10::54

; Reverse Proxy
proxy       IN      A       10.0.0.60
proxy       IN      AAAA    fd00:10::60

; Apps
app1         IN      A       10.0.0.70
app1         IN      AAAA    fd00:10::70
EOT

sudo tee /var/named/db.10.0.0 > /dev/null <<'EOT'
$TTL    3600
@       IN      SOA     ns1.lab.internal. dns-admin.lab.internal. (
                             2026080601    ; Serial YYYYMMDDnn
                                   3600    ; Refresh (1 hour)
                                    900    ; Retry (15 min)
                                 604800    ; Expire (1 week)
                                   3600 )  ; Negative cache TTL (1 hour)

; Server records
@       IN      NS      ns1.lab.internal.
@       IN      NS      ns2.lab.internal.

; Firewall
2       IN      PTR     firewall1.lab.internal.
3       IN      PTR     firewall2.lab.internal.

; DHCP
4       IN      PTR     dhcp.lab.internal.

; IPA
5       IN      PTR     ipa1.lab.internal.
6       IN      PTR     ipa2.lab.internal.

; Authoritative DNS
7      IN      PTR     dns1.lab.internal.
7      IN      PTR     ns1.lab.internal.
8      IN      PTR     dns2.lab.internal.
8      IN      PTR     ns2.lab.internal.

; Management
20      IN      PTR     admin.lab.internal.

; Logs, analytics
30      IN      PTR     logs.lab.internal.
31      IN      PTR     analytics.lab.internal.

; Database
40      IN      PTR     db1.lab.internal.
41      IN      PTR     db2.lab.internal.

; Recursive DNS resolver
53      IN      PTR     dns-rslv1.lab.internal.
54      IN      PTR     dns-rslv2.lab.internal.

; Reverse Proxy
60      IN      PTR     proxy.lab.internal.

; Apps
70      IN      PTR     app1.lab.internal.
EOT

sudo tee /var/named/db.fd00.10 > /dev/null <<'EOT'
$TTL    3600
@       IN      SOA     ns1.lab.internal. dns-admin.lab.internal. (
                             2026080601    ; Serial YYYYMMDDnn
                                   3600    ; Refresh (1 hour)
                                    900    ; Retry (15 min)
                                 604800    ; Expire (1 week)
                                   3600 )  ; Negative cache TTL (1 hour)

@       IN      NS      ns1.lab.internal.
@       IN      NS      ns2.lab.internal.

; Firewall
2.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR firewall1.lab.internal.
3.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR firewall2.lab.internal.

; DHCP
4.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dhcp.lab.internal.

; IPA
5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR ipa1.lab.internal.
6.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR ipa2.lab.internal.

; Authoritative DNS
7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dns1.lab.internal.
7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR ns1.lab.internal.
8.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dns2.lab.internal.
8.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR ns2.lab.internal.

; Management
0.2.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR admin.lab.internal.

; Logs, analytics
0.3.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR logs.lab.internal.
1.3.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR analytics.lab.internal.

; Database
0.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR db1.lab.internal.
1.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR db2.lab.internal.

; Recursive DNS resolver
3.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dns-rslv1.lab.internal.
4.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR dns-rslv2.lab.internal.

; Reverse Proxy
0.6.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR proxy.lab.internal.

; Apps
0.7.0.0.0.0.0.0.0.0.0.0.0.0.0.0     IN PTR app1.lab.internal.
EOT

sudo chown root:named /var/named/db.lab.internal /var/named/db.10.0.0 /var/named/db.fd00.10
sudo chmod 644 /var/named/db.lab.internal /var/named/db.10.0.0 /var/named/db.fd00.10


# Reset SELinux labels
sudo restorecon -Rv /etc/named /var/named

# Validate syntax and zones before restarting
sudo named-checkconf
sudo named-checkzone lab.internal /var/named/db.lab.internal
sudo named-checkzone 0.0.10.in-addr.arpa /var/named/db.10.0.0
sudo named-checkzone 0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa /var/named/db.fd00.10

sudo systemctl enable named
sudo systemctl restart named

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

        # DNS queries from the LAN only
        ip saddr 10.0.0.0/24 udp dport 53 accept
        ip saddr 10.0.0.0/24 tcp dport 53 accept
        ip6 saddr fd00:10::/64 udp dport 53 accept
        ip6 saddr fd00:10::/64 tcp dport 53 accept

        # For node exporter
        ip saddr 10.0.0.31 tcp dport 9100 accept
        ip6 saddr fd00::31 tcp dport 9100 accept
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