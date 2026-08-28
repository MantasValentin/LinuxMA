#!/bin/bash
set -euo pipefail

read -r -s -p $'IPA admin password:\n' IPA_ADMIN_PASSWORD

kinit admin <<< "$IPA_ADMIN_PASSWORD"
unset IPA_ADMIN_PASSWORD

ipa hbacrule-disable allow_all

ipa hostgroup-add dns-servers           --desc="Authoritative DNS servers"          2>/dev/null || true
ipa hostgroup-add dns-rslv-servers      --desc="Recursive DNS resolver servers"     2>/dev/null || true
ipa hostgroup-add dhcp-servers          --desc="DHCP servers"                       2>/dev/null || true
ipa hostgroup-add ipa-servers           --desc="FreeIPA identity servers"           2>/dev/null || true
ipa hostgroup-add firewall-servers      --desc="Firewalls"                          2>/dev/null || true
ipa hostgroup-add admin-workstations    --desc="Admin server"                       2>/dev/null || true
ipa hostgroup-add logging-servers       --desc="logging server"                     2>/dev/null || true
ipa hostgroup-add analytics-servers     --desc="analytics server"                   2>/dev/null || true
ipa hostgroup-add app-servers           --desc="Application servers"                2>/dev/null || true
ipa hostgroup-add proxy-servers         --desc="Proxy servers"                      2>/dev/null || true
ipa hostgroup-add db-servers            --desc="Database server"                    2>/dev/null || true
ipa hostgroup-add db-witness-servers    --desc="Database witness server"            2>/dev/null || true
ipa hostgroup-add db-backup-servers     --desc="Database backups servers"           2>/dev/null || true
ipa hostgroup-add vault-servers         --desc="Hashicorp vault servers"            2>/dev/null || true

ipa hostgroup-add db-hosts              --desc="Every database related host"        2>/dev/null || true
ipa hostgroup-add all-linux             --desc="Every managed Linux host"           2>/dev/null || true

ipa hostgroup-add-member dns-servers --hosts=dns-1.lab.internal,dns-2.lab.internal || true
ipa hostgroup-add-member dns-rslv-servers --hosts=dns-rslv-1.lab.internal,dns-rslv-2.lab.internal || true
ipa hostgroup-add-member dhcp-servers --hosts=dhcp.lab.internal || true
ipa hostgroup-add-member firewall-servers --hosts=firewall-1.lab.internal,firewall-2.lab.internal || true
ipa hostgroup-add-member ipa-servers --hosts=ipa-1.lab.internal,ipa-2.lab.internal || true
ipa hostgroup-add-member admin-workstations --hosts=admin-1.lab.internal || true
ipa hostgroup-add-member logging-servers --hosts=logs.lab.internal || true
ipa hostgroup-add-member analytics-servers --hosts=analytics.lab.internal || true
ipa hostgroup-add-member db-servers --hosts=db-1.lab.internal,db-2.lab.internal || true
ipa hostgroup-add-member db-witness-servers --hosts=db-witness.lab.internal || true
ipa hostgroup-add-member db-backup-servers --hosts=db-backup-1.lab.internal,db-backup-2.lab.internal || true
ipa hostgroup-add-member vault-servers --hosts=vault-1.lab.internal,vault-2.lab.internal || true

ipa hostgroup-add-member db-hosts --hostgroups=db-servers,db-witness-servers,db-backup-servers || true
ipa hostgroup-add-member all-linux --hostgroups=dns-servers,dns-rslv-servers,dhcp-servers,firewall-servers,ipa-servers,admin-workstations,logging-servers,analytics-servers,app-servers,proxy-servers,db-servers,db-witness-servers,db-backup-servers,vault-servers || true

ipa automember-add app-servers --type=hostgroup 2>/dev/null || true
ipa automember-add-condition app-servers --type=hostgroup --key=fqdn --inclusive-regex='^app[0-9]+\.lab\.internal$' 2>/dev/null || true

