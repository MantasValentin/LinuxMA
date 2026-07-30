# First update package lists and upgrade the machine
sudo apt update && sudo apt upgrade -y

# Install the neccecasy packages
# nftables is for the firewall and routing configuration
# openssh-server is for remote configuration
# ansible is for automated remote configuration
# git is for pulling scripts so you wouldn't need to manually input all the commands

sudo apt install -y openssh-server ansible git nftables

sudo systemctl enable NetworkManager --now
sudo systemctl enable nftables --now