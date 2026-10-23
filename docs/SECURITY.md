# Security

Tunnel Manager is an administrative tool. Run it as root, on hosts you
administer, and review every plan before confirming it.

## What it will not do

- Flush iptables or nftables, including its own chains.
- Change the default route or install `0.0.0.0/0` / `::/0`.
- Overwrite a sysctl drop-in it did not write.
- Set `rp_filter` on `all` or `default`.
- Edit `/etc/haproxy/haproxy.cfg`.
- Bind or DNAT the SSH port recorded in the host config or in `SSH_CONNECTION`.
- Add an SSH accept rule, or stop `ssh` / `sshd`.
- Source state files.
- Follow a symlink when reading or writing state.
- Write outside its state, log, run, sysctl, and `tm-*.conf` paths.
- Mix iptables and nftables in one apply. `ip6tables` is used only as the
  IPv6 companion of the iptables backend, for an IPv6 tunnel endpoint.
- Reload HAProxy without a successful `haproxy -c`.
- Start GRE without an explicit no-encryption acknowledgement.
- Include private keys in a backup unless `--include-keys` is set.

## Keys

`wg genkey` output is stored mode `0600`. The peer bundle and normal backups
contain the public key only. Logs replace 43-character base64 keys with
`[REDACTED-KEY]`, so a public key must be copied from the terminal line that
starts with the key itself, or from menu item "Show my public key". The plan
prints descriptions rather than command argv.

## Firewall interaction

Managed jumps are inserted at the top of `INPUT`, `FORWARD`, `PREROUTING`, and
`POSTROUTING`, but only toward chains that return for non-matching packets.
Existing SSH rules continue to run. On nftables, a foreign filter hook blocks
creation of a policy-accept filter chain so Tunnel Manager does not wrap
another firewall.

## Input checks

Names, addresses, ports, MTU, prefixes, and state values are checked before a
plan is built. State values may contain a path slash and may not contain
`..`, command substitution, spaces, or quotes. Duplicate listen tuples are
rejected. Tunnel prefixes are `/24` through `/31`, and the two tunnel
addresses must be different hosts in that subnet.

## Residual risk

GRE is not confidential and not authenticated. UDP SNAT changes the source
address of forwarded datagrams; that is required for the return path and is
shown in the plan. A connected route for the tunnel prefix appears when the
address is assigned. Host firewall policy outside the managed chains is left
to the operator. `doctor` and `forward test` do not prove that an arbitrary
UDP application works end to end.

## Reporting a failed change

Keep the rollback journal. Run `tunnel-manager rollback` before trying another
apply. If rollback itself fails, the journal path is printed and the remaining
lines are left in place.
