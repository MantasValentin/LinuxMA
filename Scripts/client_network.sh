#!/bin/bash
NIC=ens34                  # actual interface name for this VM
CONN_NAME=LAN              # connection name
IP_ADDR=10.0.0.10/24       # this host's static IP
HOSTNAME=admin              # matches the zone file record: logs, db, proxy, app

# sudo apt update && sudo apt upgrade -y
# sudo apt install -y network-manager nftables openssh-server git

sudo systemctl enable NetworkManager --now
sudo systemctl enable ssh --now

# Set hostname to match DNS
sudo hostnamectl set-hostname "$HOSTNAME"

# Stop NetworkManager writing its own resolv.conf, since we set it manually
sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null <<EOT
[main]
dns=none
EOT
sudo systemctl restart NetworkManager
sudo systemctl disable --now systemd-resolved

# Static IP, gateway = router, DNS = your internal DNS server (not itself!)
sudo nmcli connection add type ethernet ifname "$NIC" con-name "$CONN_NAME" \
    ipv4.method manual \
    ipv4.addresses "$IP_ADDR" \
    ipv4.gateway 10.0.0.1 \
    ipv4.dns "10.0.0.1" \
    ipv4.dns-search "lab.local" \
    ipv4.ignore-auto-dns yes \
    connection.autoconnect yes

sudo nmcli connection up "$CONN_NAME"

sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 10.0.0.1
search lab.local
EOT