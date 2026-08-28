#!/bin/bash
set -euo pipefail

# Run this on BOTH db1 and db2, after db_primary.sh/db_secondary.sh and after
# pgbackup.sh have been applied, and after the matching cert files have been
# copied over from the backup server:
#
#   db1 needs: /etc/pgbackrest/cert/{db1.crt,db1.key,ca.crt}
#   db2 needs: /etc/pgbackrest/cert/{db2.crt,db2.key,ca.crt}
#
# This script is identical on both nodes — it just points at the local node's
# own cert files, which differ by hostname.

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <this_node_short_name>   (db1 or db2)"
    exit 1
fi
NODE=$1   # db1 or db2

sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf install -y pgbackrest

sudo mkdir -p /var/log/pgbackrest
sudo chown postgres:postgres /var/log/pgbackrest /etc/pgbackrest/cert
sudo chmod 700 /etc/pgbackrest/cert
sudo chmod 600 /etc/pgbackrest/cert/${NODE}.key

sudo tee /etc/pgbackrest/pgbackrest.conf > /dev/null <<EOT
[global]
repo1-host=pgbackup.lab.internal
repo1-host-type=tls
repo1-host-ca-file=/etc/pgbackrest/cert/ca.crt
repo1-host-cert-file=/etc/pgbackrest/cert/${NODE}.crt
repo1-host-key-file=/etc/pgbackrest/cert/${NODE}.key
log-path=/var/log/pgbackrest
process-max=2
compress-type=zst

[pg-cluster]
pg1-path=/var/lib/pgsql/17/data
pg1-port=5432
EOT
sudo chown postgres:postgres /etc/pgbackrest/pgbackrest.conf

##############################################
# Wire archive_command into Patroni so it follows the primary through failover.
# This is applied via the DCS so BOTH nodes pick it up identically — Postgres
# itself only invokes archive_command when it's actually the primary, so this
# is safe to have "on" on both.
##############################################
sudo -u postgres /opt/patroni/venv/bin/patronictl -c /etc/patroni/patroni.yml \
    edit-config --pg archive_mode=on \
    --pg archive_command='pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf archive-push %p' \
    --pg restore_command='pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf archive-get %f "%p"' \
    -y || echo ">>> If this failed because the other node hasn't applied this yet, that's fine — Patroni syncs config via the DCS, run it once from either node."

##############################################
# Firewall addition — allow outbound to the repo host on 8432
# (your existing chain policy is `output ... policy accept`, so this node can
#  already reach out; nothing to add here unless output policy is tightened later)
##############################################

##############################################
# Backup schedule: full weekly (Sunday 01:00), differential nightly otherwise.
# Runs only when this node is CURRENTLY the Patroni leader — checked at runtime
# so the same cron entries work identically on both nodes regardless of who's
# primary after a failover.
##############################################
sudo tee /usr/local/bin/pg_backup_if_primary.sh > /dev/null <<'EOT'
#!/bin/bash
set -euo pipefail
TYPE=$1   # full or diff

# Only the current Patroni leader should push a base backup
if ! curl -fs http://127.0.0.1:8008/primary > /dev/null 2>&1; then
    logger "pg_backup: not primary, skipping ${TYPE} backup"
    exit 0
fi

logger "pg_backup: starting ${TYPE} backup"
sudo -u postgres pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf \
    --type="${TYPE}" backup
logger "pg_backup: ${TYPE} backup complete"
EOT
sudo chmod +x /usr/local/bin/pg_backup_if_primary.sh

sudo tee /etc/cron.d/pgbackrest > /dev/null <<EOT
0 1 * * 0 root /usr/local/bin/pg_backup_if_primary.sh full   >> /var/log/pgbackrest/cron.log 2>&1
0 1 * * 1-6 root /usr/local/bin/pg_backup_if_primary.sh diff >> /var/log/pgbackrest/cron.log 2>&1
EOT

echo ""
echo ">>> Run this identical script on the OTHER db node too, then from db1 or db2 (whichever is primary) run:"
echo ">>>   sudo -u postgres pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf stanza-create"
echo ">>>   sudo -u postgres pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf check"
echo ">>>   sudo -u postgres pgbackrest --stanza=pg-cluster --config=/etc/pgbackrest/pgbackrest.conf --type=full backup"