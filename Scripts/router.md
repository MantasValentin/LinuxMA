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

# Load the 802.1Q kernel module for vlan tagging
sudo modprobe 8021q
echo "8021q" | sudo tee -a /etc/modules

# Disable ufw to prevent interferance with nftables
sudo systemctl disable --now ufw 2>/dev/null || true

# Disable systemd-resolved, interall dns will be resolved with dnsmasq
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved

# Internall network interface will be NIC_I, externall network interface will be NIC_E, these need to be set to the ones specific to the name as it is specific to the system, it can be ens18, eth0, enp0s3 or else

# Change these
NIC_E=ens33
NIC_I=ens34

# Configure the interfaces with NetworkManager

# Dissable NetworkManager dns configuring
sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null <<EOT
[main]
dns=none
EOT

sudo systemctl reload NetworkManager

# Configure the extrernal interface to function as a WAN connection with automatic DHCP
sudo nmcli connection add type ethernet ifname $NIC_E con-name WAN ipv4.method auto
sudo nmcli connection modify WAN connection.autoconnect yes

# Configure the internal interface as a trunk and add the vlans make sure DHCP is dissabled
sudo nmcli connection add type ethernet ifname $NIC_I con-name LAN-Trunk ipv4.method disabled
sudo nmcli connection modify LAN-Trunk connection.autoconnect yes

sudo nmcli connection add type vlan ifname $NIC_I.10 dev $NIC_I id 10 con-name vlan10
sudo nmcli connection modify vlan10 ipv4.addresses 10.0.10.1/24 ipv4.method manual
sudo nmcli connection add type vlan ifname $NIC_I.20 dev $NIC_I id 20 con-name vlan20
sudo nmcli connection modify vlan20 ipv4.addresses 10.0.20.1/24 ipv4.method manual
sudo nmcli connection add type vlan ifname $NIC_I.30 dev $NIC_I id 30 con-name vlan30
sudo nmcli connection modify vlan30 ipv4.addresses 10.0.30.1/24 ipv4.method manual
sudo nmcli connection modify vlan10 connection.autoconnect yes
sudo nmcli connection modify vlan20 connection.autoconnect yes
sudo nmcli connection modify vlan30 connection.autoconnect yes

sudo systemctl restart NetworkManager

# Set the /etc/resolv.conf nameserver to localhost 127.0.0.1
sudo rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf

# Configure dnsmasq
sudo rm /etc/dnsmasq.conf
sudo tee /etc/dnsmasq.conf > /dev/null <<EOT
# Bind to VLAN interfaces
interface=$NIC_I.10
interface=$NIC_I.20
interface=$NIC_I.30

# DHCP Ranges
dhcp-range=$NIC_I.10,10.0.10.100,10.0.10.200,255.255.255.0,24h
dhcp-range=$NIC_I.20,10.0.20.100,10.0.20.200,255.255.255.0,24h
dhcp-range=$NIC_I.30,10.0.30.100,10.0.30.200,255.255.255.0,24h

# DNS server to hand out to clients
dhcp-option=$NIC_I.10,6,10.0.10.1
dhcp-option=$NIC_I.20,6,10.0.20.1
dhcp-option=$NIC_I.30,6,10.0.30.1

# DNS for the router itself
server=10.0.20.2
server=8.8.8.8

# Listen for DNS
listen-address=127.0.0.1
listen-address=10.0.10.1
listen-address=10.0.20.1
listen-address=10.0.30.1

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
        tcp dport 80 dnat to 10.0.30.2
        tcp dport 443 dnat to 10.0.30.2
    }
}

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        # Allow established/related connections
        ct state established,related accept
        # Allow loopback
        iifname "lo" accept
        # Allow SSH from management VLAN
        iifname "$NIC_I.10" tcp dport 22 accept
        # Allow ICMP
        ip protocol icmp accept
        ip6 protocol icmpv6 accept
        # Allow DHCP requests from LAN
        udp dport 68 accept
        iifname { "$NIC_I.10", "$NIC_I.20", "$NIC_I.30" } udp dport 67 accept
        # Allow DNS
        udp dport 53 accept
        tcp dport 53 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        # Allow established/related connections
        ct state established,related accept
        # Allow forwarding between LAN interfaces, VLAN 30 is for the proxy and http server
        iifname { "$NIC_I.10", "$NIC_I.20", "$NIC_I.30" } oifname "$NIC_E" accept
        iifname "$NIC_E" oifname "$NIC_I.30" tcp dport {80,443} accept
        # Allow forwarding between VLANs
        iifname { "$NIC_I.10", "$NIC_I.20", "$NIC_I.30" } oifname { "$NIC_I.10", "$NIC_I.20", "$NIC_I.30" } accept
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