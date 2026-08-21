#!/bin/bash
set -euo pipefail

read -r -s -p "IPA admin password: " IPA_ADMIN_PASSWORD

kinit admin <<< "$IPA_ADMIN_PASSWORD"
unset IPA_ADMIN_PASSWORD

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
ipa hostgroup-add all-linux             --desc="Every managed Linux host"           2>/dev/null || true

ipa hostgroup-add ansible-automation  --desc="Hosts Ansible is allowed to manage" 2>/dev/null || true

ipa hostgroup-add-member dns-servers --hosts=dns1.lab.internal,dns2.lab.internal || true
ipa hostgroup-add-member dns-rslv-servers --hosts=dns-rslv1.lab.internal,dns-rslv2.lab.internal || true
ipa hostgroup-add-member dhcp-servers --hosts=dhcp.lab.internal || true
ipa hostgroup-add-member firewall-servers --hosts=firewall1.lab.internal,firewall2.lab.internal || true
ipa hostgroup-add-member ipa-servers --hosts=ipa1.lab.internal,ipa2.lab.internal || true
ipa hostgroup-add-member admin-workstations --hosts=admin.lab.internal || true
ipa hostgroup-add-member logging-servers --hosts=logs.lab.internal || true
ipa hostgroup-add-member analytics-servers --hosts=analytics.lab.internal || true

ipa hostgroup-add-member all-linux --hostgroups=dns-servers,dns-rslv-servers,dhcp-servers,firewall-servers,ipa-servers,admin-workstations,logging-servers,analytics-servers,app-servers,proxy-servers,db-servers || true

ipa automember-add app-servers --type=hostgroup 2>/dev/null || true
ipa automember-add-condition app-servers --type=hostgroup --key=fqdn --inclusive-regex='^app[0-9]+\.lab\.internal$' 2>/dev/null || true

ipa automember-add automation-accounts --type=group 2>/dev/null || true
ipa automember-add-condition automation-accounts --type=group --key=uid --inclusive-regex='.*-automation$' 2>/dev/null || true

# Creating the ansible user for automation
# ipa automember-add ansible-automation --type=hostgroup \
#     --desc="Auto-attach every managed host except IPA/firewall/admin" 2>/dev/null || true
# ipa automember-add-condition ansible-automation --type=hostgroup --key=fqdn \
#     --inclusive-regex='.*\.lab\.internal$' \
#     --exclusive-regex='^(ipa|firewall|admin)[0-9]*\.lab\.internal$' 2>/dev/null || true
ipa automember-add ansible-automation --type=hostgroup \
    --desc="Auto-attach every managed host" 2>/dev/null || true
ipa automember-add-condition ansible-automation --type=hostgroup --key=fqdn --inclusive-regex='.*\.lab\.internal$' 2>/dev/null || true

ipa automember-rebuild --type=hostgroup

if ! ipa user-show ansible &>/dev/null; then
    ipa user-add ansible \
        --first="Ansible" \
        --last="Automation" \
        --shell=/bin/bash \
        --random
fi

# Expire random password immediately
ipa user-mod ansible --setattr=krbPasswordExpiration=19700101000000Z

if ! ipa sudorule-show ansible-nopasswd-all &>/dev/null; then
    ipa sudorule-add ansible-nopasswd-all \
        --desc="Passwordless sudo for the ansible automation account (root only)" \
        --cmdcat=all
fi
ipa sudorule-add-user ansible-nopasswd-all --users=ansible || true
ipa sudorule-add-host ansible-nopasswd-all --hostgroups=ansible-automation || true
ipa sudorule-add-option ansible-nopasswd-all --sudooption='!authenticate' || true

if ! ipa hbacrule-show ansible-ssh-access &>/dev/null; then
    ipa hbacrule-add ansible-ssh-access \
        --desc="Allow the ansible automation account to ssh to managed hosts"
fi
ipa hbacrule-add-user ansible-ssh-access --users=ansible || true
ipa hbacrule-add-host ansible-ssh-access --hostgroups=ansible-automation || true
ipa hbacrule-add-service ansible-ssh-access --hbacsvcs=sshd || true