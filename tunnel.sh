#!/bin/bash

source config.sh

#######################################################################################################
#######################################################################################################

if [[ "$tun_proto" == "gre" && $(cat "/sys/class/net/$tun_if/carrier" 2>/dev/null) == "1" ]]; then
  current_remote_ip=$(ip tunnel show | grep "$tun_if" | awk '/remote/ {split ($4,A," "); print A[1]}')
elif [[ "$tun_proto" == "wg" && $(cat "/sys/class/net/$tun_if/carrier" 2>/dev/null) == "1" ]]; then
  current_remote_ip=$(wg show "$tun_if" endpoints | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
fi
if [[ "$dynamic_ip" == "true" ]]; then
  dynamic_ip="${green}$dynamic_ip${normal}"
  remote_ip=$(cat "$ip_data" 2>/dev/null)
else
  dynamic_ip="${red}$dynamic_ip${normal}"
  remote_ip="$ip_data"
fi

function parameter() {
  if [[ "$1" == "update" ]]; then
    if [[ "$tun_proto" == "gre" ]]; then
      updateIp
    else
      echo "${yellow}Not using p2p tunnel like GRE. Peer IP update not needed.${normal}"
    fi
  elif [[ "$1" == "delete" ]]; then
    deleteIp
  elif [[ "$1" == "up" ]]; then
    up
  elif [[ "$1" == "down" ]]; then
    down
  elif [[ "$1" == "gen" ]]; then
    if [[ "$tun_proto" == "wg" ]]; then
      gen_wg_conf
    else
      echo "${yellow}Not using Wireguard. Config generation not needed..${normal}"
    fi
  elif [[ "$1" == "-f" ]]; then
    main
  else
    status
  fi
}

function main() {
  if [[ ! $(cat "/sys/class/net/$tun_if/carrier" 2>/dev/null) == "1" ]]; then
    up
  else
    echo "${green}Tunnel running. Exiting.${normal}"
    exit 0
  fi
}

function status() {
  echo "${yellow}This is Dry-Run/status mode!"
  echo "Please check all values and run this script again with '-f' option${normal}"
  echo ""
  echo "Primary NIC: ${blue}$nic${normal}"
  echo ""
  echo "Tunnel Protocol: ${blue}$tun_proto${normal}"
  echo "Tunnel Interface: ${blue}$tun_if${normal}"
  echo ""
  echo "Interface Status:${blue}"
  ip addr | grep "$tun_if"
  echo ""
  ifconfig "$tun_if"
  echo "${normal}"

  echo "Tunnel Network: ${green}$tun_local_addr${normal}"
  echo "Tunnel Endpoint: ${green}$tun_remote_addr${normal}"

  echo ""

  # Define your public IPs that will be routed to your home router
  echo "Public IPs used for home:${red}"
  for i in "${public_ip[@]}"; do
    echo "$i"
  done
  echo "---------------------"
  if [[ $ipv6 == "true" && ${#public_ip6[@]} -ge 0 ]]; then
    for i in "${public_ip6[@]}"; do
        echo "$i"
    done
  fi
  echo "${normal}"

  # Show home WAN address
  echo "Home WAN IP: ${red}$remote_ip${normal} (Dynamic IP: ${green}$dynamic_ip${normal})"

  if [[ $(cat /sys/class/net/$tun_if/carrier 2>/dev/null) == "1" ]]; then
    echo "Current WAN IP: ${red}$current_remote_ip${normal}"
    echo ""
    if [[ "$current_remote_ip" == "$remote_ip" ]]; then
      echo "${green}WAN IPs match, Tunnel endpoint is correct${normal}"
    else
      echo "${red}WAN IPs do not match, check tunnel endpoint IP${normal}"
    fi
  fi
  if ping -c 1 "$tun_remote_addr" &>/dev/null; then
    echo "${green}Tunnel endpoint is reachable via ping${normal}"
  else
    echo "${red}Tunnel endpoint is unreachable via ping${normal}"
  fi
}

function up() {
  if [[ ! $(cat "/sys/class/net/$tun_if/carrier" 2>/dev/null) == "1" ]]; then
    if [[ "$tun_proto" == "gre" ]]; then
      gre_up
    elif [[ "$tun_proto" == "wg" ]]; then
      wg_up
    fi
  fi
}

function gre_up() {
  # Create GRE tunnel
  ip tunnel add "$tun_if" mode gre local "$local_ip" remote "$remote_ip" ttl 255
  if [[ $greipv6 == "true" ]]; then
    ip tunnel add "$tun_if" mode ip6gre local "$local_ip" remote "$remote_ip" ttl 255
  fi

  # Create tunnel network
  ip addr add "$tun_local_addr" dev "$tun_if"
  if [[ $ipv6 == "true" ]]; then
    ip -6 addr add "$tun_local_addr6" dev "$tun_if"
  fi
  ip link set dev "$tun_if" mtu "$tun_mtu"
  ip link set "$tun_if" up

  # Add Route for tunnel network
  ip route add "$tun_remote_addr" dev "$tun_if"
  if [[ $ipv6 == "true" ]]; then
    ip -6 route add "$tun_remote_addr6" dev "$tun_if"
  fi

  # Check for existing public IP on main interface
  deleteIp

  # Add Routes and Proxy ARP for all given public IPs
  for i in "${public_ip[@]}"; do
    ip route add "$i" dev "$tun_if"
    ip neigh add proxy "$(echo "$i" | cut -d/ -f1)" dev "$nic"
  done
  if [[ $ipv6 == "true" && ${#public_ip6[@]} -ge 0 ]]; then
    for i in "${public_ip6[@]}"; do
      ip -6 route add "$i" dev "$tun_if"
      ip -6 neigh add proxy "$(echo "$i" | cut -d/ -f1)" dev "$nic"
    done
  fi
}

function gen_wg_conf() {
  local ipString="$tun_remote_addr"

  if [[ ! ${#public_ip[@]} -eq 0 ]]; then
    ipString="$ipString,$(joinBy , "${public_ip[@]}")"
  fi
  if [[ $ipv6 == "true" && ${#public_ip6[@]} -ge 0 ]]; then
    ipString="$ipString,$tun_remote_addr6,$(joinBy , "${public_ip6[@]}")"
    local ip6Address="Address = $tun_local_addr6"
  fi

  : >$config
  cat >"$config" <<EOF
	# configuration created on $(hostname) on $(date)
	[Interface]
	Address = $tun_local_addr
	$ip6Address
	ListenPort = $listenPort
	PrivateKey = $privateKey
	SaveConfig = false
	MTU = $tun_mtu
	[Peer]
	PublicKey = $publicKey
	AllowedIPs = $ipString
EOF
}

function wg_up() {
  # Create WG tunnel
  #wg set "$tun_if" listen-port "$listenPort" private-key "$privateKey" peer "$publicKey" allowed-ips "$tun_local_addr"
  gen_wg_conf

  wg-quick up "$tun_if"

  # Create tunnel network
  #ip link add dev wg0 type wireguard
  #ip link set up dev "$tun_if"
  #ip link set mtu "$tun_mtu" up dev "$tun_if"

  # Add Route for tunnel network
  #ip route add "$tun_remote_addr" dev "$tun_if"

  # Check for existing public IP on main interface
  deleteIp

  # Add Routes and Proxy ARP for all given public IPs
  for i in "${public_ip[@]}"; do
    ip neigh add proxy "$(echo "$i" | cut -d/ -f1)" dev "$nic"
  done
  if [[ $ipv6 == "true" && ${#public_ip6[@]} -ge 0 ]]; then
    for i in "${public_ip6[@]}"; do
      ip -6 neigh add proxy "$(echo "$i" | cut -d/ -f1)" dev "$nic"
    done
  fi
}

function down() {
  if [[ "$tun_proto" == "gre" ]]; then
    gre_down
  elif [[ "$tun_proto" == "wg" ]]; then
    wg_down
  fi
}

function gre_down() {
  # Remove Routes and Proxy ARP for all given public IPs
  for i in "${public_ip[@]}"; do
    ip route del "$i" dev "$tun_if"
    ip neigh del proxy "$(echo "$i" | cut -d/ -f1)" dev "$nic"
  done

  # Remove Route for tunnel network
  ip route del "$tun_remote_addr" dev "$tun_if"

  # Remove tunnel network
  ip link set "$tun_if" down
  ip addr del "$tun_local_addr" dev "$tun_if"

  # Remove GRE tunnel
  ip tunnel del "$tun_if" mode gre local "$local_ip" remote "$remote_ip" ttl 255
}

function wg_down() {
  # Remove Routes and Proxy ARP for all given public IPs
  for i in "${public_ip[@]}"; do
    ip neigh del proxy "$(echo "$i" | cut -d/ -f1)" dev "$nic"
  done
  if [[ $ipv6 == "true" && ${#public_ip6[@]} -ge 0 ]]; then
    for i in "${public_ip6[@]}"; do
      ip -6 neigh del proxy "$(echo "$i" | cut -d/ -f1)" dev "$nic"
    done
  fi

  # Remove Route for tunnel network
  #ip route del "$tun_remote_addr" dev "$tun_if"

  # Remove tunnel network
  wg-quick down "$tun_if"
}

function deleteIp() {
  for i in "${public_ip[@]}"; do
    if [[ $(ip addr show "$nic" | grep "inet\b" | awk '{print $2}' | cut -f1 | grep "$i") ]]; then
      echo "${red}Public IP found on physical interface${normal}"
      # Delete IPv4 from Physical Interface
      echo "Deleting $i..."
      ip addr del "$i" dev "$nic"
    fi
  done
  if [[ $ipv6 == "true" && ${#public_ip6[@]} -ge 0 ]]; then
    for i in "${public_ip6[@]}"; do
        if [[ $(ip -6 addr show "$nic" | grep "inet6\b" | awk '{print $2}' | cut -f1 | grep "$i") ]]; then
          echo "${red}Public IP found on physical interface${normal}"
          # Delete IPv6 from Physical Interface
          echo "Deleting $i..."
          ip -6 addr del "$i" dev "$nic"
        fi
    done
  fi
}

function updateIp() {
  if [[ "$tun_proto" == "gre" ]]; then
    if [[ ! "$current_remote_ip" == "$remote_ip" ]]; then
      echo "${red}WAN IPs do not match, updating...${normal}"
      ip tunnel change "$tun_if" mode gre remote "$remote_ip" local "$local_ip" ttl 255
      if [[ "$current_remote_ip" == "$remote_ip" ]]; then
        echo "${green}Update was successful, exiting${normal}"
      fi
    else
      echo "${green}WAN IPs match, exiting${normal}"
      return 0
    fi
  fi
}

function preCheck() {
  if [[ -z "$nic" || -z "$tun_if" || -z "$local_ip" || -z "$tun_local_addr" || -z "$tun_remote_addr" || -z "$tun_proto" || -z "$tun_remote_addr" ]]; then
    echo "${yellow}Configuration parameters missing. Check script variables.${normal}"
    exit
  elif [[ $ipv6 == "true" && (-z "$nic" || -z "$local_ip6" || -z "$tun_local_addr6" || -z "$tun_remote_addr6") ]]; then
    echo "${yellow}IPv6 configuration parameters missing but IPv6 is enabled in script.${normal}"
    exit
  elif [[ "$tun_proto" == "gre" && (-z "$dynamic_ip" || -z "$ip_data") ]]; then
    echo "${yellow}GRE configuration parameters missing.${normal}"
    exit
  elif [[ "$tun_proto" == "wg" && (-z "$config" || -z "$listenPort" || -z "$privateKey" || -z "$publicKey") ]]; then
    echo "${yellow}Wireguard configuration parameters missing.${normal}"
    exit
  elif [[ "$tun_proto" == "wg" ]]; then
    checkPackages
  fi
}

function checkPackages() {
  if ! command -v wg &>/dev/null; then
    apt install wireguard -y
  fi
}

function joinBy() {
  local d=${1-} f=${2-}
  if shift 2; then printf %s "$f" "${@/#/$d}"; fi
}

function colors() {
  red=$(tput setaf 1)
  green=$(tput setaf 2)
  yellow=$(tput setaf 3)
  blue=$(tput setaf 4)
  normal=$(tput sgr0)
}

colors
preCheck
parameter "$@"
