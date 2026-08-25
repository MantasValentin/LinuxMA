#!/bin/bash
set -euo pipefail

# Run this ON vault1 or vault2 (as any user in vault-admins, via sudo, or as
# root) after the node has restarted or after `vault operator init`.
#
# It just wraps `vault operator unseal` with the right VAULT_ADDR/VAULT_CACERT
# for this host - it does NOT store or accept unseal keys as arguments, so
# nothing sensitive ends up in your shell history or process list.
#
# You will be prompted 3 times (once per key-holder) if the cluster was
# initialized with the default 5-share / 3-threshold scheme from VAULT.md.

export VAULT_ADDR="https://$(hostname -f):8200"
export VAULT_CACERT="/etc/ipa/ca.crt"

echo "Unsealing $VAULT_ADDR"
echo "Current status:"
vault status || true

echo
echo "Enter unseal keys one at a time. Run this again if the node is still"
echo "sealed after your key is accepted - each key holder runs it once."
vault operator unseal

echo
vault status