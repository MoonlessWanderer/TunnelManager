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
Forward TCP ports, or build a GRE tunnel, between an Iran server and a foreign server.
GRE may use IPv4 or IPv6 endpoints. The menu and the setup command use IPv4.
Port forwarding is IPv4 only. GRE has no encryption.

Safety:
  The default route is never changed.
  Firewall tables are never flushed.
  Existing firewall rules are preserved; only TM_* chains and the
  inet/tunnel_manager table are modified.
  TCP and UDP forwards use one firewall NAT path.
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
  tunnel-manager quick SETUP-COMMAND
  tunnel-manager tunnel create --name NAME --type forward|gre \\
      --local-public-ip IP --remote-public-ip IP \\
      --local-tunnel-ip IP --remote-tunnel-ip IP --wan-iface IFACE \\
      [--cidr 30] [--mtu N] [--i-understand-no-encryption]
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
  tunnel-manager bbr [--dry-run] [--yes]

tm opens the menu. tunnel-manager with no arguments does the same on a terminal.

Menu:
  1  Configure a New Tunnel. Choose Iran or foreign.
     Iran detects its address, asks for the foreign address, then plain
     port forward or GRE. Enter accepts a shown default. An empty port
     line finishes the list. GRE with no ports is a tunnel only.
     Iran prints one setup command for the foreign server.
  2  Manage Tunnels. Lists saved tunnels, or says that none are saved.
     Choosing a tunnel shows only that tunnel's actions.
  3  Update the program.
  4  Uninstall. One confirmation removes the program and all of its saved state.
  5  Enable BBR. Sets fq and bbr only. The default route is not changed.

Global flags:
  --yes       Apply without an extra confirmation prompt.
  --dry-run   Print the plan and do not change the system.
  --verbose   Log the commands that pass the safety check.

GRE tunnels require --i-understand-no-encryption or the exact phrase
"GRE is not encrypted". --yes does not skip that confirmation.
EOF
}
