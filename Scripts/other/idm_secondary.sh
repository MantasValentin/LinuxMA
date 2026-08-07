#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <REPLICATOR_PASSWORD>"
    echo "Example: bash idm2.sh replPass2"
    exit 1
fi

REPLICATOR_PASSWORD=$1

REALM=LAB.LOCAL
DOMAIN=lab.local
BASE_DN="dc=lab,dc=local"

# --- Preflight: files that must be copied from idm1 first ---
for f in /tmp/idm2.crt /tmp/idm2.key /tmp/ca.crt /tmp/idm2.keytab /tmp/k5-stash; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found."
        echo "Copy the following from idm1 before running this script:"
        echo "  idm1:/tmp/idm2-bundle/idm2.crt    -> idm2:/tmp/idm2.crt"
        echo "  idm1:/tmp/idm2-bundle/idm2.key    -> idm2:/tmp/idm2.key"
        echo "  idm1:/tmp/idm2-bundle/ca.crt      -> idm2:/tmp/ca.crt"
        echo "  idm1:/tmp/idm2-bundle/idm2.keytab -> idm2:/tmp/idm2.keytab"
        echo "  idm1:/var/lib/krb5kdc/.k5.$REALM  -> idm2:/tmp/k5-stash"
        exit 1
    fi
done

# Interface
NIC=ens34
LAN_IP=10.0.0.6
LAN_SUBNET_MASK=24
GATEWAY=10.0.0.1

sudo hostnamectl set-hostname "idm2.lab.local"

sudo apt update && sudo apt upgrade -y

# slapd            - OpenLDAP directory server (consumer/replica)
# ldap-utils       - ldapadd/ldapsearch/ldapmodify
# krb5-kdc         - Kerberos KDC (read-only secondary, no kadmind)
# krb5-kpropd      - receives database pushes from the primary KDC
# krb5-config      - realm defaults for the krb5 libs
# chrony           - accurate time is mandatory for Kerberos
# nftables         - firewall
# openssh-server   - remote management
# git              - pulling config from your repo
sudo debconf-set-selections <<EOT
krb5-config krb5-config/default_realm string $REALM
krb5-config krb5-config/kerberos_servers string idm1.lab.local
krb5-config krb5-config/admin_server string idm1.lab.local
slapd slapd/internal/generated_adminpw password $REPLICATOR_PASSWORD
slapd slapd/internal/adminpw password $REPLICATOR_PASSWORD
slapd slapd/password1 password $REPLICATOR_PASSWORD
slapd slapd/password2 password $REPLICATOR_PASSWORD
slapd slapd/domain string $DOMAIN
slapd shared/organization string Lab
slapd slapd/backend select MDB
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/no_configuration boolean false
EOT
# Note: the adminpw set here is thrown away - idm2's mdb database gets fully
# overwritten by syncrepl from idm1, so its local admin credential doesn't matter.

sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    slapd ldap-utils krb5-kdc krb5-kpropd krb5-config \
    chrony nftables openssh-server git

sudo systemctl disable --now systemd-resolved
sudo systemctl enable nftables --now
sudo systemctl enable ssh --now

sudo tee /etc/systemd/network/10-lan.network > /dev/null <<EOT
[Match]
Name=$NIC

[Network]
Address=$LAN_IP/$LAN_SUBNET_MASK
Gateway=$GATEWAY
EOT

sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOT
nameserver 10.0.0.53
nameserver 10.0.0.54
EOT

sudo rm -fr /etc/netplan/
sudo systemctl unmask systemd-networkd systemd-networkd-wait-online
sudo systemctl enable systemd-networkd systemd-networkd-wait-online
sudo systemctl restart systemd-networkd
sudo networkctl reload
sudo networkctl reconfigure "$NIC"

# --- NTP: prefer idm1, fall back to public pool ---
sudo tee /etc/chrony/chrony.conf > /dev/null <<EOT
server 10.0.0.5 iburst prefer
pool ntp.ubuntu.com iburst
allow 10.0.0.0/24
local stratum 10
makestep 1.0 3
driftfile /var/lib/chrony/chrony.drift
EOT

sudo systemctl enable chrony --now
sudo systemctl restart chrony

##############################################
# TLS: install the bundle copied from idm1
##############################################
sudo mkdir -p /etc/ldap/private
sudo cp /tmp/idm2.crt /etc/ldap/idm2.crt
sudo cp /tmp/ca.crt /etc/ldap/ca.crt
sudo cp /tmp/idm2.key /etc/ldap/private/idm2.key
sudo chown openldap:openldap /etc/ldap/private/idm2.key /etc/ldap/idm2.crt /etc/ldap/ca.crt
sudo chmod 640 /etc/ldap/private/idm2.key
sudo chmod 644 /etc/ldap/idm2.crt /etc/ldap/ca.crt

sudo sed -i 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"|' /etc/default/slapd
grep -q '^SLAPD_SERVICES=' /etc/default/slapd || echo 'SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"' | sudo tee -a /etc/default/slapd

sudo tee /tmp/tls-config.ldif > /dev/null <<EOT
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/ca.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/idm2.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/private/idm2.key
EOT
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/tls-config.ldif

sudo tee -a /etc/ldap/ldap.conf > /dev/null <<EOT
TLS_CACERT /etc/ldap/ca.crt
EOT

##############################################
# Schemas: must match idm1 exactly (not covered by syncrepl)
##############################################
for s in cosine nis inetorgperson; do
    sudo ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/ldap/schema/${s}.ldif || true
done

