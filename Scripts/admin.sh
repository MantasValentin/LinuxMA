
sudo nmcli connection add type vlan ifname ens33.10 dev ens33 id 10 con-name client-vlan10
sudo nmcli connection modify client-vlan10 ipv4.method auto
sudo nmcli connection up client-vlan10