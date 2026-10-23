# Tunnel Manager

Tunnel Manager is a modular Bash tool for a pair of Debian or Ubuntu servers.
One server is the Iran role and the other is the foreign role. It forwards
TCP ports from Iran to the foreign server, or builds a kernel GRE tunnel
between them. TCP and UDP forwards use one firewall path: DNAT, optional
SNAT, and forward rules.

The tool does not flush firewall tables, does not replace unrelated firewall
rules, and does not change the default route.

## Requirements

- Debian or Ubuntu
- Bash 4.4 or newer
- root for apply, restore, and service installation
- Packages: `iproute2`, `iptables`, `nftables`, `iputils-ping`, `procps`

GRE has no encryption and no authentication. Creating a GRE tunnel requires
`--i-understand-no-encryption` or typing `GRE is not encrypted`. `--yes` does
not skip that confirmation.

## Install

On each Debian or Ubuntu server, one command downloads and installs the tool.
It does not enable services, flush firewall rules, or change the default route.

```bash
curl -fsSL https://raw.githubusercontent.com/MoonlessWanderer/TunnelManager/main/get.sh | sudo bash
```

Open the menu:

```bash
sudo tm
```

Or install from a checkout:

```bash
sudo ./install.sh
sudo tunnel-manager init --role iran --public-ip 203.0.113.10 --wan-iface eth0
```

Use `--role foreign` on the other server. `install.sh` does not enable
services and does not change the firewall. Enable boot persistence only after
a dry-run looks right:

```bash
sudo tunnel-manager service enable
```

Useful installer flags:

- `--prefix DIR` installs outside `/usr/local`
- `--skip-packages` skips `apt-get`
- `--skip-systemd` skips unit installation
- `--yes` is accepted and does not change network state by itself

`uninstall.sh` stops Tunnel Manager through its own `down` command and removes
its files. The menu uninstall, and `--purge-state`, also remove saved tunnels,
forwards, logs, the Tunnel Manager sysctl files, and the BBR module file.
Missing paths are ignored.
Firewall rules owned by other tools stay in place.

## Typical flow

```bash
sudo tm
```

On the Iran server, choose Configure a New Tunnel, then Iran. The menu fills
this server's address. Enter the foreign address, choose plain port forward
or GRE, and press Enter to accept a shown default. Port lines look like `443`
or `443=2053`. An empty line finishes the list. A GRE tunnel with no ports
is a tunnel only. Iran then prints one command for the foreign server.

On the foreign server, choose Foreign and paste that command. A plain port
forward does not create a tunnel there.

```bash
sudo tunnel-manager quick v1:gre:edge:203.0.113.10:203.0.113.20:10.200.0.1:10.200.0.2:30
```

1. Configure a New Tunnel. Iran or foreign, then the setup above.
2. Manage Tunnels. Lists saved tunnels. If none are saved, it says so. Choosing one tunnel shows only that tunnel's actions.
3. Update downloads the main branch and reinstalls the program. Saved tunnels stay in place and services are not enabled.
4. Uninstall asks once, then removes the program and everything it saved. Missing files are skipped. Other firewall rules stay in place.
5. Enable BBR sets `fq` and `bbr` and keeps them after reboot. When BBR is already saved, the same item becomes Disable BBR. Disable restores the previous settings and does not turn BBR back on after reboot. Neither choice changes the default route.

`tunnel-manager --dry-run apply` prints the plan and does not change the system.

IPv6 GRE addresses use prefix 64-127. An IPv6 public endpoint uses `ip6gre`
and `ip6tables` only when the iptables backend is selected. The menu setup
command is IPv4. Port forwarding is IPv4 for both TCP and UDP.

## Safety

- Every network change is shown as a plan before it runs.
- `--dry-run` prints the plan and returns without writing a journal.
- Each step records its undo before it runs. A failed step rolls those undos
  back. `tunnel-manager rollback` resumes an interrupted journal.
- Firewall changes use either iptables or nftables, never both in one apply.
  On iptables-nft the iptables command is the only API. If legacy iptables and
  nftables both already have rules, set `TM_FW_BACKEND` explicitly.
- Rules go into `TM_*` chains or the `inet tunnel_manager` table. Jumps are
  inserted at position 1 and return when they do not match, so SSH and other
  existing rules still run. Tables are never flushed.
- `0.0.0.0/0` and `::/0` are rejected. Assigning a GRE address creates a
  connected route for that prefix only. That is not a default-route change.
- Port forwarding may set `net.ipv4.ip_forward=1` and
  `net.ipv4.conf.<tunnel>.rp_filter=2`. A foreign sysctl drop-in is not
  overwritten. `rp_filter` is not changed for `all` or `default`.
- TCP and UDP forwarding use the same NAT rules. The system file
  `/etc/haproxy/haproxy.cfg` is not modified.
- Listen ports and DNAT ports that match the SSH port are refused.
- Logs still redact key-shaped strings. Backups omit key files unless
  `--include-keys` is passed, and that option prints a warning.
- State files are strict `KEY=value` records. They are never sourced.

## Layout

```text
bin/tunnel-manager          command entry point
lib/*.sh                    libraries
systemd/*.service.in        boot apply unit
examples/                   sample state files
docs/                       architecture, operations, and security notes
tests/                      unit tests and command fakes
install.sh
uninstall.sh
```

## Tests

The unit tests run in Bash and do not change the host firewall. They refuse
real `iptables`, `nft`, `ip`, `sysctl`, and `wg` commands unless a fake is
installed. A network-namespace integration test is not part of this suite.

```bash
bash tests/run-tests.sh
bash -n bin/tunnel-manager lib/*.sh install.sh uninstall.sh
```

ShellCheck is required for a static-analysis pass. If the `shellcheck` binary
is absent, that pass was not run and must not be reported as a success.

```bash
shellcheck -x bin/tunnel-manager lib/*.sh install.sh uninstall.sh tests/test_*.sh tests/helpers.sh
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/OPERATIONS.md](docs/OPERATIONS.md)
- [docs/SECURITY.md](docs/SECURITY.md)

## License

MIT. See [LICENSE](LICENSE).
