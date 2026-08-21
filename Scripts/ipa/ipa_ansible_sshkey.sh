#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <path-to-ansible-ssh-pubkey>"
    echo "Example: $0 /root/.ssh/ansible_ed25519.pub"
    exit 1
}

if [ "$#" -ne 1 ]; then
    usage
fi

SSH_PUBKEY_FILE=$1
ANSIBLE_USER=ansible

if [ ! -f "$SSH_PUBKEY_FILE" ]; then
    echo "ERROR: $SSH_PUBKEY_FILE not found."
    echo "Generate one first, e.g.:"
    echo "  ssh-keygen -t ed25519 -f /root/.ssh/ansible_ed25519 -C ansible@lab.internal -N ''"
    exit 1
fi

PUBKEY_CONTENT="$(cat "$SSH_PUBKEY_FILE")"

read -r -s -p "IPA admin password: " IPA_ADMIN_PASSWORD

kinit admin <<< "$IPA_ADMIN_PASSWORD"
unset IPA_ADMIN_PASSWORD

if ! ipa user-show "$ANSIBLE_USER" &>/dev/null; then
    echo "ERROR: the '$ANSIBLE_USER' account doesn't exist yet."
    exit 1
fi

ipa user-mod "$ANSIBLE_USER" --sshpubkey="$PUBKEY_CONTENT"