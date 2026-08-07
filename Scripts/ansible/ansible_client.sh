# Create ansible automation user
sudo useradd -m -s /bin/bash ansible

# Temporary password only for initial key installation
echo "ansible:ansible" | sudo chpasswd

# Create SSH directory
sudo install -d -m 700 -o ansible -g ansible /home/ansible/.ssh

# Give ansible passwordless sudo
sudo tee /etc/sudoers.d/ansible >/dev/null <<EOF
ansible ALL=(ALL) NOPASSWD:ALL
EOF

sudo chmod 440 /etc/sudoers.d/ansible

# Validate sudo configuration
sudo visudo -cf /etc/sudoers.d/ansible

# After ssh-copy-id is used for the account, lock it out from local users
# Also prevents any other attempt to use ssh-copy-id or use ssh to connect to the account as that requires password authentication without a key
# Make sure that only the ansible controller has the key to the ansible user on the machine
# sudo passwd -l ansible