#!/bin/ash
#
# See more details at https://openwrt.org/docs/guide-user/services/vpn/wireguard/road-warrior

# The following configuration variables are required: set them before
# running this script, or edit this script to set them:

## The base name for the wireguard interface.
## this will have "wg_" prepended to it.
export WG_INTERFACE="vpn"

## The WireGuard server port (UDP), this must be unused by other
## WireGuard interfaces or programs
export WG_SERVER_PORT="51821"

## The (existing) firewall zone for the interface that will receive
## IPv4-ingress tunnel traffic
export WG_WAN4_FWZONE="wan"

## The (existing) firewall zone name for the new WG interface
export WG_FWZONE="lan"

##An IPv4 /24 subnet (without last octet) for the IPv4 tunnel
export WG_IPV4_SUBNET="192.168.10"

## To use only IPv4 in the tunnel, leave the rest of these
## variables below commented out.

########## Optional IPv6 config below ##############

## The (existing) firewall zone for the interface that will receive
## IPv6-ingress tunnel traffic (May be identical to WG_WAN4_FWZONE)
#export WG_WAN6_FWZONE="wan"

## The prefix hint is used to compose a subnet from the /48 ULA prefix
## (obtained from the system config).  It will be composed like
## ${ULA_PREFIX}:${WG_IPV6_PREFIX_HINT}::/64
## Choose a prefix hint that is not used for any interfaces's ip6hint
## value.
#export WG_IPV6_PREFIX_HINT=4

## To use only ULA IPv6 addresses in the tunnel (no delegated
## addresses), omit WG_DELEGATED_PREFIX6.

## The prefix hint is also used to compose a subnet from the
## WG_DELEGATED_PREFIX6, but without a separating colon, so that if
## you have a prefix larger than 48, you can use hex digits to select
## the subnet.

## for a /48 prefix delegation, use a prefix up to 16 bits, so you get
## WG_delegated_interface6="nnnn:nnnn:nnnn:${WG_IPV6_PREFIX_HINT}"
#export WG_DELEGATED_PREFIX6="nnnn:nnnn:nnnn:"

## for a /56 prefix delegation, use a two-digit hex WG_IPV6_PREFIX_HINT,
## so you get WG_delegated_interface6="nnnn:nnnn:nn${WG_IPV6_PREFIX_HINT}"
#export WG_DELEGATED_PREFIX6="nnnn:nnnn:nn"

## for a /60 prefix delegation, use a one-digit hex WG_IPV6_PREFIX_HINT,
## so you get WG_delegated_interface6="nnnn:nnnn:nnn${WG_IPV6_PREFIX_HINT}"
#export WG_DELEGATED_PREFIX6="nnnn:nnnn:nnn"

clear
echo "======================================"
echo "|     Automated WireGuard Script     |"
echo "|     road-warrior server setup      |"
echo "======================================"
# Define Variables
echo -n "Defining variables... "

check_ev()
{
    evname=$1
    eval value="\$${evname}"
    if [ -z "$value" ]
    then
        echo $evname not set 1>&2
        exit 1
    fi
}

check_ev WG_INTERFACE
check_ev WG_IPV4_SUBNET
check_ev WG_SERVER_PORT
check_ev WG_FWZONE
check_ev WG_WAN4_FWZONE

find_fwzone()
{
    zone=$1
    varname=$2

    n=0
    while zname=$(uci -q get firewall.@zone[$n].name); do
        if [ "$zname" = "$zone" ]; then
            eval $varname="@zone[$n]"
            return
        fi
        n=$((n+1))
    done

    echo Unable to find firewall zone ${zone}. 1>&2
    exit 1
}

find_fwzone ${WG_FWZONE} WG_firewall_zone
find_fwzone ${WG_WAN4_FWZONE} scratch

if [ \
        -z "$WG_IPV6_PREFIX_HINT" -o \
        -z "$WG_WAN6_FWZONE" ]
then
    echo "IPv4 only mode"
    DUAL_TUNNEL=""
