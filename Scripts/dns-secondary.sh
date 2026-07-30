# Set hostname
sudo hostnamectl set-hostname "dns2"

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

sudo systemctl enable NetworkManager --now
sudo systemctl enable nftables --now
sudo systemctl enable ssh --now

# Set this to your actual interface name: ens18, eth0, enp0s3, etc.
NIC=ens34

# Stop NetworkManager from writing its own resolv.conf
sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null <<EOT
[main]
dns=none
EOT

sudo systemctl restart NetworkManager

# systemd-resolved isn't needed, bind9 serves the zone directly
sudo systemctl disable --now systemd-resolved

# LAN interface
sudo tee /etc/systemd/network/10-lan.network > /dev/null <<EOT
[Match]
Name=$NIC

[Network]
Address=10.0.0.7/24
Gateway=10.0.0.1
DNS=10.0.0.53 10.0.0.54
EOT

sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
EOT

# Need to make sure that TSIG key is copied to the secondary
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
    type secondary;
    primaries { 10.0.0.6 key xfer-key; };
    file "/var/cache/bind/db.lab.local";
};

zone "0.0.10.in-addr.arpa" {
    type secondary;
    primaries { 10.0.0.6 key xfer-key; };
    file "/var/cache/bind/db.10.0.0";
};

server 10.0.0.6 {
    keys { xfer-key; };
};
EOT

# Validate syntax before restarting
sudo named-checkconf

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