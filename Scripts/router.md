# First update package lists
sudo apt update
sudo apt upgrade -y

# Install the neccecasy packages
# vim is for a basic text editor
# nftables is for network routing configuration
# openssh-server is for remote configuration
# git is for pulling scripts so you wouldn't need to manually input all the commands
sudo apt install -y vim nftables openssh-server git

# Start the ssh server
sudo systemctl start ssh
sudo systemctl enable ssh

# Load the 802.1Q kernel module for vlan tagging
sudo modprobe 8021q
echo "8021q" | sudo tee -a /etc/modules-load.d/modules.conf

sudo ip link add link ens160 name ens160.20 type vlan id 20
sudo ip addr add 10.0.20.10/24 dev ens160.20
sudo ip link set ens160.20 up
sudo ip route add default via 10.0.20.1