#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <IPA_ADMIN_PASSWORD> <path-to-ansible-ssh-pubkey>"
    echo "Example: bash $0 password1 /home/sysadmin/.ssh/ansible_ed25519.pub"
    exit 1
fi

IPA_ADMIN_PASSWORD=$1
SSH_PUBKEY_FILE=$2

HOSTGROUP=ansible-managed
SUDORULE=ansible-nopasswd-all
HBACRULE=ansible-ssh-access
ANSIBLE_USER=ansible

if [ ! -f "$SSH_PUBKEY_FILE" ]; then
    echo "ERROR: $SSH_PUBKEY_FILE not found."
    echo "Generate one first, e.g. on the admin box:"
    echo "  ssh-keygen -t ed25519 -f ~/.ssh/ansible_ed25519 -C ansible@lab.internal -N ''"
    exit 1
fi

# Authenticate as admin
echo "$IPA_ADMIN_PASSWORD" | kinit admin

# 1. Hostgroup for every server ansible is allowed to manage
if ! ipa hostgroup-show "$HOSTGROUP" &>/dev/null; then
    ipa hostgroup-add "$HOSTGROUP" --desc "All servers managed by Ansible"
fi

# Add every host currently enrolled in IPA
for host in $(ipa host-find --pkey-only --raw | awk -F': ' '/^fqdn:/ {print $2}'); do
    ipa hostgroup-add-member "$HOSTGROUP" --hosts="$host" &>/dev/null || true
done

# Auto-add any host enrolled in the future too, matching every fqdn
if ! ipa automember-find --type=hostgroup "$HOSTGROUP" 2>/dev/null | grep -q "Automember Rule"; then
    ipa automember-add --type=hostgroup "$HOSTGROUP" \
        --desc "Auto-attach every enrolled host to $HOSTGROUP"
fi
ipa automember-add-condition "$HOSTGROUP" \
    --type=hostgroup \
    --key=fqdn \
    --inclusive-regex='.*' &>/dev/null || true

# 2. Dedicated automation user - key-only login, random unused password
if ! ipa user-show "$ANSIBLE_USER" &>/dev/null; then
    ipa user-add "$ANSIBLE_USER" \
        --first="Ansible" \
        --last="Automation" \
        --shell=/bin/bash \
        --random &>/dev/null
fi
ipa user-mod "$ANSIBLE_USER" --sshpubkey="$(cat "$SSH_PUBKEY_FILE")"

# 3. Passwordless sudo, any command, as any user, on every managed host
if ! ipa sudorule-show "$SUDORULE" &>/dev/null; then
    ipa sudorule-add "$SUDORULE" \
        --desc "Passwordless sudo for the ansible automation account" \
        --cmdcat=all \
        --runasusercat=all \
        --runasgroupcat=all
fi
ipa sudorule-add-user "$SUDORULE" --users="$ANSIBLE_USER" &>/dev/null || true
ipa sudorule-add-host "$SUDORULE" --hostgroups="$HOSTGROUP" &>/dev/null || true
ipa sudorule-add-option "$SUDORULE" --sudooption='!authenticate' &>/dev/null || true

# 4. Allow the ansible user to ssh in to every managed host
if ! ipa hbacrule-show "$HBACRULE" &>/dev/null; then
    ipa hbacrule-add "$HBACRULE" \
        --desc "Allow the ansible automation account to ssh to managed hosts"
fi
ipa hbacrule-add-user "$HBACRULE" --users="$ANSIBLE_USER" &>/dev/null || true
ipa hbacrule-add-host "$HBACRULE" --hostgroups="$HOSTGROUP" &>/dev/null || true
ipa hbacrule-add-service "$HBACRULE" --hbacsvcs=sshd &>/dev/null || true