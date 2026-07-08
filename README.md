# bulkvpn

**Bulk-deploy the Tailscale + Mullvad fail-closed kill-switch across every LXC container and VM on a Proxmox VE node — in one command.**

`bulkvpn` walks every *running* guest on a Proxmox node and, for any guest that isn't already protected, it installs Tailscale (if missing), enrolls it into your tailnet, then deploys and schedules the [Mullvad kill-switch](https://github.com/thelorax1775/tailscale-mullvad-killswitch): an nftables fail-closed egress firewall plus a self-healing exit-node rotator on a 15-minute timer. Re-runs are idempotent — already-protected guests are skipped.

It combines two upstream projects by [@thelorax1775](https://github.com/thelorax1775):

- **[tailscale-mullvad-killswitch](https://github.com/thelorax1775/tailscale-mullvad-killswitch)** — the per-host fail-closed setup (nftables ruleset + `mullvad-rotate.sh` + systemd units). Its files are vendored verbatim in [`assets/`](assets/).
- **[TailAdjuster](https://github.com/thelorax1775/TailAdjuster)** — the bulk "scan every LXC/VM on a Proxmox node and act on each" pattern. `bulkvpn`'s enumeration, `pct exec` / `qm guest exec` mechanics, TUN handling, and idempotency checks follow it.

## What it does per guest

```
enumerate running LXC + VMs on the node
  pre-scan: union every running guest's own LAN subnet(s)   [all-guests reachability]
  └─ for each guest:
       already protected?          → SKIP
       not systemd-based?          → SKIP (warn)  [kill-switch ships as systemd units]
       Tailscale not on tailnet?   → install + enroll (needs TS_AUTHKEY)
       no Mullvad exit node seen?  → SKIP (no endpoint to protect with; never fail-close)
       deploy kill-switch:
         push 5 assets, template LAN subnet(s) (own + all guests) + country filter,
         enable boot firewall, start 15-min self-heal timer,
         kick a first rotation to select a verified exit node
       verify firewall loaded + timer active → SUCCESS
```

- **LXC** guests are driven with `pct exec`; assets are written with a base64 pipe (works for unprivileged containers).
- **VMs** are driven via the QEMU guest agent (`qm guest exec`) — the VM must have **qemu-guest-agent** installed and running, or it is skipped.

## Requirements

**On the Proxmox host:** run as `root`; `pvesh`, `pct`, `qm`, `jq`, and `base64` (all standard on PVE).

**In each guest that should be protected:**
- systemd (Alpine/OpenRC guests are detected and skipped);
- reachable egress *at deploy time* (the kill-switch is only loaded after Tailscale is up);
- VMs additionally need qemu-guest-agent.

## Usage

Run it directly on the Proxmox host as `root` (no `sudo` needed):

```bash
# minimum: a Tailscale auth key
TS_AUTHKEY=tskey-auth-xxxxxxdeploy ./bulkvpn-deploy.sh

# see what it would do, change nothing
DRY_RUN=1 TS_AUTHKEY=tskey-... ./bulkvpn-deploy.sh

# pin exit nodes to a country; also allow an extra subnet on top of the
# auto-detected LAN (e.g. a separate management VLAN)
TS_AUTHKEY=tskey-... \
  MULLVAD_COUNTRY_FILTER=USA \
  MULLVAD_LAN_SUBNET=10.0.10.0/24 \
  ./bulkvpn-deploy.sh

# re-run on the same node to roll out an updated ruleset / config to guests
# that were already protected by an earlier run
FORCE_REDEPLOY=1 TS_AUTHKEY=tskey-... ./bulkvpn-deploy.sh
```

### Re-running on the same node

Re-runs are **idempotent**: by default a guest that's already protected (rotate
script present + kill-switch service enabled + self-heal timer active) is
**skipped** and left untouched — so a plain re-run does *not* re-push assets or
pick up config/asset changes on guests deployed by an earlier run. To roll out a
new ruleset or changed settings (for example this LAN-reachability update) to
guests you've already deployed to, run with `FORCE_REDEPLOY=1`: it re-pushes
every asset, reloads the nft ruleset (via `systemctl restart`, so the new LAN set
actually takes effect — `enable --now` alone is a no-op on an already-active
oneshot service), and kicks a fresh rotation that re-asserts the LAN bypass
routes. Brand-new / unprotected guests are deployed the same way with or without
the flag.

By default each guest's own LAN subnet is **auto-detected and kept reachable**, so SSH / web UIs stay up without you having to specify anything. On top of that, every other running container / VM / LXC's LAN subnet on the node is collected up-front and allowed on **every** guest, so guests stay reachable to each other on the same LAN subnet(s) they were on before the kill-switch was applied. Set `MULLVAD_LAN_INCLUDE_GUESTS=0` to keep only each guest's own subnet.

### Configuration (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `TS_AUTHKEY` | *(required)* | Tailscale auth key used to enroll guests that aren't on the tailnet |
| `TS_LOGIN_SERVER` | *(none)* | Alternative control server (e.g. Headscale) |
| `TS_HOSTNAME_PREFIX` | `ct-` (LXC) / `vm-` (VM) | Prefix for each guest's tailnet hostname |
| `TS_EXTRA_ARGS` | *(none)* | Extra flags appended to every `tailscale up` |
| `MULLVAD_LAN_AUTODETECT` | `1` | Auto-detect and allow each guest's own LAN subnet(s). `0` = don't. |
| `MULLVAD_LAN_INCLUDE_GUESTS` | `1` | Also allow every other running guest's LAN subnet(s) on the node, so containers, VMs, and LXCs stay reachable to each other on the LAN. `0` = each guest's own subnet only. |
| `MULLVAD_LAN_SUBNET` | *(none)* | Extra subnet(s) to always allow, on top of auto-detect (space/comma separated) |
| `MULLVAD_COUNTRY_FILTER` | *(any)* | Restrict exit-node rotation to a country (e.g. `USA`) |
| `PVE_NODE` | `hostname -s` | Proxmox node to scan |
| `DRY_RUN` | `0` | `1` = enumerate & classify only, deploy nothing |
| `FORCE_REDEPLOY` | `0` | `1` = re-push assets and reload the ruleset on **already-protected** guests too (use to roll out config/asset changes to guests deployed by an earlier run) |

Every run writes a timestamped log to `/root/bulkvpn-<timestamp>.log` and prints a `SUCCESS / SKIPPED / FAILED` tally.

## How the kill-switch behaves once deployed

- `mullvad-killswitch.service` loads an nftables `output` chain with a default `drop` policy at boot. Only loopback, established/related flows, the `tailscale0` tunnel, Tailscale's marked underlay (`0x80000`), your LAN, and DHCP are allowed — everything else is dropped, so a dropped exit node never leaks your real IP.
- `mullvad-healthcheck.timer` runs `mullvad-rotate.sh --check-only` 2 minutes after boot and every 15 minutes, re-acquiring a working Mullvad exit node whenever connectivity is down.
- Manual controls inside a guest (as root): `mullvad-rotate.sh` (rotate now), `systemctl status mullvad-healthcheck.timer`, `tail -f /var/log/mullvad-rotate.log`.

## Caveats

- **LAN access is automatic.** Each guest's own directly-connected LAN subnet(s) are auto-detected (from its link routes, excluding loopback / link-local / the Tailscale CGNAT range) and allowed by the firewall, so SSH / web UIs stay reachable without configuration. In addition, a one-time pre-scan unions the LAN subnet(s) of *every* running container / VM / LXC on the node and allows that whole set on every guest, so guests stay reachable to each other on the same LAN subnet(s) they were on before — set `MULLVAD_LAN_INCLUDE_GUESTS=0` to allow only each guest's own subnet. If nothing is detectable the firewall falls back to the private RFC1918 ranges (never locks you out). Set `MULLVAD_LAN_SUBNET` to add extra subnets (e.g. a separate management VLAN), or `MULLVAD_LAN_AUTODETECT=0` to allow *only* what you list. On the Tailscale side, `--exit-node-allow-lan-access=true` is set automatically whenever an exit node is in use — the rotate script sets it on every node switch, and enrollment adds it too if you pin an exit node via `TS_EXTRA_ARGS` — so routing traffic through an exit node never blackholes direct access to your local network. Because `--exit-node-allow-lan-access` only exempts each guest's *own* directly-connected subnet, the rotate script additionally installs a high-priority `ip rule` (`to <subnet> lookup main`, priority 5200 — above Tailscale's diverter) for every allowed subnet, so traffic to *other* LAN subnets reached via the gateway egresses directly instead of being swallowed into the tunnel. That's what lets containers/VMs/LXCs on different subnets keep pinging each other once the kill-switch is active; the rules are runtime-only and re-asserted on every self-heal run (2 min after boot, then every 15 min).
- **Fail-closed ordering is enforced.** Tailscale + a visible Mullvad exit node are verified *before* the drop-policy firewall is loaded. A guest with no Mullvad exit node visible on the tailnet is **skipped** and left untouched rather than cut off — the kill-switch is only ever deployed where there's an endpoint to protect with.
- **nftables in LXC:** privileged containers work cleanly; unprivileged containers run the firewall in their own netns and usually work, but `/dev/net/tun` passthrough for Tailscale is more reliable in a privileged CT (a warning is logged).
- **systemd only.** The kill-switch ships as systemd units; non-systemd guests (Alpine/OpenRC, etc.) are detected and skipped.
- **VMs need qemu-guest-agent** installed and running, or they're skipped with a note.
- **The Proxmox host itself is never modified** (beyond loading the `tun` kernel module for LXC passthrough) — only guests are touched.

## Repository layout

```
bulkvpn-deploy.sh              # main script — run as root on the Proxmox host
assets/
  mullvad-rotate.sh            # → /usr/local/bin/ in each guest
  nftables/mullvad-killswitch.nft
  systemd/
    mullvad-killswitch.service
    mullvad-healthcheck.service
    mullvad-healthcheck.timer
```

The `assets/` files are the single source of truth (vendored verbatim from the upstream kill-switch repo). `bulkvpn-deploy.sh` embeds identical copies inline so it can provision guests without fetching anything — handy since the kill-switch itself blocks egress. If you edit an asset, mirror the change into the matching `asset_*()` heredoc in the script.

## Removing bulkvpn from individual guests

Deployment is idempotent, but there is no built-in *removal* — a guest stays
protected until you tear the kill-switch off it by hand. This section covers
peeling it back off one guest, or off several from the host, without touching
the guests you want to keep protected.

> **Order matters.** The firewall is fail-closed, so you **open egress before
> clearing the exit node** — otherwise the guest loses WAN the moment the exit
> node goes away but the drop-policy table is still loaded. The sequence below
> is already in the safe order.

> **If a guest is unreachable over the network**, don't rely on SSH — get in
> from the Proxmox host instead. For an LXC: `pct enter <ctid>`. For a VM: the
> noVNC console in the PVE web UI, or `qm terminal <vmid>`. Neither path
> traverses the guest's own networking, so a bad firewall state can't lock you
> out of the teardown.

### On a single guest (run as root inside the guest)

```bash
# 1. stop the self-healer + firewall so nothing re-asserts mid-teardown
systemctl disable --now mullvad-healthcheck.timer mullvad-healthcheck.service mullvad-killswitch.service 2>/dev/null

# 2. drop the fail-closed nft table -> egress open again (BEFORE clearing the exit node)
nft list tables | grep -i mullvad | while read _ fam name; do nft delete table $fam $name; done

# 3. clear the Mullvad exit node
tailscale set --exit-node= --exit-node-allow-lan-access=false

# 4. remove the runtime policy-routing rules the rotator installs (priority 5200)
while ip rule show | grep -q "^5200:"; do ip rule del priority 5200; done

# 5. delete the deployed assets + units
rm -f /usr/local/bin/mullvad-rotate.sh /var/log/mullvad-rotate.log
rm -f /etc/systemd/system/mullvad-killswitch.service \
      /etc/systemd/system/mullvad-healthcheck.service \
      /etc/systemd/system/mullvad-healthcheck.timer
systemctl daemon-reload
```

Step 1 is the important one: disabling `mullvad-healthcheck.timer` is what stops
the 15-minute rotator from re-pinning an exit node the moment you clear it.
Removing the unit files (step 5) is what keeps it from coming back on the next
reboot. Tailscale itself is left up and enrolled — only the Mullvad exit-node
routing and the kill-switch are removed.

### From the Proxmox host (per guest, no guest shell needed)

**LXC** — driven with `pct exec`, same mechanics the deploy script uses:

```bash
CTID=102
pct exec "$CTID" -- bash -c '
  systemctl disable --now mullvad-healthcheck.timer mullvad-healthcheck.service mullvad-killswitch.service 2>/dev/null
  nft list tables | grep -i mullvad | while read _ fam name; do nft delete table $fam $name; done
  tailscale set --exit-node= --exit-node-allow-lan-access=false
  while ip rule show | grep -q "^5200:"; do ip rule del priority 5200; done
  rm -f /usr/local/bin/mullvad-rotate.sh /var/log/mullvad-rotate.log \
        /etc/systemd/system/mullvad-killswitch.service \
        /etc/systemd/system/mullvad-healthcheck.{service,timer}
  systemctl daemon-reload
'
```

**VM** — via the QEMU guest agent (the VM needs `qemu-guest-agent` running, same
as at deploy time):

```bash
VMID=201
qm guest exec "$VMID" -- bash -c '
  systemctl disable --now mullvad-healthcheck.timer mullvad-healthcheck.service mullvad-killswitch.service 2>/dev/null
  nft list tables | grep -i mullvad | while read _ fam name; do nft delete table $fam $name; done
  tailscale set --exit-node= --exit-node-allow-lan-access=false
  while ip rule show | grep -q "^5200:"; do ip rule del priority 5200; done
  rm -f /usr/local/bin/mullvad-rotate.sh /var/log/mullvad-rotate.log \
        /etc/systemd/system/mullvad-killswitch.service \
        /etc/systemd/system/mullvad-healthcheck.{service,timer}
  systemctl daemon-reload
'
```

### Verifying the guest is clean

```bash
tailscale status | grep -i "exit node"        # no exit node -> returns nothing
ping -c3 8.8.8.8                               # back to normal WAN latency
curl -s https://am.i.mullvad.net/connected     # should report you are NOT connected via Mullvad
```

For a service with a web UI, also load it from another LAN box (not from inside
the guest) to confirm the earlier drop-policy isn't still blackholing LAN
replies — an in-guest `curl` to localhost will return `200` even while the
firewall is dropping traffic to other hosts.

### Note: a torn-down guest becomes a redeploy target

Deployment skips guests that are *already protected* and deploys to ones that
aren't. Once you tear the kill-switch off a guest, it counts as unprotected
again — so the **next plain run of `bulkvpn-deploy.sh` will redeploy to it.**
There is currently no deploy-time exclude list, so if you want a guest to stay
permanently unprotected, either don't re-run the deploy against that node, or
add an exclusion (see below).

## Credits & license

Kill-switch design and the vendored `assets/` files are from [tailscale-mullvad-killswitch](https://github.com/thelorax1775/tailscale-mullvad-killswitch); the bulk Proxmox deployment pattern is from [TailAdjuster](https://github.com/thelorax1775/TailAdjuster), both by [@thelorax1775](https://github.com/thelorax1775). Licensed under Apache-2.0 — see [LICENSE](LICENSE).
