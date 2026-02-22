#!/bin/bash
# vim: ts=2 sw=2 et

# test with
# docker run --rm -ti --privileged -v "$(pwd)":/hostdir alpine
# apk add wireguard-tools curl jq bash ip6tables
# env_dev=1 env_peer=de-ber-wg-005,gb-lon-wg-003 /hostdir/entry.sh true

set -euo pipefail
scriptdir="$(cd "$(dirname "$0")"; pwd;)"
hostdir="/hostdir"

mvd_peers_db="${scriptdir}/peers.json"
mvd_peers_dbv2="${scriptdir}/peersv2.json"
mvd_status="${scriptdir}/vpn_status.json"
my_ips_file="${scriptdir}/my_ips.txt"

mvd_devices="${scriptdir}/devices.json"
tunnel_helper="${scriptdir}/tunnel.sh"

secrets="${scriptdir}/.env"

# For (some) help with the APIs see
# - https://gist.github.com/t-lo/e80c8aa082386954cff807e6c33adedc
# - https://api.mullvad.net/app/documentation/
# - https://api.mullvad.net/public/documentation/

function _get_public_ip4() {
    curl -sSL http://ip6.me/api/ \
        | awk -F, '/^IPv4/ {print $2}'
}
# --

function _mvd_fetch_peers() {
  curl -SsL 'https://api.mullvad.net/public/relays/wireguard/v1/' \
	> "${mvd_peers_db}"

  # V2 is structured differently and has some info v1 does not, like
  #  supported peer port ranges and dns / gw IPs.
  #  However, as of now it lacks multihop port information.
  curl -SsL 'https://api.mullvad.net/public/relays/wireguard/v2/' \
	> "${mvd_peers_dbv2}"
}
# --

function _mvd_fetch_my_ips() {
  local account="$1"
  local pubkey="$2"

  curl -sSL https://api.mullvad.net/wg/ \
       -d account="${account}" \
       --data-urlencode pubkey="${pubkey}" \
	> "${my_ips_file}"
}
# --

function _mvd_fetch_vpn_status() {
  curl -sSL https://am.i.mullvad.net/json \
    > "${mvd_status}"
}
# --

# Required e.g. for deleting devices.
# Valid for 1h.
function _mvd_fetch_api_access_token() {
  curl -sSL https://api.mullvad.net/auth/v1/token \
       --header "Content-Type: application/json" \
       --data "{\"account_number\": \"${account_number}\"}" \
       --request POST \
    | _jq  -r '.access_token'
}
# --

function _mvd_fetch_devices() {
  local token="${1}"
  curl -sSL https://api.mullvad.net/accounts/v1/devices \
    --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${token}" \
    --request GET \
    > "${mvd_devices}"
}
# --

function _jq() {
  jq --exit-status "${@}" || {
    echo "ERROR: Exit status $? for JSON query '${*}'" >&2
    return 1
  }
}
# --

function _mvd_device_id_from_pubkey() {
  local pubkey="${1}"

  _jq -r ".[] | select(.pubkey==\"${pubkey}\") | .id" \
    "${mvd_devices}"
}
# --

function _mvd_get_relay_val_v1() {
  local peer_host="${1}"
  local key="${2}"

  _jq -r ".countries[].cities[].relays[] | select( .hostname == \"${peer_host}\") | \"\\(.${key})\"" "${mvd_peers_db}"
}
# --

function _mvd_get_status_val() {
  local key="${1}"

  _jq -r ".${key}" "${mvd_status}"
}
# --

function _check_peer() {
  local peer ret=""
  for peer in ${1/,/ }; do
    jq -r --exit-status \
      ".countries[].cities[].relays[] | select( .hostname == \"${peer}\")" "${mvd_peers_db}" \
      >/dev/null \
      || ret="${peer} ${ret}"
  done

  if [[ -n "${ret}" ]] ; then
    echo "ERROR: Peer(s) ${ret} not found. Use './mullist.sh' to get an up-to-date list of peers."
    return 1
  fi
}
# --

