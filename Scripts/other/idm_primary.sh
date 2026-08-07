#!/bin/bash
set -euo pipefail

# Check if the correct number of arguments is provided
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <LDAP_ADMIN_PASSWORD> <REPLICATOR_PASSWORD> <KRB5_MASTER_PASSWORD> <KRB5_ADMIN_PASSWORD>"
    echo "Example: bash idm1.sh ldapPass1 replPass2 krbMaster3 krbAdmin4"
    exit 1
fi

LDAP_ADMIN_PASSWORD=$1
REPLICATOR_PASSWORD=$2
KRB5_MASTER_PASSWORD=$3
KRB5_ADMIN_PASSWORD=$4

# Interface
NIC=ens34
LAN_IP=10.0.0.5
LAN_SUBNET_MASK=24
GATEWAY=10.0.0.1

REALM=LAB.LOCAL
DOMAIN=lab.local
BASE_DN="dc=lab,dc=local"

sudo hostnamectl set-hostname "idm1.lab.local"

sudo apt update && sudo apt upgrade -y

# slapd              - OpenLDAP directory server
# ldap-utils         - ldapadd/ldapsearch/ldapmodify
# krb5-kdc           - Kerberos KDC
# krb5-admin-server  - kadmind (principal admin, only runs on the primary)
# krb5-config        - realm defaults for the krb5 libs
# chrony             - accurate time is mandatory for Kerberos
# openssl            - self-signed CA + server certs for LDAPS
# nftables           - firewall
# openssh-server     - remote management
# git                - pulling config from your repo
sudo debconf-set-selections <<EOT
krb5-config krb5-config/default_realm string $REALM
krb5-config krb5-config/kerberos_servers string idm1.lab.local
krb5-config krb5-config/admin_server string idm1.lab.local
slapd slapd/internal/generated_adminpw password $LDAP_ADMIN_PASSWORD
slapd slapd/internal/adminpw password $LDAP_ADMIN_PASSWORD
slapd slapd/password1 password $LDAP_ADMIN_PASSWORD
slapd slapd/password2 password $LDAP_ADMIN_PASSWORD
slapd slapd/domain string $DOMAIN
slapd shared/organization string Lab
slapd slapd/backend select MDB
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/no_configuration boolean false
EOT

sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    slapd ldap-utils krb5-kdc krb5-admin-server krb5-config \
    chrony openssl nftables openssh-server git

sudo systemctl disable --now systemd-resolved
sudo systemctl enable nftables --now
sudo systemctl enable ssh --now

# LAN interface
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

# --- NTP ---
sudo tee /etc/chrony/chrony.conf > /dev/null <<EOT
pool ntp.ubuntu.com iburst
allow 10.0.0.0/24
local stratum 10
makestep 1.0 3
driftfile /var/lib/chrony/chrony.drift
EOT

sudo systemctl enable chrony --now
sudo systemctl restart chrony

##############################################
# TLS: self-signed CA + certs for idm1 & idm2
##############################################
sudo mkdir -p /etc/ldap/private
cd /tmp

# CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -subj "/CN=lab.local Lab CA" -out ca.crt

# idm1 server cert
openssl genrsa -out idm1.key 2048
openssl req -new -key idm1.key -subj "/CN=idm1.lab.local" -out idm1.csr
openssl x509 -req -in idm1.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out idm1.crt -days 730 -sha256 \
    -extfile <(printf "subjectAltName=DNS:idm1.lab.local,DNS:ldap.lab.local,IP:10.0.0.5")

# idm2 server cert (signed here since this box holds the CA key; copy to idm2 manually)
openssl genrsa -out idm2.key 2048
openssl req -new -key idm2.key -subj "/CN=idm2.lab.local" -out idm2.csr
openssl x509 -req -in idm2.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out idm2.crt -days 730 -sha256 \
    -extfile <(printf "subjectAltName=DNS:idm2.lab.local,DNS:ldap.lab.local,IP:10.0.0.6")

sudo cp ca.crt idm1.crt idm1.key /etc/ldap/private/
sudo mv /etc/ldap/private/idm1.crt /etc/ldap/idm1.crt
sudo mv /etc/ldap/private/ca.crt /etc/ldap/ca.crt
sudo chown openldap:openldap /etc/ldap/private/idm1.key /etc/ldap/idm1.crt /etc/ldap/ca.crt
sudo chmod 640 /etc/ldap/private/idm1.key
sudo chmod 644 /etc/ldap/idm1.crt /etc/ldap/ca.crt

# Stage idm2's bundle for manual transfer - do NOT leave the CA key lying around after
mkdir -p /tmp/idm2-bundle
cp idm2.crt idm2.key ca.crt /tmp/idm2-bundle/
echo ">>> idm2 TLS bundle staged at /tmp/idm2-bundle - copy these 3 files to idm2 before running idm2.sh:"
echo ">>>   scp /tmp/idm2-bundle/* sysadmin@10.0.0.6:/tmp/"
rm -f ca.key idm1.csr idm2.csr ca.srl   # don't leave the CA private key on disk longer than needed

# Enable ldaps:/// alongside ldap:/// and ldapi:///
sudo sed -i 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"|' /etc/default/slapd
grep -q '^SLAPD_SERVICES=' /etc/default/slapd || echo 'SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"' | sudo tee -a /etc/default/slapd

