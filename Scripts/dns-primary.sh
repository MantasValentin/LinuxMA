# Interface
NIC=ens34

# Set hostname
sudo hostnamectl set-hostname "dns1"

# Update and upgrade
sudo apt update && sudo apt upgrade -y

# bind9           - the DNS server itself
# bind9utils      - named-checkconf / named-checkzone / rndc tools
# bind9-doc       - documentation
# dnsutils        - dig / nslookup for testing
# nftables        - firewall
# openssh-server  - remote management
# git             - pulling config from your repo
sudo apt install -y bind9 bind9utils bind9-doc dnsutils nftables openssh-server git

sudo systemctl enable nftables --now
sudo systemctl enable ssh --now


# systemd-resolved isn't needed, bind9 serves the zone directly
sudo systemctl disable --now systemd-resolved

# LAN interface
sudo tee /etc/systemd/network/10-lan.network > /dev/null <<EOT
[Match]
Name=$NIC

[Network]
Address=10.0.0.6/24
Gateway=10.0.0.1
DNS=10.0.0.53 10.0.0.54
EOT

sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
EOT

# Use to generate a TSIG key for DNS authentication between primary and secondary dns servers
sudo tsig-keygen -a hmac-sha256 xfer-key | sudo tee /etc/bind/tsig-xfer.key

# Lock access to the key
sudo chown root:bind /etc/bind/tsig-xfer.key
sudo chmod 640 /etc/bind/tsig-xfer.key

# Deploy the config 
sudo tee /etc/bind/named.conf.options > /dev/null <<'EOT'
options {
    directory "/var/cache/bind";
    recursion no;
    allow-query { localhost; 10.0.0.0/24; };
    listen-on { any; };
    listen-on-v6 { none; };   // Disable IPv6 since the lab is IPv4-only
    allow-transfer { none; };
    dnssec-validation auto;
    version "not disclosed";
};
EOT

sudo tee /etc/bind/named.conf.local > /dev/null <<'EOT'
include "/etc/bind/tsig-xfer.key";

zone "lab.local" {
    type primary;
    file "/etc/bind/db.lab.local";
    allow-update { none; };
    allow-transfer { key xfer-key; };
    notify yes;
};

zone "0.0.10.in-addr.arpa" {
    type primary;
    file "/etc/bind/db.10.0.0";
    allow-update { none; };
    allow-transfer { key xfer-key; };
    notify yes;
};

server 10.0.0.7 {
    keys { xfer-key; };
};
EOT

sudo tee /etc/bind/db.lab.local > /dev/null <<'EOT'
$TTL    3600
@       IN      SOA     ns1.lab.local. dns-admin.lab.local. (
                             2026072601    ; Serial YYYYMMDDnn
                                   3600    ; Refresh (1 hour)
                                    900    ; Retry (15 min)
                                 604800    ; Expire (1 week)
                                   3600 )  ; Negative cache TTL (1 hour)

; Server records
@       IN      NS      ns1.lab.local.
@       IN      NS      ns2.lab.local.

; Firewall
firewall1    IN      A       10.0.0.1
firewall2    IN      A       10.0.0.2

; DHCP
dhcp      IN      A       10.0.0.3

; IPA
ipa1        IN      A       10.0.0.4
ipa2        IN      A       10.0.0.5

; Kerberos/LDAP service discovery
_kerberos-master._tcp.lab.local. IN SRV 0 100 88  ipa1.lab.local.
_kerberos-master._udp.lab.local. IN SRV 0 100 88  ipa1.lab.local.
_kerberos._tcp.lab.local.        IN SRV 0 100 88  ipa1.lab.local.
_kerberos._tcp.lab.local.        IN SRV 0 100 88  ipa2.lab.local.
_kerberos._udp.lab.local.        IN SRV 0 100 88  ipa1.lab.local.
_kerberos._udp.lab.local.        IN SRV 0 100 88  ipa2.lab.local.
_kpasswd._tcp.lab.local.         IN SRV 0 100 464 ipa1.lab.local.
_kpasswd._tcp.lab.local.         IN SRV 0 100 464 ipa2.lab.local.
_kpasswd._udp.lab.local.         IN SRV 0 100 464 ipa1.lab.local.
_kpasswd._udp.lab.local.         IN SRV 0 100 464 ipa2.lab.local.
_ldap._tcp.lab.local.            IN SRV 0 100 389 ipa1.lab.local.
_ldap._tcp.lab.local.            IN SRV 0 100 389 ipa2.lab.local.
_kerberos.lab.local.             IN TXT "LAB.LOCAL"