else
    find_fwzone ${WG_WAN6_FWZONE} scratch

    if [ -n "$WG_DELEGATED_PREFIX6" ]
    then
        export WG_delegated_interface6="${WG_DELEGATED_PREFIX6}${WG_IPV6_PREFIX_HINT}"
        echo "IPv6 ULA and delegated prefix mode"
        export WG_server_IP6_delegated="${WG_delegated_interface6}::1"
    else
        echo "IPv6 ULA only mode"
    fi
    echo "IPv4/IPv6 dual tunnel mode"
    DUAL_TUNNEL=yes
    ## TODO: future: determine upstream settings/prefixes/etc
    ## Look at https://openwrt.org/docs/guide-developer/jshn
    # case $(uci get network.wan6.proto) in
    #   6in4)
    #   # Use ifstatus wan with jshn
    #   ;;
    #   dhcpv6)
    #   # TODO: get this from ifstatus?
    #   ;;
    # esac
    if ! uci -q get network.globals.ula_prefix >/dev/null
    then
        echo "No ULA defined, unable to proceed." 1>&2
        exit 1
    fi
    ula=$(uci get network.globals.ula_prefix)
    ula=${ula%%::/*}
    export interface6_ula="${ula}:${WG_IPV6_PREFIX_HINT}"
    export WG_server_IP6_ula="${interface6_ula}::1"
fi

export WG_server_IP="${WG_IPV4_SUBNET}.1"
export WG_INTERFACE_NAME=wg_${WG_INTERFACE}
export WG_NAT6_name=nat6_${WG_INTERFACE_NAME}
echo "Done"

# Create directories
echo -n "Creating directories and pre-defining permissions on those directories... "
wg_directory=/etc/wireguard
mkdir -p ${wg_directory}/networks/${WG_INTERFACE}/peers
chmod 700 ${wg_directory}/networks/${WG_INTERFACE}
if ! fgrep -w -q ${wg_directory} /etc/sysupgrade.conf && \
   ! fgrep -w -q ${wg_directory}/ /etc/sysupgrade.conf
then
    echo ${wg_directory} >>/etc/sysupgrade.conf
fi
echo "Done"

# Remove pre-existing WireGuard interface
echo -n "Removing pre-existing WireGuard interface... "
uci -q del network.${WG_INTERFACE_NAME}
uci -q del_list firewall.${WG_firewall_zone}.network="${WG_INTERFACE_NAME}"
echo -n "Disabling pre-existing firewall script... "
uci -q delete firewall.${WG_NAT6_name}
echo "Done"

# Generate WireGuard server keys
echo -n "Generating WireGuard server keys for '${WG_INTERFACE}' network... "
wg genkey | tee "${wg_directory}/networks/${WG_INTERFACE}/${WG_INTERFACE}_server_private.key" | wg pubkey | tee "${wg_directory}/networks/${WG_INTERFACE}/${WG_INTERFACE}_server_public.key" >/dev/null 2>&1
echo "Done"

# Create WireGuard interface for 'LAN' network
echo -n "Creating WireGuard interface for '${WG_INTERFACE}' network... "
uci set network.${WG_INTERFACE_NAME}=interface
uci set network.${WG_INTERFACE_NAME}.proto='wireguard'
uci set network.${WG_INTERFACE_NAME}.private_key="$(cat ${wg_directory}/networks/${WG_INTERFACE}/${WG_INTERFACE}_server_private.key)"
uci set network.${WG_INTERFACE_NAME}.listen_port="${WG_SERVER_PORT}"
uci add_list network.${WG_INTERFACE_NAME}.addresses="${WG_server_IP}/24"
if [ -n "$DUAL_TUNNEL" ]
then
    uci add_list network.${WG_INTERFACE_NAME}.addresses="${WG_server_IP6_ula}/64"
    if [ -n "${WG_server_IP6_delegated}" ]
    then
        uci add_list network.${WG_INTERFACE_NAME}.addresses="${WG_server_IP6_delegated}/64"
    fi
fi
uci add_list firewall.${WG_firewall_zone}.network="${WG_INTERFACE_NAME}"
uci set network.${WG_INTERFACE_NAME}.mtu='1280'
echo "Done"

# Add firewall rule
echo -n "Adding firewall rules for '${WG_INTERFACE}' network... "
uci set firewall.wg_rule_${WG_INTERFACE}="rule"
uci set firewall.wg_rule_${WG_INTERFACE}.name="Allow-WireGuard-${WG_INTERFACE}-${WG_WAN4_FWZONE}"
uci set firewall.wg_rule_${WG_INTERFACE}.src="${WG_WAN4_FWZONE}"
uci set firewall.wg_rule_${WG_INTERFACE}.dest_port="${WG_SERVER_PORT}"
uci set firewall.wg_rule_${WG_INTERFACE}.proto="udp"
uci set firewall.wg_rule_${WG_INTERFACE}.target="ACCEPT"

if [ -n "$DUAL_TUNNEL" ]
then
    if [ "${WG_WAN6_FWZONE}" != "${WG_WAN4_FWZONE}" ]
    then
        uci set firewall.wg_rule6_${WG_INTERFACE}="rule"
        uci set firewall.wg_rule6_${WG_INTERFACE}.name="Allow-WireGuard-${WG_INTERFACE}-${WG_WAN6_FWZONE}"
        uci set firewall.wg_rule6_${WG_INTERFACE}.src="${WG_WAN6_FWZONE}"
        uci set firewall.wg_rule6_${WG_INTERFACE}.dest_port="${WG_SERVER_PORT}"
        uci set firewall.wg_rule6_${WG_INTERFACE}.proto="udp"
        uci set firewall.wg_rule6_${WG_INTERFACE}.target="ACCEPT"
    fi

    if [ -d /etc/nftables.d ]; then
        # Create NAT6 firewall chain for ULA egress
        fwscript=/etc/nftables.d/${WG_NAT6_name}.nft
        cat >${fwscript} <<EOF
# Created by ${0##*/}
chain srcnat_ula6_${WG_INTERFACE} {
  type nat hook postrouting priority srcnat; policy accept;
  oifname "\$${WG_WAN6_FWZONE}_devices" ip6 saddr ${interface6_ula}::/64 counter masquerade comment "!fw4: ULA masquerade6"
}
EOF
    else
        # Create NAT6 firewall addition script for ULA
        fwscript=/etc/firewall.${WG_NAT6_name}.sh
        cat >$fwscript <<EOF
