#!/bin/bash

set -e

VPN_USER=${1:-$USER}
CONNECTION_NAME=LShift.de

connection_create() {
    nmcli con add type vpn ifname "*" con-name $CONNECTION_NAME \
          autoconnect no vpn-type openvpn
}

connection_info() {
    nmcli con show $CONNECTION_NAME 2>/dev/null
}

connection_mod() {
    echo "Setting $2 = $3"
    nmcli con mod "$@"
}

connection_info >/dev/null || connection_create

UUID=$(connection_info|grep connection.uuid|awk '{ print $2 }')

echo "Modifying ${CONNECTION_NAME} (${UUID})"

connection_mod $UUID connection.autoconnect  no
connection_mod $UUID connection.zone         work
connection_mod $UUID ipv4.method             auto
connection_mod $UUID ipv4.dhcp-send-hostname yes
connection_mod $UUID ipv4.never-default      yes
connection_mod $UUID ipv4.may-fail           yes
connection_mod $UUID ipv6.method             ignore
connection_mod $UUID vpn.data \
               "key = /etc/openvpn/${VPN_USER}.key, cert-pass-flags = 0, connection-type = tls, cert = /etc/openvpn/${VPN_USER}.crt, ca = /etc/openvpn/openvpn.crt, remote = vpn.lshift.de, comp-lzo = yes"
