#!/bin/ash

# See more details at https://openwrt.org/docs/guide-user/services/vpn/wireguard/road-warrior

# These variables are required: set them before running this script,
# or edit this script to set them:

## Match this to the value used for WG_INTERFACE in wg_roadwarrior.sh
export WG_INTERFACE="vpn"

## Set the hostname or address for the WG server for IPv4 tunnel
## ingress
WG_DDNS="hzwl-yc.synology.me"

## Set this to "0" to use a delegated non-ULA subnet from the WG
## interface.  Set this to "1" to skip using a delegated prefix.  If
## you created the WG server with a delegated prefix, this can be the
## client's choice to use either ONLY_ULA=0 or ONLY_ULA=1, but if you
## created the WG server with only a ULA subnet, then this must be
## ONLY_ULA=1.
#ONLY_ULA="0"

## Optional: set the hostname or address for the WG server for IPv6
## tunnel ingress
#WG_DDNS6="yourserver-ipv6.dyndns.org"

## for debugging, change these to start with 'echo '
UCI=uci
TRIAL=

if [ -z "$1" ]; then
    echo too few arguments: usage $0 peer_name 1>&2
    exit 1
fi
export username="$1"

clear
echo "========================================================="
echo "|               Automated WireGuard Script              |"
echo "|                 Add road-warrior peer                 |"
echo "========================================================="
# Define Variables
if [ -z "${WG_INTERFACE}" ]
then
    echo WG_INTERFACE not set 1>&2
    exit 1
fi
if [ -z "${WG_DDNS}" ]
then
    echo WG_DDNS not set 1>&2
    exit 1
