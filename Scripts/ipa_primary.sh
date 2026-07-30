# FreeIPA must have a real FQDN hostname, not a short name
sudo hostnamectl set-hostname "ipa1.lab.local"

# Update and upgrade
sudo apt update && sudo apt upgrade -y

# freeipa-server   - the IPA stack (389-ds, MIT Kerberos, Dogtag CA, web UI)
# chrony           - accurate time is mandatory for Kerberos
# nftables         - firewall
# openssh-server   - remote management
# git              - pulling config from your repo
sudo apt install -y freeipa-server chrony nftables openssh-server git

sudo systemctl enable NetworkManager --now
sudo systemctl enable nftables --now
sudo systemctl enable ssh --now
sudo systemctl enable chrony --now

NIC=ens34

sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null <<EOT
[main]
dns=none
EOT

sudo systemctl restart NetworkManager
sudo systemctl disable --now systemd-resolved

# Gateway is the firewall (10.0.0.1), dns resolution is dns-rslv
sudo nmcli connection add type ethernet ifname "$NIC" con-name LAN \
    ipv4.method manual \
    ipv4.addresses 10.0.0.4/24 \
    ipv4.gateway 10.0.0.1 \
    ipv4.dns "10.0.0.53" \
    ipv4.ignore-auto-dns yes \
    connection.autoconnect yes
sudo nmcli connection up LAN

sudo systemctl restart NetworkManager

sudo rm -f /etc/resolv.conf
echo "nameserver 10.0.0.53" | sudo tee /etc/resolv.conf

echo ">>> Verifying forward/reverse DNS before installing (required by ipa-server-install)"
getent hosts ipa1.lab.local
dig +short -x 10.0.0.7
echo ">>> If either of the above is empty, fix DNS on dns1/dns2 first and re-run."

# --- IPA server install ---
# Not using --setup-dns since dns1/dns2 already serve lab.local authoritatively.
# Set these from environment/vault rather than hardcoding in a committed script:
#   IPA_DM_PASSWORD  - Directory Manager password
#   IPA_ADMIN_PASSWORD - admin user password
sudo ipa-server-install \
    --realm=LAB.LOCAL \
    --domain=lab.local \
    --hostname=ipa1.lab.local \
    --ds-password="${IPA_DM_PASSWORD:?set IPA_DM_PASSWORD}" \
    --admin-password="${IPA_ADMIN_PASSWORD:?set IPA_ADMIN_PASSWORD}" \
    --no-host-dns \
    --no-ntp \
    --unattended

# Firewall Config - LDAP/Kerberos/HTTPS open to the LAN, replication + SSH restricted
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

        # SSH only from the management range 10.0.0.10-19
        ip saddr 10.0.0.10-10.0.0.19 tcp dport 22 accept

        # Kerberos + kpasswd, from the LAN
        ip saddr 10.0.0.0/24 tcp dport { 88, 464 } accept
        ip saddr 10.0.0.0/24 udp dport { 88, 464 } accept

        # LDAP/LDAPS, from the LAN
        ip saddr 10.0.0.0/24 tcp dport { 389, 636 } accept

        # Web UI / cert enrollment, from the LAN
        ip saddr 10.0.0.0/24 tcp dport { 80, 443 } accept

        # NTP (chrony) from the LAN
        ip saddr 10.0.0.0/24 udp dport 123 accept

        # Replica install / custodia secret transfer, IPA peer only
        ip saddr 10.0.0.8 tcp dport 8888 accept
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