#!/bin/sh
# Created by ${0##*/}
MY_NETWORK=${WG_INTERFACE_NAME}
NET_PFX6="${interface6_ula}::/64"
. /lib/functions/network.sh
network_flush_cache
network_find_wan6 NET_IF6
network_get_device NET_DEV6 "\${NET_IF6}"
if [ -n "\${NET_DEV6}" ];
then
  logger -t firewall.${WG_NAT6_name} -p info -- adding NAT/MASQUERADE for source net "\${NET_PFX6}" through "\${NET_DEV6}"
  ip6tables -t nat -A POSTROUTING -s "\${NET_PFX6}" -o "\${NET_DEV6}" -j MASQUERADE
fi

exit 0
EOF
        chmod 555 $fwscript

        uci set firewall.${WG_NAT6_name}="include"
        uci set firewall.${WG_NAT6_name}.path="${fwscript}"
        uci set firewall.${WG_NAT6_name}.reload='1'
    fi
    if ! fgrep -w -q ${fwscript} /etc/sysupgrade.conf; then
        echo ${fwscript} >>/etc/sysupgrade.conf
    fi

fi
echo "Done"

# Remove existing peers
echo -n "Removing pre-existing peers... "
while uci -q delete network.@wireguard_${WG_INTERFACE_NAME}[0]; do :; done
rm -R ${wg_directory}/networks/${WG_INTERFACE}/peers/* >/dev/null 2>&1
echo "Done"

# Commit UCI changes
echo -en "\nCommiting changes... "
uci commit
echo "Done"

# Restart WireGuard interface
echo -en "\nRestarting WireGuard interface... "
ifup ${WG_INTERFACE_NAME}
echo "Done"

# Restart firewall
echo -en "\nRestarting firewall... "
service firewall restart >/dev/null 2>&1
echo "Done"