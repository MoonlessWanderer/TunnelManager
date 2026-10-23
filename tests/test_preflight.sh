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
  "iptables -t nat -A TM_PREROUTING -i eth0 -p tcp --dport 443 -m comment --comment tm:tcp:web:dnat -j DNAT --to-destination 10.200.0.2:443"
  "iptables -t nat -A TM_POSTROUTING -p tcp -d 10.200.0.2 --dport 443 -m comment --comment tm:tcp:web:snat -j SNAT --to-source 10.200.0.1"
  "iptables -t nat -D TM_POSTROUTING -d 203.0.113.31/32 -p tcp -m tcp --dport 443 -m comment --comment tm:tcp:p443:snat -j SNAT --to-source 203.0.113.10"
  "iptables -t filter -D TM_FORWARD -s 203.0.113.31/32 -p tcp -m tcp --sport 443 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment tm:tcp:p443:fwdret -j ACCEPT"
  "iptables -t filter -D TM_FORWARD -s 203.0.113.31/32 -p tcp -m tcp --sport 443 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment tm:tcp:p443:fwdret -j ACCEPT"
  "iptables -t filter -A TM_FORWARD -p tcp -d 10.200.0.2 --dport 443 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:tcp:web:fwd -j ACCEPT"
  "iptables -t filter -A TM_FORWARD -p tcp -s 10.200.0.2 --sport 443 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment tm:tcp:web:fwdret -j ACCEPT"
  "iptables -t nat -A TM_POSTROUTING -p udp -d 10.200.0.2 --dport 5000 -m comment --comment tm:udp:edge:snat -j SNAT --to-source 10.200.0.1"
  "iptables -t filter -A TM_FORWARD -p udp -d 10.200.0.2 --dport 5000 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:udp:edge:fwd -j ACCEPT"
  "iptables -t filter -A TM_FORWARD -p udp -s 10.200.0.2 --sport 5000 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment tm:udp:edge:fwdret -j ACCEPT"
  "iptables -t filter -A TM_INPUT -i eth0 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "iptables -t filter -D TM_INPUT -i eth0 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "ip6tables -t filter -D TM_INPUT -i eth0 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "iptables -t filter -A TM_INPUT -i eth0 -s 203.0.113.20 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "iptables -t filter -D TM_INPUT -s 203.0.113.20/32 -i eth0 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "ip6tables -t filter -A TM_INPUT -i eth0 -s 2001:db8::20 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "ip6tables -t filter -D TM_INPUT -s 2001:db8::20/128 -i eth0 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "nft add rule inet tunnel_manager input iifname eth0 meta l4proto gre accept comment tm:gre:edge:input"
  "nft add rule inet tunnel_manager input iifname eth0 ip saddr 203.0.113.20 meta l4proto gre accept comment tm:gre:edge:input"
  "nft add rule inet tunnel_manager input iifname eth0 ip6 saddr 2001:db8::20 meta l4proto gre accept comment tm:gre:edge:input"
  "iptables -t nat -S"
  "nft list ruleset"
  "ss -H -l -n -t sport = :443"
  "iptables -t filter -A TM_FORWARD -p udp -d 10.200.0.2 --dport 22 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:udp:edge:fwd -j ACCEPT"
  "ip link add name tm-edge type gre local 203.0.113.10 remote 203.0.113.20 ttl 64"
  "ip link add name tm-edge type gre local 203.0.113.10 remote 203.0.113.20 ttl 255 key 180879360"
  "ip -o addr show"
  "ip addr add 10.200.0.1/30 dev tm-edge"
  "ip route show default"
  "ip route get 10.200.0.2"
  "sysctl -n net.ipv4.ip_forward"
  "sysctl -w net.ipv4.ip_forward=1"
  "sysctl -w net.ipv4.conf.tm-edge.rp_filter=2"
  "systemctl daemon-reload"
  "modprobe ip_gre"
  "modprobe ip6_gre"
  "modprobe tcp_bbr"
  "sysctl -n net.ipv4.tcp_congestion_control"
  "sysctl -w net.core.default_qdisc=fq"
  "sysctl -w net.ipv4.tcp_congestion_control=bbr"
  "ip link add name tm-edge type ip6gre local 2001:db8::10 remote 2001:db8::20 ttl 64"
  "ip addr add 2001:db8:1::1/64 dev tm-edge"
  "ip6tables -t filter -A TM_INPUT -i eth0 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "ping -6 -c 3 -W 2 2001:db8:1::2"
)

