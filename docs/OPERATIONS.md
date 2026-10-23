# Operations

## First server

```bash
sudo install.sh
sudo tm
```

Choose Configure a New Tunnel, then Iran. The detected address is the default;
press Enter to keep it. Enter the foreign server's IPv4 address, then choose
plain port forward or GRE.

For GRE, the inner defaults are `10.200.0.1` on Iran and `10.200.0.2` on the
foreign server, prefix 30. Press Enter to accept a default. Then enter TCP
ports, one per line:

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
sudo tunnel-manager quick v1:gre:edge:203.0.113.10:203.0.113.20:10.200.0.1:10.200.0.2:30
```

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
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.5 --remote-tunnel-ip 10.200.0.6 \
  --wan-iface eth0
sudo tunnel-manager tunnel create --name gre1 --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
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
   - Lists saved tunnels. If none are saved, it says so.
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
saved state. It does not prompt. An interface that is already up is left up if
a later step fails.

Menu setup, adding ports from the menu, and `quick` enable the unit when they
save a tunnel. The setup summary says so before anything runs. A server set up
by an older version, or with other commands, needs it once:

```bash
sudo tunnel-manager service enable
```
