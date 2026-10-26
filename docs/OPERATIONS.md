# Operations

## First server

```bash
curl -fsSL https://raw.githubusercontent.com/MoonlessWanderer/TunnelManager/main/get.sh | sudo bash
sudo tm
```

Choose Configure a New Tunnel, then Iran. The detected address is the default;
press Enter to keep it. Enter the foreign server's IPv4 address, then choose
plain port forward or GRE.

For GRE, the menu suggests a free inner pair from `10.200.0.0/16`, prefix 30:
the first address on Iran and the second on the foreign server. Press Enter
to accept a default. Then enter TCP ports, one per line:

```text
443
443=2053
```

The first form listens on 443 and sends to 443. The second listens on 443 and
sends to 2053. An empty line finishes the list. For GRE, an empty list means
the tunnel only, with no port forward. A plain port forward needs at least
one port.

The menu prints one command. Run that command on the foreign server. It looks
like:

```bash
sudo tunnel-manager quick v2:gre:edge:203.0.113.10:203.0.113.20:10.200.0.1:10.200.0.2:30:180879360
```

The last field is the GRE key. Both servers need the same Tunnel Manager
version; a command from another version is refused with a message to update.

A plain port forward does not need a tunnel on the foreign server. The service
there must already listen on the destination port.

## Second server

Install Tunnel Manager, run `sudo tm`, choose Foreign, and paste the command
from Iran. The same command works without the menu.

`tunnel test` checks that a GRE interface exists and pings the peer tunnel
address. IPv6 peers are probed with `ping -6`. A ping failure is reported as
a test result. It does not roll back the tunnel. A plain port forward has no
interface to test.

An IPv6 GRE tunnel can still be created from the command line. IPv4 inner
prefixes are 24-31 and IPv6 inner prefixes are 64-127. Leave `--cidr` unset
to get 30 or 64 from the address family. Port forwarding is IPv4 for both
TCP and UDP. The menu setup command is IPv4 only.

```bash
sudo tunnel-manager tunnel create --name gre6 --type gre \
  --local-public-ip 2001:db8::10 --remote-public-ip 2001:db8::20 \
  --local-tunnel-ip 2001:db8:1::1 --remote-tunnel-ip 2001:db8:1::2 \
  --wan-iface eth0
```

Update the installed program from the menu or with:

```bash
sudo tunnel-manager update
```

## More than one tunnel

These layouts work:

- One Iran server to one foreign server.
- One Iran server to several foreign servers. Run Iran setup once per foreign
  server.
- Several Iran servers to one foreign server. Paste each Iran command on the
  foreign server.
- Several GRE tunnels between the same two servers. Iran setup says the
  servers are already connected and continues. To only forward more ports,
  open Manage Tunnels and add them to the existing tunnel instead.

Each GRE tunnel has its own inner subnet and a GRE key. The key is the inner
network as a number, so both ends agree on it and it differs between tunnels
on one server. The kernel tells tunnels between the same two addresses apart
by that key. The default MTU is 1472 for IPv4 endpoints and 1452 for IPv6,
which leaves room for the key.

- The Iran menu suggests a different free subnet for each new GRE tunnel. An
  inner subnet that overlaps another saved tunnel is refused.
- On the foreign server, `quick` refuses a setup command that was already
  applied there. It also refuses an inner subnet that another tunnel there
  uses. In that case, delete the new tunnel on Iran and set it up again with
  other inner addresses. If the tunnel name is taken, the next free name is
  used, such as `edge2`.
- `apply` and `down` handle each tunnel and forward on its own. One that
  fails is rolled back and named in the error, and the rest stay applied.
  Forwards of a tunnel that did not start are skipped.

## Other tunnel tools on the same server

Tunnel Manager only touches `tm-*` interfaces, its own firewall chains or
table, and its own sysctl file. It also avoids these clashes with other tools:

- An inner subnet that overlaps an address on another interface is refused,
  and the menu does not suggest it.
- Its GRE links carry a key. A GRE link from another tool between the same
  two addresses without a key keeps working.
- The GRE allow rule accepts GRE from the peer's public address only.
- A listen port is refused when a service already listens on it on a public
  address, or when another tool's DNAT or REDIRECT rule already takes it.
- When the last forward goes away, IPv4 forwarding is left on if another
  sysctl file turns it on.

## Forwards

TCP:

