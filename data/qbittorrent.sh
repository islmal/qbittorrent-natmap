#!/usr/bin/env bash

VPN_IF_NAME=Torrent
QBITTORRENT_SERVER=127.0.0.1
QBITTORRENT_PORT=8080
QBITTORRENT_USER=admin
QBITTORRENT_PASS=admins
VPN_GATEWAY=10.2.0.1
NAT_LEASE_LIFETIME=60

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

getpublicip() {
    # shellcheck disable=SC2086
    natpmpc -g ${VPN_GATEWAY} | grep -oP '(?<=Public.IP.address.:.).*'
}

findconfiguredport() {
    curl -s -i --header "Referer: http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}" --cookie "$1" "http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/preferences" | grep -oP '(?<=\"listen_port\"\:)(\d{1,5})'
}

findactiveport() {
    # shellcheck disable=SC2086
    natpmpc -a 1 0 udp ${NAT_LEASE_LIFETIME} -g ${VPN_GATEWAY} >/dev/null 2>&1
    # shellcheck disable=SC2086
    natpmpc -a 1 0 tcp ${NAT_LEASE_LIFETIME} -g ${VPN_GATEWAY} | grep -oP '(?<=Mapped public port.).*(?=.protocol.*)'
}

qbt_login() {
    qbt_sid=$(curl -s -i --header "Referer: http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}" --data "username=${QBITTORRENT_USER}" --data-urlencode "password=${QBITTORRENT_PASS}" "http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/auth/login" | grep -oP '(?!set-cookie:.)SID=.*(?=\;.HttpOnly\;)')
    return $?
}

qbt_changeport(){
    curl -s -i --header "Referer: http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}" --cookie "$1" --data-urlencode "json={\"listen_port\":$2,\"random_port\":false,\"upnp\":false}" "http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/setPreferences" >/dev/null 2>&1
    return $?
}

qbt_checksid(){
    if curl -s --header "Referer: http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}" --cookie "${qbt_sid}" "http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/version" | grep -qi forbidden; then
        return 1
    else
        return 0
    fi
}

qbt_isreachable(){
    # shellcheck disable=SC2086
    nc -4 -vw 5 ${QBITTORRENT_SERVER} ${QBITTORRENT_PORT} &>/dev/null 2>&1
}

fw_delrule(){
    if (/sbin/iptables -L INPUT -n | grep -qP "^ACCEPT.*${configured_port}.*"); then
        # shellcheck disable=SC2086
       /sbin/iptables -D INPUT -i "${VPN_IF_NAME}" -p tcp --dport ${configured_port} -j ACCEPT
        # shellcheck disable=SC2086
       /sbin/iptables -D INPUT -i "${VPN_IF_NAME}" -p udp --dport ${configured_port} -j ACCEPT
    fi
}

fw_addrule(){
    if ! (/sbin/iptables -L INPUT -n | grep -qP "^ACCEPT.*${active_port}.*"); then
        # shellcheck disable=SC2086
        /sbin/iptables -A INPUT -i "${VPN_IF_NAME}" -p tcp --dport ${active_port} -j ACCEPT
        # shellcheck disable=SC2086
        /sbin/iptables -A INPUT -i "${VPN_IF_NAME}" -p udp --dport ${active_port} -j ACCEPT
        return 0
    else
        return 1
    fi
}

get_portmap() {
    res=0
    public_ip=$(getpublicip)

    if ! qbt_checksid; then
        echo "$(timestamp) | qBittorrent Cookie invalid, getting new SessionID"
        if ! qbt_login; then
            echo "$(timestamp) | Failed getting new SessionID from qBittorrent"
	          return 1
        fi
    else
        echo "$(timestamp) | qBittorrent SessionID Ok!"
    fi

    configured_port=$(findconfiguredport "${qbt_sid}")
    active_port=$(findactiveport)

    echo "$(timestamp) | Public IP: ${public_ip}"
    echo "$(timestamp) | Configured Port: ${configured_port}"
    echo "$(timestamp) | Active Port: ${active_port}"

    # shellcheck disable=SC2086
    if [ ${configured_port} != ${active_port} ]; then
        if qbt_changeport "${qbt_sid}" ${active_port}; then
            if fw_delrule; then
                echo "$(timestamp) | IPTables rule deleted for port ${configured_port} on QBIT container"
            fi
            echo "$(timestamp) | Port Changed to: $(findconfiguredport ${qbt_sid})"
        else
            echo "$(timestamp) | Port Change failed."
            res=1
        fi
    else
        echo "$(timestamp) | Port OK (Act: ${active_port} Cfg: ${configured_port})"
    fi

    if fw_addrule; then
        echo "$(timestamp) | IPTables rule added for port ${active_port} on Qbitcontainer container"
    fi

    return $res
}

load_vals(){
    public_ip=$(getpublicip)
    if qbt_isreachable; then
        if qbt_login; then
            configured_port=$(findconfiguredport "${qbt_sid}")
        else
            echo "$(timestamp) | Unable to login to qBittorrent at ${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}"
            exit 7
        fi
    else
        echo "$(timestamp) | Unable to reach qBittorrent at ${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}"
        exit 6
    fi
    active_port=''
}

public_ip=
configured_port=
active_port=
qbt_sid=

while true;
do
    if get_portmap; then
        echo "$(timestamp) | NAT-PMP/UPnP Ok!"
    else
        echo "$(timestamp) | NAT-PMP/UPnP Failed"
    fi
    # shellcheck disable=SC2086
    echo "$(timestamp) | Sleeping for $(echo ${CHECK_INTERVAL}/60 | bc) minutes"
    # shellcheck disable=SC2086
    sleep 50
done

exit $?