function _list() {
  if [[ "$#" -eq 0 ]] ; then
    _jq -r '.countries[] | "\(.name): \(.cities[].relays[].hostname)"' "${mvd_peers_db}"
    return
  fi

  local peer ret=0
  for peer in ${1//,/ }; do

    echo -n "hostname: ${peer} "
    _check_peer "${peer}" || { ret=1; continue; }

    local ip4 ip6 pubkey multihop location
    ip4="$(_mvd_get_relay_val_v1 "${peer}" "ipv4_addr_in")"
    ip6="$(_mvd_get_relay_val_v1 "${peer}" "ipv6_addr_in")"
    pubkey="$(_mvd_get_relay_val_v1 "${peer}" "public_key")"
    multihop="$(_mvd_get_relay_val_v1 "${peer}" "multihop_port")"
    location="$(_mvd_location_from_hostname "${peer}")"

    echo "ip4: ${ip4}, ip6: ${ip6}, multihop-port: ${multihop}, public-key: ${pubkey}, location: ${location}."
  done

  return $ret
}
# --

function _mvd_location_from_hostname() {
  local peer_host="${1}"
  local codes="${peer_host%-*-*}"

  local country city
  country="$(_jq -r ".countries[] | select( .code == \"${codes%-*}\") | .name" "${mvd_peers_db}")"
  city="$(_jq -r ".countries[].cities[] | select( .code == \"${codes#*-}\") | .name" "${mvd_peers_db}")"
  echo "${country} / ${city}"
}
# --

function _mvd_get_gw_ip4() {
  _jq -r '.wireguard.ipv4_gateway' "${mvd_peers_dbv2}"
}
# --

function _mvd_get_port_ranges() {
  _jq -r '.wireguard.port_ranges[] | @tsv' "${mvd_peers_dbv2}"
}
# --

function _mvd_get_my_ip4() {
  sed 's/,.*//' "${my_ips_file}"
}
# --

function _mvd_get_my_ip6() {
  sed 's/.*,//' "${my_ips_file}"
}
# --

function _check_custom_port() {
  local port="$1"

  while read -r lower upper; do
    if [[ "$port" -ge "$lower" ]] && [[ "$port" -le "$upper" ]] ; then
      return 0
    fi
  done <<< "$(_mvd_get_port_ranges)"

  echo >&2
  echo "ERROR: illegal custom port '${wg_peer_port}'" >&2
  echo "Supported custom port ranges:" >&2
  echo -e "from\tto" >&2
  _mvd_get_port_ranges >&2
  echo >&2

  return 1
}
# --

function _create_tunnel_helper() {
  local wg_peer_ip="${1}"
  local my_docker_ip wg_gw_dns
  my_docker_ip="$(ip -j a s \
                  | _jq -r '.[] | select(.ifname=="eth0") | .addr_info[].local')"
  wg_gw_dns="$(_mvd_get_gw_ip4)"

  cat <<EOF
#!/bin/bash
# Run this on your host (as root) to route all host traffic through
# the container / VPN"

set -xeuo pipefail

default_gw="\$(ip -j r s | jq -r '[.[] | select(.dst=="default") | .gateway] | .[0]')"
ip r a ${wg_peer_ip}/32 via \${default_gw}
ip r a 0.0.0.0/1 via ${my_docker_ip}
ip r a 128.0.0.0/1 via ${my_docker_ip}

# Reroute DNS to the VPN's DNS server
iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to ${wg_gw_dns}
iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to ${wg_gw_dns}

set +x
echo
echo "### The tunnel is up."
echo
echo "Go to https://mullvad.net/en/check to verify."
echo
read -p "Press RETURN to stop tunneling."
set -x

# Let's clean up

set +e # plow through clean-up even if we encounter errors
ip r d 128.0.0.0/1 via ${my_docker_ip}
ip r d 0.0.0.0/1 via ${my_docker_ip}
ip r d ${wg_peer_ip}/32 via \${default_gw}
iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to ${wg_gw_dns}
iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to ${wg_gw_dns}
EOF
}
# --

function _generate_wg_config() {
  local mvd_dev="${1}"
  local mvd_peer_cfg="${2%:*}"
  local mvd_port="${2#*:}"

  local wg_my_ips
  wg_my_ips="$(_mvd_get_my_ip4)"

  # Multihop: <ingress-peer>,<egress-peer>. ingress == egress if no "," present.
  local mvd_ingress="${mvd_peer_cfg%,*}"
  local mvd_egress="${mvd_peer_cfg#*,}"

  # Multihop: use ingress IP, egress multihop port and key.
  # See https://mullvad.net/en/help/wireguard-and-mullvad-vpn for details.
  local wg_peer_pubkey wg_peer_ip4
  wg_peer_pubkey="$(_mvd_get_relay_val_v1 "${mvd_egress}" "public_key")"
  wg_peer_ip4="$(_mvd_get_relay_val_v1 "${mvd_ingress}" "ipv4_addr_in")"

  local msg="" wg_peer_port="${mvd_port}"
  if [[ "${mvd_ingress}" == "${mvd_egress}" ]] ; then
    [[ -n "${wg_peer_port}" ]] || wg_peer_port="${devices[$mvd_dev,"port"]}"
    _check_custom_port "${wg_peer_port}"
    msg=" # ${mvd_ingress}"
  else
    wg_peer_port="$(_mvd_get_relay_val_v1 "${mvd_egress}" "multihop_port")"
    msg=" # multihop '${mvd_ingress}' ==> '${mvd_egress}'"
  fi

  local key="${devices[$mvd_dev,"key"]}"

  cat <<-_EOF
		[Interface]
		PrivateKey = ${key}
		Address = ${wg_my_ips}
		
		[Peer]
		PublicKey = ${wg_peer_pubkey}
		AllowedIPs = 0.0.0.0/0
		Endpoint = ${wg_peer_ip4}:${wg_peer_port} ${msg} 
	_EOF

  _create_tunnel_helper "${wg_peer_ip4}" > "${tunnel_helper}"
  chmod 755 "${tunnel_helper}"
}
# --

function _update_routes() {
  local mvd_peer="${1}"
  local mvd_ingress="${mvd_peer%,*}"

  local wg_peer_ip4 orig_gw
  wg_peer_ip4="$(_mvd_get_relay_val_v1 "${mvd_ingress}" "ipv4_addr_in")"
  orig_gw="$(ip -j r s | jq -r '.[] | select(.dst=="default") | .gateway')"

  echo
  echo "###  Updating container routes"

  if ! ping -c 1 -W 1 -w 1 -q "${orig_gw}" >/dev/null ; then
    echo "ERROR Unable to detect / ping container's default gateway '${orig_gw}'"
    return 1
  fi

  echo "   Removing default route via '${orig_gw}' and setting explicit route to '${wg_peer_ip4}' (peer '${mvd_ingress}')"
  ip r d default
  ip r a "${wg_peer_ip4}/32" via "${orig_gw}"

  if [[ -n "${env_host_networks}" ]] ; then
    echo "   Adding routes to host network(s) '${env_host_networks}'" 
    local host_net
    for host_net in ${env_host_networks//,/ }; do
      if ip -j r s \
           | jq --exit-status ".[] | select(.dst==\"${host_net}\")" >/dev/null;
      then
        echo "     Skipping '${host_net}' as it's already present"
      else
        echo "     Adding '${host_net}' via '${orig_gw}'"
        ip r a "${host_net}" via "${orig_gw}"
      fi
    done
  fi
}
# --

function _set_wg_route_dns() {
  local wg_gw_and_dns
  wg_gw_and_dns="$(_mvd_get_gw_ip4)"

  echo
  echo "### Setting new default route and nameserver '${wg_gw_and_dns}'"
  ip r a default via "${wg_gw_and_dns}"
  echo "nameserver ${wg_gw_and_dns}" > "/etc/resolv.conf"

  echo -n "    Waiting for gateway '${wg_gw_and_dns}' to become available:."
  while ! ping -c1 -w1 -W1 -i 0.5 "${wg_gw_and_dns}" >/dev/null; do
    echo -n "."
    sleep 0.5  # this allows CTRL+C to break the loop
  done
  echo " OK."
}
# --

function _setup_vpn() {
  local mvd_dev="${1}"
  local mvd_peer="${2%:*}"
  local wg_conf="${mvd_peer}"

  _check_peer "${mvd_peer}"

  if [[ ${mvd_peer} =~ .*,.* ]] ; then
    # multihop peer name (<ingress>,<egress>)
    local i="${mvd_peer%,*}"
    local e="${mvd_peer#*,}"
    wg_conf="${i%-*-*}--${e%-*-*}"
  fi

  local pubkey="${devices[$mvd_dev,"pub"]}"

  _mvd_fetch_my_ips "${account}" "${pubkey}"  

  echo
  echo "### Generating Wireguard configuration"
  _generate_wg_config "${@}" \
    | tee "/etc/wireguard/${wg_conf}.conf" \
    | sed 's/^/    /'

  _update_routes "${mvd_peer}"

  echo
  echo "### Starting wireguard"
  wg-quick up "${wg_conf}" 2>&1 | sed 's/^/    /'

  _set_wg_route_dns

  # This is handy if host wants to route its traffic through the container
  iptables -t nat -A POSTROUTING -o "${wg_conf}" -j MASQUERADE

  echo
  echo "### Final route settings"
  ip r | sed 's/^/    /'
  echo
}
# --

function _verify_mullvad() {
  local orig_ip="${1}"
  local orig_org="${2}"
  local orig_city="${3}"
  local orig_country="${4}"
  local peer_hosts="${5%:*}"
  local egress_host="${peer_hosts#*,}"

  local my_pub_ip
  my_pub_ip="$(_get_public_ip4)"

  echo " ### Running VPN sanity checks"
  echo "     Original IP was ${orig_ip} hosted by ${orig_org} in ${orig_city}, ${orig_country}".

  function _error() {
    echo
    echo "     ERROR: ${*}"
    echo "     This is a potential VPN leak; shutting down now."
    echo
  }

  if [[ "${my_pub_ip}" == "${orig_ip}" ]] ; then
    _error "Public IP '${my_pub_ip}' is the same as public IP before VPN came up ('${orig_ip}')"
    return 1
  fi

  _mvd_fetch_vpn_status
  local stat_egress_host stat_egress_ip stat_is_mullvad_ip
  stat_egress_ip="$(_mvd_get_status_val "ip")"
  stat_egress_host="$(_mvd_get_status_val "mullvad_exit_ip_hostname")"
  stat_is_mullvad_ip="$(_mvd_get_status_val "mullvad_exit_ip")"

  if [[ "${stat_is_mullvad_ip}" != "true" ]] ; then
    _error "Not using Mullvad VPN! (mullvad_exit_ip is '${stat_is_mullvad_ip}'"
    return 1
  fi

  if [[ "${egress_host}" != "${stat_egress_host}" ]] ; then
    _error "Egress host '${egress_host}' is not the Mullvad VPN egress host '${stat_egress_host}'"
    return 1
  fi

  if [[ "${my_pub_ip}" != "${stat_egress_ip}" ]] ; then
    _error "Public IP '${my_pub_ip}' is not the advertised Mullvad VPN exit IP '${stat_egress_ip}'"
    return 1
  fi

  local stat_hoster stat_city stat_country
  stat_hoster="$(_mvd_get_status_val "organization")"
  stat_country="$(_mvd_get_status_val "country")"
  stat_city="$(_mvd_get_status_val "city")"
  echo "     Now using Mullvad egress ${stat_egress_host} (${my_pub_ip} == ${stat_egress_ip}) hosted by ${stat_hoster} in ${stat_city}, ${stat_country}".
  echo
}
# --

function _run_cmd() {
  local user group

  group="$(getent group "${env_gid}" | sed 's/:.*//g')" \
    || {
        group="hostgroup"
        addgroup -g "$env_gid" "${group}"
  }

  user="$(getent passwd "${env_gid}" | sed 's/:.*//g')" \
    || {
        user="hostuser"
        adduser -u "$env_uid" -G "${group}" -D -s /bin/bash "${user}"
  }

  echo "${user} ALL=(ALL:ALL) NOPASSWD: ALL" \
    > "/etc/sudoers.d/${user}"

  cd "$hostdir"
  echo "### Running command(s) '${*}' as ${user}/${group} (${env_uid}/${env_gid})"
  exec sudo --user "${user}" --group "${group}" bash -c "${*}"
}
# --

function usage() {
  echo "Usage:"
  echo "  $0 list [<peer>] - list all available peers, or the details of <peer> if provided."
  echo 
  echo "  $0 <command> [<args...>] - run <command> and route its network access through the VPN."
  echo "   env_uid, env_gid, env_dev, and env_peer must be set."
  echo 
  echo "  $0 tunnel - route all host traffic through the VPN."
  echo "   The command will pause when the VPN is up; press ENTER to shut down."
  echo "   The container is expected to run in host networking mode."
  echo "   env_dev and env_peer must be set."
  echo 
  echo "  $0 help - this help."
  echo "  Mullvad settings must be available at '${secrets}'."
}
# --

case "${1:-}" in
  list)
    shift # literal "list"
    _mvd_fetch_peers
    _list "${@}"
  ;; 
  h|help|-h|--help)
    usage
  ;;
  *)
    if    [[ -z "${env_dev:-}" ]] \
       || [[ -z "${env_uid:-}" ]] \
       || [[ -z "${env_gid:-}" ]] \
       || [[ -z "${env_peer:-}" ]] ; then
      usage
      exit
    fi

    if [[ ! -f "${secrets}" ]] ; then
      echo "Mullvad settings not found at '${secrets}'"
      exit 1
    fi
    source "${secrets}"

    _mvd_fetch_vpn_status
    orig_ip="$(_get_public_ip4)"
    orig_org="$(_mvd_get_status_val "organization")"
    orig_city="$(_mvd_get_status_val "city")"
    orig_country="$(_mvd_get_status_val "country")"

    _mvd_fetch_peers
    _setup_vpn "${env_dev}" "${env_peer}" "${@}"
    _verify_mullvad "${orig_ip}" "${orig_org}" "${orig_city}" "${orig_country}" "${env_peer}"

    _run_cmd "${@}"
  ;;
esac