# Databse manager account
if ! ipa user-show db-manager &>/dev/null; then
    ipa user-add db-manager \
        --first="Database" \
        --last="Manager" \
        --shell=/bin/bash \
        --random
    # Expire random password immediately
    ipa user-mod db-manager --setattr=krbPasswordExpiration=19700101000000Z
fi

for cmd in \
    '/usr/bin/systemctl start patroni' \
    '/usr/bin/systemctl stop patroni' \
    '/usr/bin/systemctl restart patroni' \
    '/usr/bin/systemctl status patroni' \
    '/usr/bin/systemctl start etcd' \
    '/usr/bin/systemctl stop etcd' \
    '/usr/bin/systemctl restart etcd' \
    '/usr/bin/systemctl status etcd' \
    '/usr/bin/systemctl start haproxy' \
    '/usr/bin/systemctl stop haproxy' \
    '/usr/bin/systemctl restart haproxy' \
    '/usr/bin/systemctl status haproxy' \
    '/usr/bin/systemctl start keepalived' \
    '/usr/bin/systemctl stop keepalived' \
    '/usr/bin/systemctl restart keepalived' \
    '/usr/bin/systemctl status keepalived' \
    '/usr/bin/systemctl start pgbackrest' \
    '/usr/bin/systemctl stop pgbackrest' \
    '/usr/bin/systemctl restart pgbackrest' \
    '/usr/bin/systemctl status pgbackrest' \
    '/usr/bin/journalctl -u patroni *' \
    '/usr/bin/journalctl -u etcd *' \
    '/usr/bin/journalctl -u haproxy *' \
    '/usr/bin/journalctl -u keepalived *' \
    '/usr/bin/journalctl -u pgbackrest *' \
    '/usr/bin/getcert list *'
do
    ipa sudocmd-add "$cmd" 2>/dev/null || true
done

ipa sudocmdgroup-add db-hosts-service-cmds \
    --desc="systemctl/journalctl/certmonger commands needed to operate the db-cluster stack" \
    2>/dev/null || true
ipa sudocmdgroup-add-member db-hosts-service-cmds --sudocmds=\
'/usr/bin/systemctl start patroni','/usr/bin/systemctl stop patroni','/usr/bin/systemctl restart patroni','/usr/bin/systemctl status patroni',\
'/usr/bin/systemctl start etcd','/usr/bin/systemctl stop etcd','/usr/bin/systemctl restart etcd','/usr/bin/systemctl status etcd',\
'/usr/bin/systemctl start haproxy','/usr/bin/systemctl stop haproxy','/usr/bin/systemctl restart haproxy','/usr/bin/systemctl status haproxy',\
'/usr/bin/systemctl start keepalived','/usr/bin/systemctl stop keepalived','/usr/bin/systemctl restart keepalived','/usr/bin/systemctl status keepalived',\
'/usr/bin/systemctl start pgbackrest','/usr/bin/systemctl stop pgbackrest','/usr/bin/systemctl restart pgbackrest','/usr/bin/systemctl status pgbackrest',\
'/usr/bin/journalctl -u patroni *','/usr/bin/journalctl -u etcd *','/usr/bin/journalctl -u haproxy *','/usr/bin/journalctl -u keepalived *','/usr/bin/journalctl -u pgbackrest *',\
'/usr/bin/getcert list *' \
    2>/dev/null || true

if ! ipa sudorule-show db-manager-service-control &>/dev/null; then
    ipa sudorule-add db-manager-service-control \
        --desc="db-manager: start/stop/restart/status + logs for the db-hosts services, as root"
fi
ipa sudorule-add-user db-manager-service-control --users=db-manager || true
ipa sudorule-add-host db-manager-service-control --hostgroups=db-hosts || true
ipa sudorule-add-allow-command-group db-manager-service-control --sudocmdgroups=db-hosts-service-cmds || true
ipa sudorule-add-option db-manager-service-control --sudooption='!authenticate' || true

