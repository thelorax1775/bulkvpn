# bulkvpn

**Bulk-deploy the Tailscale + Mullvad fail-closed kill-switch across every LXC container and VM on a Proxmox VE node — in one command.**

`bulkvpn` walks every *running* guest on a Proxmox node and, for any guest that isn't already protected, it installs Tailscale (if missing), enrolls it into your tailnet, then deploys and schedules the [Mullvad kill-switch](https://github.com/thelorax1775/tailscale-mullvad-killswitch): an nftables fail-closed egress firewall plus a self-healing exit-node rotator on a 15-minute timer. Re-runs are idempotent — already-protected guests are skipped.

It combines two upstream projects by [@thelorax1775](https://github.com/thelorax1775):

- **[tailscale-mullvad-killswitch](https://github.com/thelorax1775/tailscale-mullvad-killswitch)** — the per-host fail-closed setup (nftables ruleset + `mullvad-rotate.sh` + systemd units). Its files are vendored verbatim in [`assets/`](assets/).
- **[TailAdjuster](https://github.com/thelorax1775/TailAdjuster)** — the bulk "scan every LXC/VM on a Proxmox node and act on each" pattern. `bulkvpn`'s enumeration, `pct exec` / `qm guest exec` mechanics, TUN handling, and idempotency checks follow it.

## What it does per guest

```
enumerate running LXC + VMs on the node
  └─ for each guest:
       already protected?          → SKIP
       not systemd-based?          → SKIP (warn)  [kill-switch ships as systemd units]
       Tailscale not on tailnet?   → install + enroll (needs TS_AUTHKEY)
       no Mullvad exit node seen?  → SKIP (no endpoint to protect with; never fail-close)
       deploy kill-switch:
         push 5 assets, template LAN subnet + country filter,
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
```

By default each guest's own LAN subnet is **auto-detected and kept reachable**, so SSH / web UIs stay up without you having to specify anything.

### Configuration (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `TS_AUTHKEY` | *(required)* | Tailscale auth key used to enroll guests that aren't on the tailnet |
| `TS_LOGIN_SERVER` | *(none)* | Alternative control server (e.g. Headscale) |
| `TS_HOSTNAME_PREFIX` | `ct-` (LXC) / `vm-` (VM) | Prefix for each guest's tailnet hostname |
| `TS_EXTRA_ARGS` | *(none)* | Extra flags appended to every `tailscale up` |
| `MULLVAD_LAN_AUTODETECT` | `1` | Auto-detect and allow each guest's own LAN subnet(s). `0` = don't. |
| `MULLVAD_LAN_SUBNET` | *(none)* | Extra subnet(s) to always allow, on top of auto-detect (space/comma separated) |
| `MULLVAD_COUNTRY_FILTER` | *(any)* | Restrict exit-node rotation to a country (e.g. `USA`) |
| `PVE_NODE` | `hostname -s` | Proxmox node to scan |
| `DRY_RUN` | `0` | `1` = enumerate & classify only, deploy nothing |

Every run writes a timestamped log to `/root/bulkvpn-<timestamp>.log` and prints a `SUCCESS / SKIPPED / FAILED` tally.

## How the kill-switch behaves once deployed

- `mullvad-killswitch.service` loads an nftables `output` chain with a default `drop` policy at boot. Only loopback, established/related flows, the `tailscale0` tunnel, Tailscale's marked underlay (`0x80000`), your LAN, and DHCP are allowed — everything else is dropped, so a dropped exit node never leaks your real IP.
- `mullvad-healthcheck.timer` runs `mullvad-rotate.sh --check-only` 2 minutes after boot and every 15 minutes, re-acquiring a working Mullvad exit node whenever connectivity is down.
- Manual controls inside a guest (as root): `mullvad-rotate.sh` (rotate now), `systemctl status mullvad-healthcheck.timer`, `tail -f /var/log/mullvad-rotate.log`.

## Caveats

- **LAN access is automatic.** Each guest's own directly-connected LAN subnet(s) are auto-detected (from its link routes, excluding loopback / link-local / the Tailscale CGNAT range) and allowed by the firewall, so SSH / web UIs stay reachable without configuration. If nothing is detectable the firewall falls back to the private RFC1918 ranges (never locks you out). Set `MULLVAD_LAN_SUBNET` to add extra subnets (e.g. a separate management VLAN), or `MULLVAD_LAN_AUTODETECT=0` to allow *only* what you list.
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

## Credits & license

Kill-switch design and the vendored `assets/` files are from [tailscale-mullvad-killswitch](https://github.com/thelorax1775/tailscale-mullvad-killswitch); the bulk Proxmox deployment pattern is from [TailAdjuster](https://github.com/thelorax1775/TailAdjuster), both by [@thelorax1775](https://github.com/thelorax1775). Licensed under Apache-2.0 — see [LICENSE](LICENSE).