```bash
sudo tunnel-manager forward add --name web --proto tcp --listen-port 443 \
  --dest-ip 10.200.0.2 --dest-port 443 --source-ip 10.200.0.1 --ingress-iface eth0
```

UDP:

```bash
sudo tunnel-manager forward add --name dns --proto udp --listen-port 5300 \
  --dest-ip 10.200.0.2 --dest-port 53 --source-ip 10.200.0.1 --ingress-iface eth0 --snat auto
```

`forward test` checks that the firewall DNAT rule is present. It does not
claim end-to-end success for TCP or UDP.

A forward also takes connections that arrive over any Tunnel Manager tunnel
and are addressed to this server. So a chain works without extra steps: Iran
forwards port 443 over GRE to Germany, and Germany forwards port 443 to a
third server. TCP forwards clamp the MSS, so full-size packets fit the tunnel.
After an update, run `sudo tunnel-manager apply` once so saved forwards get
both rules.

Edit and delete:

```bash
sudo tunnel-manager forward edit --name web --listen-port 8443
sudo tunnel-manager forward delete --name dns
```

## Day to day

```bash
sudo tunnel-manager status
sudo tunnel-manager doctor
sudo tunnel-manager --dry-run apply
sudo tunnel-manager apply
sudo tunnel-manager tunnel restart --name edge
sudo tunnel-manager down
sudo tunnel-manager backup create --output /root/tm.tar.gz
sudo tunnel-manager backup restore --file /root/tm.tar.gz
```

`down` removes runtime interfaces and TCP/UDP NAT rules. It keeps the saved
configuration. `apply` installs that configuration again through the firewall.

## Firewall backend

```bash
sudo tunnel-manager firewall detect
sudo tunnel-manager init --role iran --public-ip 203.0.113.10 --wan-iface eth0 --fw-backend iptables --yes
```

Choose `iptables` on iptables-nft hosts. Choose `nft` only when iptables is
absent or when you have pinned nft after confirming the other backend has no
rules you still need. Tunnel Manager will not mix the two.

## Recovery

If apply stops midway, the journal remains:

```bash
sudo tunnel-manager rollback
```

Do not delete `/var/lib/tunnel-manager/rollback.journal` by hand unless you
have inspected it. A second apply is refused while the journal exists.

## GRE

```bash
sudo tunnel-manager --dry-run tunnel create --name gre1 --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.30 \
  --local-tunnel-ip 10.200.0.5 --remote-tunnel-ip 10.200.0.6 \
  --wan-iface eth0
sudo tunnel-manager tunnel create --name gre1 --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.30 \
  --local-tunnel-ip 10.200.0.5 --remote-tunnel-ip 10.200.0.6 \
  --wan-iface eth0
```

Read the plan before confirming.

## Menu

`sudo tm` opens the menu.

1. Configure a New Tunnel
   - Choose Iran or foreign.
   - Iran detects its address, asks for the foreign address, then plain port
     forward or GRE. Enter accepts a shown default. An empty port line
     finishes the list.
   - Foreign asks for the setup command printed by Iran.
2. Manage Tunnels
   - Lists saved tunnels with their type and remote server. If none are
     saved, it says so.
   - Choosing a tunnel offers details, test, TCP ports, and delete. GRE also
     offers restart.
   - Maintenance has status, troubleshoot, backup, restore, apply, dry-run, and rollback.
3. Update reinstalls the program, keeps saved tunnels and boot settings, and
   reopens the menu on the new version.
4. Uninstall asks once, then removes the program, saved tunnels, and logs. Missing paths are ignored. Other firewall rules are not flushed.
5. Enable BBR, or Disable BBR when those boot settings are already saved.
   Enable sets `net.core.default_qdisc=fq` and
   `net.ipv4.tcp_congestion_control=bbr`, and loads `tcp_bbr` on the next boot.
   Disable restores the previous values and removes the boot settings, so a
   reboot does not turn BBR on again. Neither choice changes the default route.

## Reboot

`tunnel-manager-apply.service` runs `apply --yes` on boot. That reconciles
saved state. It does not prompt. Each tunnel and forward is applied on its
own, so one that fails does not take the others down. An interface that is
already up stays up.

Menu setup, adding ports from the menu, and `quick` enable the unit when they
save a tunnel. The setup summary says so before anything runs. Tunnels and
forwards made only with `tunnel create` or `forward add` need it once:

```bash
sudo tunnel-manager service enable
```
