# Security

Tunnel Manager is an administrative tool. Run it as root, on hosts you
administer, and review every plan before confirming it.

## What it will not do

- Flush iptables or nftables, including its own chains.
- Change the default route or install `0.0.0.0/0` / `::/0`.
- Overwrite a sysctl drop-in or BBR module file it did not write.
- Set `rp_filter` on `all` or `default`.
- Bind or DNAT the SSH port recorded in the host config or in `SSH_CONNECTION`.
- Add an SSH accept rule, or stop `ssh` / `sshd`.
- Source state files.
- Follow a symlink when reading or writing state.
- Write outside its state, log, run, sysctl, and BBR module paths.
- Mix iptables and nftables in one apply. `ip6tables` is used only as the
  IPv6 companion of the iptables backend, for an IPv6 tunnel endpoint.
- Forward TCP or UDP through a second proxy. Both protocols use firewall NAT.
- Change the default route while enabling or disabling BBR. BBR may set only
  `net.core.default_qdisc` and `net.ipv4.tcp_congestion_control`.

## Setup command

The Iran server prints `tunnel-manager quick` plus one token. The token
contains the tunnel type, name, public addresses, and GRE inner addresses.
The foreign server checks that the foreign address is configured locally
before it creates GRE. A plain forward token does not create a tunnel on the
foreign server. The plan prints descriptions rather than command argv.

## Firewall interaction

Managed jumps are inserted at the top of `INPUT`, `FORWARD`, `PREROUTING`, and
`POSTROUTING`, and of mangle `FORWARD` for the MSS clamp, but only toward
chains that return for non-matching packets. The mangle chain may hold only
`TCPMSS --clamp-mss-to-pmtu` on SYN packets of a forward's address and port.
A DNAT rule on the `tm-*` wildcard must also require a local destination
address.
Existing SSH rules continue to run. On nftables, a foreign filter hook blocks
creation of a policy-accept filter chain so Tunnel Manager does not wrap
another firewall.

## Input checks

Names, addresses, ports, MTU, prefixes, and state values are checked before a
plan is built. State values hold only letters, digits, `.`, `:`, `_`, and
`-`, and may not contain `..`. Duplicate listen tuples are
rejected. Tunnel prefixes are `/24` through `/31`, and the two tunnel
addresses must be different hosts in that subnet.

## Residual risk

UDP SNAT changes the source address of forwarded datagrams. That is required
for the return path and is shown in the plan. A connected route for the tunnel
prefix appears when the address is assigned. Host firewall policy outside the
managed chains is left to the operator. `doctor` and `forward test` do not
prove that an arbitrary UDP application works end to end.

## Reporting a failed change

Keep the rollback journal. Run `tunnel-manager rollback` before trying another
apply. If rollback itself fails, the journal path is printed and the remaining
lines are left in place.
