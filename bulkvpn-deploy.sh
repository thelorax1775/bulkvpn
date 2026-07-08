#!/usr/bin/env bash
#
# bulkvpn-deploy.sh — bulk-deploy the Tailscale + Mullvad fail-closed
# kill-switch across every LXC container and VM on a Proxmox VE node.
#
# For each RUNNING guest it will, idempotently:
#   1. skip it if the kill-switch is already installed & scheduled,
#   2. skip it (with a warning) if the guest is not systemd-based,
#   3. install + enroll Tailscale if it isn't already on the tailnet,
#   4. verify a Mullvad exit node is available on the tailnet,
#   5. push in the kill-switch (nftables ruleset + rotate script + 3 systemd
#      units), enable the boot firewall, start the 15-minute self-heal timer,
#      and kick a first rotation so a verified exit node is selected.
#
# LXC guests are driven with `pct exec`; VMs via the QEMU guest agent
# (`qm guest exec`) — a VM therefore needs qemu-guest-agent installed & running.
#
# Run as root on the Proxmox host.
#
# Combines and builds on:
#   https://github.com/thelorax1775/tailscale-mullvad-killswitch
#   https://github.com/thelorax1775/TailAdjuster
#
# --------------------------------------------------------------------------
# Configuration (environment variables):
#   TS_AUTHKEY               (required) Tailscale auth key for enrollment
#   TS_LOGIN_SERVER          alt control server (e.g. Headscale); default: none
#   TS_HOSTNAME_PREFIX       hostname prefix; default: "ct-" (LXC) / "vm-" (VM)
#   TS_EXTRA_ARGS            extra flags appended to every `tailscale up`
#   MULLVAD_LAN_AUTODETECT   1 (default) = auto-allow each guest's own LAN subnet(s)
#   MULLVAD_LAN_INCLUDE_GUESTS 1 (default) = also allow every other running
#                            guest's LAN subnet(s) on the node, so containers,
#                            VMs, and LXCs stay reachable to each other on the LAN
#   MULLVAD_LAN_SUBNET       extra subnet(s) to always allow (space/comma sep); default: none
#   MULLVAD_COUNTRY_FILTER   limit rotation to a country (e.g. "USA"); default: any
#   PVE_NODE                 Proxmox node to scan; default: `hostname -s`
#   SELECT_GUESTS            space/comma-separated vmids to deploy to; default:
#                            unset. When unset and a terminal is attached, an
#                            interactive checklist (whiptail, or a numbered text
#                            prompt fallback) lets you pick which running guests
#                            get the kill-switch. When unset with no terminal
#                            (cron/pipe), every running guest is selected.
#   DRY_RUN                  1 = enumerate & classify only, change nothing
#   FORCE_REDEPLOY           1 = re-push assets to every guest even if already
#                            protected (use to roll out config/asset changes)
#
# Usage:  TS_AUTHKEY=tskey-... ./bulkvpn-deploy.sh [--help]
# --------------------------------------------------------------------------

set -Eeuo pipefail

### ---- Configuration -------------------------------------------------------
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_LOGIN_SERVER="${TS_LOGIN_SERVER:-}"
TS_HOSTNAME_PREFIX_LXC="${TS_HOSTNAME_PREFIX:-ct-}"
TS_HOSTNAME_PREFIX_VM="${TS_HOSTNAME_PREFIX:-vm-}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
MULLVAD_LAN_AUTODETECT="${MULLVAD_LAN_AUTODETECT:-1}"   # 1 = auto-allow each guest's own LAN
MULLVAD_LAN_INCLUDE_GUESTS="${MULLVAD_LAN_INCLUDE_GUESTS:-1}"  # 1 = also allow every other running guest's LAN subnet(s)
MULLVAD_LAN_SUBNET="${MULLVAD_LAN_SUBNET:-}"            # extra subnet(s) to always allow (space/comma sep)
MULLVAD_COUNTRY_FILTER="${MULLVAD_COUNTRY_FILTER:-}"
PVE_NODE="${PVE_NODE:-$(hostname -s)}"
SELECT_GUESTS="${SELECT_GUESTS:-}"      # space/comma vmids to deploy to; empty = menu (TTY) or all (no TTY)
DRY_RUN="${DRY_RUN:-0}"
FORCE_REDEPLOY="${FORCE_REDEPLOY:-0}"   # 1 = re-push to already-protected guests too

LXC_READY_TIMEOUT="${LXC_READY_TIMEOUT:-30}"
VM_AGENT_TIMEOUT="${VM_AGENT_TIMEOUT:-90}"
VM_EXEC_TIMEOUT="${VM_EXEC_TIMEOUT:-180}"
LOG_FILE="/root/bulkvpn-$(date '+%Y%m%d-%H%M%S').log"
### --------------------------------------------------------------------------