sudo tee /tmp/sudo-schema.ldif > /dev/null <<'EOT'
dn: cn=sudo,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: sudo
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.1 NAME 'sudoUser' DESC 'User(s) this rule applies to' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.2 NAME 'sudoHost' DESC 'Host(s) this rule applies to' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.3 NAME 'sudoCommand' DESC 'Command(s) to be executed' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.4 NAME 'sudoRunAs' DESC 'Deprecated' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.5 NAME 'sudoOption' DESC 'Options followed by sudo' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.6 NAME 'sudoRunAsUser' DESC 'User(s) impersonated by sudo' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.7 NAME 'sudoRunAsGroup' DESC 'Group(s) impersonated by sudo' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.8 NAME 'sudoNotBefore' DESC 'Start of the entry validity window' EQUALITY generalizedTimeMatch ORDERING generalizedTimeOrderingMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.24 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.9 NAME 'sudoNotAfter' DESC 'End of the entry validity window' EQUALITY generalizedTimeMatch ORDERING generalizedTimeOrderingMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.24 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.10 NAME 'sudoOrder' DESC 'Sort order for a sudoRole' EQUALITY integerMatch ORDERING integerOrderingMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.27 )
olcObjectClasses: ( 1.3.6.1.4.1.15953.9.2.1 NAME 'sudoRole' SUP top STRUCTURAL DESC 'Sudoer entry' MUST ( cn ) MAY ( sudoUser $ sudoHost $ sudoCommand $ sudoRunAs $ sudoRunAsUser $ sudoRunAsGroup $ sudoOption $ sudoNotBefore $ sudoNotAfter $ sudoOrder $ description ) )
EOT
sudo ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/sudo-schema.ldif

##############################################
# Replication: syncrepl consumer, read-only, updates refer to idm1
##############################################
sudo tee /tmp/syncrepl.ldif > /dev/null <<EOT
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcSyncrepl
olcSyncrepl: rid=001
  provider=ldap://idm1.lab.local
  bindmethod=simple
  binddn="cn=replicator,$BASE_DN"
  credentials=$REPLICATOR_PASSWORD
  searchbase="$BASE_DN"
  scope=sub
  schemachecking=on
  type=refreshAndPersist
  retry="60 +"
  starttls=critical
-
add: olcUpdateRef
olcUpdateRef: ldap://idm1.lab.local
EOT
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/syncrepl.ldif

sudo tee /tmp/readonly.ldif > /dev/null <<EOT
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcReadOnly
olcReadOnly: TRUE
EOT
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/readonly.ldif

sudo systemctl restart slapd
sleep 5
echo ">>> Verifying initial sync from idm1..."
sudo ldapsearch -x -H ldap://localhost -b "$BASE_DN" -s base dn || echo "WARNING: initial sync check failed - check 'journalctl -u slapd'"

##############################################
# Kerberos: secondary KDC, no kadmind, receives via kprop
##############################################
sudo mkdir -p /etc/krb5kdc

sudo tee /etc/krb5.conf > /dev/null <<EOT
[libdefaults]
    default_realm = $REALM
    dns_lookup_realm = false
    dns_lookup_kdc = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    $REALM = {
        kdc = idm1.lab.local
        kdc = idm2.lab.local
        admin_server = idm1.lab.local
    }

[domain_realm]
    .lab.local = $REALM
    lab.local = $REALM
EOT

sudo tee /etc/krb5kdc/kdc.conf > /dev/null <<EOT
[realms]
    $REALM = {
        acl_file = /etc/krb5kdc/kadm5.acl
        max_renewable_life = 7d 0h 0m 0s
        supported_enctypes = aes256-cts-hmac-sha384-192:normal aes128-cts-hmac-sha256-128:normal
    }
EOT

# Master key stash MUST be byte-identical to idm1's - copied over, never regenerated here
sudo cp /tmp/k5-stash "/var/lib/krb5kdc/.k5.$REALM"
sudo chmod 600 "/var/lib/krb5kdc/.k5.$REALM"
sudo chown root:root "/var/lib/krb5kdc/.k5.$REALM"

# Who is allowed to push database updates to this box
sudo tee /etc/krb5kdc/kpropd.acl > /dev/null <<EOT
host/idm1.lab.local@$REALM
EOT

sudo cp /tmp/idm2.keytab /etc/krb5.keytab
sudo chmod 600 /etc/krb5.keytab

# No database exists yet - it's created by the first kprop push from idm1.
# krb5-kdc will fail to start until that happens; kpropd needs to be up to receive it.
sudo systemctl enable krb5-kpropd --now

echo ">>> Trigger the first push from idm1 now:"
echo "    ssh idm1.lab.local 'sudo systemctl start kdc-propagate.service'"
echo ">>> Then on idm2: sudo systemctl enable --now krb5-kdc"

##############################################
# Firewall
##############################################
sudo tee /etc/nftables.conf > /dev/null <<EOT
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        iifname "lo" accept
        ip protocol icmp accept

        # SSH only from the management range
        ip saddr 10.0.0.20-10.0.0.29 tcp dport 22 accept

        # Kerberos, from the LAN (no kpasswd here - kadmind only runs on idm1)
        ip saddr 10.0.0.0/24 tcp dport 88 accept
        ip saddr 10.0.0.0/24 udp dport 88 accept

        # LDAP/LDAPS, from the LAN
        ip saddr 10.0.0.0/24 tcp dport { 389, 636 } accept

        # NTP (chrony) from the LAN
        ip saddr 10.0.0.0/24 udp dport 123 accept

        # kprop database push, idm1 only
        ip saddr 10.0.0.5 tcp dport 754 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOT

sudo nft -f /etc/nftables.conf
sudo nft list ruleset
sudo systemctl restart nftables

# Clean up staged secrets now that they're installed
sudo shred -u /tmp/idm2.crt /tmp/idm2.key /tmp/ca.crt /tmp/idm2.keytab /tmp/k5-stash 2>/dev/null || true