sudo tee /tmp/tls-config.ldif > /dev/null <<EOT
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/ca.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/idm1.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/private/idm1.key
EOT
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/tls-config.ldif

sudo tee -a /etc/ldap/ldap.conf > /dev/null <<EOT
TLS_CACERT /etc/ldap/ca.crt
EOT

##############################################
# Schemas: cosine/nis/inetorgperson + sudoRole
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
# Base tree: People, Groups, Sudoers, replicator
##############################################
sudo tee /tmp/base-structure.ldif > /dev/null <<EOT
dn: ou=People,$BASE_DN
objectClass: organizationalUnit
ou: People

dn: ou=Groups,$BASE_DN
objectClass: organizationalUnit
ou: Groups

dn: ou=Sudoers,$BASE_DN
objectClass: organizationalUnit
ou: Sudoers

dn: cn=replicator,$BASE_DN
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
description: Bind account used by idm2 for LDAP replication only
userPassword: $REPLICATOR_PASSWORD
EOT
sudo ldapadd -x -D "cn=admin,$BASE_DN" -w "$LDAP_ADMIN_PASSWORD" -f /tmp/base-structure.ldif

##############################################
# ACLs: protect userPassword, allow replicator full read
##############################################
sudo tee /tmp/acl.ldif > /dev/null <<EOT
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by dn.exact="cn=replicator,$BASE_DN" read by anonymous auth by * none
olcAccess: {1}to dn.subtree="$BASE_DN" by dn.exact="cn=replicator,$BASE_DN" read by * break
olcAccess: {2}to * by self write by dn.exact="cn=admin,$BASE_DN" write by * read
EOT
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/acl.ldif

##############################################
# Replication: syncprov overlay on this provider
##############################################
sudo tee /tmp/syncprov.ldif > /dev/null <<EOT
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov.la

dn: olcOverlay=syncprov,olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
EOT
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/syncprov.ldif

sudo systemctl restart slapd

##############################################
# Kerberos KDC (primary) + kadmind
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

sudo tee /etc/krb5kdc/kadm5.acl > /dev/null <<EOT
*/admin@$REALM  *
EOT

printf '%s\n%s\n' "$KRB5_MASTER_PASSWORD" "$KRB5_MASTER_PASSWORD" | sudo kdb5_util create -s -r "$REALM"

sudo kadmin.local -q "addprinc -pw $KRB5_ADMIN_PASSWORD admin/admin"

# Host principals for replication/kprop auth on both KDCs
sudo kadmin.local -q "addprinc -randkey host/idm1.lab.local"
sudo kadmin.local -q "ktadd host/idm1.lab.local"
sudo kadmin.local -q "addprinc -randkey host/idm2.lab.local"
sudo kadmin.local -q "ktadd -k /tmp/idm2-bundle/idm2.keytab host/idm2.lab.local"
sudo chmod 644 /tmp/idm2-bundle/idm2.keytab
echo ">>> idm2's keytab is also staged at /tmp/idm2-bundle/idm2.keytab - copy it along with the TLS bundle"

sudo systemctl enable krb5-kdc --now
sudo systemctl enable krb5-admin-server --now

##############################################
# kprop: push the KDC database to idm2 periodically
##############################################
sudo tee /usr/local/sbin/kdc-propagate.sh > /dev/null <<'EOT'
#!/bin/bash
set -euo pipefail
kdb5_util dump /var/lib/krb5kdc/replica_datatrans
kprop -f /var/lib/krb5kdc/replica_datatrans idm2.lab.local
EOT
sudo chmod +x /usr/local/sbin/kdc-propagate.sh

sudo tee /etc/systemd/system/kdc-propagate.service > /dev/null <<EOT
[Unit]
Description=Propagate Kerberos KDC database to idm2

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kdc-propagate.sh
EOT

sudo tee /etc/systemd/system/kdc-propagate.timer > /dev/null <<EOT
[Unit]
Description=Run kdc-propagate.service every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOT

sudo systemctl daemon-reload
sudo systemctl enable --now kdc-propagate.timer

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

        # Kerberos + kpasswd, from the LAN
        ip saddr 10.0.0.0/24 tcp dport { 88, 464 } accept
        ip saddr 10.0.0.0/24 udp dport { 88, 464 } accept

        # LDAP/LDAPS, from the LAN
        ip saddr 10.0.0.0/24 tcp dport { 389, 636 } accept

        # NTP (chrony) from the LAN
        ip saddr 10.0.0.0/24 udp dport 123 accept
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

echo "=========================================================="
echo "idm1 provisioned. Before running idm2.sh, copy these files"
echo "from idm1 to idm2 (over an already-trusted channel, e.g. ssh):"
echo "  /tmp/idm2-bundle/idm2.crt        -> idm2:/tmp/idm2.crt"
echo "  /tmp/idm2-bundle/idm2.key        -> idm2:/tmp/idm2.key"
echo "  /tmp/idm2-bundle/ca.crt          -> idm2:/tmp/ca.crt"
echo "  /tmp/idm2-bundle/idm2.keytab     -> idm2:/tmp/idm2.keytab"
echo "  /var/lib/krb5kdc/.k5.$REALM      -> idm2:/tmp/k5-stash"
echo "    (the Kerberos master key stash - idm2 MUST use the same one)"
echo "=========================================================="