# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — command help.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "usage.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_USAGE_LOADED:-}" ]]; then
  return 0
fi
TM_USAGE_LOADED=1

tm_usage() {
  cat <<EOF
Tunnel Manager ${TM_VERSION}
Manage a WireGuard or GRE tunnel and TCP/UDP forwards between two servers.
Tunnel addresses and endpoints may be IPv4 or IPv6. UDP forwarding is IPv4 only.

Safety:
  The default route is never changed.
  Firewall tables are never flushed.
  Existing firewall rules are preserved; only TM_* chains and the
  inet/tunnel_manager table are modified.
  HAProxy is a separate process and is validated before reload.
  SSH listen ports are refused as forward listen ports.

Usage:
  tm
  tunnel-manager
  tunnel-manager help
  tunnel-manager version
  tunnel-manager menu
  tunnel-manager init --role iran|foreign --public-ip IP --wan-iface IFACE
                      [--ssh-port PORT] [--fw-backend auto|iptables|nft]
  tunnel-manager status
  tunnel-manager doctor
  tunnel-manager firewall detect
  tunnel-manager apply [--dry-run] [--yes]
  tunnel-manager down [--dry-run] [--yes]
  tunnel-manager rollback [--dry-run] [--yes]
  tunnel-manager tunnel keygen --name NAME
  tunnel-manager tunnel create --name NAME --type wireguard|gre \\
      --local-public-ip IP --remote-public-ip IP \\
      --local-tunnel-ip IP --remote-tunnel-ip IP --wan-iface IFACE \\
      [--cidr 30] [--listen-port 51820] [--mtu N] [--peer-public-key KEY]
      [--i-understand-no-encryption]
  tunnel-manager tunnel set-peer --name NAME --peer-public-key KEY
  tunnel-manager tunnel up|down|restart|test|show --name NAME
  tunnel-manager tunnel list
  tunnel-manager tunnel delete --name NAME [--yes]
  tunnel-manager tunnel export-peer --name NAME --output FILE
  tunnel-manager forward add --name NAME --proto tcp|udp --listen-port PORT \\
      --dest-ip IP [--dest-port PORT] [--listen-ip IP] [--source-ip IP]
      [--tunnel NAME] [--ingress-iface IFACE] [--snat auto|always|never]
  tunnel-manager forward edit --name NAME [same options]
  tunnel-manager forward delete --name NAME [--yes]
  tunnel-manager forward list
  tunnel-manager forward test --name NAME
  tunnel-manager backup create --output FILE [--include-keys]
  tunnel-manager backup restore --file FILE [--include-keys] [--dry-run] [--yes]
  tunnel-manager backup list
  tunnel-manager service enable|disable|status [--yes]
  tunnel-manager update [--dry-run] [--yes]

tm opens the menu. tunnel-manager with no arguments does the same on a terminal.

Menu shortcuts:
  1  Quick WireGuard setup. Asks which side this server is, the two reachable
     addresses, and the other public key if you already have it. Tunnel name
     edge, addresses 10.200.0.1 and 10.200.0.2, port 51820, and the WAN
     interface are filled in automatically.
  2  Paste the other server public key and start the tunnel.
  3  Show this server public key. Copy that line, not a log line.
  4  Forward a port. The tunnel addresses and WAN interface come from the
     saved tunnel. Port 443 TCP is the default.

Global flags:
  --yes       Apply without an extra confirmation prompt.
  --dry-run   Print the plan and do not change the system.
  --verbose   Log the commands that pass the safety check.

GRE tunnels require --i-understand-no-encryption or the exact phrase
"GRE is not encrypted". WireGuard is the recommended tunnel type.
EOF
}
