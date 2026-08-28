#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <path-to-db-manager-ssh-pubkey>"
    echo "Example: $0 /root/.ssh/db_manager_ed25519.pub"
    exit 1
}

if [ "$#" -ne 1 ]; then
    usage
fi

SSH_PUBKEY_FILE=$1
USER=db-manager

if [ ! -f "$SSH_PUBKEY_FILE" ]; then
    echo "ERROR: $SSH_PUBKEY_FILE not found."
    echo "Generate one first, e.g.:"
    echo "  ssh-keygen -t ed25519 -f /root/.ssh/db_manager_ed25519 -C db-manager@lab.internal -N ''"
    exit 1
fi

PUBKEY_CONTENT="$(cat "$SSH_PUBKEY_FILE")"

read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

kinit admin <<< "$IPA_ADMIN_PASSWORD"
unset IPA_ADMIN_PASSWORD

if ! ipa user-show "$USER" &>/dev/null; then
    echo "ERROR: the '$USER' account doesn't exist yet."
    exit 1
fi

ipa user-mod "$USER" --sshpubkey="$PUBKEY_CONTENT"