ipa sudocmd-add '/opt/patroni/venv/bin/patronictl *' 2>/dev/null || true
ipa sudocmd-add '/usr/bin/pgbackrest *' 2>/dev/null || true

ipa sudocmdgroup-add dbcluster-postgres-cmds \
    --desc="Patroni/pgBackRest commands that must run as the postgres service account" \
    2>/dev/null || true
ipa sudocmdgroup-add-member dbcluster-postgres-cmds \
    --sudocmds='/opt/patroni/venv/bin/patronictl *','/usr/bin/pgbackrest *' \
    2>/dev/null || true

if ! ipa sudorule-show db-manager-postgres-cmds &>/dev/null; then
    ipa sudorule-add db-manager-postgres-cmds \
        --desc="db-manager: patronictl/pgbackrest, forced to run as postgres (never root)"
fi
ipa sudorule-add-user db-manager-postgres-cmds --users=db-manager || true
ipa sudorule-add-host db-manager-postgres-cmds --hostgroups=db-hosts || true
ipa sudorule-add-allow-command-group db-manager-postgres-cmds --sudocmdgroups=dbcluster-postgres-cmds || true
ipa sudorule-add-runasuser db-manager-postgres-cmds --users=postgres || true
ipa sudorule-add-option db-manager-postgres-cmds --sudooption='!authenticate' || true

ipa group-add db-managers \
    --desc="Read-only visibility into db-cluster logs on db-hosts (see local ACLs)" \
    2>/dev/null || true
ipa group-add-member db-managers --users=db-manager || true

if ! ipa hbacrule-show db-manager-ssh-access &>/dev/null; then
    ipa hbacrule-add db-manager-ssh-access \
        --desc="Allow the db management account to ssh to database hosts"
fi
ipa hbacrule-add-user db-manager-ssh-access --users=db-manager || true
ipa hbacrule-add-host db-manager-ssh-access --hostgroups=db-hosts || true
ipa hbacrule-add-service db-manager-ssh-access --hbacsvcs=sshd || true

# Creating the ansible user for automation
# ipa automember-add ansible-automation --type=hostgroup \
#     --desc="Auto-attach every managed host except IPA/firewall/admin" 2>/dev/null || true
# ipa automember-add-condition ansible-automation --type=hostgroup --key=fqdn \
#     --inclusive-regex='.*\.lab\.internal$' \
#     --exclusive-regex='^(ipa|firewall|admin)[0-9]*\.lab\.internal$' 2>/dev/null || true

# Ansible automation account
if ! ipa user-show ansible &>/dev/null; then
    ipa user-add ansible \
        --first="Ansible" \
        --last="Automation" \
        --shell=/bin/bash \
        --random
    # Expire random password immediately
    ipa user-mod ansible --setattr=krbPasswordExpiration=19700101000000Z
fi

if ! ipa sudorule-show ansible-nopasswd-all &>/dev/null; then
    ipa sudorule-add ansible-nopasswd-all \
        --desc="Passwordless sudo for the ansible automation account (root only)" \
        --cmdcat=all
fi
ipa sudorule-add-user ansible-nopasswd-all --users=ansible || true
ipa sudorule-add-host ansible-nopasswd-all --hostgroups=all-linux || true
ipa sudorule-add-option ansible-nopasswd-all --sudooption='!authenticate' || true

if ! ipa hbacrule-show ansible-ssh-access &>/dev/null; then
    ipa hbacrule-add ansible-ssh-access \
        --desc="Allow the ansible automation account to ssh to managed hosts"
fi
ipa hbacrule-add-user ansible-ssh-access --users=ansible || true
ipa hbacrule-add-host ansible-ssh-access --hostgroups=all-linux || true
ipa hbacrule-add-service ansible-ssh-access --hbacsvcs=sshd || true