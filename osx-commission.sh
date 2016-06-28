 #!/bin/bash

set -e

KDC=ipa.in.lshift.de
CONF_KRB5=/Library/Preferences/edu.mit.Kerberos
CONF_SSH=/etc/ssh_config
CONF_SSHD=/etc/sshd_config
PAM_AUTH=/etc/pam.d/authorization
SCRIPTS=/Library/Scripts/LShift.de
FIREFOX=/Applications/Firefox.app/Contents/Resources
OD=/Library/Preferences/OpenDirectory/Configurations/LDAPv3/${KDC}.plist
HOST=$1
IFACE=$2

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

if [[ $# -ne 2 ]]; then
    echo "Usage: osx-commission.sh HOSTNAME IFACE"
    exit 1
fi

if [[ ! -e /etc/krb5.keytab ]]; then
    echo "Need valid keytab file at /etc/krb5.keytab"
    exit 1
fi

backup() {
    if [[ -e $1 ]]; then
        cp -f $1{,~}
    fi
}

report() {
    echo -n ">> $1... "
}

report_done() {
    echo "done"
}

report "Probing IPA server"
curl -sI $KDC > /dev/null
report_done

report "Setting NTP configuration"
systemsetup -setusingnetworktime on > /dev/null
systemsetup -setnetworktimeserver $KDC
report_done

report "Setting hostname to $HOST"
scutil --set HostName $HOST
report_done

report "Downloading IPA certificate"
mkdir -p /etc/ipa
curl -o /etc/ipa/ca.crt -L http://$KDC/ipa/config/ca.crt
report_done

report "Writing Kerberos configuration"
backup $CONF_KRB5
cat > $CONF_KRB5 <<EOF
[domain_realm]
    .in.lshift.de = IN.LSHIFT.DE
    in.lshift.de = IN.LSHIFT.DE

[libdefaults]
    default_realm = IN.LSHIFT.DE
    dns_lookup_realm = true
    dns_lookup_kdc = true
    rdns = false
    ticket_lifetime = 24h
    forwardable = yes
    renewable = true

[realms]
    IN.LSHIFT.DE = {
        pkinit_anchors = FILE:/etc/ipa/ca.crt
    }
EOF
report_done

report "Writing PAM authentication configuration"
backup $PAM_AUTH 
cat > $PAM_AUTH <<EOF
# authorization: auth account
auth       optional       pam_krb5.so use_first_pass use_kcminit default_principal
auth       sufficient     pam_krb5.so use_first_pass default_principal
auth       optional       pam_ntlm.so use_first_pass
auth       required       pam_opendirectory.so use_first_pass nullok
account    required       pam_opendirectory.so
EOF
report_done

report "Setting up IPA LDAP configuration"
dsconfigldap -r $KDC ||:
dsconfigldap -s -e -n "IPA LDAP" -a $KDC
dscl localhost -merge /Search CSPSearchPath /LDAPv3/$KDC
dscl localhost -merge /Contact CSPSearchPath /LDAPv3/$KDC

# odutil show configuration /LDAPv3/${KDC}
# plutil -convert json -r -o - $OD

plutil -convert binary1 -o $OD - <<'EOF'
{
  "mappings" : {
    "attributes" : [
      "objectClass"
    ],
    "function" : "ldap:translate_recordtype",
    "recordtypes" : {
      "dsRecTypeStandard:Users" : {
        "attributetypes" : {
          "dsAttrTypeStandard:NFSHomeDirectory" : {
            "native" : "#\/Users\/$uid$"
          },
          "dsAttrTypeStandard:RecordName" : {
            "native" : "uid"
          },
          "dsAttrTypeStandard:HomeDirectory" : {
            "native" : "#\/Users\/$uid$"
          },
          "dsAttrTypeStandard:RealName" : {
            "native" : "cn"
          },
          "dsAttrTypeStandard:PrimaryGroupID" : {
            "native" : "gidNumber"
          },
          "dsAttrTypeStandard:UniqueID" : {
            "native" : "uidNumber"
          },
          "dsAttrTypeStandard:UserShell" : {
            "native" : "loginShell"
          },
          "dsAttrTypeStandard:AuthenticationAuthority" : {
            "native" : "uid"
          }
        },
        "info" : {
          "Group Object Classes" : "OR",
          "Object Classes" : [
            "inetOrgPerson"
          ],
          "Search Base" : "dc=in,dc=lshift,dc=de"
        }
      },
      "dsRecTypeStandard:Groups" : {
        "attributetypes" : {
          "dsAttrTypeStandard:RecordName" : {
            "native" : "cn"
          },
          "dsAttrTypeStandard:PrimaryGroupID" : {
            "native" : "gidNumber"
          }
        },
        "info" : {
          "Group Object Classes" : "OR",
          "Object Classes" : [
            "posixgroup"
          ],
          "Search Base" : "cn=groups,cn=accounts,dc=in,dc=lshift,dc=de"
        }
      }
    }
  },
  "trusttype" : "anonymous",
  "module options" : {
    "AppleODClient" : {
      "Server Mappings" : false
    },
    "ldap" : {
      "Use DNS replicas" : false,
      "Denied SASL Methods" : [
        "DIGEST-MD5"
      ],
      "LDAP Referrals" : false
    }
  },
  "node name" : "\/LDAPv3\/ipa.in.lshift.de",
  "description" : "IPA LDAP",
  "options" : {
    "man-in-the-middle" : false,
    "connection setup timeout" : 10,
    "destination" : {
      "other" : "ldap",
      "host" : "ipa.in.lshift.de",
      "port" : 389
    },
    "packet encryption" : 1,
    "no cleartext authentication" : false,
    "packet signing" : 1,
    "query timeout" : 30,
    "connection idle disconnect" : 60
  },
  "template" : "LDAPv3",
  "uuid" : "A2C6364D-A7EE-4872-AFC2-9AA10D7C1EA4"
}
EOF
report_done

report "Activating network logins"
defaults write /Library/Preferences/com.apple.loginwindow SHOWFULLNAME -bool true
dseditgroup -o delete -T group com.apple.access_loginwindow &>/dev/null ||:
report_done
    
report "Restarting LDAP services"
dscacheutil -flushcache
launchctl stop org.openldap.slapd &>/dev/null ||:
report_done

report "Sending DNS forward record"
kinit -k -t /etc/krb5.keytab -p host/$HOST
nsupdate -g <<EOF
update add $HOST 86400 A $(ipconfig getifaddr $IFACE)
send
EOF
report_done

report "Enabling SSH GSSAPI support"

backup $CONF_SSH

if ! grep -q 'Host *.in.lshift.de' $CONF_SSH; then
    cat >> $CONF_SSH <<'EOF'
Host *.in.lshift.de
  GSSAPIAuthentication yes
  GSSAPIDelegateCredentials yes
EOF
fi

if ! grep -qE '^GSSAPIAuthentication yes' $CONF_SSHD; then
    backup $CONF_SSHD
    cat >> $CONF_SSHD <<'EOF'
GSSAPIAuthentication yes
EOF
fi
report_done

report "Writing Chrome config"
defaults write /Library/Preferences/com.google.Chrome.plist AuthServerWhitelist '.in.lshift.de'
defaults write /Library/Preferences/com.google.Chrome.plist AuthNegotiateDelegateWhitelist '.in.lshift.de'
report_done

report "Importing CA into system keychain"
security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /etc/ipa/ca.crt
report_done

# sudo dseditgroup -o edit -a geoff -t user wheel
