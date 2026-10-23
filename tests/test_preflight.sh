#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

safe=(
  "iptables -V"
  "iptables -S"
  "iptables -t nat -N TM_PREROUTING"
  "iptables -t nat -X TM_PREROUTING"
  "iptables -t nat -I PREROUTING 1 -m comment --comment tm:jump:nat-prerouting -j TM_PREROUTING"
  "iptables -t nat -A TM_PREROUTING -i eth0 -p udp --dport 5000 -m comment --comment tm:udp:edge:dnat -j DNAT --to-destination 10.200.0.2:5000"
  "iptables -t nat -A TM_POSTROUTING -p udp -d 10.200.0.2 --dport 5000 -m comment --comment tm:udp:edge:snat -j SNAT --to-source 10.200.0.1"
  "iptables -t filter -A TM_FORWARD -p udp -d 10.200.0.2 --dport 5000 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:udp:edge:fwd -j ACCEPT"
  "iptables -t filter -A TM_FORWARD -p udp -s 10.200.0.2 --sport 5000 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment tm:udp:edge:fwdret -j ACCEPT"
  "iptables -t filter -A TM_INPUT -i eth0 -p udp --dport 51820 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:wg:edge:input -j ACCEPT"
  "iptables -t filter -A TM_INPUT -i eth0 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "iptables -t filter -A TM_FORWARD -p udp -d 10.200.0.2 --dport 22 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:udp:edge:fwd -j ACCEPT"
  "ip link add name tm-edge type gre local 203.0.113.10 remote 203.0.113.20 ttl 64"
  "ip addr add 10.200.0.1/30 dev tm-edge"
  "ip route show default"
  "ip route get 10.200.0.2"
  "sysctl -n net.ipv4.ip_forward"
  "sysctl -w net.ipv4.ip_forward=1"
  "sysctl -w net.ipv4.conf.tm-edge.rp_filter=2"
  "systemctl enable --now wg-quick@tm-edge"
  "systemctl daemon-reload"
  "modprobe ip_gre"
  "wg genkey"
  "wg show tm-edge"
  "wg-quick up tm-edge"
  "wg-quick down tm-edge"
  "haproxy -c -f ${TM_HAPROXY_CFG}"
)

unsafe=(
  "iptables -F"
  "iptables -t nat -F TM_PREROUTING"
  "iptables -X INPUT"
  "iptables -P INPUT DROP"
  "iptables -P FORWARD ACCEPT"
  "iptables -t nat -A PREROUTING -p udp --dport 5000 -m comment --comment tm:udp:edge:dnat -j DNAT --to-destination 10.200.0.2:5000"
  "iptables -D INPUT -p tcp --dport 22 -j ACCEPT"
  "iptables -A INPUT -p tcp --dport 22 -j ACCEPT"
  "iptables -t filter -A FORWARD -j ACCEPT"
  "iptables -t nat -A TM_POSTROUTING -j MASQUERADE"
  "nft flush ruleset"
  "nft delete table inet filter"
  "ip route add default via 192.0.2.1"
  "ip route replace default via 192.0.2.1"
  "ip route del default"
  "ip route delete default"
  "ip route add 0.0.0.0/0 via 192.0.2.1"
  "ip link del dev eth0"
  "ip link set dev eth0 down"
  "ip addr add 10.0.0.1/8 dev tm-edge"
  "ip addr add 10.200.0.1/30 dev eth0"
  "sysctl -w net.ipv4.conf.all.rp_filter=0"
  "sysctl -w net.ipv4.ip_forward=2"
  "systemctl stop ssh"
  "systemctl stop sshd"
  "systemctl stop networking"
  "wg-quick up wg0"
  "wg set tm-edge peer abc allowed-ips 0.0.0.0/0"
  "modprobe -r ip_gre"
  "haproxy -c -f /etc/haproxy/haproxy.cfg"
  "rm -rf /"
  "bash -c true"
)

check_words() {
  local mode="$1"
  shift
  local line
  for line in "$@"; do
    # shellcheck disable=SC2086
    if tm_argv_is_safe $line; then
      if [[ "$mode" == "safe" ]]; then
        tm_pass "allows: ${line}"
      else
        tm_fail "should reject: ${line}"
      fi
    elif [[ "$mode" == "unsafe" ]]; then
      tm_pass "rejects: ${line}"
    else
      tm_fail "should allow: ${line}"
    fi
  done
}

check_words safe "${safe[@]}"
check_words unsafe "${unsafe[@]}"

tm_finish
