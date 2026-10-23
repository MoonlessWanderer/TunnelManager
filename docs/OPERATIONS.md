# Operations

## First server

```bash
sudo install.sh
sudo tunnel-manager init --role iran --public-ip 203.0.113.10 --wan-iface eth0 --ssh-port 22
sudo tunnel-manager tunnel create --name edge --type wireguard \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.1 --remote-tunnel-ip 10.200.0.2 \
  --cidr 30 --listen-port 51820 --wan-iface eth0
sudo tunnel-manager tunnel export-peer --name edge --output /root/iran.peer
```

The create above has no peer key yet, so the tunnel stays down. Copy
`/root/iran.peer` to the foreign server. It contains the public key only.

## Second server

```bash
sudo install.sh
sudo tunnel-manager init --role foreign --public-ip 203.0.113.20 --wan-iface eth0
sudo tunnel-manager tunnel create --name edge --type wireguard \
  --local-public-ip 203.0.113.20 --remote-public-ip 203.0.113.10 \
  --local-tunnel-ip 10.200.0.2 --remote-tunnel-ip 10.200.0.1 \
  --wan-iface eth0 --peer-file /root/iran.peer
sudo tunnel-manager tunnel export-peer --name edge --output /root/foreign.peer
```

## Finish the first server

```bash
sudo tunnel-manager tunnel set-peer --name edge --peer-file /root/foreign.peer
sudo tunnel-manager tunnel test --name edge
```

`tunnel test` checks that the interface exists and pings the peer tunnel
address. IPv6 peers are probed with `ping -6`. A ping failure is reported as
a test result. It does not roll back the tunnel, because the peer may not be
ready yet.

An IPv6 tunnel uses the same commands. IPv4 inner prefixes are 24-31 and IPv6
inner prefixes are 64-127. Leave `--cidr` unset to get 30 or 64 from the
address family. UDP forwarding still requires IPv4. TCP forwarding accepts
an IPv6 destination.

```bash
sudo tm
sudo tunnel-manager tunnel create --name edge6 --type wireguard \
  --local-public-ip 2001:db8::10 --remote-public-ip 2001:db8::20 \
  --local-tunnel-ip 2001:db8:1::1 --remote-tunnel-ip 2001:db8:1::2 \
  --wan-iface eth0 --peer-public-key 'PEER_PUBLIC_KEY'
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

`forward test` validates the HAProxy config for TCP. For UDP it checks that
the saved forward and the firewall command exist. It does not claim an
end-to-end UDP success.

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

`down` removes runtime interfaces, HAProxy, and UDP rules. It keeps the saved
configuration. `apply` installs that configuration again.

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
  --wan-iface eth0 --i-understand-no-encryption
```

Read the plan before confirming. GRE traffic can be read and modified in
transit.

## Menu

`sudo tm` opens the menu.

1. Configure a New Tunnel
   - Quick WireGuard setup asks which side this server is and the two reachable
     addresses. It uses tunnel name `edge`, inner addresses `10.200.0.1` and
     `10.200.0.2`, listen port 51820, and the detected WAN interface.
   - Advanced tunnel asks for every address.
2. Manage Tunnels
   - Show the public key, paste the other server's key, or forward a port.
     Press Enter on the forward prompts to publish TCP 443 through `edge`.
   - Test, restart, and delete a tunnel.
   - Port forwards has add, edit, delete, list, and test.
   - Maintenance has status, troubleshoot, backup, restore, apply, dry-run, and rollback.
3. Update reinstalls the program and keeps saved tunnels.
4. Uninstall stops Tunnel Manager and does not flush other firewall rules.
5. Enable BBR. The plan sets `net.core.default_qdisc=fq` and
   `net.ipv4.tcp_congestion_control=bbr`. It does not change the default route.

## Reboot

After `service enable`, `tunnel-manager-apply.service` runs `apply --yes` on
boot. That reconciles saved state. It does not prompt. An interface that is
already up is left up if a later step fails.
