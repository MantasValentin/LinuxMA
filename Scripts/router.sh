# First update package lists and upgrade the machine
sudo apt update && sudo apt upgrade -y

# Install the neccecasy packages
# nftables is for the firewall and routing configuration
# dnsmasq is for dns and dhcp configuration
# network-manager is for network interface configuration
# vim is for a basic text editor
# openssh-server is for remote configuration
# git is for pulling scripts so you wouldn't need to manually input all the commands

sudo apt install -y vim openssh-server git nftables dnsmasq network-manager

sudo systemctl enable NetworkManager --now
sudo systemctl enable nftables --now

# Start the ssh server
sudo systemctl enable ssh --now

# Enable ip forwarding
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-router.conf
sudo sysctl --system

# Disable ufw to prevent interferance with nftables
sudo systemctl disable --now ufw 2>/dev/null || true

# Internall network interface will be NIC_I, externall network interface will be NIC_E, these need to be set to the ones specific to the name as it is specific to the system, it can be ens18, eth0, enp0s3 or else

# Change these
NIC_E=ens33
NIC_I=ens34

# 10.0.0.0/24, router = 10.0.0.1
#   10.0.0.10 - 10.0.0.19   management 
#   10.0.0.20 - 10.0.0.29   infrastructure
#   10.0.0.30 - 10.0.0.39   servers / reverse proxy
#   10.0.0.100 - 10.0.0.200 DHCP pool for everything else

# Configure the interfaces with NetworkManager

# Dissable NetworkManager dns configuring
sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null <<EOT
[main]
dns=none
EOT

sudo systemctl restart NetworkManager

# Disable systemd-resolved, interall dns will be resolved with dnsmasq
sudo systemctl disable --now systemd-resolved

# Configure the extrernal interface to function as a WAN connection with automatic DHCP
sudo nmcli connection add type ethernet ifname $NIC_E con-name WAN ipv4.method auto
sudo nmcli connection modify WAN connection.autoconnect yes

# Configure the internal interface as a single flat LAN with a static IP
sudo nmcli connection add type ethernet ifname $NIC_I con-name LAN ipv4.method manual ipv4.addresses 10.0.0.1/24
sudo nmcli connection modify LAN connection.autoconnect yes

sudo systemctl restart NetworkManager

# Set the /etc/resolv.conf nameserver to localhost 127.0.0.1
sudo rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf

# Configure dnsmasq
sudo rm /etc/dnsmasq.conf
sudo tee /etc/dnsmasq.conf > /dev/null <<EOT
# Bind to the LAN interface
interface=$NIC_I

# DHCP range
dhcp-range=10.0.0.100,10.0.0.200,255.255.255.0,24h

# DNS server to hand out to clients
dhcp-option=6,10.0.0.1

# DNS for the router itself, point this at your infra DNS box if you have one
server=10.0.0.20
server=8.8.8.8

# Listen for DNS
listen-address=127.0.0.1
listen-address=10.0.0.1

# Do not read /etc/resolv.conf
no-resolv

# Logging
log-facility=-
EOT

sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

# Configure nftables for routing
sudo rm /etc/nftables.conf
sudo tee /etc/nftables.conf > /dev/null <<EOT
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$NIC_E" masquerade
    }

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # Route all http traffic to reverse proxy
        tcp dport 80 dnat to 10.0.0.30
        tcp dport 443 dnat to 10.0.0.30
    }
}

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        # Allow established/related connections
        ct state established,related accept
        # Allow loopback
        iifname "lo" accept
        # Allow SSH only from the management range 10.0.0.10-19
        ip saddr 10.0.0.10-10.0.0.19 tcp dport 22 accept
        # Allow ICMP
        ip protocol icmp accept
        # Allow DHCP requests from LAN
        udp dport 68 accept
        iifname "$NIC_I" udp dport 67 accept
        # Allow DNS
        udp dport 53 accept
        tcp dport 53 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        # Allow established/related connections
        ct state established,related accept
        # Allow forwarding from LAN out to WAN
        iifname "$NIC_I" oifname "$NIC_E" accept
        # Allow inbound WAN traffic only to the reverse proxy on 80/443
        iifname "$NIC_E" oifname "$NIC_I" ip daddr 10.0.0.30 tcp dport {80,443} accept
        # Allow forwarding within the LAN
        iifname "$NIC_I" oifname "$NIC_I" accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOT

# Load the rules
sudo nft -f /etc/nftables.conf
# Verify
sudo nft list ruleset
sudo systemctl restart nftables