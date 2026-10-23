# Tunnel Manager

Forward TCP ports from an Iran server to a foreign server, or connect the two
with a GRE tunnel. A small Bash tool for Debian and Ubuntu.

It never flushes firewall tables, never touches unrelated rules, and never
changes the default route.

## Install

Run this on both servers:

```bash
curl -fsSL https://raw.githubusercontent.com/MoonlessWanderer/TunnelManager/main/get.sh | sudo bash
```

Then open the menu:

```bash
sudo tm
```

The installer needs root, Bash 4.4 or newer, and Debian or Ubuntu. It installs
the packages it uses. From a checkout, run `sudo ./install.sh` instead.

## Setup

1. On the Iran server, choose Configure a New Tunnel, then Iran.
2. Enter the foreign server's IP and choose Plain port forward or GRE tunnel.
   Press Enter to keep a shown default.
3. Enter TCP ports one per line, `443` or `443=2053`. An empty line finishes.
4. Check the summary and confirm. The menu prints one command for the foreign
   server.
5. On the foreign server, choose Configure a New Tunnel, then Foreign, and
   paste that command. A plain port forward needs nothing on the foreign side.

Saved tunnels and ports come back after a reboot. A server set up by an older
version needs this once:

```bash
sudo tunnel-manager service enable
```

## Menu

- **Configure a New Tunnel**: set up the Iran or the foreign side.
- **Manage Tunnels**: details, test, add or remove TCP ports, and delete. GRE
  tunnels can also restart. Maintenance has status, troubleshooting, backup,
  restore, and rollback.
- **Update**: installs the latest version. Saved tunnels stay.
- **Uninstall**: removes the program and everything it saved. Other firewall
  rules stay.
- **Enable BBR** or **Disable BBR**: turns TCP BBR on or off, kept across
  reboots.

## Safety

- Every change is shown as a plan before it runs. A failed step is rolled back.
- `--dry-run` shows the plan and changes nothing.
- Rules live in their own `TM_*` chains, or the `inet tunnel_manager` table.
  iptables and nftables are never mixed.
- Ports that match SSH are refused, and so are `0.0.0.0/0` and `::/0`.

More in [docs/OPERATIONS.md](docs/OPERATIONS.md),
[docs/SECURITY.md](docs/SECURITY.md), and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Development

```bash
bash tests/run-tests.sh
shellcheck -x bin/tunnel-manager lib/*.sh install.sh uninstall.sh tests/*.sh
```

The tests use fake `ip`, `iptables`, `nft`, `sysctl`, and `systemctl`
commands, so they never change the host network.

## License

MIT. See [LICENSE](LICENSE).
