# Tunnel Manager

Tunnel Manager is a modular Bash tool for a pair of Debian or Ubuntu servers.
One server is the Iran role and the other is the foreign role. It builds a
WireGuard or kernel GRE tunnel between them, forwards TCP with a dedicated
HAProxy process, and forwards UDP with DNAT, optional SNAT, and forward rules.

The tool does not flush firewall tables, does not replace unrelated firewall
rules, and does not change the default route.

## Requirements

- Debian or Ubuntu
- Bash 4.4 or newer
- root for apply, restore, and service installation
- Packages: `wireguard`, `iproute2`, `iptables`, `nftables`, `haproxy`,
  `iputils-ping`, `procps`

WireGuard is the recommended tunnel. GRE has no encryption and no
authentication. Creating a GRE tunnel requires
`--i-understand-no-encryption` or typing `GRE is not encrypted`. `--yes` does
not skip that confirmation.

## Install

On each server:

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

`uninstall.sh` stops Tunnel Manager through its own `down` command, removes
its files, and does not remove `wireguard` or `haproxy`. `--purge-state`
also removes `/etc/tunnel-manager` and `/var/lib/tunnel-manager`.

## Typical flow

```bash
sudo tunnel-manager tunnel keygen --name edge
sudo tunnel-manager tunnel export-peer --name edge --output /root/edge.peer
# copy the public bundle to the other server, then:
sudo tunnel-manager tunnel create --name edge --type wireguard \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.1 --remote-tunnel-ip 10.200.0.2 \
  --wan-iface eth0 --peer-file /root/edge.peer
sudo tunnel-manager forward add --name web --proto tcp --listen-port 443 \
  --dest-ip 10.200.0.2 --source-ip 10.200.0.1 --ingress-iface eth0
sudo tunnel-manager forward add --name dns --proto udp --listen-port 5300 \
  --dest-ip 10.200.0.2 --dest-port 53 --source-ip 10.200.0.1 --ingress-iface eth0
sudo tunnel-manager tunnel test --name edge
sudo tunnel-manager doctor
```

Run `tunnel-manager` with no arguments on a terminal to open the menu.
`tunnel-manager --dry-run apply` prints the plan and does not change the system.

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
- WireGuard uses `Table = off` and a peer `/32`. `0.0.0.0/0` and `::/0` are
  rejected. Assigning a tunnel address creates a connected route for that
  prefix only. That is not a default-route change.
- UDP forwarding may set `net.ipv4.ip_forward=1` and
  `net.ipv4.conf.<tunnel>.rp_filter=2`. A foreign sysctl drop-in is not
  overwritten. `rp_filter` is not changed for `all` or `default`.
- TCP forwarding uses `/etc/tunnel-manager/haproxy.cfg`. The system file
  `/etc/haproxy/haproxy.cfg` is not modified. `haproxy -c` runs before a reload.
- Listen ports and DNAT ports that match the SSH port are refused.
- Private keys are mode `0600`. Logs redact WireGuard key material. Backups
  omit keys unless `--include-keys` is passed, and that option prints a warning.
- State files are strict `KEY=value` records. They are never sourced.

## Layout

```text
bin/tunnel-manager          command entry point
lib/*.sh                    libraries
lib/haproxy-reload.sh       validates HAProxy before a graceful reload
systemd/*.service.in        apply and dedicated HAProxy units
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
