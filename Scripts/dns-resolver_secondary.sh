# Set hostname
sudo hostnamectl set-hostname "dns-rslv2"

# Interface
NIC=ens34

# Temporary bootstrap networking
# sudo ip link set "$NIC" up
# sudo ip addr add 10.0.0.250/24 dev "$NIC"
# sudo ip route add default via 10.0.0.1
# echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null

# Update and upgrade
sudo apt update && sudo apt upgrade -y

# bind9           - used here purely as a caching/forwarding resolver
# bind9utils      - named-checkconf tools
# dnsutils        - dig / nslookup for testing
# nftables        - firewall
# openssh-server  - remote management
# git             - pulling config from your repo
sudo apt install -y bind9 bind9utils dnsutils nftables openssh-server git

# Remove the temporary networking
sudo ip addr flush dev "$NIC"
sudo ip route flush dev "$NIC"

# Disable automatic dns resolution
sudo systemctl disable --now systemd-resolved

sudo systemctl enable nftables --now
sudo systemctl enable ssh --now

# LAN interface
sudo tee /etc/systemd/network/10-lan.network > /dev/null <<EOT
[Match]
Name=$NIC

[Network]
Address=10.0.0.54/24
Gateway=10.0.0.1
DNS=127.0.0.1
EOT

# Restart networking
sudo systemctl enable systemd-networkd --now
sudo networkctl reload
sudo networkctl reconfigure "$NIC"

# This box is the resolver, so it resolves through itself
sudo rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf

# Recurse and cache for the LAN, forward everything else to public resolvers
sudo tee /etc/bind/named.conf.options > /dev/null <<'EOT'
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-recursion { localhost; 10.0.0.0/24; };
    allow-query { localhost; 10.0.0.0/24; };
    listen-on { any; };
    listen-on-v6 { none; };
    forwarders {
        8.8.8.8;
        1.1.1.1;
    };
    forward first;
    dnssec-validation auto;
    version "not disclosed";
};
EOT

# lab.local get forwarded specifically to the authoritative pair
sudo tee /etc/bind/named.conf.local > /dev/null <<'EOT'
zone "lab.local" {
    type forward;
    forward only;
    forwarders { 10.0.0.6; 10.0.0.7; };
};

zone "0.0.10.in-addr.arpa" {
    type forward;
    forward only;
    forwarders { 10.0.0.6; 10.0.0.7; };
};
EOT

sudo named-checkconf

sudo systemctl enable bind9
sudo systemctl restart bind9

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