SUCCESS=0; SKIPPED=0; FAILED=0
SELECTED_IDS=""                         # space-separated vmids chosen for deploy

usage() { sed -n '2,48p' "$0"; }
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

# Output is mirrored to a timestamped log from inside main(), *after* the guest
# selection menu has run — whiptail draws on stderr, so the tee redirect must
# not be in effect while the menu is on screen.

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
inc()  { eval "$1=\$(( \${$1} + 1 ))"; }   # set -e-safe counter increment
die()  { log "FATAL: $*"; exit 1; }
# is_selected: true iff vmid $1 is in the chosen SELECTED_IDS set (exact-word
# match so "10" never matches "100").
is_selected() { [[ " $SELECTED_IDS " == *" $1 "* ]]; }

DRY=false;   [[ "$DRY_RUN" == "1" ]] && DRY=true
FORCE=false; [[ "$FORCE_REDEPLOY" == "1" ]] && FORCE=true

### ---- Embedded kill-switch assets ----------------------------------------
# Single source of truth lives in assets/; these heredocs are kept identical
# so the host can provision guests that have no working egress yet.

asset_rotate() {
cat <<'ROTATE_EOF'
#!/usr/bin/env bash
#
# mullvad-rotate.sh — rotate / self-heal the Tailscale + Mullvad exit node.
# Vendored by bulkvpn from tailscale-mullvad-killswitch.

set -euo pipefail

### ---- Configuration -------------------------------------------------------
COUNTRY_FILTER=""              # e.g. "USA"; empty = any country
ALLOW_LAN=true                 # keep LAN access to the web UI / SSH
LAN_SUBNETS=""                 # space-separated CIDRs to keep reachable directly
                               # (off the exit-node tunnel), e.g. other guests' LANs
LAN_BYPASS_PRIO=5200           # ip-rule priority (above Tailscale's ~5230 diverter)
LOG_FILE="/var/log/mullvad-rotate.log"
CHECK_TIMEOUT=8                # seconds per connectivity probe
TUNNEL_SETTLE=3                # seconds to wait after switching before probing
TAILSCALE="$(command -v tailscale || echo /usr/bin/tailscale)"
### --------------------------------------------------------------------------

CHECK_ONLY=false
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=true

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

[[ -x "$TAILSCALE" ]] || die "tailscale binary not found at '$TAILSCALE'"

# ensure_lan_bypass: keep the configured LAN subnets reachable *directly* while
# an exit node is active. Tailscale policy-routes the default route into the
# tunnel (ip rule at priority ~5230), which otherwise swallows traffic to other
# LAN subnets reached via the gateway (--exit-node-allow-lan-access only exempts
# the node's own directly-connected subnet). A higher-priority rule sends these
# subnets to the main table so they egress via the local gateway instead of the
# tunnel — so containers/VMs/LXCs on the LAN can still reach each other. These
# rules are runtime-only, so re-assert them on every run (idempotent).
ensure_lan_bypass() {
    [[ -n "$LAN_SUBNETS" ]] || return 0
    command -v ip >/dev/null 2>&1 || return 0
    local net
    for net in $LAN_SUBNETS; do
        [[ "$net" == */* ]] || continue
        ip rule del to "$net" lookup main priority "$LAN_BYPASS_PRIO" 2>/dev/null || true
        if ip rule add to "$net" lookup main priority "$LAN_BYPASS_PRIO" 2>/dev/null; then
            log "LAN bypass: $net -> main table (direct, off tunnel)"
        fi
    done
}

# Keep the LAN reachable before anything else, on every run (including
# --check-only heals), so a reboot that comes up healthy still restores it.
ensure_lan_bypass

verify_connectivity() {
    local host
    for host in 1.1.1.1 9.9.9.9; do
        if timeout "$CHECK_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/443" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

if $CHECK_ONLY; then
    if verify_connectivity; then
        log "check-only: tunnel healthy, no action"
        exit 0
    fi
    log "check-only: NO connectivity detected — acquiring a new node"
fi

list_cmd=("$TAILSCALE" exit-node list)
[[ -n "$COUNTRY_FILTER" ]] && list_cmd+=(--filter="$COUNTRY_FILTER")

mapfile -t NODES < <(
    "${list_cmd[@]}" \
        | awk '/mullvad\.ts\.net/ && tolower($0) !~ /offline/ { print $2 }' \
        | sort -u
)
(( ${#NODES[@]} > 0 )) || die "no online Mullvad exit nodes found${COUNTRY_FILTER:+ for '$COUNTRY_FILTER'}"

CURRENT=""
if command -v jq >/dev/null 2>&1; then
    CURRENT="$("$TAILSCALE" status --json 2>/dev/null \
        | jq -r '.. | objects | select(.ExitNode? == true) | .DNSName? // empty' \
        | sed 's/\.$//' | head -n1)"
fi

mapfile -t ORDER < <(printf '%s\n' "${NODES[@]}" | grep -vxF "${CURRENT:-__none__}" | shuf)
[[ -n "$CURRENT" ]] && ORDER+=("$CURRENT")

LABEL=""; $CHECK_ONLY && LABEL="[heal] "
log "${LABEL}Selecting from ${#NODES[@]} candidates (current: ${CURRENT:-none})"

for TARGET in "${ORDER[@]}"; do
    log "Trying $TARGET ..."
    if ! "$TAILSCALE" set --exit-node="$TARGET" --exit-node-allow-lan-access="$ALLOW_LAN"; then
        log "WARN: could not set $TARGET, trying next"
        continue
    fi
    sleep "$TUNNEL_SETTLE"
    if verify_connectivity; then
        log "OK: traffic verified through $TARGET"
        exit 0
    fi
    log "WARN: $TARGET set but no connectivity — re-acquiring"
done

die "exhausted ${#NODES[@]} candidates with no working tunnel — egress remains blocked by kill-switch (no leak)"
ROTATE_EOF
}

asset_nft() {
cat <<'NFT_EOF'
#!/usr/sbin/nft -f
# mullvad-killswitch.nft — fail-closed egress firewall (vendored by bulkvpn).

define LAN = 192.168.1.0/24

add table inet mullvad_killswitch
delete table inet mullvad_killswitch
table inet mullvad_killswitch {
    chain output {
        type filter hook output priority 0; policy drop;

        oif "lo" accept
        ct state established,related accept

        oifname "tailscale0" accept

        meta mark and 0xff0000 == 0x80000 accept

        ip daddr $LAN accept

        udp dport 67 accept
    }
}
NFT_EOF
}

asset_killswitch_service() {
cat <<'KS_EOF'
[Unit]
Description=Mullvad/Tailscale fail-closed kill-switch (nftables)
Wants=network-pre.target
Before=network-pre.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/mullvad-killswitch.nft

[Install]
WantedBy=multi-user.target
KS_EOF
}

asset_healthcheck_service() {
cat <<'HC_EOF'
[Unit]
Description=Self-heal Tailscale/Mullvad exit node if connectivity is down
After=tailscaled.service mullvad-killswitch.service
Wants=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mullvad-rotate.sh --check-only
HC_EOF
}

asset_healthcheck_timer() {
cat <<'HT_EOF'
[Unit]
Description=Check Mullvad exit-node connectivity every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
HT_EOF
}

# Templated variants (apply per-deployment config).
rotate_templated() {   # $1 = space-separated LAN subnets to keep off the tunnel
    asset_rotate \
        | sed "s|^COUNTRY_FILTER=.*|COUNTRY_FILTER=\"${MULLVAD_COUNTRY_FILTER}\"|" \
        | sed "s|^LAN_SUBNETS=.*|LAN_SUBNETS=\"${1}\"|"
}
nft_templated() {   # $1 = LAN value for the nft `define LAN` line (e.g. "{ 192.168.1.0/24 }")
    asset_nft | sed "s|^define LAN = .*|define LAN = ${1}|"
}

# Union of every running guest's own LAN subnet(s), collected up-front by
# collect_guest_lans() so each guest can be kept reachable to all the others.
GUEST_LAN_SET=""

# resolve_lan_list: echo a space-separated list of subnets to keep reachable for
# one guest — the guest's own auto-detected LAN(s), every other running guest's
# LAN(s) on the node, plus any operator-specified extras, falling back to the
# RFC1918 private ranges so a guest is never locked out.
resolve_lan_list() {   # engine id
    local detected="" extras="" guests="" all
    if [[ "$MULLVAD_LAN_AUTODETECT" == "1" ]]; then
        detected="$(run_guest "$1" "$2" "$CMD_DETECT_LAN" 2>/dev/null | tr -d '\r')"
    fi
    [[ "$MULLVAD_LAN_INCLUDE_GUESTS" == "1" ]] && guests="$GUEST_LAN_SET"
    extras="$(printf '%s' "$MULLVAD_LAN_SUBNET" | tr ',' ' ')"
    # normalise to one CIDR per line, keep only things that look like subnets, dedupe.
    all="$(printf '%s %s %s\n' "$extras" "$detected" "$guests" | tr ' ' '\n' | grep -E '/[0-9]+$' | sort -u || true)"
    [[ -n "$all" ]] || all=$'10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16'
    printf '%s' "$(printf '%s\n' "$all" | paste -sd' ' -)"
}

# lan_nft_set: turn a space-separated subnet list into an nft set literal,
# e.g. "192.168.1.0/24 192.168.2.0/24" -> "{ 192.168.1.0/24, 192.168.2.0/24 }".
lan_nft_set() {   # "a b c"
    local list
    list="$(printf '%s' "$1" | tr ' ' '\n' | grep -E '/[0-9]+$' | paste -sd, - | sed 's/,/, /g')"
    printf '{ %s }' "$list"
}

### ---- In-guest command snippets ------------------------------------------
GUEST_PM='pm_install(){ if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y >/dev/null && apt-get install -y "$@"; elif command -v dnf >/dev/null 2>&1; then dnf install -y "$@"; elif command -v yum >/dev/null 2>&1; then yum install -y "$@"; else echo "no supported package manager"; return 1; fi; }'

CMD_HAS_SYSTEMD='test -d /run/systemd/system'
CMD_TS_ACTIVE='command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 && tailscale status 2>/dev/null | grep -q "100\."'
CMD_PROTECTED='test -x /usr/local/bin/mullvad-rotate.sh && systemctl is-enabled --quiet mullvad-killswitch.service && systemctl is-active --quiet mullvad-healthcheck.timer'
CMD_MULLVAD_AVAIL='tailscale exit-node list 2>/dev/null | grep -qi "mullvad.ts.net"'
# Print the guest's own directly-connected IPv4 LAN subnet(s), excluding
# loopback, link-local, and the Tailscale CGNAT range (100.64.0.0/10).
CMD_DETECT_LAN='ip -o -4 route show scope link 2>/dev/null | cut -d" " -f1 | grep "/" | grep -vE "^(127|169\.254|100)\." | sort -u | tr "\n" " "'
CMD_INSTALL_TS="$GUEST_PM"'; command -v curl >/dev/null 2>&1 || pm_install curl ca-certificates; curl -fsSL https://tailscale.com/install.sh | sh'
CMD_INSTALL_KS_DEPS="$GUEST_PM"'; command -v nft >/dev/null 2>&1 || pm_install nftables; command -v jq >/dev/null 2>&1 || pm_install jq; mkdir -p /etc/nftables.d /etc/systemd/system'
# Use restart (not just enable --now) so a re-push actually reloads the freshly
# templated nft ruleset / units — enable --now is a no-op on an already-active
# oneshot service and would leave the old LAN set loaded in the kernel.
CMD_ENABLE='systemctl daemon-reload && systemctl enable mullvad-killswitch.service && systemctl restart mullvad-killswitch.service && systemctl enable mullvad-healthcheck.timer && systemctl restart mullvad-healthcheck.timer'
CMD_KICK='/usr/local/bin/mullvad-rotate.sh'
CMD_VERIFY='test -x /usr/local/bin/mullvad-rotate.sh && systemctl is-active --quiet mullvad-healthcheck.timer && nft list table inet mullvad_killswitch >/dev/null 2>&1'

### ---- Host prerequisites ---------------------------------------------------
require_host_tools() {
    local t
    for t in pvesh pct qm jq base64; do
        command -v "$t" >/dev/null 2>&1 || die "required host tool not found: $t"
    done
    [[ -n "$TS_AUTHKEY" ]] || die "TS_AUTHKEY is required (Tailscale auth key)"
}

sanitize_hostname() { printf '%s' "$1" | tr -c 'a-zA-Z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//'; }

build_up_cmd() {   # $1 hostname -> echoes the in-guest `tailscale up ...` command
    local host="$1" cmd
    cmd="tailscale up --authkey='${TS_AUTHKEY}' --hostname='${host}'"
    [[ -n "$TS_LOGIN_SERVER" ]] && cmd+=" --login-server='${TS_LOGIN_SERVER}'"
    [[ -n "$TS_EXTRA_ARGS"   ]] && cmd+=" ${TS_EXTRA_ARGS}"
    # If an exit node is used at enrollment (e.g. pinned via TS_EXTRA_ARGS),
    # allow direct LAN access automatically so we don't lose the web UI / SSH
    # to the tunnel before the first rotation. Skip if the caller set it.
    if [[ "$cmd" == *--exit-node* && "$cmd" != *--exit-node-allow-lan-access* ]]; then
        cmd+=" --exit-node-allow-lan-access=true"
    fi
    printf '%s' "$cmd"
}

### ---- Generic guest exec / file push -------------------------------------
# vm_guest_exec: run a command in a VM via the guest agent; echoes out-data,
# returns the guest command's exit code.
vm_guest_exec() {
    local vmid="$1" cmd="$2" json rc out
    json="$(qm guest exec "$vmid" --timeout "$VM_EXEC_TIMEOUT" -- bash -c "$cmd" 2>/dev/null)" || return 90
    rc="$(printf '%s' "$json"  | jq -r '.exitcode // empty' 2>/dev/null)"
    out="$(printf '%s' "$json" | jq -r '."out-data" // empty' 2>/dev/null)"
    [[ -n "$out" ]] && printf '%s' "$out"
    [[ -n "$rc" ]] || rc=91
    return "$rc"
}

run_guest() {   # engine id cmd
    case "$1" in
        lxc) pct exec "$2" -- bash -c "$3" ;;
        vm)  vm_guest_exec "$2" "$3" ;;
    esac
}

push_file() {   # engine id path mode   (file content on stdin)
    local engine="$1" id="$2" path="$3" mode="$4" b64 dir cmd
    b64="$(base64 -w0)"
    dir="$(dirname "$path")"
    cmd="mkdir -p '$dir' && printf '%s' '$b64' | base64 -d > '$path' && chmod $mode '$path'"
    run_guest "$engine" "$id" "$cmd"
}

### ---- LXC helpers ----------------------------------------------------------
lxc_is_unprivileged() { grep -q '^unprivileged: 1' "/etc/pve/lxc/${1}.conf" 2>/dev/null; }

wait_for_lxc_ready() {
    local vmid="$1" i
    for (( i=0; i<LXC_READY_TIMEOUT; i++ )); do
        pct exec "$vmid" -- true >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

enable_tun_lxc() {   # returns 0 = no change, 1 = changed (reboot needed)
    local vmid="$1" changed=0
    local conf="/etc/pve/lxc/${vmid}.conf"
    if ! grep -q '^lxc.cgroup2.devices.allow: c 10:200 rwm' "$conf" 2>/dev/null; then
        echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> "$conf"; changed=1
    fi
    if ! grep -q '^lxc.mount.entry: /dev/net/tun' "$conf" 2>/dev/null; then
        echo 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >> "$conf"; changed=1
    fi
    return $changed
}

### ---- VM helpers -----------------------------------------------------------
vm_agent_ready() { qm guest cmd "$1" ping >/dev/null 2>&1; }

wait_for_vm_agent() {
    local vmid="$1" i
    for (( i=0; i<VM_AGENT_TIMEOUT; i++ )); do
        vm_agent_ready "$vmid" && return 0
        sleep 1
    done
    return 1
}

### ---- Kill-switch deployment (engine-agnostic) ----------------------------
deploy_killswitch() {   # engine id label
    local engine="$1" id="$2" label="$3"

    log "  [$label] installing kill-switch dependencies (nftables, jq)"
    run_guest "$engine" "$id" "$CMD_INSTALL_KS_DEPS" \
        || { log "  [$label] FAILED to install dependencies"; return 1; }

    local lan_list lan_set
    lan_list="$(resolve_lan_list "$engine" "$id")"
    lan_set="$(lan_nft_set "$lan_list")"
    log "  [$label] LAN kept reachable: $lan_set"

    log "  [$label] pushing kill-switch assets"
    rotate_templated "$lan_list"  | push_file "$engine" "$id" /usr/local/bin/mullvad-rotate.sh 755 || return 1
    nft_templated "$lan_set"      | push_file "$engine" "$id" /etc/nftables.d/mullvad-killswitch.nft 644 || return 1
    asset_killswitch_service    | push_file "$engine" "$id" /etc/systemd/system/mullvad-killswitch.service 644 || return 1
    asset_healthcheck_service   | push_file "$engine" "$id" /etc/systemd/system/mullvad-healthcheck.service 644 || return 1
    asset_healthcheck_timer     | push_file "$engine" "$id" /etc/systemd/system/mullvad-healthcheck.timer 644 || return 1

    log "  [$label] enabling firewall service + 15-min self-heal timer"
    run_guest "$engine" "$id" "$CMD_ENABLE" || { log "  [$label] FAILED to enable units"; return 1; }

    log "  [$label] kicking first rotation to select a verified exit node"
    if ! run_guest "$engine" "$id" "$CMD_KICK"; then
        log "  [$label] WARN: initial rotation did not verify a tunnel (timer will keep retrying)"
    fi

    run_guest "$engine" "$id" "$CMD_VERIFY" \
        || { log "  [$label] FAILED post-deploy verification"; return 1; }
    return 0
}

### ---- Per-guest orchestration ---------------------------------------------
process_lxc() {
    local vmid="$1" name="$2" label host reboot=0
    label="ct/${vmid} (${name})"
    host="$(sanitize_hostname "${TS_HOSTNAME_PREFIX_LXC}${name}")"
    log "LXC $label"

    if run_guest lxc "$vmid" "$CMD_PROTECTED"; then
        if ! $FORCE; then
            log "  [$label] SKIP — kill-switch already installed & scheduled (set FORCE_REDEPLOY=1 to re-push)"; inc SKIPPED; return 0
        fi
        log "  [$label] FORCE_REDEPLOY — re-pushing assets to already-protected guest"
    fi
    if ! run_guest lxc "$vmid" "$CMD_HAS_SYSTEMD"; then
        log "  [$label] SKIP — guest is not systemd-based"; inc SKIPPED; return 0
    fi
    if $DRY; then
        log "  [$label] WOULD deploy (dry run)"; inc SKIPPED; return 0
    fi

    # Tailscale layer.
    if ! run_guest lxc "$vmid" "$CMD_TS_ACTIVE"; then
        lxc_is_unprivileged "$vmid" && log "  [$label] WARN: unprivileged CT — /dev/net/tun may need a privileged container"
        if enable_tun_lxc "$vmid"; then :; else reboot=1; fi
        if (( reboot )); then
            log "  [$label] added /dev/net/tun to config — rebooting CT"
            pct reboot "$vmid" >/dev/null 2>&1 || true
            wait_for_lxc_ready "$vmid" || { log "  [$label] FAILED — CT not ready after reboot"; inc FAILED; return 0; }
        fi
        log "  [$label] installing Tailscale"
        run_guest lxc "$vmid" "$CMD_INSTALL_TS" || { log "  [$label] FAILED to install Tailscale"; inc FAILED; return 0; }
        log "  [$label] enrolling into tailnet as '$host'"
        if ! run_guest lxc "$vmid" "$(build_up_cmd "$host")"; then
            log "  [$label] join failed — rebooting and retrying once"
            pct reboot "$vmid" >/dev/null 2>&1 || true
            wait_for_lxc_ready "$vmid" || true
            run_guest lxc "$vmid" "$(build_up_cmd "$host")" \
                || { log "  [$label] FAILED to join tailnet"; inc FAILED; return 0; }
        fi
    else
        log "  [$label] Tailscale already active"
    fi

    if ! run_guest lxc "$vmid" "$CMD_MULLVAD_AVAIL"; then
        log "  [$label] SKIP — no Mullvad exit node visible on tailnet (nothing to protect with)"; inc SKIPPED; return 0
    fi

    if deploy_killswitch lxc "$vmid" "$label"; then
        log "  [$label] SUCCESS — kill-switch deployed & scheduled"; inc SUCCESS
    else
        inc FAILED
    fi
}

process_vm() {
    local vmid="$1" name="$2" label host
    label="vm/${vmid} (${name})"
    host="$(sanitize_hostname "${TS_HOSTNAME_PREFIX_VM}${name}")"
    log "VM $label"

    if ! wait_for_vm_agent "$vmid"; then
        log "  [$label] SKIP — qemu-guest-agent not responding (install & start it in the guest)"; inc SKIPPED; return 0
    fi
    if run_guest vm "$vmid" "$CMD_PROTECTED"; then
        if ! $FORCE; then
            log "  [$label] SKIP — kill-switch already installed & scheduled (set FORCE_REDEPLOY=1 to re-push)"; inc SKIPPED; return 0
        fi
        log "  [$label] FORCE_REDEPLOY — re-pushing assets to already-protected guest"
    fi
    if ! run_guest vm "$vmid" "$CMD_HAS_SYSTEMD"; then
        log "  [$label] SKIP — guest is not systemd-based"; inc SKIPPED; return 0
    fi
    if $DRY; then
        log "  [$label] WOULD deploy (dry run)"; inc SKIPPED; return 0
    fi

    if ! run_guest vm "$vmid" "$CMD_TS_ACTIVE"; then
        log "  [$label] installing Tailscale"
        run_guest vm "$vmid" "$CMD_INSTALL_TS" || { log "  [$label] FAILED to install Tailscale"; inc FAILED; return 0; }
        log "  [$label] enrolling into tailnet as '$host'"
        if ! run_guest vm "$vmid" "$(build_up_cmd "$host")"; then
            log "  [$label] join failed — rebooting and retrying once"
            qm reboot "$vmid" >/dev/null 2>&1 || true
            wait_for_vm_agent "$vmid" || true
            run_guest vm "$vmid" "$(build_up_cmd "$host")" \
                || { log "  [$label] FAILED to join tailnet"; inc FAILED; return 0; }
        fi
    else
        log "  [$label] Tailscale already active"
    fi

    if ! run_guest vm "$vmid" "$CMD_MULLVAD_AVAIL"; then
        log "  [$label] SKIP — no Mullvad exit node visible on tailnet (nothing to protect with)"; inc SKIPPED; return 0
    fi

    if deploy_killswitch vm "$vmid" "$label"; then
        log "  [$label] SUCCESS — kill-switch deployed & scheduled"; inc SUCCESS
    else
        inc FAILED
    fi
}

### ---- Guest enumeration & selection ---------------------------------------
# list_guests: echo TSV rows "vmid<TAB>status<TAB>name" for one engine.
list_guests() {   # lxc | qemu
    pvesh get "/nodes/$PVE_NODE/$1" --output-format json \
        | jq -r '.[] | [.vmid, .status, .name] | @tsv'
}

# select_guests: populate SELECTED_IDS with the vmids to deploy to. Enumerates
# the RUNNING guests once, then resolves the selection from (in priority order):
#   1. SELECT_GUESTS       — explicit space/comma vmid list (non-interactive)
#   2. no terminal         — every running guest (historical default; cron/pipe)
#   3. whiptail checklist  — interactive TUI, all guests pre-checked
#   4. numbered text prompt — fallback when whiptail is absent
select_guests() {
    local vmid status name eng elabel
    local -a run_ids=() run_desc=()
    for eng in lxc qemu; do
        [[ "$eng" == "lxc" ]] && elabel="ct" || elabel="vm"
        while IFS=$'\t' read -r vmid status name; do
            [[ "$status" == "running" ]] || continue
            run_ids+=("$vmid")
            run_desc+=("$elabel  ${name:-<noname>}")
        done < <(list_guests "$eng")
    done

    (( ${#run_ids[@]} > 0 )) || die "no running guests found on node '$PVE_NODE'"

    # 1. Explicit non-interactive selection.
    if [[ -n "$SELECT_GUESTS" ]]; then
        local tok
        for tok in $(printf '%s' "$SELECT_GUESTS" | tr ',' ' '); do
            if printf '%s\n' "${run_ids[@]}" | grep -qxF "$tok"; then
                SELECTED_IDS+=" $tok"
            else
                log "WARN: SELECT_GUESTS id '$tok' is not a running guest on '$PVE_NODE' — ignoring"
            fi
        done
        SELECTED_IDS="$(printf '%s\n' $SELECTED_IDS | sort -un | paste -sd' ' -)"
        [[ -n "$SELECTED_IDS" ]] || die "SELECT_GUESTS matched no running guests"
        return 0
    fi

    # 2. No terminal → historical behavior: every running guest.
    if [[ ! -t 0 || ! -t 1 ]]; then
        SELECTED_IDS="$(printf '%s ' "${run_ids[@]}")"
        log "No terminal attached and SELECT_GUESTS unset — deploying to all running guests."
        return 0
    fi

    # 3. Interactive whiptail checklist.
    if command -v whiptail >/dev/null 2>&1; then
        local -a items=() ; local i rc=0 chosen
        for i in "${!run_ids[@]}"; do
            items+=("${run_ids[$i]}" "${run_desc[$i]}" ON)
        done
        chosen="$(whiptail --title "bulkvpn — select guests" \
            --checklist "Space toggles, Enter confirms. Deploy the kill-switch to:" \
            20 72 "$(( ${#run_ids[@]} < 12 ? ${#run_ids[@]} : 12 ))" \
            "${items[@]}" 3>&1 1>&2 2>&3)" || rc=$?
        (( rc == 0 )) || { log "Selection cancelled — nothing deployed."; exit 0; }
        SELECTED_IDS="$(printf '%s' "$chosen" | tr -d '"')"   # tags come back quoted
        [[ -n "$SELECTED_IDS" ]] || { log "No guests selected — nothing deployed."; exit 0; }
        return 0
    fi

    # 4. Plain numbered text fallback.
    local i tok reply
    printf '\nSelect guests to deploy the kill-switch to (node %s):\n\n' "$PVE_NODE"
    for i in "${!run_ids[@]}"; do
        printf '  %2d) %-8s %s\n' "$(( i + 1 ))" "${run_ids[$i]}" "${run_desc[$i]}"
    done
    printf '\nEnter list numbers and/or vmids separated by spaces, or "all" [all]: '
    read -r reply || reply="all"
    if [[ -z "$reply" || "$reply" == "all" ]]; then
        SELECTED_IDS="$(printf '%s ' "${run_ids[@]}")"; return 0
    fi
    for tok in $reply; do
        if printf '%s\n' "${run_ids[@]}" | grep -qxF "$tok"; then
            SELECTED_IDS+=" $tok"                                 # a vmid
        elif [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#run_ids[@]} )); then
            SELECTED_IDS+=" ${run_ids[$(( tok - 1 ))]}"           # a list index
        else
            log "WARN: '$tok' is neither a listed number nor a running vmid — ignoring"
        fi
    done
    SELECTED_IDS="$(printf '%s\n' $SELECTED_IDS | sort -un | paste -sd' ' -)"
    [[ -n "$SELECTED_IDS" ]] || { log "No valid guests selected — nothing deployed."; exit 0; }
}

### ---- Cross-guest LAN discovery -------------------------------------------
# collect_guest_lans: sweep every RUNNING guest once up-front and union their
# directly-connected LAN subnet(s) into GUEST_LAN_SET, so resolve_lan() can keep
# each guest reachable to all the other containers/VMs/LXCs on the LAN — not
# just to its own subnet. Read-only (`ip route`), so it is safe in DRY_RUN too.
collect_guest_lans() {
    [[ "$MULLVAD_LAN_INCLUDE_GUESTS" == "1" ]] || return 0
    local vmid status name detected subs=""

    log "Pre-scan: collecting LAN subnets across all running guests ..."
    while IFS=$'\t' read -r vmid status name; do
        [[ "$status" == "running" ]] || continue
        detected="$(run_guest lxc "$vmid" "$CMD_DETECT_LAN" 2>/dev/null | tr -d '\r')" || true
        [[ -n "$detected" ]] && subs+=" $detected"
    done < <(list_guests lxc)

    while IFS=$'\t' read -r vmid status name; do
        [[ "$status" == "running" ]] || continue
        vm_agent_ready "$vmid" || continue   # unreachable VMs are simply not counted
        detected="$(run_guest vm "$vmid" "$CMD_DETECT_LAN" 2>/dev/null | tr -d '\r')" || true
        [[ -n "$detected" ]] && subs+=" $detected"
    done < <(list_guests qemu)

    GUEST_LAN_SET="$(printf '%s' "$subs" | tr ' ' '\n' | grep -E '/[0-9]+$' | sort -u | tr '\n' ' ')"
    if [[ -n "$GUEST_LAN_SET" ]]; then
        log "Pre-scan: guest LAN subnets kept reachable everywhere: ${GUEST_LAN_SET}"
    else
        log "Pre-scan: no guest LAN subnets detected"
    fi
}

### ---- Main -----------------------------------------------------------------
main() {
    require_host_tools

    # Pick which guests to deploy to *before* redirecting output — whiptail draws
    # on stderr, so the tee redirect below must not be active during the menu.
    select_guests

    # Mirror all output to a timestamped log from here on.
    exec > >(tee -a "$LOG_FILE") 2>&1

    log "bulkvpn — Mullvad kill-switch bulk deploy"
    local lanmode; [[ "$MULLVAD_LAN_AUTODETECT" == "1" ]] && lanmode="auto${MULLVAD_LAN_SUBNET:+ +($MULLVAD_LAN_SUBNET)}" || lanmode="${MULLVAD_LAN_SUBNET:-RFC1918}"
    [[ "$MULLVAD_LAN_INCLUDE_GUESTS" == "1" ]] && lanmode+=" +all-guests"
    log "Node: $PVE_NODE   LAN: $lanmode   Country: ${MULLVAD_COUNTRY_FILTER:-any}   Dry-run: $DRY   Force-redeploy: $FORCE"
    log "Selected guests: $SELECTED_IDS"
    log "Log:  $LOG_FILE"
    log "----------------------------------------------------------------------"

    # Ensure the tun module is available on the host for LXC TUN passthrough.
    if ! lsmod | grep -qw '^tun'; then
        modprobe tun 2>/dev/null || log "WARN: could not modprobe tun on host"
        grep -qxF tun /etc/modules-load.d/tun.conf 2>/dev/null || echo tun >> /etc/modules-load.d/tun.conf 2>/dev/null || true
    fi

    # Union every running guest's LAN subnet(s) first, so each guest's firewall
    # can keep all the other containers/VMs/LXCs on the LAN reachable.
    collect_guest_lans
    log "----------------------------------------------------------------------"

    log "Scanning LXC containers on $PVE_NODE ..."
    while IFS=$'\t' read -r vmid status name; do
        [[ "$status" == "running" ]] || { log "LXC ct/${vmid} (${name}) SKIP — not running"; inc SKIPPED; continue; }
        is_selected "$vmid" || { log "LXC ct/${vmid} (${name}) SKIP — not selected"; inc SKIPPED; continue; }
        process_lxc "$vmid" "$name" || log "LXC ct/${vmid}: unexpected error (continuing)"
    done < <(list_guests lxc)

    log "----------------------------------------------------------------------"
    log "Scanning VMs on $PVE_NODE ..."
    while IFS=$'\t' read -r vmid status name; do
        [[ "$status" == "running" ]] || { log "VM vm/${vmid} (${name}) SKIP — not running"; inc SKIPPED; continue; }
        is_selected "$vmid" || { log "VM vm/${vmid} (${name}) SKIP — not selected"; inc SKIPPED; continue; }
        process_vm "$vmid" "$name" || log "VM vm/${vmid}: unexpected error (continuing)"
    done < <(list_guests qemu)

    log "----------------------------------------------------------------------"
    log "Done.  SUCCESS=$SUCCESS  SKIPPED=$SKIPPED  FAILED=$FAILED"
    log "Full log: $LOG_FILE"
    (( FAILED == 0 ))
}

main "$@"
