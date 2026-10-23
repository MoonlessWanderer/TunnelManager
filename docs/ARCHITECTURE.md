# Architecture

Tunnel Manager keeps desired state under `/etc/tunnel-manager` and applies it
with a plan. Libraries are sourced in a fixed order from `lib/load.sh`.
External commands pass through `tm_run`, which checks an allowlist before
execution.

## Roles

`init` stores `iran` or `foreign`, the reachable public address, the WAN
interface, the SSH port, and the firewall backend pin (`auto`, `iptables`, or
`nft`). The same command set runs on both servers. Addresses are different;
the code is not.

## Tunnels

A tunnel name matches `^[a-z][a-z0-9-]{0,11}$`. The interface is `tm-<name>`
and stays within the 15-character interface limit.

A `forward` tunnel stores the two public addresses and does not create an
interface. Its port forwards DNAT to the foreign address and SNAT back to the
local public address. No route is added.

GRE uses `ip link add type gre` for IPv4 endpoints and `type ip6gre` for IPv6
endpoints. The inner address is IPv4 `/24` through `/31`, or IPv6 `/64`
through `/127`. The tool never runs
`ip route add`, `replace`, or `del`.

Each GRE link carries a key (`TM_GRE_KEY`). For IPv4 it is the inner network
address as a 32-bit number; for IPv6 it is the `cksum` of `network/prefix`.
0 becomes 1. Both ends derive the same key, and the key differs between the
tunnels of one host because their inner subnets never overlap. The kernel
keeps one GRE link per local address, remote address, and key, so several
tunnels between the same two servers can coexist, and so can an unkeyed link
from another tool. The default MTU is 1472 for IPv4 endpoints and 1452 for
IPv6, which covers the 4-byte key.

A new GRE tunnel is refused when:

- another saved GRE tunnel has the same public pair and key;
- its inner subnet overlaps another saved tunnel's subnet, because the kernel
  would route that traffic through whichever interface came first;
- its inner subnet clashes with an address on an interface that Tunnel
  Manager does not own. A host prefix of /24 or longer (/64 for IPv6) clashes
  on any overlap. A wider host prefix clashes only when its address lies
  inside the new subnet, so a /30 inside a site-wide /8 stays allowed.

The Iran menu suggests a /30 inside `10.200.0.0/16`. The start block is
seeded from both public addresses, and the search moves past blocks that
would be refused. `quick` saves a GRE tunnel under the next free name when
the name from the setup command is already used on that server.

The setup command is `v2:TYPE:NAME:IRAN_IP:FOREIGN_IP:IRAN_TUN:FOREIGN_TUN:CIDR:KEY`.
A plain port forward uses key 0. Any other version is refused with a message
to update both servers.

`apply` records whether a tunnel interface was already up. Rollback stops
only a tunnel that this run started.

## Port forwarding

TCP and UDP use the same firewall NAT path. Both are IPv4 only. The tunnel
itself may still be IPv6. A saved forward sets `net.ipv4.ip_forward=1`.

`forward add`, `forward edit` with a new protocol or port, and setup refuse
a listen port that is already taken outside Tunnel Manager. Taken means `ss`
shows a listener on a non-loopback address, or `iptables -t nat -S` or
`nft list ruleset` shows a DNAT or REDIRECT rule for that port without a
`tm:` comment. The jumps into Tunnel Manager chains sit at position 1, so
such a port would otherwise be taken over silently.

## Firewall

The active backend is detected from `iptables -V` and the presence of
`nft`.

- iptables-nft (`nf_tables` in the version string) uses iptables only.
- Legacy iptables plus an nft binary is `conflict-possible`. If both already
  contain user rules and the pin is `auto`, apply stops and asks for
  `TM_FW_BACKEND`.
- A pin uses only that backend.

iptables rules live in `TM_PREROUTING`, `TM_POSTROUTING`, `TM_FORWARD`, and
`TM_INPUT`. Jumps from the builtin chains are inserted at position 1 with a
`tm:jump:*` comment. Non-matching packets return to the existing rules.
Deletion removes individual rules. An empty managed chain is deleted with
`-X` after its jump is removed. `-F` and `-P` are not used.

nftables uses `table inet tunnel_manager` only. NAT chains are always
created. Filter base chains are created only when `nft list ruleset` shows
no foreign `hook input` or `hook forward`. If that check fails, NAT rules
are still installed and filter rules are skipped.

SNAT is `auto`, `always`, or `never`. `auto` does not SNAT when the
destination is this host's tunnel address. It does SNAT for the peer tunnel
address and any other destination, because the peer would otherwise answer
toward its public default route. No route is added when the destination is
outside the tunnel subnet; the plan warns that the destination must already
be reachable.

The GRE allow rule in `TM_INPUT` or the nft input chain matches the WAN
interface, the peer public address, and protocol GRE. GRE from other peers
falls through to the rules of whatever else manages the host.

`net.ipv4.ip_forward` is raised while any saved forward exists. When the last
one goes away, the value from before is restored, unless a file under
`/etc/sysctl.conf`, `/etc/sysctl.d`, `/run/sysctl.d`, `/usr/local/lib/sysctl.d`,
or `/usr/lib/sysctl.d` turns forwarding on; then it stays on.

## Plans and rollback

`tm_plan_add` stores a description, a quoted command, and a quoted undo.
`tm_plan_apply` prints the plan, including the statements that the default
route is unchanged and the firewall is not flushed. Dry-run returns before
any command runs. Otherwise the operator confirms, each undo is appended to
`/var/lib/tunnel-manager/rollback.journal`, and the command runs. On failure
the journal is replayed in reverse and rewritten after every successful undo.

`apply` and `down` show one plan and ask once. They then run each tunnel, each
forward, and the final sysctl step as a separate plan through `tm_plan_run`.
A failed item is rolled back on its own. The other items keep their changes,
and the command exits 4 with the failed items named. On `apply`, the forwards
of a tunnel that did not start are skipped. If a rollback fails, the run
stops and the journal is kept.

Commands are quoted with `printf %q` and replayed into an argument array.
The array must name a `tm_*` function or an allowlisted external command.
Descriptions are shown to the operator; raw argv is not.

## Services

`tunnel-manager-apply.service` is a oneshot unit. Its start command is
`tunnel-manager apply --yes` and its stop command is `tunnel-manager down
--yes`. Saved state is the confirmation, so boot does not prompt.
`service enable` enables the apply unit only. Menu setup and `quick` call it
after a tunnel is saved, unless the unit is already enabled.

## Backups

Archives contain an allowlisted set of members: `MANIFEST`, `host.conf`,
`tunnels/*.conf`, and `forwards/*.conf`. Restore checks every member, copies
the files, and does not apply them. The operator runs `apply` after review.
