# Set hostname
sudo hostnamectl set-hostname "firewall1"

# External (WAN) and internal (LAN) interfaces
NIC_E=ens33
NIC_I=ens34

# Update and upgrade
sudo apt update && sudo apt upgrade -y

# openssh-server  - remote management
# git             - pulling config from your repo
# nftables        - firewall, NAT, DNAT
sudo apt install -y openssh-server git nftables

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-firewall.conf
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
Address=10.0.0.1/24
DNS=10.0.0.53 10.0.0.54
EOT

# Restart networking
sudo systemctl enable systemd-networkd --now
sudo networkctl reload
sudo networkctl reconfigure "$NIC_E" "$NIC_I"

# dns resolution goes to dns-rslv
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

        # Loopback
        iifname "lo" accept

        # ICMP
        ip protocol icmp accept

        # SSH only from the management range 10.0.0.20-29
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # Established/related connections
        ct state established,related accept

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