fi
export WG_INTERFACE_NAME=wg_${WG_INTERFACE}
export WG_server_port="$(uci get network.${WG_INTERFACE_NAME}.listen_port)"
ula=$(uci get network.globals.ula_prefix |sed -e 's,::/.*,,')
ticker=1
DUAL_TUNNEL=""
for network in $(uci -q get network.${WG_INTERFACE_NAME}.addresses)
do
    case $network in
        *.*.*.*/*)
            ipv4addr=${network%%/*}
            export interface=$(echo ${ipv4addr} | cut -d . -f 1,2,3)
            export WG_server_IP="${interface}.1"
            ;;

        *:*/*)
            if [ -z "${ONLY_ULA}" ]
            then
                echo ONLY_ULA not set 1>&2
                exit 1
            fi
            ipv6prefix=${network%%::1/*}
            ipv6addr=${network%%/*}
            ulamatch1=${network##fd*}
            ulamatch2=${network##fc*}
            if [ "${ONLY_ULA}" = 0 -o -z "${ulamatch1}" -o -z "${ulamatch2}" ]; then
                export WG_server_IP6_${ticker}=${ipv6addr}
                export interface6_${ticker}="${ipv6prefix}"
                ticker=$((ticker+1))
            fi
            if [ -z "${ulamatch1}" -o -z "${ulamatch2}" ]; then
                export dns6_ula=${ipv6addr}
                export interface6_ula=${ipv6prefix}
            fi
            DUAL_TUNNEL="yes"
            ;;
    esac
    shift
done

if [ -n "$DUAL_TUNNEL" ]
then
    echo IPv4/IPv6 dual tunnel
else
    echo IPv4 only tunnel
fi
if [ -z "$WG_DDNS6" ]
then
    echo only providing tunnel ingress via IPv4
else
    echo including tunnel ingress via IPv6
fi

echo -n "Checking variables... "
if [ -z "${WG_INTERFACE}" -o \
        -z "${interface}" -o \
        -z "${WG_DDNS}" -o \
        -z "${WG_server_port}" -o \
        -z "${WG_server_IP}" ]
then
    echo Insufficient configurations found in existing network "${WG_INTERFACE}" 1>&2
    exit 1
fi

function last_peer_ID () {
        cd "/etc/wireguard/networks/${WG_INTERFACE}/peers"
        ls | sort -V | tail -1 | cut -d '_' -f 1
}

peer_ID=$(last_peer_ID)
if [ -z "$peer_ID" ]; then
    export peer_ID=1
else
    export peer_ID=$((peer_ID+1))
fi
echo using new peer ID ${peer_ID} for ${username}
export peer_IP=$((peer_ID+1))
echo "Done"

if [ -n "$DUAL_TUNNEL" ]
then
    if [ -z "${interface6_1}" -o \
        -z "${dns6_ula}" -o \
        -z "${interface6_ula}" -o \
        -z "${WG_server_IP6_1}" ]
    then
        echo Insufficient EVs or configurations found for IPv6 dual tunnel 1>&2
        exit 1
    fi
    allowed_ips6="${interface6_1}::${interface}.${peer_IP}/128"
    allowed_ips6_ula="${interface6_ula}::${interface}.${peer_IP}/128"
else
    allowed_ips6=""
fi

create_peer_config()
{
    CONFNAME="$1"
    ENDPOINT="$2"
    DNS="$3"
    PEERIPS="$4"
    SERVERIPS="$5"
    # Create peer configuration
    echo -n "Creating config for '${peer_ID}_${WG_INTERFACE}_${username} (${ENDPOINT})'... "
    confdir="/etc/wireguard/networks/${WG_INTERFACE}/peers/${peer_ID}_${WG_INTERFACE}_${username}"
    conffile="${peer_ID}_${WG_INTERFACE}_${username}.${CONFNAME}"
    cat <<-EOF > "${confdir}/${conffile}.conf"
[Interface]
# Name = ${username}-${CONFNAME}
Address = ${PEERIPS}
PrivateKey = $(cat /etc/wireguard/networks/${WG_INTERFACE}/peers/${peer_ID}_${WG_INTERFACE}_${username}/${peer_ID}_${WG_INTERFACE}_${username}_private.key) # Peer's private key
DNS = ${DNS}

[Peer]
PublicKey = $(cat /etc/wireguard/networks/${WG_INTERFACE}/${WG_INTERFACE}_server_public.key) # Server's public key
PresharedKey = $(cat /etc/wireguard/networks/${WG_INTERFACE}/peers/${peer_ID}_${WG_INTERFACE}_${username}/${peer_ID}_${WG_INTERFACE}_${username}.psk) # Peer's pre-shared key
PersistentKeepalive = 25
AllowedIPs = ${SERVERIPS}
Endpoint = ${ENDPOINT}:${WG_server_port}
EOF
    qrencode -t svg -o "${confdir}/${conffile}.svg" -r "${confdir}/${conffile}.conf"
    echo "Done"
}

# Configure Variables
echo ""
echo -n "Defining variables for '${peer_ID}_${WG_INTERFACE}_${username}'... "

# Gather allowed IP addresses: one for provided IPv4 tunnel endpoint
# plus one for each allowed IPv6 address
allowed_ips4="${interface}.${peer_IP}/32"
allowed_ips6_list="${allowed_ips6}"
n=2;
eval "nextinterface=\${interface6_${n}}"
while [ -n "${nextinterface}" ]; do
    echo adding "${nextinterface}"
    ip6="${nextinterface}::${interface}.${peer_IP}/128"
    allowed_ips6="${allowed_ips6},${ip6}"
    allowed_ips6_list="${allowed_ips6_list} ${ip6}"
    n=$((n+1))
    eval "nextinterface=\${interface6_${n}}"
done
allowed_ips="${allowed_ips4},${allowed_ips6}"
allowed_ips_ula="${allowed_ips4},${allowed_ips6_ula}"

# Create directory for storing peers
echo -n "Creating directory for peer '${peer_ID}_${WG_INTERFACE}_${username}'... "
mkdir -p "/etc/wireguard/networks/${WG_INTERFACE}/peers/${peer_ID}_${WG_INTERFACE}_${username}"
echo "Done"

# Generate peer keys
echo -n "Generating peer keys for '${peer_ID}_${WG_INTERFACE}_${username}'... "
wg genkey | tee "/etc/wireguard/networks/${WG_INTERFACE}/peers/${peer_ID}_${WG_INTERFACE}_${username}/${peer_ID}_${WG_INTERFACE}_${username}_private.key" | wg pubkey | tee "/etc/wireguard/networks/${WG_INTERFACE}/peers/${peer_ID}_${WG_INTERFACE}_${username}/${peer_ID}_${WG_INTERFACE}_${username}_public.key" >/dev/null 2>&1
echo "Done"

# Generate Pre-shared key
echo -n "Generating peer PSK for '${peer_ID}_${WG_INTERFACE}_${username}'... "
wg genpsk | tee "/etc/wireguard/networks/${WG_INTERFACE}/peers/${peer_ID}_${WG_INTERFACE}_${username}/${peer_ID}_${WG_INTERFACE}_${username}.psk" >/dev/null 2>&1
echo "Done"

# Add peer to server
echo -n "Adding '${peer_ID}_${WG_INTERFACE}_${username}' to WireGuard server... "
${UCI} add network wireguard_${WG_INTERFACE_NAME} >/dev/null 2>&1
${UCI} set network.@wireguard_${WG_INTERFACE_NAME}[-1].public_key="$(cat /etc/wireguard/networks/${WG_INTERFACE}/peers/${peer_ID}_${WG_INTERFACE}_${username}/${peer_ID}_${WG_INTERFACE}_${username}_public.key)"
${UCI} set network.@wireguard_${WG_INTERFACE_NAME}[-1].preshared_key="$(cat /etc/wireguard/networks/${WG_INTERFACE}/peers/${peer_ID}_${WG_INTERFACE}_${username}/${peer_ID}_${WG_INTERFACE}_${username}.psk)"
${UCI} set network.@wireguard_${WG_INTERFACE_NAME}[-1].description="${username}"
${UCI} add_list network.@wireguard_${WG_INTERFACE_NAME}[-1].allowed_ips="${allowed_ips4}"
for ip6 in ${allowed_ips6_list}
do
    ${UCI} add_list network.@wireguard_${WG_INTERFACE_NAME}[-1].allowed_ips="${ip6}"
done
${UCI} set network.@wireguard_${WG_INTERFACE_NAME}[-1].route_allowed_ips='1'
${UCI} set network.@wireguard_${WG_INTERFACE_NAME}[-1].persistent_keepalive='25'
echo "Done"

if [ -n "$DUAL_TUNNEL" ]
then
   # IPv4 tunnel endpoint, dual stack tunnel
   create_peer_config "${WG_DDNS}-dual" "${WG_DDNS}" "${WG_server_IP},${dns6_ula}" "${allowed_ips}" "0.0.0.0/0,::/0"

   # IPv4 tunnel endpoint, dual stack (ULA only) tunnel
   create_peer_config "${WG_DDNS}-dual-ula" "${WG_DDNS}" "${WG_server_IP},${dns6_ula}" "${allowed_ips_ula}" "0.0.0.0/0,::/0"

   # IPv4 tunnel endpoint, IPv6 tunnel
   create_peer_config "${WG_DDNS}-ipv6" "${WG_DDNS}" "${dns6_ula}" "${allowed_ips6}" "::/0"

   # IPv4 tunnel endpoint, IPv6 ULA tunnel
   create_peer_config "${WG_DDNS}-ipv6-ula" "${WG_DDNS}" "${dns6_ula}" "${allowed_ips6_ula}" "::/0"
fi

# IPv4 tunnel endpoint, IPv4 only tunnel
create_peer_config "${WG_DDNS}-ipv4" "${WG_DDNS}" "${WG_server_IP}" "${allowed_ips4}" "0.0.0.0/0"

if [ -n "$DUAL_TUNNEL" -a -n "$WG_DDNS6" ]
then
    # IPv6 tunnel endpoint, dual stack tunnel
    create_peer_config "${WG_DDNS6}-dual-via6" "${WG_DDNS6}" "${WG_server_IP},${dns6_ula}" "${allowed_ips}" "0.0.0.0/0,::/0"

    # IPv6 tunnel endpoint, dual stack (ULA only) tunnel
    create_peer_config "${WG_DDNS6}-dual-ula-via6" "${WG_DDNS6}" "${WG_server_IP},${dns6_ula}" "${allowed_ips_ula}" "0.0.0.0/0,::/0"
fi

# Commit UCI changes
echo -en "\nCommiting changes... "
${UCI} commit
echo "Done"

# Restart WireGuard interface
echo -en "\nRestarting WireGuard interface... "
${TRIAL} ifup ${WG_INTERFACE_NAME}
echo "Done"

# Restart firewall
echo -en "\nRestarting firewall... "
${TRIAL} service firewall restart 2>/dev/null
echo "Done"