unsafe=(
  "iptables -F"
  "iptables -t nat -F TM_PREROUTING"
  "iptables -X INPUT"
  "iptables -P INPUT DROP"
  "iptables -P FORWARD ACCEPT"
  "iptables -t nat -A PREROUTING -p udp --dport 5000 -m comment --comment tm:udp:edge:dnat -j DNAT --to-destination 10.200.0.2:5000"
  "iptables -D INPUT -p tcp --dport 22 -j ACCEPT"
  "iptables -t filter -A TM_INPUT -i eth0 -p udp --dport 5000 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:udp:edge:input -j ACCEPT"
  "iptables -t filter -A TM_INPUT -i eth0 -p tcp --dport 443 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:tcp:web:input -j ACCEPT"
  "iptables -t filter -A TM_FORWARD -i eth0 -p gre -m comment --comment tm:gre:edge:input -j ACCEPT"
  "iptables -t filter -A TM_FORWARD -p tcp -m owner --uid-owner root -d 10.200.0.2 --dport 443 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:tcp:web:fwd -j ACCEPT"
  "nft add rule inet tunnel_manager input iifname eth0 udp dport 5000 accept comment tm:udp:edge:input"
  "nft add rule inet tunnel_manager input iifname eth0 meta l4proto udp accept comment tm:udp:edge:input"
  "iptables -A INPUT -p tcp --dport 22 -j ACCEPT"
  "iptables -t filter -A FORWARD -j ACCEPT"
  "iptables -t nat -A TM_POSTROUTING -j MASQUERADE"
  "iptables -t nat -D TM_POSTROUTING -d 10.200.0.0/24 -p tcp --dport 443 -m comment --comment tm:tcp:web:snat -j SNAT --to-source 10.200.0.1"
  "iptables -t filter -D TM_FORWARD -p tcp --sport 443 -m conntrack --ctstate INVALID -m comment --comment tm:tcp:p443:fwdret -j ACCEPT"
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
  "ip addr add 2001:db8:1::1/48 dev tm-edge"
  "ip link add name eth0 type ip6gre local 2001:db8::10 remote 2001:db8::20 ttl 64"
  "ip link add name tm-edge type gre local 203.0.113.10 remote 203.0.113.20 ttl 255 key 0"
  "ip link add name tm-edge type gre local 203.0.113.10 remote 203.0.113.20 ttl 255 key 4294967296"
  "ip link add name tm-edge type gre local 203.0.113.10 remote 203.0.113.20 ttl 255 ikey 5"
  "nft add rule inet tunnel_manager input iifname eth0 ip saddr 2001:db8::20 meta l4proto gre accept comment tm:gre:edge:input"
  "curl -fsSL --proto =https --tlsv1.2 -o /tmp/x https://example.com/archive.tar.gz"
  "ip addr add 10.200.0.1/30 dev eth0"
  "sysctl -w net.ipv4.conf.all.rp_filter=0"
  "sysctl -w net.ipv4.ip_forward=2"
  "sysctl -w net.ipv4.tcp_congestion_control=bad-value"
  "sysctl -w kernel.hostname=x"
  "modprobe tcp_bbr extra"
  "systemctl stop ssh"
  "systemctl stop sshd"
  "systemctl stop networking"
  "modprobe -r ip_gre"
  "modprobe ipip"
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