; Authoritative DNS
dns1        IN      A       10.0.0.6
ns1         IN      A       10.0.0.6
dns2        IN      A       10.0.0.7
ns2         IN      A       10.0.0.7

; Management
admin       IN      A       10.0.0.20

; Logs, analytics
logs        IN      A       10.0.0.30
analytics   IN      A       10.0.0.31

; Database
db1          IN      A       10.0.0.40
db2          IN      A       10.0.0.41

; Recursive DNS resolver
dns-rslv1    IN      A       10.0.0.53
dns-rslv2    IN      A       10.0.0.54

; Reverse Proxy
proxy       IN      A       10.0.0.60

; Apps
app1         IN      A       10.0.0.70
EOT

sudo tee /etc/bind/db.10.0.0 > /dev/null <<'EOT'
$TTL    3600
@       IN      SOA     ns1.lab.local. dns-admin.lab.local. (
                             2026072601    ; Serial YYYYMMDDnn
                                   3600    ; Refresh (1 hour)
                                    900    ; Retry (15 min)
                                 604800    ; Expire (1 week)
                                   3600 )  ; Negative cache TTL (1 hour)

; Server records
@       IN      NS      ns1.lab.local.
@       IN      NS      ns2.lab.local.

; Firewall
1       IN      PTR     firewall1.lab.local.
2       IN      PTR     firewall2.lab.local.

; DHCP
3       IN      PTR     dhcp.lab.local.

; IPA
4       IN      PTR     ipa1.lab.local.
5       IN      PTR     ipa2.lab.local.

; Authoritative DNS
6      IN      PTR     dns1.lab.local.
6      IN      PTR     ns1.lab.local.
7      IN      PTR     dns2.lab.local.
7      IN      PTR     ns2.lab.local.

; Management
20      IN      PTR     admin.lab.local.

; Logs, analytics
30      IN      PTR     logs.lab.local.
31      IN      PTR     analytics.lab.local.

; Database
40      IN      PTR     db1.lab.local.
41      IN      PTR     db2.lab.local.

; Recursive DNS resolver
53      IN      PTR     dns-rslv1.lab.local.
54      IN      PTR     dns-rslv2.lab.local.

; Reverse Proxy
60      IN      PTR     proxy.lab.local.

; Apps
70      IN      PTR     app1.lab.local.
EOT

sudo chown root:bind /etc/bind/db.lab.local /etc/bind/db.10.0.0
sudo chmod 644 /etc/bind/db.lab.local /etc/bind/db.10.0.0

# Validate syntax and zones before restarting
sudo named-checkconf
sudo named-checkzone lab.local /etc/bind/db.lab.local
sudo named-checkzone 0.0.10.in-addr.arpa /etc/bind/db.10.0.0

sudo systemctl enable bind9
sudo systemctl restart bind9

# Firewall Config
sudo tee /etc/nftables.conf > /dev/null <<'EOT'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Established/related connections
        ct state established,related accept

        # Loopback
        iifname "lo" accept

        # ICMP
        ip protocol icmp accept

        # SSH only from the management range 10.0.0.20-29
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 accept

        # DNS queries from the LAN only
        ip saddr 10.0.0.0/24 udp dport 53 accept
        ip saddr 10.0.0.0/24 tcp dport 53 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOT

sudo nft -f /etc/nftables.conf
sudo nft list ruleset
sudo systemctl restart nftables