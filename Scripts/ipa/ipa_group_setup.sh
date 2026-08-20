ipa hostgroup-add dns-servers           --desc="Authoritative DNS servers"
ipa hostgroup-add dns-rslv-servers      --desc="DNS resolition servers"
ipa hostgroup-add dhcp-servers          --desc="DHCP servers"
ipa hostgroup-add ipa-servers           --desc="FreeIPA identity servers"
ipa hostgroup-add firewall-servers      --desc="Firewalls"
ipa hostgroup-add admin-servers         --desc="Admin server"
ipa hostgroup-add logging-servers       --desc="logging server"
ipa hostgroup-add monitoring-servers    --desc="monitoring server"
ipa hostgroup-add app-servers           --desc="Application servers"
ipa hostgroup-add proxy-servers         --desc="Application servers"
ipa hostgroup-add db-servers            --desc="Database server"
ipa hostgroup-add all-linux             --desc="Every managed Linux host"

ipa hostgroup-add-member dns-servers --hosts=dns1.lab.internal,dns2.lab.internal
ipa hostgroup-add-member dns-rslv-servers --hosts=dns-rslv1.lab.internal,dns-rslv2.lab.internal
ipa hostgroup-add-member dhcp-servers --hosts=dhcp.lab.internal
ipa hostgroup-add-member firewall-servers --hosts=firewall1.lab.internal,firewall2.lab.internal
ipa hostgroup-add-member ipa-servers --hosts=ipa1.lab.internal,ipa2.lab.internal
ipa hostgroup-add-member admin-servers --hosts=admin.lab.internal

ipa hostgroup-add-member all-linux --hostgroups=dns-servers,dns-rslv-servers,dhcp-servers,firewall-servers,ipa-servers,admin-servers,logging-servers,monitoring-servers,app-servers,proxy-servers,db-servers

ipa automember-add app-servers --type=hostgroup
ipa automember-add-condition app-servers --type=hostgroup --key=fqdn --regex='^app[0-9]+\.lab\.internal$' --inclusive-regex='^app[0-9]+\.lab\.internal$'

ipa automember-add automation-accounts --type=group
ipa automember-add-condition automation-accounts --type=group --key=uid --regex='.*-service$'

ipa automember-rebuild --type=hostgroup